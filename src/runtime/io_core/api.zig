// 平台无关的 I/O 核心类型、错误集与抽象定义（api.zig）
//
// 职责
//   - 定义 linux.zig / darwin.zig / windows.zig 共用的类型与错误，由 mod.zig 按 builtin.os.tag 分派到具体实现；
//   - 不包含任何平台特定代码，仅声明 Completion、SendFileError、InitOptions、BufferPool、ChunkAllocator 等契约。
//
// 三层漏斗（详见 docs/IO_CORE_ROADMAP.md）
//   - 底层 I/O：已压榨（io_uring/kqueue/IOCP 批量、零拷贝、SoA 等）；
//   - Buffer 调度：ChunkAllocator 提供「全局 Slab」接口，目标为每线程本地无锁栈 + 与全局批量交换，消除锁争用；
//   - 协议解析：SIMD 向量化 + 零拷贝 []const u8 引用（见 io_core/simd_scan.zig 与上层解析器）。
//
// 主要类型
//   - SendFileError：零拷贝 sendFile / TransmitFile 可能返回的错误集；
//   - Completion：单次 I/O 完成项，pollCompletions 返回的元素，含 user_data、buffer_ptr、len、err；
//   - InitOptions：初始化选项（max_connections、max_completions），各平台可扩展；
//   - BufferPool：64-byte 对齐的缓冲池，供内核注册或用户态写入，再借给 JSC（Buffer 继承，§1.6）。
//
// 大文件 / 大模型读取（能力与建议）
//   - 当前 io_core 主场景：高并发 accept + 首包 recv（64KB 池）、文件→网络 sendFile/TransmitFile。
//   - 读大文件：上层 Shu.fs.readSync 若用 readToEndAlloc 一次性读入整文件，大模型（几 GB～几百 GB）易 OOM、延迟高；
//   - 优化（§1.7）：大文件只读用 mmap（mapFileReadOnly，见 mmap.zig），零拷贝、按需换页；流式可扩展 submitReadFile + 大块 buffer。
//   - 入口：io_core.mapFileReadOnly / mapFileReadWrite；fs 层可在大文件 + encoding:null 时选用。
//
// 调用约定
//   - BufferPool.allocAligned / allocHugePages（仅 Linux）/ allocLargePagesWindows（仅 Windows）返回的池由调用方 deinit；Completion 切片有效期至下一次 pollCompletions 前。
//
// HighPerfIO 统一 I/O 契约（各 backend 实现）
//   - submitAcceptWithBuffer(listen_fd, user_data)：提交 accept+首包，完成时 tag=accept、client_stream 与 buffer 有效
//   - pollCompletions(timeout_ns)：收割所有完成项（accept/recv/send），返回 []Completion
//   - submitRecv(stream, user_data)：在连接上提交一次 recv，数据写入池块，完成时 tag=recv、buffer_ptr/len/chunk_index 有效，用毕须 releaseChunk
//   - submitSend(stream, data, user_data)：在连接上提交 send，data 在完成前须保持有效，完成时 tag=send、len=已发送字节数
//   - releaseChunk(chunk_index)：归还 recv 完成项占用的池块，须在下次 pollCompletions 前调用

const std = @import("std");
const builtin = @import("builtin");

/// 零拷贝 sendFile 或平台 I/O 可能返回的错误
pub const SendFileError = error{
    Unsupported,
    FileRead,
    SocketWrite,
    SendfileFailed,
    TransmitFileFailed,
};

/// 完成项类型：accept=新连接+首包，recv=连接上收到数据，send=连接上发送完成，file_read/file_write=异步文件 I/O
pub const CompletionTag = enum {
    accept,
    recv,
    send,
    file_read,
    file_write,
};

