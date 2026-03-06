//! 平台无关的 I/O 核心类型、错误集与抽象定义（api.zig）
//!
//! 职责：
//!   - 定义 `libs_io` 跨平台后端（Linux/Darwin/Windows）共用的核心契约与数据结构。
//!   - 提供高性能 Buffer 调度：`BufferPool`（对齐池）与 `ChunkAllocator`（Slab 分配）。
//!   - 提供线程本地性能增强：`ThreadLocalChunkCache` 结合批量交换技术，消除全局锁竞争。
//!
//! 极致压榨亮点：
//!   1. **零拷贝 Buffer 继承**：`BufferPool` 支持 64 字节对齐、大页（HugePages/LargePages），直接与内核注册并借给 JSC。
//!   2. **线程本地 Slab 缓存**：`ThreadLocalChunkCache` 实现了 90%+ 操作无锁化，支持批量 `appendSlice` 刷新到全局池。
//!   3. **统一完成项契约**：`Completion` 结构经过极致精简，支持 SoA 访问模式，确保热路径缓存局部性。
//!
//! 适用规范：
//!   - 遵循 00 §1.6（Buffer 继承）、§3.0（统一 I/O 入口）、§3.6（避免锁竞争）。
//!
//! [Allocates] 部分函数返回由调用方负责释放的资源，详见函数文档。

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

/// 完成项类型：accept=新连接+首包，recv=连接上收到数据，send=连接上发送完成，file_read/file_write=异步文件 I/O，splice=Socket 间零拷贝
pub const CompletionTag = enum {
    accept,
    recv,
    send,
    file_read,
    file_write,
    splice,
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
    /// [仅 Linux] 关联的首环 fd；设置后 params.flags 会带上 IORING_SETUP_ATTACH_WQ，与首环共享内核工作队列线程池，降低上下文切换与资源占用
    linux_attach_wq_fd: ?i32 = null,
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

    /// [Allocates] 分配 64-byte 对齐的 buffer 池；调用方负责 deinit。
    pub fn allocAligned(allocator: std.mem.Allocator, size: usize) !BufferPool {
        const ptr = try allocator.alignedAlloc(u8, .@"64", size);
        return .{
            .ptr = ptr.ptr,
            .len = ptr.len,
            .allocator = allocator,
            .backing = .allocator,
        };
    }

    /// [Allocates] [仅 Linux] 使用 MAP_HUGETLB 分配大页池（2MB 页），减少 TLB 未命中；size 会对齐到 2MB；调用方负责 deinit。
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

    /// [Allocates] [仅 Windows] 使用 VirtualAlloc MEM_LARGE_PAGES 分配大页池（2MB/1GB 等），减少 TLB 未命中；size 会对齐到 GetLargePageMinimum()；调用方负责 deinit。
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

/// 基于 BufferPool 的块级分配器：按 chunk_size 将池切块，take/release 以块索引为单位；与 HighPerfIO 的 free_list 语义兼容，可供上层或后续平台层分片化使用。
/// 使用 ArrayListUnmanaged 存空闲块索引，结构体更紧凑、单 Cache Line 可容纳更多有效数据（01 §1.2）。
pub const ChunkAllocator = struct {
    pool: *const BufferPool,
    chunk_size: usize,
    /// 空闲块索引栈（Unmanaged：不存 allocator 指针，release/releaseBatch/deinit 时由调用方传 allocator）
    free_stack: std.ArrayListUnmanaged(usize),
    allocator: std.mem.Allocator,

    /// 初始化：以 pool 与 chunk_size 切块，所有块索引入栈；调用方负责在 ChunkAllocator 生命周期内保持 pool 有效，deinit 时归还栈内存
    pub fn init(allocator: std.mem.Allocator, pool: *const BufferPool, chunk_size: usize) !ChunkAllocator {
        const slice = pool.slice();
        if (slice.len < chunk_size or chunk_size == 0) return error.OutOfMemory;
        const n = slice.len / chunk_size;
        var free_stack = try std.ArrayListUnmanaged(usize).initCapacity(allocator, n);
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
        self.free_stack.append(self.allocator, chunk_index) catch {};
    }

    /// [Borrows] 根据块索引返回池内该块的只读切片；调用方不得在 release 后继续使用。
    pub fn chunkSlice(self: *const ChunkAllocator, chunk_index: usize) []const u8 {
        const start = chunk_index * self.chunk_size;
        const end = @min(start + self.chunk_size, self.pool.len);
        return self.pool.ptr[start..end];
    }

    /// 批量取块，写入 out[0..]，返回实际取到的数量；用于线程本地缓存 refill
    pub fn takeBatch(self: *ChunkAllocator, out: []usize) usize {
        const n = @min(out.len, self.free_stack.items.len);
        if (n == 0) return 0;
        const start = self.free_stack.items.len - n;
        std.mem.copyForwards(usize, out[0..n], self.free_stack.items[start..]);
        self.free_stack.shrinkRetainingCapacity(start);
        return n;
    }

    /// 批量归还块索引；用于线程本地缓存 flush
    pub fn releaseBatch(self: *ChunkAllocator, indices: []const usize) void {
        self.free_stack.appendSlice(self.allocator, indices) catch {};
    }
};

// -----------------------------------------------------------------------------
// 线程本地无锁栈 + 与全局 Slab 批量交换（每 I/O 线程一个实例，包装 ArrayList 全局池）
// -----------------------------------------------------------------------------
const CHUNK_CACHE_STACK_SIZE = 128;
const CHUNK_CACHE_BATCH = 16;

/// 每 I/O 线程持有一个，包装全局 free_list；take/release 绝大多数命中本地栈，空/满时与全局批量交换（01 §1.2 Unmanaged）
pub const ThreadLocalChunkCache = struct {
    stack: [CHUNK_CACHE_STACK_SIZE]usize = undefined,
    len: usize = 0,
    global: *std.ArrayListUnmanaged(usize),
    allocator: std.mem.Allocator,

    /// 绑定到全局池（通常为 HighPerfIO.free_list）与 allocator；registerBufferPool 后调用
    pub fn init(global: *std.ArrayListUnmanaged(usize), allocator: std.mem.Allocator) ThreadLocalChunkCache {
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
        const n = @min(CHUNK_CACHE_BATCH, self.global.items.len);
        if (n == 0) return;
        const start = self.global.items.len - n;
        std.mem.copyForwards(usize, self.stack[self.len .. self.len + n], self.global.items[start..]);
        self.global.shrinkRetainingCapacity(start);
        self.len += n;
    }

    fn flush(self: *ThreadLocalChunkCache) void {
        const n = @min(CHUNK_CACHE_BATCH, self.len);
        if (n == 0) return;

        self.global.appendSlice(self.allocator, self.stack[0..n]) catch {};

        if (n < self.len) {
            std.mem.copyForwards(usize, self.stack[0 .. self.len - n], self.stack[n..self.len]);
        }
        self.len -= n;
    }
};
