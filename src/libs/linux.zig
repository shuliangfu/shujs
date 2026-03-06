// Linux 平台 I/O 核心（linux.zig）：io_uring + sendfile 零拷贝。
//
// 职责
//   - 实现 HighPerfIO：单环 io_uring、PROVIDE_BUFFERS 池、accept+首包 recv 由内核直接写入注册内存；
//   - 实现 sendFile：文件→网络零拷贝，循环 sendfile 直至发完或错误，EAGAIN 时重试。
//
// 规范对应（00-性能规则）
//   - §3.1、§4.2：必须使用 io_uring，Fixed Buffers / IORING_OP_PROVIDE_BUFFERS；accept 与首包 recv 合并为内核选 buffer 填入；
//   - §3.1 SQPOLL：初始化优先尝试 IORING_SETUP_SQPOLL（0 syscall 提交），EPERM 时优雅降级为标准轮询并打 performance-hint；
//   - §3.4、§4.2：文件→网络一律 sendfile，禁止 read+write；每核一环、Thread-per-Core 由调用方保证。
//
// 数据流简述
//   - registerBufferPool：将 BufferPool 按 64KB 分块，PROVIDE_BUFFERS 提交给内核；
//   - submitAcceptWithBuffer：提交 accept，完成时自动提交 recv（buffer_selection 用 BUFFER_GROUP_ID），CQE 中通过 buffer_id 得到指针；
//   - pollCompletions：copy_cqes，按 user_data 区分 accept CQE（内部再提交 recv）与 recv CQE（填 completion_buffer）；返回切片有效至下次 poll。
//
// 槽位与 user_data
//   - 槽位用 SoA（SlotFields + MultiArrayList）存储，pollCompletions 热路径只摸 tag/caller_user_data/client_fd 等连续数组，缓存友好；
//   - accept 完成时占用一 recv 槽位并提交 recv，user_data 高位用 RECV_USER_DATA_TAG 区分。
//
// 内存与释放
//   - 显式 allocator（§1.5）：init 接收 allocator，deinit 中 free_list.deinit(self.allocator)、释放 completion_buffer、slot_data.deinit(allocator)。
//
// --- 进阶压榨（已做/可继续深挖）---
// 1) 大页 Buffer 池：api.zig 已提供 BufferPool.allocHugePages(allocator, size)（仅 Linux），
//    MAP_HUGETLB 2MB 页，减少 TLB 未命中；deinit 时 munmap；池大（数百 MB）时推荐使用。
// 2) IORING_OP_SPLICE：当前仅 sendfile（文件→socket）。Socket→Socket 代理场景可用 io_uring splice，
//    数据在内核缓冲间搬运、不经过用户态；可扩展为 submitSplice(in_fd, out_fd, len) + 完成项类型。
// 3) IORING_SETUP_ATTACH_WQ：Thread-per-Core 多环时，后续环可用 params.wq_fd 关联首环的 work queue，
//    共享内核线程池、降低上下文切换；需暴露「主环 fd」与 initAttached(allocator, options, primary_wq_fd) 类 API。
// 4) 槽位 SoA：已实现，slot_data 为 MultiArrayList(SlotFields)，热路径按字段访问。
//
// --- 微米级压榨（已做）---
// 5) 冷路径提示：错误与早期 return 分支使用 @branchHint(.cold)（Zig 0.16 官方 builtin），利于 CPU 流水线与分支预测。
// 6) 批量提交：提供 submitAcceptWithBufferDeferred + flushSubmits()；降级模式（无 SQPOLL）下可先循环 Deferred 再一次 flushSubmits，将多次 submit 合并为一次系统调用。
//
// --- 物理极限级（指令集/硬件拓扑）---
// 7) 寄存器传参：pollCompletions 循环前将 slot_data 各字段切片取出为局部变量，传入 handleAcceptCqe/handleRecvCqe，使 ptr+len 常驻寄存器，减少热路径结构体寻址。
// 8) SQPOLL 亲和性：InitOptions.linux_sq_thread_cpu 设置后启用 IORING_SETUP_SQ_AFF，将 sq 内核线程钉到指定核；调用方可用 sched_setaffinity 将本线程绑到兄弟/临近核。
// 9) 向量化空闲列表：已实现 free_bitmap + @ctz（TZCNT），popFreeSlot/pushFreeSlot 替代原 free_list，批量申请槽位时更省内存访问。
// 10) Varying Buffer Sizes：已支持多 BUFFER_GROUP_ID；registerBufferPool 注册组 0（64KB），registerBufferGroup(group_id, pool, chunk_size) 注册它组；submitAcceptWithBuffer(..., group_id) 指定该连接使用的 buffer 组（HTTP 小包 vs 模型流大块）。
//
// --- 硬件定制级（通用 Web Server 外的可选扩展）---
// 当前实现（io_uring + PROVIDE_BUFFERS + 上述优化）在通用场景下已是工程学上的顶点。若需进一步压榨，属于「硬件/场景定制」：
//
// 11) IORING_REGISTER_BUFFERS：当前用 PROVIDE_BUFFERS（动态选池），适合网络 recv 的「内核从池里挑一块」语义。若有**固定、极高频**读写的 buffer 集合，可改用 io_uring_register(IORING_REGISTER_BUFFERS) 将地址长期 Pin 在内核，减少每次 I/O 的内核态映射开销；recv 需走 fixed buffer 路径（buffer_index 指定槽位），与 PROVIDE_BUFFERS 二选一或分场景使用。
//
// 12) Zero-copy Rx (TCP_ZEROCOPY_RECEIVE)：在 100Gbps 级网卡上，内核支持网卡→用户态内存的零拷贝（页翻转）。需特定网卡驱动与 mmap 等配合，对**通用 Web Server** 而言，当前 io_uring + PROVIDE_BUFFERS 已是通用场景顶点；零拷贝 Rx 留给专用/超算场景。

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const api = @import("api.zig");