/// 单次 I/O 完成项（pollCompletions 返回的元素）
/// user_data 为 submit* 传入的句柄（如 connection_id）；buffer_ptr/len 由实现填入
/// tag=accept 时 client_stream 非 null，首包在 buffer_ptr[0..len]，调用方负责关闭 stream
/// tag=recv 时 buffer_ptr[0..len] 为本次读入数据，chunk_index 非 null 时调用方用毕须 releaseChunk
/// tag=send 时 len 为本次发送字节数，buffer_ptr 未使用
/// tag=file_read 时 buffer_ptr[0..len] 为读入数据，file_err 非 null 表示读失败
/// tag=file_write 时 len 为写入字节数，buffer_ptr 未使用，file_err 非 null 表示写失败
/// 返回的 []Completion 切片有效期为下一次 pollCompletions 调用前，调用方需在此之前消费
pub const Completion = struct {
    pub const Tag = CompletionTag;
    user_data: usize,
    buffer_ptr: [*]const u8,
    len: usize,
    err: ?SendFileError = null,
    /// 新连接时由 backend 填入，调用方负责关闭。Zig 0.16：std.net → std.Io.net
    client_stream: ?std.Io.net.Stream = null,
    /// 完成类型：accept / recv / send / file_read / file_write
    tag: CompletionTag = .accept,
    /// recv 完成时：数据所在池块索引，用毕须调用 HighPerfIO.releaseChunk；accept/send 时为 null
    chunk_index: ?usize = null,
    /// 仅 file_read/file_write 时使用；非 null 表示本次文件 I/O 失败（如 EIO、ENOSPC）
    file_err: ?anyerror = null,
};

/// 初始化选项（各平台可扩展平台专属字段）
pub const InitOptions = struct {
    /// 每环/每线程预期最大连接数（用于预分配事件数组、client 槽位等）
    max_connections: usize = 4096,
    /// 单次 pollCompletions 最多返回的完成项数量；内部预分配 []Completion，调用方只读返回切片
    max_completions: usize = 256,
    /// [仅 Linux] SQPOLL 内核线程绑定的 CPU 编号；设置后 params.flags 会带上 IORING_SETUP_SQ_AFF，避免 sq 线程在核间飘移导致 L1/L2 失效；可与调用方线程绑定到兄弟核或临近核
    linux_sq_thread_cpu: ?u32 = null,
    /// [仅 Windows] 为 true 时，accept 完成后不关闭 socket，投递 DisconnectEx(..., TF_REUSE_SOCKET)，完成时句柄入池，下次 submitAcceptWithBuffer 优先复用，绕过 WSASocketW 创建开销（短连接压榨）
    windows_socket_reuse: bool = false,
    /// [仅 Windows] 预投递 AcceptEx 积压目标数；>0 时 ensureAcceptBacklog() 与 pollCompletions 后会补足，保持内核中待命 accept 数量，适合百万级连接
    windows_accept_backlog: usize = 0,
};

/// Buffer 池的底层分配方式：普通 allocator、Linux 大页或 Windows 大页（deinit 时分别 free / munmap / VirtualFree）
pub const BufferPoolBacking = enum {
    /// allocator 分配，deinit 时 allocator.free
    allocator,
    /// Linux MAP_HUGETLB 分配，deinit 时 munmap（仅 Linux 有效）
    linux_huge,
    /// Windows VirtualAlloc MEM_LARGE_PAGES 分配，deinit 时 VirtualFree（仅 Windows 有效，需 SeLockMemoryPrivilege）
    windows_large,
};

