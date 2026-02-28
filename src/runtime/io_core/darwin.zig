// macOS (Darwin) 平台 I/O 核心（darwin.zig）：kqueue 边缘触发 + sendfile 零拷贝。
//
// 职责
//   - 实现 HighPerfIO：单 kqueue、预分配 buffer 池分块、accept 后对 client 做 EVFILT_READ 边缘触发，读入池中块；
//   - 实现 sendFile：文件→网络零拷贝，BSD sendfile(file_fd, socket_fd, offset, &len, ...)，循环直至发完或错误。
//
// 规范对应（00-性能规则）
//   - §4.1：I/O 多路复用用 kqueue，边缘触发 EV_CLEAR；每线程独立 kqueue；文件→网络 sendfile；
//   - 无内核 PROVIDE_BUFFERS 等价物，采用用户态预分配池 + accept 后 read 进池，与 Linux 语义一致。
//
// 数据流简述
//   - registerBufferPool：按 CHUNK_SIZE（64KB）分块，建立 free_list；
//   - submitAcceptWithBuffer：将 (listen_fd, user_data) 加入 pending_accepts，listen_fd 首次时 kevent EV_ADD+EV_CLEAR；
//   - pollCompletions：kevent 取事件，listen 可读时 handleListenReady（accept、取池块、对 client 注册 EVFILT_READ、写入 client_info），client 可读时 handleClientReady（read 入池块、填 completion、关闭 fd、归还块）。
//
// 内存与释放
//   - 显式 allocator（§1.5）：free_list、pending_accepts、listen_fds、slot_data、free_slots、changelist 等 deinit 时释放；未完成的 client 槽位会 close(fd)。
//
// --- 进阶压榨（已做）---
// 1) 批量 Kevent：changelist 累积 EV_ADD/EV_DELETE，在 pollCompletions 开头一次 kevent(changelist, events) 提交，系统调用从 O(N) 降至 O(1)。
// 2) udata 零查找：client 用槽位索引存 ev.udata，热路径直接 slot_data[ev.udata] 取上下文，去掉 client_info HashMap。
// 3) 边缘触发循环 accept：handleListenReady 内循环 accept 直至 EAGAIN，一次唤醒处理完所有积压连接。
// 4) 槽位化：slot_data (SoA) + free_slots，与 Linux 版槽位模型对齐；pending_accepts 保留为列表（按 listen_fd 取一即可）。
//
// --- 物理极限级（最后 1%）---
// 5) 预分配 changelist：固定 []Kevent 替代 ArrayList，消除扩容带来的延迟毛刺；容量 4*max_connections+32（含 EVFILT_READ+WRITE 双通道）。
// 6) 单系统调用读写：kevent(kq, changelist, events) 已在一轮内完成「提交变更 + 取事件」；EV_DELETE 入 changelist 下一轮提交，无需额外 kevent。
// 7) M 芯片 L3 友好：原 ClientSlot 32 字节对齐；可选 SoA 见下。
//
// --- 黑魔法级（可选，收益约 1–2%）---
// 8) SoA：与 Linux 版对齐，使用 ClientFields + MultiArrayList；热路径只加载 client_fd 数组，缓存局部性更佳；代价为失去单槽 32 字节对齐。
// 9) EVFILT_WRITE 预热：accept 后同时注册 EVFILT_WRITE（边缘触发 EV_CLEAR），内核在 socket 可写时即通知，sendfile 启动更早。
// 10) M 芯片线程拓扑：setIoThreadQosUserInteractive() 在 I/O 线程调用，将当前线程设为 USER_INTERACTIVE，尽量跑在 P 核。
//
// --- 与 Linux 的差异 ---
// 大页/Splice/ATTACH_WQ 为 io_uring 特性，Darwin 无直接对应。sendfile 可扩展 sf_hdtr（header+file+trailer 一次系统调用），见 sendFile 注释。

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const api = @import("api.zig");

/// 每块 buffer 大小（与 Linux 64K 对齐，便于池布局一致）
const CHUNK_SIZE = 64 * 1024;

/// 单条待处理 accept：(listen_fd, user_data)，EVFILT_READ 时取一、accept、再读入池
const PendingAccept = struct { listen_fd: i32, user_data: usize };