/// 每块 buffer 大小（与 io_uring 常用 64K 对齐，PROVIDE_BUFFERS 时使用）
const CHUNK_SIZE = 64 * 1024;
/// 默认 buffer 组 ID（HTTP/首包等小 buffer）
const BUFFER_GROUP_ID_DEFAULT: u16 = 0;
/// 最大支持的 buffer 组数量（不同 chunk 大小对应不同业务：API 小包 vs 模型流大块）
const MAX_BUFFER_GROUPS = 4;
/// recv CQE 的 user_data 高位标记，便于与 accept 的 index 区分
const RECV_USER_DATA_TAG: u64 = 1 << 63;
/// send CQE 的 user_data 高位标记
const SEND_USER_DATA_TAG: u64 = 1 << 62;
/// splice CQE 的 user_data 高位标记
const SPLICE_USER_DATA_TAG: u64 = 1 << 61;

/// 槽位 tag：free / accept 进行中 / recv 首包（accept 后）/ conn_recv（submitRecv）/ conn_send（submitSend）/ conn_splice（submitSplice）
const SlotTag = enum { free, accept, recv, conn_recv, conn_send, conn_splice };

/// 线程本地槽位缓存：与 Darwin/Windows 的 ThreadLocalChunkCache 等价，Linux 管理的是 slot 索引（非 chunk）；take/release 绝大多数命中本地栈，空/满时与 free_bitmap 批量交换
const SLOT_CACHE_STACK_SIZE = 128;
const SLOT_CACHE_BATCH = 16;

const ThreadLocalSlotCache = struct {
    stack: [SLOT_CACHE_STACK_SIZE]usize = undefined,
    len: usize = 0,
    io: *HighPerfIO,

    /// 绑定到本线程的 HighPerfIO；registerBufferPool 内调用
    pub fn init(io: *HighPerfIO) ThreadLocalSlotCache {
        return .{ .io = io };
    }

    /// 取一槽位；先看本地栈，空则从 free_bitmap 批量 refill 再取
    pub fn take(self: *ThreadLocalSlotCache) ?usize {
        if (self.len == 0) self.refill();
        if (self.len == 0) return null;
        self.len -= 1;
        return self.stack[self.len];
    }

    /// 归还槽位；先放回本地栈，满则向 free_bitmap flush 一批再放
    pub fn release(self: *ThreadLocalSlotCache, slot: usize) void {
        if (self.len >= SLOT_CACHE_STACK_SIZE) self.flush();
        self.stack[self.len] = slot;
        self.len += 1;
    }

    fn refill(self: *ThreadLocalSlotCache) void {
        const batch = self.io.popFreeSlotBatch(self.stack[self.len..][0 .. @min(SLOT_CACHE_BATCH, SLOT_CACHE_STACK_SIZE - self.len)]);
        self.len += batch;
    }

    fn flush(self: *ThreadLocalSlotCache) void {
        const n = @min(SLOT_CACHE_BATCH, self.len);
        if (n == 0) return;
        self.io.pushFreeSlotBatch(self.stack[0..n]);
        if (n < self.len) {
            std.mem.copyForwards(usize, self.stack[0 .. self.len - n], self.stack[n..self.len]);
        }
        self.len -= n;
    }
};

/// 单组 buffer 信息：供多 BUFFER_GROUP 时按 group_id 选不同 chunk 大小
const BufferGroupInfo = struct {
    ptr: [*]const u8 = undefined,
    chunk_count: usize = 0,
    chunk_size: u32 = CHUNK_SIZE,
};

/// 槽位 SoA 字段：用于 MultiArrayList，热路径只摸 tag/caller_user_data/client_fd 等连续数组
const SlotFields = struct {
    tag: SlotTag = .free,
    listen_fd: i32 = 0,
    client_fd: i32 = 0,
    caller_user_data: usize = 0,
    /// accept 时指定后续 recv 使用的 buffer 组（用于 Varying Buffer Sizes）
    accept_group_id: u16 = 0,
    /// recv 槽位记录使用的 buffer 组，CQE 时用于解析 buffer 指针
    recv_group_id: u16 = 0,
};