/// 64-byte 对齐的 Buffer 池，供内核注册或用户态直接写，再借给 JSC（Buffer 继承）
/// 具体布局与注册方式由各平台实现；此处仅声明接口
pub const BufferPool = struct {
    /// 底层连续内存（64-byte 对齐）；由 allocAligned 或 allocHugePages 分配，deinit 时按 backing 释放
    ptr: [*]align(64) u8,
    len: usize,
    allocator: std.mem.Allocator,
    backing: BufferPoolBacking = .allocator,

    /// 分配 64-byte 对齐的 buffer 池；调用方负责 deinit
    pub fn allocAligned(allocator: std.mem.Allocator, size: usize) !BufferPool {
        const ptr = try allocator.alignedAlloc(u8, .@"64", size);
        return .{
            .ptr = ptr.ptr,
            .len = ptr.len,
            .allocator = allocator,
            .backing = .allocator,
        };
    }

    /// [仅 Linux] 使用 MAP_HUGETLB 分配大页池（2MB 页），减少 TLB 未命中；size 会对齐到 2MB；调用方负责 deinit
    /// 池较大（如数百 MB）时推荐使用；需系统预留大页（如 echo 128 > /proc/sys/vm/nr_hugepages）
    pub fn allocHugePages(allocator: std.mem.Allocator, size: usize) !BufferPool {
        if (builtin.os.tag != .linux) return error.Unsupported;
        const linux = std.os.linux;
        const HUGEPAGE_SIZE_2MB = 2 * 1024 * 1024;
        const aligned_size = std.mem.alignForward(usize, size, HUGEPAGE_SIZE_2MB);
        if (aligned_size == 0) return error.OutOfMemory;
        const flags = linux.MAP{
            .TYPE = .PRIVATE,
            .ANONYMOUS = true,
            .HUGETLB = true,
        };
        const raw_flags = @as(u32, @bitCast(flags)) | (21 << 26);
        const flags_with_huge = @as(linux.MAP, @bitCast(raw_flags));
        const prot = linux.PROT.READ | linux.PROT.WRITE;
        const result = linux.mmap(null, aligned_size, prot, flags_with_huge, -1, 0);
        const addr = @as(usize, @intCast(result));
        if (addr == std.math.maxInt(usize)) return error.OutOfMemory;
        const ptr = @as([*]align(64) u8, @ptrCast(@alignCast(addr)));
        return .{
            .ptr = ptr,
            .len = aligned_size,
            .allocator = allocator,
            .backing = .linux_huge,
        };
    }

    /// [仅 Windows] 使用 VirtualAlloc MEM_LARGE_PAGES 分配大页池（2MB/1GB 等），减少 TLB 未命中；size 会对齐到 GetLargePageMinimum()；调用方负责 deinit
    /// 需进程具备 SeLockMemoryPrivilege（锁定内存页）；64KB CHUNK 布局下大页可显著提升内存密集型性能
    pub fn allocLargePagesWindows(allocator: std.mem.Allocator, size: usize) !BufferPool {
        if (builtin.os.tag != .windows) return error.Unsupported;
        const win = std.os.windows;
        const kernel32 = win.kernel32;
        const page_size = kernel32.GetLargePageMinimum();
        if (page_size == 0) return error.Unsupported;
        const aligned_size = std.mem.alignForward(usize, size, page_size);
        if (aligned_size == 0) return error.OutOfMemory;
        const MEM_COMMIT = 0x1000;
        const MEM_RESERVE = 0x2000;
        const MEM_LARGE_PAGES = 0x20000000;
        const PAGE_READWRITE = 4;
        const ptr = kernel32.VirtualAlloc(null, aligned_size, MEM_COMMIT | MEM_RESERVE | MEM_LARGE_PAGES, PAGE_READWRITE);
        if (ptr == null) return error.OutOfMemory;
        const aligned_ptr = @as([*]align(64) u8, @ptrCast(@alignCast(ptr)));
        return .{
            .ptr = aligned_ptr,
            .len = aligned_size,
            .allocator = allocator,
            .backing = .windows_large,
        };
    }

    /// 释放池；allocator 用 free，linux_huge 用 munmap，windows_large 用 VirtualFree；调用后不得再使用 ptr
    pub fn deinit(self: *BufferPool) void {
        switch (self.backing) {
            .allocator => self.allocator.free(self.ptr[0..self.len]),
            .linux_huge => {
                if (builtin.os.tag == .linux) {
                    const mem = @as([]align(std.mem.page_size) const u8, @alignCast(self.ptr[0..self.len]));
                    std.posix.munmap(mem);
                }
            },
            .windows_large => {
                if (builtin.os.tag == .windows) {
                    const win = std.os.windows;
                    const kernel32 = win.kernel32;
                    const MEM_RELEASE = 0x8000;
                    _ = kernel32.VirtualFree(self.ptr, 0, MEM_RELEASE);
                }
            },
        }
        self.* = undefined;
    }

    /// 返回可写切片，供内核或用户态写入
    pub fn slice(self: *const BufferPool) []u8 {
        return self.ptr[0..self.len];
    }
};

// -----------------------------------------------------------------------------
// Buffer 调度：ChunkAllocator（目标为「线程本地无锁栈 + 全局 Slab」）
// -----------------------------------------------------------------------------
// 当前实现为单栈（全局 Slab 的简化版）；生产版应为每 I/O 线程持有一个小栈（如 128 块），
// 申请时先看本地栈，释放时先放回本地栈；空/满时与 ChunkAllocator 做批量交换（如 16 块），
// 使 90%+ 操作无锁、在 L1/L2 内完成。Chunk 地址 64 字节对齐，按 Cache Line 填充防伪共享。