/// 槽位操作类型：accept 首包读 vs 连接后续 recv（均用 EVFILT_READ + udata=slot_index）
const SlotOp = enum { accept_first_read, conn_recv };

/// 槽位 SoA 字段：与 Linux SlotFields 对齐，热路径只摸 client_fd/user_data/chunk_index 连续数组，缓存友好
const ClientFields = struct {
    op_kind: SlotOp = .accept_first_read,
    user_data: usize = 0,
    chunk_index: usize = 0,
    client_fd: i32 = -1,
};

/// 平台句柄：kqueue + 预分配 buffer 池分块 + 完成项数组 + changelist 批量提交 + 槽位化 client
pub const HighPerfIO = struct {
    allocator: std.mem.Allocator,
    kq_fd: i32,
    completion_buffer: []api.Completion,
    completion_count: usize,
    max_connections: usize,

    pool_ptr: [*]const u8 = undefined,
    chunk_count: usize = 0,
    free_list: std.ArrayList(usize),
    /// 线程本地块缓存，take/release 绝大多数命中本地栈，空/满时与 free_list 批量交换（见 api.ThreadLocalChunkCache）
    chunk_cache: api.ThreadLocalChunkCache = undefined,

    /// 待处理 (listen_fd, user_data)；边缘触发时循环取一、accept、直至 EAGAIN
    pending_accepts: std.ArrayList(PendingAccept),
    listen_fds: std.AutoHashMap(i32, void),
    /// 槽位 SoA：ev.udata = slot_index，热路径只摸 client_fd 等连续数组（与 Linux 版一致）
    slot_data: std.MultiArrayList(ClientFields),
    /// 空闲 client 槽位索引
    free_slots: std.ArrayList(usize),

    /// 预分配 changelist 缓冲区（固定大小，无扩容毛刺）；changelist_len 为当前有效长度
    changelist: []posix.Kevent,
    changelist_len: usize = 0,
    /// kevent 返回的 events 数组
    events: []posix.Kevent,

    /// 初始化 Darwin I/O 子系统：创建 kqueue、分配完成项/events/changelist/client 槽位（§4.1 每线程独立 kqueue）
    pub fn init(allocator: std.mem.Allocator, options: api.InitOptions) !HighPerfIO {
        const kq_fd = posix.kqueue() catch return error.SystemResources;
        errdefer posix.close(kq_fd);

        const completion_buffer = try allocator.alloc(api.Completion, options.max_completions);
        errdefer allocator.free(completion_buffer);

        const max_ev = options.max_connections * 2;
        const events = try allocator.alloc(posix.Kevent, max_ev);
        errdefer allocator.free(events);

        var slot_data = std.MultiArrayList(ClientFields){};
        errdefer slot_data.deinit(allocator);
        try slot_data.ensureTotalCapacity(allocator, options.max_connections);
        for (0..options.max_connections) |_| {
            slot_data.appendAssumeCapacity(.{ .op_kind = .accept_first_read, .client_fd = -1 });
        }

        var free_slots = try std.ArrayList(usize).initCapacity(allocator, options.max_connections);
        errdefer free_slots.deinit(allocator);
        for (0..options.max_connections) |i| {
            free_slots.appendAssumeCapacity(i);
        }

        const changelist_cap = options.max_connections * 4 + 32;
        const changelist = try allocator.alloc(posix.Kevent, changelist_cap);
        errdefer allocator.free(changelist);

        return .{
            .allocator = allocator,
            .kq_fd = kq_fd,
            .completion_buffer = completion_buffer,
            .completion_count = 0,
            .max_connections = options.max_connections,
            .free_list = try std.ArrayList(usize).initCapacity(allocator, 0),
            .pending_accepts = try std.ArrayList(PendingAccept).initCapacity(allocator, 0),
            .listen_fds = std.AutoHashMap(i32, void).init(allocator),
            .slot_data = slot_data,
            .free_slots = free_slots,
            .changelist = changelist,
            .changelist_len = 0,
            .events = events,
        };
    }

    /// 释放 kqueue、所有堆内存（§1.5 显式 allocator 释放）；仅关闭 accept 首包阶段的 fd，conn_recv 的 stream 由调用方持有
    pub fn deinit(self: *HighPerfIO) void {
        const op_kinds = self.slot_data.items(.op_kind);
        const client_fds = self.slot_data.items(.client_fd);
        for (op_kinds, client_fds) |op, fd| {
            if (fd >= 0 and op == .accept_first_read) posix.close(fd);
        }
        posix.close(self.kq_fd);
        self.allocator.free(self.completion_buffer);
        self.allocator.free(self.events);
        self.slot_data.deinit(self.allocator);
        self.free_list.deinit(self.allocator);
        self.pending_accepts.deinit(self.allocator);
        self.listen_fds.deinit();
        self.free_slots.deinit(self.allocator);
        self.allocator.free(self.changelist);
        self.* = undefined;
    }

    /// 向实现注册 buffer 池：按 CHUNK_SIZE 分块，建立 free_list 并绑定线程本地 chunk_cache
    pub fn registerBufferPool(self: *HighPerfIO, pool: *api.BufferPool) void {
        const slice = pool.slice();
        if (slice.len < CHUNK_SIZE) return;
        self.chunk_count = slice.len / CHUNK_SIZE;
        self.pool_ptr = slice.ptr;
        self.free_list.clearRetainingCapacity();
        self.free_list.ensureTotalCapacity(self.allocator, self.chunk_count) catch return;
        for (0..self.chunk_count) |i| {
            self.free_list.appendAssumeCapacity(@intCast(i));
        }
        self.chunk_cache = api.ThreadLocalChunkCache.init(&self.free_list, self.allocator);
    }

    /// 提交「在 listen_fd 上接受一连接并将首包读入池中 buffer」请求；user_data 在完成时原样带回。EV_ADD 入 changelist，下次 pollCompletions 时批量提交
    pub fn submitAcceptWithBuffer(self: *HighPerfIO, listen_fd: i32, user_data: usize) void {
        self.pending_accepts.append(self.allocator, .{ .listen_fd = listen_fd, .user_data = user_data }) catch return;
        if (!self.listen_fds.contains(listen_fd)) {
            _ = self.pushChangelist(.{
                .ident = @intCast(listen_fd),
                .filter = posix.system.EVFILT.READ,
                .flags = posix.system.EV.ADD | posix.system.EV.CLEAR,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            });
            self.listen_fds.put(listen_fd, {}) catch return;
        }
    }

    /// 将当前线程设为 USER_INTERACTIVE QoS，便于 M 芯片调度到 P 核；需在运行 pollCompletions 的 I/O 线程内调用一次（如事件循环入口）
    pub fn setIoThreadQosUserInteractive(self: *HighPerfIO) void {
        _ = self;
        if (builtin.os.tag == .macos) {
            setDarwinThreadQosUserInteractive();
        }
    }

    /// 向预分配 changelist 追加一条（不扩容，避免延迟毛刺）；满则返回 false，调用方需做清理
    inline fn pushChangelist(self: *HighPerfIO, ev: posix.Kevent) bool {
        if (self.changelist_len < self.changelist.len) {
            self.changelist[self.changelist_len] = ev;
            self.changelist_len += 1;
            return true;
        }
        return false;
    }

    /// 收割已完成项：先一次 kevent(changelist, events) 批量提交并取事件，再处理 listen/client；返回切片有效至下次 poll
    pub fn pollCompletions(self: *HighPerfIO, timeout_ns: i64) []api.Completion {
        self.completion_count = 0;
        var ts: posix.timespec = undefined;
        const timeout_ptr: ?*const posix.timespec = if (timeout_ns < 0) null else blk: {
            ts.sec = @intCast(@divTrunc(timeout_ns, std.time.ns_per_s));
            ts.nsec = @intCast(@mod(timeout_ns, std.time.ns_per_s));
            break :blk &ts;
        };
        const ch_slice = self.changelist[0..self.changelist_len];
        const n = posix.kevent(self.kq_fd, ch_slice, self.events, timeout_ptr) catch return self.completion_buffer[0..self.completion_count];
        self.changelist_len = 0;

        const pool_ptr = self.pool_ptr;
        const op_kinds = self.slot_data.items(.op_kind);
        const client_fds = self.slot_data.items(.client_fd);
        for (self.events[0..n]) |*ev| {
            const fd = @as(i32, @intCast(ev.ident));
            if (self.listen_fds.contains(fd)) {
                self.handleListenReady(fd, pool_ptr);
            } else {
                const slot_index = ev.udata;
                if (slot_index < self.max_connections and client_fds[slot_index] >= 0) {
                    if (op_kinds[slot_index] == .conn_recv) {
                        self.handleConnRecvReady(@intCast(slot_index), pool_ptr);
                    } else {
                        self.handleClientReady(@intCast(slot_index), pool_ptr);
                    }
                }
            }
        }
        return self.completion_buffer[0..self.completion_count];
    }

    /// 边缘触发：循环 accept 直至 EAGAIN，每次成功取一 pending、占一 client 槽位、EV_ADD 入 changelist（udata=slot_index）
    fn handleListenReady(self: *HighPerfIO, listen_fd: i32, _: [*]const u8) void {
        while (true) {
            var i: usize = 0;
            while (i < self.pending_accepts.items.len) {
                if (self.pending_accepts.items[i].listen_fd == listen_fd) break;
                i += 1;
            }
            if (i >= self.pending_accepts.items.len) return;
            const user_data = self.pending_accepts.swapRemove(i).user_data;

            const chunk_index = self.chunk_cache.take() orelse {
                self.pushCompletion(user_data, null, 0, error.SocketWrite, null);
                continue;
            };
            var addr: posix.sockaddr = undefined;
            var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
            const client_fd = posix.accept(listen_fd, &addr, &addr_len, posix.SOCK.NONBLOCK) catch |err| {
                if (err == posix.AcceptError.WouldBlock) {
                    self.pending_accepts.append(self.allocator, .{ .listen_fd = listen_fd, .user_data = user_data }) catch {};
                    self.chunk_cache.release(chunk_index);
                    return;
                }
                self.pushCompletion(user_data, null, 0, error.SocketWrite, null);
                self.chunk_cache.release(chunk_index);
                return;
            };
            setNonBlocking(client_fd) catch {
                posix.close(client_fd);
                self.chunk_cache.release(chunk_index);
                self.pending_accepts.append(self.allocator, .{ .listen_fd = listen_fd, .user_data = user_data }) catch {};
                return;
            };
            const slot_index = self.free_slots.pop() orelse {
                posix.close(client_fd);
                self.chunk_cache.release(chunk_index);
                self.pending_accepts.append(self.allocator, .{ .listen_fd = listen_fd, .user_data = user_data }) catch {};
                return;
            };
            self.slot_data.set(slot_index, .{ .op_kind = .accept_first_read, .user_data = user_data, .chunk_index = chunk_index, .client_fd = client_fd });
            if (!self.pushChangelist(.{
                .ident = @intCast(client_fd),
                .filter = posix.system.EVFILT.READ,
                .flags = posix.system.EV.ADD | posix.system.EV.CLEAR,
                .fflags = 0,
                .data = 0,
                .udata = slot_index,
            })) {
                self.slot_data.set(slot_index, .{ .op_kind = .accept_first_read, .client_fd = -1 });
                self.free_slots.append(self.allocator, slot_index) catch {};
                posix.close(client_fd);
                self.chunk_cache.release(chunk_index);
                self.pending_accepts.append(self.allocator, .{ .listen_fd = listen_fd, .user_data = user_data }) catch {};
                return;
            }
            _ = self.pushChangelist(.{
                .ident = @intCast(client_fd),
                .filter = posix.system.EVFILT.WRITE,
                .flags = posix.system.EV.ADD | posix.system.EV.CLEAR,
                .fflags = 0,
                .data = 0,
                .udata = slot_index,
            });
        }
    }

    /// 通过 udata 拿到的 slot_index 取上下文，EV_DELETE READ+WRITE 入 changelist，读池块、填 completion、归还槽位与 chunk
    fn handleClientReady(self: *HighPerfIO, slot_index: usize, pool_ptr: [*]const u8) void {
        const slice = self.slot_data.slice();
        const client_fd = slice.items(.client_fd)[slot_index];
        const user_data = slice.items(.user_data)[slot_index];
        const chunk_index = slice.items(.chunk_index)[slot_index];
        self.slot_data.set(slot_index, .{ .client_fd = -1 });
        self.free_slots.append(self.allocator, slot_index) catch {};

        _ = self.pushChangelist(.{
            .ident = @intCast(client_fd),
            .filter = posix.system.EVFILT.READ,
            .flags = posix.system.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        });
        _ = self.pushChangelist(.{
            .ident = @intCast(client_fd),
            .filter = posix.system.EVFILT.WRITE,
            .flags = posix.system.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        });
        defer self.chunk_cache.release(chunk_index);
        const client_stream: std.net.Stream = .{ .handle = client_fd };

        if (chunk_index >= self.chunk_count) {
            posix.close(client_fd);
            return;
        }
        const buf = @as([*]u8, @ptrCast(@constCast(pool_ptr + chunk_index * CHUNK_SIZE)))[0..CHUNK_SIZE];
        const n = posix.read(client_fd, buf) catch {
            self.pushCompletion(user_data, buf.ptr, 0, error.FileRead, client_stream);
            return;
        };
        if (n <= 0) {
            self.pushCompletion(user_data, buf.ptr, 0, null, client_stream);
            return;
        }
        self.pushCompletion(user_data, buf.ptr, @as(usize, @intCast(n)), null, client_stream);
    }

    /// 连接 recv 完成：读入池块，填 tag=recv 的 completion（含 chunk_index），EV_DELETE 并归还槽位；chunk 由调用方 releaseChunk 归还
    fn handleConnRecvReady(self: *HighPerfIO, slot_index: usize, pool_ptr: [*]const u8) void {
        const slice = self.slot_data.slice();
        const client_fd = slice.items(.client_fd)[slot_index];
        const user_data = slice.items(.user_data)[slot_index];
        const chunk_index = slice.items(.chunk_index)[slot_index];
        self.slot_data.set(slot_index, .{ .op_kind = .conn_recv, .client_fd = -1 });
        self.free_slots.append(self.allocator, slot_index) catch {};

        _ = self.pushChangelist(.{
            .ident = @intCast(client_fd),
            .filter = posix.system.EVFILT.READ,
            .flags = posix.system.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        });
        if (chunk_index >= self.chunk_count) return;
        const buf = @as([*]u8, @ptrCast(@constCast(pool_ptr + chunk_index * CHUNK_SIZE)))[0..CHUNK_SIZE];
        const n = posix.read(client_fd, buf) catch {
            self.pushCompletionRecv(user_data, buf.ptr, 0, error.FileRead, chunk_index);
            return;
        };
        self.pushCompletionRecv(user_data, buf.ptr, @as(usize, @intCast(n)), null, chunk_index);
    }

    /// 在连接上提交一次 recv；数据写入池块，完成时 tag=recv、chunk_index 有效，用毕须 releaseChunk
    pub fn submitRecv(self: *HighPerfIO, stream: std.net.Stream, user_data: usize) void {
        const client_fd = stream.handle;
        const chunk_index = self.chunk_cache.take() orelse return;
        const slot_index = self.free_slots.pop() orelse {
            self.chunk_cache.release(chunk_index);
            return;
        };
        self.slot_data.set(slot_index, .{ .op_kind = .conn_recv, .user_data = user_data, .chunk_index = chunk_index, .client_fd = client_fd });
        _ = self.pushChangelist(.{
            .ident = @intCast(client_fd),
            .filter = posix.system.EVFILT.READ,
            .flags = posix.system.EV.ADD | posix.system.EV.CLEAR,
            .fflags = 0,
            .data = 0,
            .udata = slot_index,
        });
    }

    /// 归还 recv 完成项占用的池块；须在下次 pollCompletions 前调用
    pub fn releaseChunk(self: *HighPerfIO, chunk_index: usize) void {
        self.chunk_cache.release(chunk_index);
    }

    /// 在连接上提交 send；data 在完成前须保持有效；完成时 tag=send、len=已发送字节数（暂为桩，后续实现 EVFILT_WRITE + write）
    pub fn submitSend(self: *HighPerfIO, _: std.net.Stream, _: []const u8, _: usize) void {
        _ = self;
    }

    inline fn pushCompletion(self: *HighPerfIO, user_data: usize, buffer_ptr: ?[*]const u8, len: usize, err: ?api.SendFileError, client_stream: ?std.net.Stream) void {
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
};

fn setNonBlocking(fd: i32) !void {
    const flags = posix.fcntl(fd, posix.F.GETFL, 0) catch return error.SocketWrite;
    _ = posix.fcntl(fd, posix.F.SETFL, flags | 0x4) catch return error.SocketWrite; // O_NONBLOCK on Darwin
}

/// Darwin 专用：将当前线程 QoS 设为 USER_INTERACTIVE，利于调度到 P 核；非 macOS 编译为 no-op，不引用 Darwin 符号
fn setDarwinThreadQosUserInteractive() void {
    if (builtin.os.tag == .macos) {
        const QOS_CLASS_USER_INTERACTIVE: c_uint = 0x21;
        _ = std.c.pthread_set_qos_class_self_np(null, QOS_CLASS_USER_INTERACTIVE, 0);
    }
}

/// 零拷贝：文件 → 网络（Darwin/BSD sendfile）；len 为 in/out，需循环直至发送完或错误（§4.1）。
/// 进阶：macOS sendfile 支持 sf_hdtr（header + file + trailer 一次提交），可在发送文件前后附加 HTTP 头或签名，相比 Linux 的 writev + sendfile 可省一次系统调用；需要时可扩展本函数接受 optional hdtr。
pub fn sendFile(stream: std.net.Stream, file: std.fs.File, offset: u64, count: u64) api.SendFileError!void {
    const file_fd = file.handle;
    const socket_fd = stream.handle;
    var sent: u64 = 0;
    while (sent < count) {
        var len: i64 = @intCast(count - sent);
        const rc = std.c.sendfile(file_fd, socket_fd, @intCast(offset + sent), &len, null, 0);
        if (rc != 0) return error.SendfileFailed;
        if (len <= 0) return error.SendfileFailed;
        sent += @as(u64, @intCast(len));
    }
}

// -----------------------------------------------------------------------------
// 异步文件 I/O（线程池 + pread/pwrite，kqueue 无文件完成事件故用工作线程）
// -----------------------------------------------------------------------------
const MAX_FILE_PENDING: usize = 256;
const FileOpKind = enum { read, write };
const FileJob = struct {
    fd: posix.fd_t,
    caller_user_data: usize,
    op: FileOpKind,
    buffer_ptr: [*]u8,
    data_ptr: [*]const u8,
    len: usize,
    offset: u64,
};

pub const AsyncFileIO = struct {
    allocator: std.mem.Allocator,
    completion_buffer: []api.Completion,
    completion_count: usize,
    job_mutex: std.Thread.Mutex = .{},
    job_queue: std.ArrayList(FileJob) = undefined,
    done_mutex: std.Thread.Mutex = .{},
    done_list: std.ArrayList(api.Completion) = undefined,
    cond: std.Thread.Condition = .{},
    worker: ?std.Thread = null,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator) !AsyncFileIO {
        var job_queue = std.ArrayList(FileJob).initCapacity(allocator, MAX_FILE_PENDING) catch return error.OutOfMemory;
        const done_list = std.ArrayList(api.Completion).initCapacity(allocator, MAX_FILE_PENDING) catch {
            job_queue.deinit(allocator);
            return error.OutOfMemory;
        };
        const completion_buffer = try allocator.alloc(api.Completion, MAX_FILE_PENDING);
        var self = AsyncFileIO{
            .allocator = allocator,
            .completion_buffer = completion_buffer,
            .completion_count = 0,
            .job_queue = job_queue,
            .done_list = done_list,
        };
        self.worker = try std.Thread.spawn(.{}, workerRun, .{&self});
        return self;
    }

    pub fn deinit(self: *AsyncFileIO) void {
        self.shutdown.store(true, .seq_cst);
        self.cond.signal();
        if (self.worker) |t| t.join();
        self.job_queue.deinit(self.allocator);
        self.done_list.deinit(self.allocator);
        self.allocator.free(self.completion_buffer);
        self.* = undefined;
    }

    fn workerRun(self: *AsyncFileIO) void {
        while (!self.shutdown.load(.acquire)) {
            self.job_mutex.lock();
            const job: ?FileJob = if (self.job_queue.items.len > 0)
                self.job_queue.orderedRemove(0)
            else
                null;
            self.job_mutex.unlock();
            if (job) |j| {
                var comp: api.Completion = undefined;
                comp.user_data = j.caller_user_data;
                comp.client_stream = null;
                comp.err = null;
                comp.chunk_index = null;
                if (j.op == .read) {
                    const n = posix.pread(j.fd, j.buffer_ptr[0..j.len], j.offset);
                    if (n) |read_len| {
                        comp.buffer_ptr = j.buffer_ptr;
                        comp.len = read_len;
                        comp.tag = .file_read;
                        comp.file_err = null;
                    } else |e| {
                        comp.buffer_ptr = j.buffer_ptr;
                        comp.len = 0;
                        comp.tag = .file_read;
                        comp.file_err = e;
                    }
                } else {
                    const n = posix.pwrite(j.fd, j.data_ptr[0..j.len], j.offset);
                    if (n) |write_len| {
                        comp.buffer_ptr = @ptrCast(&[_]u8{});
                        comp.len = write_len;
                        comp.tag = .file_write;
                        comp.file_err = null;
                    } else |e| {
                        comp.buffer_ptr = @ptrCast(&[_]u8{});
                        comp.len = 0;
                        comp.tag = .file_write;
                        comp.file_err = e;
                    }
                }
                self.done_mutex.lock();
                self.done_list.append(self.allocator, comp) catch {};
                self.done_mutex.unlock();
            } else {
                self.job_mutex.lock();
                self.cond.wait(&self.job_mutex);
                self.job_mutex.unlock();
            }
        }
    }

    pub fn submitReadFile(
        self: *AsyncFileIO,
        fd: posix.fd_t,
        buffer_ptr: [*]u8,
        len: usize,
        offset: u64,
        caller_user_data: usize,
    ) !void {
        self.job_mutex.lock();
        defer self.job_mutex.unlock();
        if (self.job_queue.items.len >= MAX_FILE_PENDING) return error.TooManyPending;
        try self.job_queue.append(self.allocator, .{
            .fd = fd,
            .caller_user_data = caller_user_data,
            .op = .read,
            .buffer_ptr = buffer_ptr,
            .data_ptr = @ptrCast(&[_]u8{}),
            .len = len,
            .offset = offset,
        });
        self.cond.signal();
    }

    pub fn submitWriteFile(
        self: *AsyncFileIO,
        fd: posix.fd_t,
        data_ptr: [*]const u8,
        len: usize,
        offset: u64,
        caller_user_data: usize,
    ) !void {
        self.job_mutex.lock();
        defer self.job_mutex.unlock();
        if (self.job_queue.items.len >= MAX_FILE_PENDING) return error.TooManyPending;
        try self.job_queue.append(self.allocator, .{
            .fd = fd,
            .caller_user_data = caller_user_data,
            .op = .write,
            .buffer_ptr = @constCast(@ptrCast(&[_]u8{})),
            .data_ptr = data_ptr,
            .len = len,
            .offset = offset,
        });
        self.cond.signal();
    }

    /// 收割文件 I/O 完成项（从线程池结果队列取出）；返回切片有效至下次 pollCompletions 前
    pub fn pollCompletions(self: *AsyncFileIO, timeout_ns: i64) []api.Completion {
        _ = timeout_ns;
        self.completion_count = 0;
        self.done_mutex.lock();
        const n = @min(self.done_list.items.len, self.completion_buffer.len);
        for (self.done_list.items[0..n], self.completion_buffer[0..n]) |src, *dst| dst.* = src;
        if (n > 0) {
            var i: usize = n;
            while (i < self.done_list.items.len) : (i += 1) {
                self.done_list.items[i - n] = self.done_list.items[i];
            }
            self.done_list.shrinkRetainingCapacity(self.done_list.items.len - n);
        }
        self.done_mutex.unlock();
        self.completion_count = n;
        return self.completion_buffer[0..self.completion_count];
    }
};