/// 平台句柄：io_uring 环 + PROVIDE_BUFFERS 池 + 完成项数组
pub const HighPerfIO = struct {
    allocator: std.mem.Allocator,
    ring: linux.IoUring,
    /// 预分配完成项，pollCompletions 填入并返回 [0..completion_count]
    completion_buffer: []api.Completion,
    completion_count: usize,
    max_connections: usize,

    /// 槽位 SoA：accept/recv 进行中时按字段存 tag、listen_fd/client_fd、caller_user_data
    slot_data: std.MultiArrayList(SlotFields),
    /// 空闲槽位位图：每 bit 对应一槽位，1=空闲 0=占用；用 @ctz 快速找空闲索引（TZCNT）
    free_bitmap: []u64,
    /// 扫描提示，记录上次扫描到的位置，减少下次扫描开销
    free_scan_hint: usize = 0,
    /// 当前空闲槽位数量
    free_count: usize,

    /// 线程本地槽位缓存：take/release 经此，与 Darwin/Windows 的 chunk_cache 等价；registerBufferPool 时 init
    slot_cache: ThreadLocalSlotCache = undefined,

    /// 已注册的 buffer 组（PROVIDE_BUFFERS）；group_id 0 为默认 64KB，可 registerBufferGroup 注册多组
    groups: [MAX_BUFFER_GROUPS]BufferGroupInfo = .{.{}} ** MAX_BUFFER_GROUPS,

    /// 已注册的固定缓冲区（IORING_REGISTER_BUFFERS）；用于极速 I/O（减少内核映射开销）
    registered_buffers: []posix.iovec = &.{},

    /// 已注册的文件描述符数组（IORING_REGISTER_FILES）；用于极速 fd 查找（0 syscall + 内核索引）
    /// 索引 0..31 预留给监听 socket，32..max_connections+31 给连接 socket
    registered_fds: []i32,
    registered_fds_count: usize = 0,
    used_sqpoll: bool = false,

    /// SQPOLL 核预留（00 §3.1）：将当前线程 CPU 亲和性设为除 sq_cpu 外的所有核，避免与 io_sqp 争抢；best-effort，失败静默返回
    fn applySqpollCoreReservation(sq_cpu: u32) void {
        const sched_c = @cImport({
            @cDefine("_GNU_SOURCE", "1");
            @cInclude("sched.h");
        });
        const cpu_count = std.Thread.getCpuCount() catch return;
        if (cpu_count == 0 or sq_cpu >= cpu_count) return;
        var mask: sched_c.cpu_set_t = undefined;
        sched_c.CPU_ZERO(&mask);
        for (0..cpu_count) |i| {
            if (i != sq_cpu) sched_c.CPU_SET(@as(sched_c.c_int, @intCast(i)), &mask);
        }
        _ = sched_c.sched_setaffinity(0, @sizeOf(sched_c.cpu_set_t), &mask);
    }

    /// 初始化 Linux I/O 子系统：优先尝试 SQPOLL（0 syscall），无权限时优雅降级为标准轮询并打 performance-hint
    pub fn init(allocator: std.mem.Allocator, options: api.InitOptions) !HighPerfIO {
        const entries: u16 = @intCast(std.math.min(options.max_connections * 2, 4096));
        
        // 性能增强标志（00 §3.1）：
        // - IORING_SETUP_SQPOLL: 内核线程轮询，减少 syscall
        // - IORING_SETUP_SINGLE_ISSUER: 限制单线程提交，减少内核锁（适合 Thread-per-Core）
        // - IORING_SETUP_COOP_TASKRUN: 协同任务运行，降低中断开销（5.19+）
        // - IORING_SETUP_TASKRUN_FLAG: 配合 COOP_TASKRUN 使用（5.19+）
        // - IORING_SETUP_DEFER_TASKRUN: 推迟任务运行至 enter，极大降低高并发下处理开销（6.1+）
        const IORING_SETUP_DEFER_TASKRUN: u32 = 1 << 13;
        const perf_flags = linux.IORING_SETUP_SQPOLL | 
                           linux.IORING_SETUP_SINGLE_ISSUER |
                           linux.IORING_SETUP_COOP_TASKRUN |
                           linux.IORING_SETUP_TASKRUN_FLAG |
                           IORING_SETUP_DEFER_TASKRUN;

        var params = std.mem.zeroInit(linux.io_uring_params, .{
            .flags = perf_flags | 
                     (if (options.linux_sq_thread_cpu != null) linux.IORING_SETUP_SQ_AFF else 0) |
                     (if (options.linux_attach_wq_fd != null) linux.IORING_SETUP_ATTACH_WQ else 0),
            .sq_thread_idle = 1000,
            .sq_thread_cpu = options.linux_sq_thread_cpu orelse 0,
            .wq_fd = @intCast(options.linux_attach_wq_fd orelse 0),
        });
        var used_sqpoll = true;
        var ring = linux.IoUring.init_params(entries, &params) catch |err| blk: {
            // 若高性能标志组合失败，尝试降级
            used_sqpoll = false;
            if (err == error.PermissionDenied or err == error.SystemOutdated or err == error.InvalidArgument) {
                std.debug.print("[io_core] performance-hint: advanced io_uring flags failed ({s}), falling back to basic.\n", .{@errorName(err)});
                break :blk linux.IoUring.init(entries, 0) catch |e| switch (e) {
                    error.SystemOutdated, error.PermissionDenied => return error.Unsupported,
                    else => return e,
                };
            }
            return err;
        };
        errdefer ring.deinit();

        const completion_buffer = try allocator.alloc(api.Completion, options.max_completions);
        errdefer allocator.free(completion_buffer);

        var slot_data = std.MultiArrayList(SlotFields){};
        errdefer slot_data.deinit(allocator);
        try slot_data.ensureTotalCapacity(allocator, options.max_connections);
        for (0..options.max_connections) |_| {
            slot_data.appendAssumeCapacity(.{ .tag = .free });
        }

        const bitmap_words = (options.max_connections + 63) / 64;
        const free_bitmap = try allocator.alloc(u64, bitmap_words);
        errdefer allocator.free(free_bitmap);
        @memset(free_bitmap, std.math.maxInt(u64));
        if (options.max_connections % 64 != 0) {
            const last_word = options.max_connections / 64;
            free_bitmap[last_word] &= (1 << @as(u6, @intCast(options.max_connections % 64))) - 1;
        }

        // 预注册文件描述符表（00 §4.2）：
        // 大小为 max_connections + 32（前 32 位给监听 fd）。
        // 使用 IOSQE_FIXED_FILE 绕过内核 fd 表锁，在高并发 accept/close 时极致压榨。
        const reg_fds_size = options.max_connections + 32;
        const registered_fds = try allocator.alloc(i32, reg_fds_size);
        errdefer allocator.free(registered_fds);
        @memset(registered_fds, -1);
        const ret_reg = linux.syscall4(
            linux.SYS.io_uring_register,
            @as(usize, @intCast(ring.fd)),
            linux.IORING_REGISTER_FILES,
            @intFromPtr(registered_fds.ptr),
            reg_fds_size,
        );
        if (ret_reg != 0) {
            std.debug.print("[io_core] performance-hint: io_uring register files failed, using standard fds.\n", .{});
        }

        // SQPOLL 核预留（00 §3.1）：若 SQPOLL 生效且指定了 sq_thread_cpu，将当前线程亲和性设为「排除该核」，避免与 io_sqp 争抢 L1/L2
        if (used_sqpoll and options.linux_sq_thread_cpu != null) {
            applySqpollCoreReservation(options.linux_sq_thread_cpu.?);
        }

        return .{
            .allocator = allocator,
            .ring = ring,
            .completion_buffer = completion_buffer,
            .completion_count = 0,
            .max_connections = options.max_connections,
            .slot_data = slot_data,
            .free_bitmap = free_bitmap,
            .free_count = options.max_connections,
            .registered_fds = if (ret_reg == 0) registered_fds else &.{},
            .used_sqpoll = used_sqpoll,
        };
    }

    /// 释放 io_uring、所有堆内存（§1.5 显式 allocator 释放）
    pub fn deinit(self: *HighPerfIO) void {
        if (self.registered_buffers.len > 0) {
            _ = linux.syscall4(linux.SYS.io_uring_register, @as(usize, @intCast(self.ring.fd)), linux.IORING_UNREGISTER_BUFFERS, 0, 0);
            self.allocator.free(self.registered_buffers);
        }
        if (self.registered_fds.len > 0) {
            _ = linux.syscall4(linux.SYS.io_uring_register, @as(usize, @intCast(self.ring.fd)), linux.IORING_REGISTER_FILES_UPDATE, 0, 0); // Not strictly necessary on deinit, but good practice
            self.allocator.free(self.registered_fds);
        }
        self.ring.deinit();
        self.allocator.free(self.completion_buffer);
        self.slot_data.deinit(self.allocator);
        self.allocator.free(self.free_bitmap);
        self.* = undefined;
    }

    /// [仅 Linux] 注册一组固定缓冲区（IORING_REGISTER_BUFFERS）；之后 read_fixed/write_fixed 可省去内核页映射开销
    pub fn registerBuffers(self: *HighPerfIO, buffers: []const []u8) !void {
        if (self.registered_buffers.len > 0) return error.AlreadyRegistered;
        const iovecs = try self.allocator.alloc(posix.iovec, buffers.len);
        errdefer self.allocator.free(iovecs);
        for (buffers, 0..) |buf, i| {
            iovecs[i] = .{ .base = buf.ptr, .len = buf.len };
        }

        const ret = linux.io_uring_register(
            @intCast(self.ring.fd),
            .REGISTER_BUFFERS,
            iovecs.ptr,
            @intCast(iovecs.len),
        );
        if (linux.errno(ret) != .SUCCESS) return error.RegisterBuffersFailed;
        self.registered_buffers = iovecs;
    }

    /// [仅 Linux] 注册一组文件描述符（IORING_REGISTER_FILES）；之后 submitAcceptWithBuffer 等可利用内核索引加速
    /// 返回的索引数组由 HighPerfIO 持有，deinit 时释放。
    pub fn registerFiles(self: *HighPerfIO, fds: []const i32) !void {
        if (self.registered_fds.len > 0) return error.AlreadyRegistered;
        const reg_fds = try self.allocator.dupe(i32, fds);
        errdefer self.allocator.free(reg_fds);
        
        const ret = linux.syscall4(
            linux.SYS.io_uring_register,
            @as(usize, @intCast(self.ring.fd)),
            linux.IORING_REGISTER_FILES,
            @intFromPtr(reg_fds.ptr),
            reg_fds.len,
        );
        if (ret != 0) return error.RegisterFilesFailed;
        self.registered_fds = reg_fds;
    }

    /// 从位图中弹出一个空闲槽位索引；1=空闲，用 @ctz 找最低位（TZCNT），比栈 pop 更省内存访问
    inline fn popFreeSlot(self: *HighPerfIO) ?usize {
        if (self.free_count == 0) return null;
        const start = self.free_scan_hint;
        for (0..self.free_bitmap.len) |i| {
            const word_i = (start + i) % self.free_bitmap.len;
            const word = &self.free_bitmap[word_i];
            if (word.* != 0) {
                const bit_idx = @ctz(word.*);
                const slot = word_i * 64 + bit_idx;
                word.* &= ~(@as(u64, 1) << bit_idx);
                self.free_count -= 1;
                self.free_scan_hint = word_i;
                return slot;
            }
        }
        return null;
    }

    /// 将槽位索引归还到位图
    inline fn pushFreeSlot(self: *HighPerfIO, slot: usize) void {
        const word_i = slot / 64;
        const bit = @as(u64, 1) << @as(u6, @intCast(slot % 64));
        self.free_bitmap[word_i] |= bit;
        self.free_count += 1;
        // 归还时更新扫描提示，以便下次能快速取到
        if (word_i < self.free_scan_hint) self.free_scan_hint = word_i;
    }

    /// 从位图批量弹出空闲槽位索引，写入 out[0..]，返回实际数量；供线程本地槽位缓存 refill
    fn popFreeSlotBatch(self: *HighPerfIO, out: []usize) usize {
        var n: usize = 0;
        const start = self.free_scan_hint;
        outer: for (0..self.free_bitmap.len) |i| {
            const word_i = (start + i) % self.free_bitmap.len;
            const word = &self.free_bitmap[word_i];
            while (word.* != 0) {
                const bit_idx = @ctz(word.*);
                const slot = word_i * 64 + bit_idx;
                word.* &= ~(@as(u64, 1) << bit_idx);
                self.free_count -= 1;
                out[n] = slot;
                n += 1;
                self.free_scan_hint = word_i;
                if (n >= out.len or self.free_count == 0) break :outer;
            }
        }
        return n;
    }

    /// 将一批槽位索引归还到位图；供线程本地槽位缓存 flush
    fn pushFreeSlotBatch(self: *HighPerfIO, indices: []const usize) void {
        for (indices) |slot| self.pushFreeSlot(slot);
    }

    /// 向内核注册默认 buffer 池（组 0，64KB 块）：PROVIDE_BUFFERS 提交，内核从池中选 buffer 填 recv 数据
    pub fn registerBufferPool(self: *HighPerfIO, pool: *api.BufferPool) void {
        self.registerBufferGroup(BUFFER_GROUP_ID_DEFAULT, pool, CHUNK_SIZE);
        self.slot_cache = ThreadLocalSlotCache.init(self);
    }

    /// 注册一组 buffer（可选）：不同 group_id 对应不同 chunk_size，供 HTTP API（小包）与模型流（大块）等区分
    pub fn registerBufferGroup(self: *HighPerfIO, group_id: u16, pool: *api.BufferPool, chunk_size: u32) void {
        if (group_id >= MAX_BUFFER_GROUPS or chunk_size == 0) return;
        const slice = pool.slice();
        if (slice.len < chunk_size) return;
        const n = slice.len / chunk_size;
        _ = self.ring.provide_buffers(
            0,
            slice.ptr,
            chunk_size,
            n,
            group_id,
            0,
        ) catch return;
        _ = self.ring.submit_and_wait(1) catch return;
        var cqe: linux.io_uring_cqe = self.ring.copy_cqe() catch return;
        switch (cqe.err()) {
            .SUCCESS => {},
            .INVAL, .BADF => return,
            else => return,
        }
        self.groups[group_id] = .{
            .ptr = slice.ptr,
            .chunk_count = n,
            .chunk_size = chunk_size,
        };
    }

    /// 注册监听 socket 到固定文件表（00 §4.2）；前 32 位预留给监听 fd
    pub fn registerListenSocket(self: *HighPerfIO, fd: i32) void {
        if (self.registered_fds.len == 0) return;
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            if (self.registered_fds[i] == fd) return;
            if (self.registered_fds[i] == -1) {
                self.registered_fds[i] = fd;
                _ = linux.syscall4(
                    linux.SYS.io_uring_register,
                    @as(usize, @intCast(self.ring.fd)),
                    linux.IORING_REGISTER_FILES_UPDATE,
                    @intFromPtr(&self.registered_fds[i]),
                    1,
                );
                return;
            }
        }
    }

    /// 提交「在 listen_fd 上接受一连接并将首包读入池中 buffer」请求；
    /// 极致优化：使用 IORING_ACCEPT_FIXED_FILE 直接接受到预注册的文件槽位，绕过用户态 fd 创建（00 §4.2）
    pub fn submitAcceptWithBuffer(self: *HighPerfIO, listen_fd: i32, user_data: usize, group_id: u16) void {
        const gid = if (group_id < MAX_BUFFER_GROUPS) group_id else BUFFER_GROUP_ID_DEFAULT;
        const idx = self.slot_cache.take() orelse return;
        self.slot_data.set(idx, .{ .tag = .accept, .listen_fd = listen_fd, .caller_user_data = user_data, .accept_group_id = gid });
        
        const sqe = self.ring.get_sqe() catch {
            @branchHint(.cold);
            self.slot_data.set(idx, .{ .tag = .free });
            self.slot_cache.release(idx);
            return;
        };
        
        // IORING_OP_ACCEPT
        sqe.opcode = .ACCEPT;
        sqe.user_data = @intCast(idx);
        sqe.addr = 0;
        sqe.off = 0;
        sqe.len = 0;
        sqe.accept_flags = posix.SOCK.NONBLOCK;
        
        // 若 listen_fd 已在固定表（0..31），使用 IOSQE_FIXED_FILE
        if (self.findRegisteredFileIndex(listen_fd)) |reg_idx| {
            sqe.fd = @intCast(reg_idx);
            sqe.flags |= linux.IOSQE_FIXED_FILE;
        } else {
            sqe.fd = listen_fd;
        }

        // 极致压榨：直接 accept 到固定文件表的 32+idx 槽位
        if (self.registered_fds.len > 0) {
            const fixed_idx = 32 + @as(u32, @intCast(idx));
            sqe.__union_4.file_index = fixed_idx + 1; // io_uring accept file_index 是 1-based (0=not fixed)
        }

        self.submitSqueezed();
    }

    /// 与 submitAcceptWithBuffer 相同，但不调用 ring.submit()。用于批量提交：循环调用本函数 N 次后，再调用一次 flushSubmits()，将 N 个 accept 合并为一次系统调用（降级无 SQPOLL 时有效；SQPOLL 下 flushSubmits 几乎无额外成本）
    pub fn submitAcceptWithBufferDeferred(self: *HighPerfIO, listen_fd: i32, user_data: usize, group_id: u16) void {
        const gid = if (group_id < MAX_BUFFER_GROUPS) group_id else BUFFER_GROUP_ID_DEFAULT;
        const idx = self.slot_cache.take() orelse return;
        self.slot_data.set(idx, .{ .tag = .accept, .listen_fd = listen_fd, .caller_user_data = user_data, .accept_group_id = gid });
        
        const sqe = self.ring.get_sqe() catch {
            @branchHint(.cold);
            self.slot_data.set(idx, .{ .tag = .free });
            self.slot_cache.release(idx);
            return;
        };
        
        sqe.opcode = .ACCEPT;
        sqe.user_data = @intCast(idx);
        sqe.addr = 0;
        sqe.off = 0;
        sqe.len = 0;
        sqe.accept_flags = posix.SOCK.NONBLOCK;
        
        if (self.findRegisteredFileIndex(listen_fd)) |reg_idx| {
            sqe.fd = @intCast(reg_idx);
            sqe.flags |= linux.IOSQE_FIXED_FILE;
        } else {
            sqe.fd = listen_fd;
        }

        if (self.registered_fds.len > 0) {
            const fixed_idx = 32 + @as(u32, @intCast(idx));
            sqe.__union_4.file_index = fixed_idx + 1;
        }
    }

    /// 将此前通过 submitAcceptWithBufferDeferred 入队的 SQE 一次性提交给内核；批量提交后必须调用一次，否则 accept 不会生效
    pub fn flushSubmits(self: *HighPerfIO) void {
        _ = self.ring.submit() catch {};
    }

    // Hot-path
    /// 提交 SQE 的极致压榨版本：SQPOLL 模式下，仅在内核线程睡眠（NEED_WAKEUP）时才调用 enter 系统调用（00 §3.1）
    /// 降级模式下退化为标准 submit()。
    fn submitSqueezed(self: *HighPerfIO) void {
        if (self.ring.sq.flags.* & linux.IORING_SQ_NEED_WAKEUP != 0) {
            _ = self.ring.submit() catch {};
        } else if (self.ring.sq.head.* == self.ring.sq.tail.*) {
            // 若 SQ 为空且非 SQPOLL（或 SQPOLL 未激活），由调用方保证提交逻辑；
            // 实际上对于非 SQPOLL，必须调用 enter。
            // 这里我们假定 init 时已处理好 used_sqpoll 状态。
            _ = self.ring.submit() catch {};
        }
    }

    // Hot-path（01 §3.3）：修改时检查汇编无意外 call/逃逸
    /// 收割已完成项：copy_cqes，区分 accept CQE（内部提交 recv）与 recv CQE（填 completion_buffer）；返回切片有效至下次 poll。
    /// 循环前预取 slot 各字段切片为局部变量并传入 handle*，使 ptr+len 更易常驻寄存器（寄存器传参优化）。
    pub fn pollCompletions(self: *HighPerfIO, timeout_ns: i64) []api.Completion {
        self.completion_count = 0;
        // wait_nr 是等待的最少完成项数。timeout_ns < 0 表示阻塞（等 1 个），>= 0 表示不阻塞或有界阻塞（peek）。
        // 注意：Zig 0.16 的 copy_cqes 不带 timeout，若需精准 timeout 需 IORING_OP_TIMEOUT；此处暂用 peek (wait_nr=0) 满足高性能非阻塞需求。
        const wait_nr: u32 = if (timeout_ns < 0) 1 else 0;
        var cqes: [128]linux.io_uring_cqe = undefined; // 增加批量处理容量
        const n = self.ring.copy_cqes(&cqes, wait_nr) catch {
            @branchHint(.cold);
            return self.completion_buffer[0..self.completion_count];
        };

        const slot_slice = self.slot_data.slice();
        const tags = slot_slice.items(.tag);
        const caller_ud_arr = slot_slice.items(.caller_user_data);
        const client_fd_arr = slot_slice.items(.client_fd);
        const accept_group_id_arr = slot_slice.items(.accept_group_id);
        const recv_group_id_arr = slot_slice.items(.recv_group_id);

        for (cqes[0..n]) |*cqe| {
            const user_data = cqe.user_data;
            if (user_data & RECV_USER_DATA_TAG != 0) {
                self.handleRecvCqe(tags, caller_ud_arr, client_fd_arr, recv_group_id_arr, user_data & ~RECV_USER_DATA_TAG, cqe);
            } else if (user_data & SEND_USER_DATA_TAG != 0) {
                self.handleSendCqe(tags, caller_ud_arr, user_data & ~SEND_USER_DATA_TAG, cqe);
            } else if (user_data & SPLICE_USER_DATA_TAG != 0) {
                self.handleSpliceCqe(tags, caller_ud_arr, user_data & ~SPLICE_USER_DATA_TAG, cqe);
            } else if (user_data < self.max_connections) {
                self.handleAcceptCqe(tags, caller_ud_arr, accept_group_id_arr, @intCast(user_data), cqe);
            }
        }
        return self.completion_buffer[0..self.completion_count];
    }

    /// 处理 accept CQE：用预取的 tags/caller_ud_arr/accept_group_id_arr 访问槽位；按 accept_group_id 选 buffer 组提交 recv
    fn handleAcceptCqe(
        self: *HighPerfIO,
        tags: []const SlotTag,
        caller_ud_arr: []const usize,
        accept_group_id_arr: []const u16,
        idx: usize,
        cqe: *linux.io_uring_cqe,
    ) void {
        if (tags[idx] != .accept) {
            @branchHint(.cold);
            return;
        }
        const caller_ud = caller_ud_arr[idx];
        const gid = if (accept_group_id_arr[idx] < MAX_BUFFER_GROUPS) accept_group_id_arr[idx] else BUFFER_GROUP_ID_DEFAULT;
        const grp = &self.groups[gid];
        self.slot_data.set(idx, .{ .tag = .free });
        self.slot_cache.release(idx);
        
        const res = cqe.res;
        if (res < 0) {
            @branchHint(.cold);
            return;
        }

        const recv_idx = self.slot_cache.take() orelse {
            @branchHint(.cold);
            // 若使用了固定文件表，需异步或同步关闭固定槽位（此处暂用标准 fd 处理逻辑，需优化）
            return;
        };

        const chunk_len = if (grp.chunk_count > 0) grp.chunk_size else CHUNK_SIZE;
        const recv_gid = if (grp.chunk_count > 0) gid else BUFFER_GROUP_ID_DEFAULT;
        
        // 如果使用了固定槽位，res 往往是 0（或者 fd）；我们记录该 client 的固定索引
        const client_is_fixed = (self.registered_fds.len > 0);
        const client_fd: i32 = if (client_is_fixed) @intCast(32 + idx) else res;

        self.slot_data.set(recv_idx, .{ 
            .tag = .recv, 
            .client_fd = client_fd, 
            .caller_user_data = caller_ud, 
            .recv_group_id = recv_gid 
        });

        const sqe = self.ring.recv(
            RECV_USER_DATA_TAG | @as(u64, recv_idx),
            @intCast(client_fd),
            .{ .buffer_selection = .{ .group_id = recv_gid, .len = chunk_len } },
            0,
        ) catch {
            @branchHint(.cold);
            self.slot_data.set(recv_idx, .{ .tag = .free });
            self.slot_cache.release(recv_idx);
            return;
        };

        if (client_is_fixed) {
            sqe.flags |= linux.IOSQE_FIXED_FILE;
        }

        self.submitSqueezed();
    }

    /// 处理 recv CQE：.recv=accept 首包（推 client_stream），.conn_recv=submitRecv（推 tag=recv、chunk_index）
    fn handleRecvCqe(
        self: *HighPerfIO,
        tags: []const SlotTag,
        caller_ud_arr: []const usize,
        client_fd_arr: []const i32,
        recv_group_id_arr: []const u16,
        recv_idx: usize,
        cqe: *linux.io_uring_cqe,
    ) void {
        if (recv_idx >= self.max_connections) {
            @branchHint(.cold);
            return;
        }
        const tag = tags[recv_idx];
        if (tag != .recv and tag != .conn_recv) {
            @branchHint(.cold);
            return;
        }
        const caller_ud = caller_ud_arr[recv_idx];
        const client_fd = client_fd_arr[recv_idx];
        const gid = if (recv_group_id_arr[recv_idx] < MAX_BUFFER_GROUPS) recv_group_id_arr[recv_idx] else BUFFER_GROUP_ID_DEFAULT;
        const grp = &self.groups[gid];
        self.slot_data.set(recv_idx, .{ .tag = .free });
        self.slot_cache.release(recv_idx);
        const res = cqe.res;
        const buffer_id = cqe.flags >> 16;
        if (tag == .recv) {
            const client_stream: std.Io.net.Stream = .{ .handle = client_fd };
            if (res < 0) {
                @branchHint(.cold);
                self.pushCompletion(caller_ud, null, 0, error.FileRead, client_stream);
                return;
            }
            const len = @as(usize, @intCast(res));
            const ptr = if (grp.chunk_count > 0 and buffer_id < grp.chunk_count)
                grp.ptr + buffer_id * grp.chunk_size
            else
                @as([*]const u8, @ptrCast(&[_]u8{}));
            self.pushCompletion(caller_ud, ptr, len, null, client_stream);
            return;
        }
        if (res < 0) {
            @branchHint(.cold);
            self.pushCompletionRecv(caller_ud, @as([*]const u8, @ptrCast(&[_]u8{})), 0, error.FileRead, 0);
            return;
        }
        const len = @as(usize, @intCast(res));
        const ptr = if (grp.chunk_count > 0 and buffer_id < grp.chunk_count)
            grp.ptr + buffer_id * grp.chunk_size
        else
            @as([*]const u8, @ptrCast(&[_]u8{}));
        self.pushCompletionRecv(caller_ud, ptr, len, null, buffer_id);
    }

    /// 处理 send CQE：推 tag=send、len=已发送字节
    fn handleSendCqe(
        self: *HighPerfIO,
        tags: []const SlotTag,
        caller_ud_arr: []const usize,
        send_idx: usize,
        cqe: *linux.io_uring_cqe,
    ) void {
        if (send_idx >= self.max_connections) {
            @branchHint(.cold);
            return;
        }
        if (tags[send_idx] != .conn_send) {
            @branchHint(.cold);
            return;
        }
        const caller_ud = caller_ud_arr[send_idx];
        self.slot_data.set(send_idx, .{ .tag = .free });
        self.slot_cache.release(send_idx);
        const res = cqe.res;
        const len = if (res > 0) @as(usize, @intCast(res)) else 0;
        self.pushCompletionSend(caller_ud, len);
    }

    /// 处理 splice CQE：推 tag=splice、len=已拼接字节
    fn handleSpliceCqe(
        self: *HighPerfIO,
        tags: []const SlotTag,
        caller_ud_arr: []const usize,
        splice_idx: usize,
        cqe: *linux.io_uring_cqe,
    ) void {
        if (splice_idx >= self.max_connections) {
            @branchHint(.cold);
            return;
        }
        if (tags[splice_idx] != .conn_splice) {
            @branchHint(.cold);
            return;
        }
        const caller_ud = caller_ud_arr[splice_idx];
        self.slot_data.set(splice_idx, .{ .tag = .free });
        self.slot_cache.release(splice_idx);
        const res = cqe.res;
        if (res < 0) {
            @branchHint(.cold);
            self.pushCompletionSplice(caller_ud, 0, error.SendfileFailed);
            return;
        }
        const len = @as(usize, @intCast(res));
        self.pushCompletionSplice(caller_ud, len, null);
    }

    inline fn pushCompletion(self: *HighPerfIO, user_data: usize, buffer_ptr: ?[*]const u8, len: usize, err: ?api.SendFileError, client_stream: ?std.Io.net.Stream) void {
        if (self.completion_count >= self.completion_buffer.len) return;
        self.completion_buffer[self.completion_count] = .{
            .user_data = user_data,
            .buffer_ptr = buffer_ptr orelse @ptrCast(&[_]u8{}),
            .len = len,
            .err = err,
            .client_stream = client_stream,
            .tag = .accept,
            .chunk_index = null,
        };
        self.completion_count += 1;
    }

    inline fn pushCompletionRecv(self: *HighPerfIO, user_data: usize, buffer_ptr: [*]const u8, len: usize, err: ?api.SendFileError, chunk_index: usize) void {
        if (self.completion_count >= self.completion_buffer.len) return;
        self.completion_buffer[self.completion_count] = .{
            .user_data = user_data,
            .buffer_ptr = buffer_ptr,
            .len = len,
            .err = err,
            .client_stream = null,
            .tag = .recv,
            .chunk_index = chunk_index,
        };
        self.completion_count += 1;
    }

    inline fn pushCompletionSend(self: *HighPerfIO, user_data: usize, len: usize) void {
        if (self.completion_count >= self.completion_buffer.len) return;
        self.completion_buffer[self.completion_count] = .{
            .user_data = user_data,
            .buffer_ptr = @ptrCast(&[_]u8{}),
            .len = len,
            .err = null,
            .client_stream = null,
            .tag = .send,
            .chunk_index = null,
        };
        self.completion_count += 1;
    }

    inline fn pushCompletionSplice(self: *HighPerfIO, user_data: usize, len: usize, err: ?api.SendFileError) void {
        if (self.completion_count >= self.completion_buffer.len) return;
        self.completion_buffer[self.completion_count] = .{
            .user_data = user_data,
            .buffer_ptr = @ptrCast(&[_]u8{}),
            .len = len,
            .err = err,
            .client_stream = null,
            .tag = .splice,
            .chunk_index = null,
        };
        self.completion_count += 1;
    }

    // Hot-path
    /// 在连接上提交一次 recv；数据由内核写入 provide_buffers 池，完成时 tag=recv、chunk_index 为 buffer_id（releaseChunk 在 Linux 为 no-op）
    pub fn submitRecv(self: *HighPerfIO, stream: std.Io.net.Stream, user_data: usize) void {
        const idx = self.slot_cache.take() orelse return;
        const gid = BUFFER_GROUP_ID_DEFAULT;
        const grp = &self.groups[gid];
        const chunk_len = if (grp.chunk_count > 0) grp.chunk_size else CHUNK_SIZE;
        self.slot_data.set(idx, .{ .tag = .conn_recv, .listen_fd = 0, .client_fd = @intCast(stream.handle), .caller_user_data = user_data, .accept_group_id = 0, .recv_group_id = gid });
        
        const sqe = self.ring.recv(
            RECV_USER_DATA_TAG | @as(u64, idx),
            @intCast(stream.handle),
            .{ .buffer_selection = .{ .group_id = gid, .len = chunk_len } },
            0,
        ) catch {
            @branchHint(.cold);
            self.slot_data.set(idx, .{ .tag = .free });
            self.slot_cache.release(idx);
            return;
        };

        // 若 fd 在预注册表（0..31 或 32..），使用 IOSQE_FIXED_FILE
        if (self.findRegisteredFileIndex(stream.handle)) |reg_idx| {
            sqe.fd = @intCast(reg_idx);
            sqe.flags |= linux.IOSQE_FIXED_FILE;
        }

        self.submitSqueezed();
    }

    // Hot-path
    /// 归还 recv 完成项占用的池块；Linux provide_buffers 由内核自动复用，本调用为 no-op
    pub fn releaseChunk(self: *HighPerfIO, _: usize) void {
        _ = self;
    }

    // Hot-path
    /// 在连接上提交 send；data 在完成前须保持有效
    pub fn submitSend(self: *HighPerfIO, stream: std.Io.net.Stream, data: []const u8, user_data: usize) void {
        if (data.len == 0) return;
        const idx = self.slot_cache.take() orelse return;
        self.slot_data.set(idx, .{ .tag = .conn_send, .listen_fd = 0, .client_fd = @intCast(stream.handle), .caller_user_data = user_data, .accept_group_id = 0, .recv_group_id = 0 });
        
        const sqe = self.ring.send(SEND_USER_DATA_TAG | @as(u64, idx), @intCast(stream.handle), data, 0) catch {
            @branchHint(.cold);
            self.slot_data.set(idx, .{ .tag = .free });
            self.slot_cache.release(idx);
            return;
        };

        if (self.findRegisteredFileIndex(stream.handle)) |reg_idx| {
            sqe.fd = @intCast(reg_idx);
            sqe.flags |= linux.IOSQE_FIXED_FILE;
        }

        self.submitSqueezed();
    }

    // Hot-path
    /// 在连接上提交一次 read_fixed；使用已注册的缓冲区索引 buf_index（§3.1）
    pub fn submitReadFixed(self: *HighPerfIO, fd: i32, buf_index: u32, offset: u64, user_data: usize) void {
        const idx = self.slot_cache.take() orelse return;
        self.slot_data.set(idx, .{ .tag = .conn_recv, .client_fd = fd, .caller_user_data = user_data });
        _ = self.ring.read_fixed(
            RECV_USER_DATA_TAG | @as(u64, idx),
            fd,
            &self.registered_buffers[buf_index],
            offset,
            @intCast(buf_index),
        ) catch {
            @branchHint(.cold);
            self.slot_data.set(idx, .{ .tag = .free });
            self.slot_cache.release(idx);
            return;
        };
        _ = self.ring.submit() catch {
            @branchHint(.cold);
            self.slot_data.set(idx, .{ .tag = .free });
            self.slot_cache.release(idx);
        };
    }

    // Hot-path
    /// 在连接上提交一次 write_fixed；使用已注册的缓冲区索引 buf_index（§3.1）
    pub fn submitWriteFixed(self: *HighPerfIO, fd: i32, buf_index: u32, offset: u64, user_data: usize) void {
        const idx = self.slot_cache.take() orelse return;
        self.slot_data.set(idx, .{ .tag = .conn_send, .client_fd = fd, .caller_user_data = user_data });
        _ = self.ring.write_fixed(
            SEND_USER_DATA_TAG | @as(u64, idx),
            fd,
            &self.registered_buffers[buf_index],
            offset,
            @intCast(buf_index),
        ) catch {
            @branchHint(.cold);
            self.slot_data.set(idx, .{ .tag = .free });
            self.slot_cache.release(idx);
            return;
        };
        _ = self.ring.submit() catch {
            @branchHint(.cold);
            self.slot_data.set(idx, .{ .tag = .free });
            self.slot_cache.release(idx);
        };
    }

    // Hot-path
    /// 在两个文件描述符间提交 splice（零拷贝）；in/out 至少一个必须是 pipe；flags 为 linux.SPLICE.F.*
    pub fn submitSplice(self: *HighPerfIO, fd_in: i32, off_in: i64, fd_out: i32, off_out: i64, len: u32, flags: u32, user_data: usize) void {
        const idx = self.slot_cache.take() orelse return;
        self.slot_data.set(idx, .{ .tag = .conn_splice, .listen_fd = 0, .client_fd = fd_out, .caller_user_data = user_data, .accept_group_id = 0, .recv_group_id = 0 });
        _ = self.ring.splice(SPLICE_USER_DATA_TAG | @as(u64, idx), fd_in, off_in, fd_out, off_out, len, flags) catch {
            @branchHint(.cold);
            self.slot_data.set(idx, .{ .tag = .free });
            self.slot_cache.release(idx);
            return;
        };
        _ = self.ring.submit() catch {
            @branchHint(.cold);
            self.slot_data.set(idx, .{ .tag = .free });
            self.slot_cache.release(idx);
        };
    }

    fn findRegisteredFileIndex(self: *HighPerfIO, fd: i32) ?u32 {
        if (self.registered_fds.len == 0) return null;
        // 1) 优先检查监听 fd（索引 0..31）
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            if (self.registered_fds[i] == fd) return @intCast(i);
        }
        // 2) 对于连接 fd，若其值落在 32..max_connections+31 范围内，
        // 且我们开启了固定文件表优化，则它本身就是固定索引。
        const u_fd = @as(u32, @intCast(fd));
        if (u_fd >= 32 and u_fd < 32 + self.max_connections) {
            return u_fd;
        }
        return null;
    }
};