/// 基于 BufferPool 的块级分配器：按 chunk_size 将池切块，take/release 以块索引为单位；与 HighPerfIO 的 free_list 语义兼容，可供上层或后续平台层分片化使用
pub const ChunkAllocator = struct {
    pool: *const BufferPool,
    chunk_size: usize,
    /// 空闲块索引栈；生产版此处为「全局 Slab」，每线程另有本地栈并与此批量交换
    free_stack: std.ArrayList(usize),
    allocator: std.mem.Allocator,

    /// 初始化：以 pool 与 chunk_size 切块，所有块索引入栈；调用方负责在 ChunkAllocator 生命周期内保持 pool 有效，deinit 时归还栈内存
    pub fn init(allocator: std.mem.Allocator, pool: *const BufferPool, chunk_size: usize) !ChunkAllocator {
        const slice = pool.slice();
        if (slice.len < chunk_size or chunk_size == 0) return error.OutOfMemory;
        const n = slice.len / chunk_size;
        var free_stack = try std.ArrayList(usize).initCapacity(allocator, n);
        for (0..n) |i| {
            free_stack.appendAssumeCapacity(i);
        }
        return .{
            .pool = pool,
            .chunk_size = chunk_size,
            .free_stack = free_stack,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ChunkAllocator) void {
        self.free_stack.deinit(self.allocator);
        self.* = undefined;
    }

    /// 取一块，返回块索引；无可用块时返回 null
    pub fn take(self: *ChunkAllocator) ?usize {
        return self.free_stack.pop();
    }

    /// 归还块索引
    pub fn release(self: *ChunkAllocator, chunk_index: usize) void {
        _ = self.free_stack.append(self.allocator, chunk_index) catch {};
    }

    /// 根据块索引返回池内该块的只读切片；调用方不得在 release 后继续使用
    pub fn chunkSlice(self: *const ChunkAllocator, chunk_index: usize) []const u8 {
        const start = chunk_index * self.chunk_size;
        const end = @min(start + self.chunk_size, self.pool.len);
        return self.pool.ptr[start..end];
    }

    /// 批量取块，写入 out[0..]，返回实际取到的数量；用于线程本地缓存 refill
    pub fn takeBatch(self: *ChunkAllocator, out: []usize) usize {
        var n: usize = 0;
        while (n < out.len) {
            const idx = self.free_stack.pop() orelse break;
            out[n] = idx;
            n += 1;
        }
        return n;
    }

    /// 批量归还块索引；用于线程本地缓存 flush
    pub fn releaseBatch(self: *ChunkAllocator, indices: []const usize) void {
        for (indices) |idx| _ = self.free_stack.append(self.allocator, idx) catch {};
    }
};

// -----------------------------------------------------------------------------
// 线程本地无锁栈 + 与全局 Slab 批量交换（每 I/O 线程一个实例，包装 ArrayList 全局池）
// -----------------------------------------------------------------------------
const CHUNK_CACHE_STACK_SIZE = 128;
const CHUNK_CACHE_BATCH = 16;

/// 每 I/O 线程持有一个，包装全局 free_list；take/release 绝大多数命中本地栈，空/满时与全局批量交换
pub const ThreadLocalChunkCache = struct {
    stack: [CHUNK_CACHE_STACK_SIZE]usize = undefined,
    len: usize = 0,
    global: *std.ArrayList(usize),
    allocator: std.mem.Allocator,

    /// 绑定到全局池（通常为 HighPerfIO.free_list）与 allocator；registerBufferPool 后调用
    pub fn init(global: *std.ArrayList(usize), allocator: std.mem.Allocator) ThreadLocalChunkCache {
        return .{ .global = global, .allocator = allocator };
    }

    /// 取一块；先看本地栈，空则从全局批量 refill 再取
    pub fn take(self: *ThreadLocalChunkCache) ?usize {
        if (self.len == 0) self.refill();
        if (self.len == 0) return null;
        self.len -= 1;
        return self.stack[self.len];
    }

    /// 归还块；先放回本地栈，满则向全局 flush 一批再放
    pub fn release(self: *ThreadLocalChunkCache, chunk_index: usize) void {
        if (self.len >= CHUNK_CACHE_STACK_SIZE) self.flush();
        self.stack[self.len] = chunk_index;
        self.len += 1;
    }

    fn refill(self: *ThreadLocalChunkCache) void {
        var count: usize = 0;
        while (count < CHUNK_CACHE_BATCH) : (count += 1) {
            const idx = self.global.pop() orelse break;
            self.stack[self.len] = idx;
            self.len += 1;
        }
    }

    fn flush(self: *ThreadLocalChunkCache) void {
        const n = @min(CHUNK_CACHE_BATCH, self.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            self.global.append(self.allocator, self.stack[i]) catch break;
        }
        var j = n;
        while (j < self.len) : (j += 1) {
            self.stack[j - n] = self.stack[j];
        }
        self.len -= n;
    }
};