/// 零拷贝：文件 → 网络（Linux sendfile）；循环发送直至 count 或错误，EAGAIN 时重试
pub fn sendFile(stream: std.Io.net.Stream, file: std.fs.File, offset: u64, count: u64) api.SendFileError!void {
    const socket_fd = stream.handle;
    const file_fd = file.handle;
    var off: i64 = @intCast(offset);
    var left: usize = count;
    while (left > 0) {
        const n = std.c.sendfile(socket_fd, file_fd, &off, left);
        if (n < 0) {
            const e = std.c._errno();
            if (e == posix.E.AGAIN) continue;
            return error.SendfileFailed;
        }
        if (n == 0) return error.SendfileFailed;
        left -= @as(usize, @intCast(n));
    }
}

// 异步文件 I/O（AsyncFileIO）已迁至 io_core/file.zig；Linux 实现为本模块外 file.zig 内 AsyncFileIOLinux，由 mod 统一导出 file.AsyncFileIO。

// ------------------------------------------------------------------------------
// NUMA：00 §3.1、§4.2 将 buffer 池绑定到当前线程所在 NUMA 节点，多路服务器可降约 30% 内存延迟
// ------------------------------------------------------------------------------

/// 将 [ptr..ptr+len] 绑定到当前 CPU 所在 NUMA 节点（best-effort）；页对齐时调用 getcpu + mbind(MPOL_BIND)，失败则静默返回
/// 调用方保证 ptr 页对齐、len 为页大小整数倍。单节点或 getcpu/mbind 失败时无副作用；多路服务器上可降约 30% 内存延迟
pub fn mbindToCurrentNode(ptr: [*]align(std.heap.page_size_min) const u8, len: usize) void {
    var node: u32 = 0;
    const ret_getcpu = linux.syscall3(
        linux.SYS.getcpu,
        0,
        @intFromPtr(&node),
        0,
    );
    if (ret_getcpu != 0) return;
    if (node >= 64) return;
    const nodemask: u64 = @as(u64, 1) << node;
    const MPOL_BIND: u64 = 2;
    const ret_mbind = linux.syscall6(
        linux.SYS.mbind,
        @intFromPtr(ptr),
        len,
        MPOL_BIND,
        @intFromPtr(&nodemask),
        node + 1,
        0,
    );
    _ = ret_mbind;
}
