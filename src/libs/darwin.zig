//! macOS (Darwin) 平台 I/O 核心（darwin.zig）
//!
//! 职责：
//!   - 实现 `HighPerfIO` 契约：基于 `kqueue` 边缘触发（EV_CLEAR）模型。
//!   - 实现零拷贝 `sendFile`：基于 BSD `sendfile` 系统调用。
//!   - 提供槽位化（Slot-based）连接管理与位图（Bitmask）快速分配。
//!
//! 极致压榨亮点：
//!   1. **O(1) Accept 队列**：使用固定容量环形队列 `PendingAcceptQueue` 替代 `ArrayList`，消除连接积压时的平移开销。
//!   2. **位图槽位分配**：`free_bitmap` 配合 `TZCNT` (@ctz) 指令，实现 O(1) 的空闲槽位查找与回收。
//!   3. **批量 Kevent 提交**：通过 `changelist` 缓冲区在一次 `kevent` 调用中完成「变更提交 + 事件收割」。
//!   4. **QoS 调度增强**：支持 `setIoThreadQosUserInteractive`，利用 Apple Silicon P 核处理 I/O 任务。
//!   5. **零 fcntl 热路径**：利用监听 FD 属性继承特性，在 `accept` 后省去非阻塞设置的系统调用。
//!
//! 适用规范：
//!   - 遵循 00 §4.1（macOS 低延迟优先）、§3.5（Thread-per-Core）。
//!
//! [Allocates] `init` 分配的资源由 `deinit` 释放。

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const api = @import("api.zig");

/// 每块 buffer 大小（与 Linux 64K 对齐，便于池布局一致）
const CHUNK_SIZE = 64 * 1024;

/// 单条待处理 accept：(listen_fd, user_data)，EVFILT_READ 时取一、accept、再读入池
const PendingAccept = struct { listen_fd: i32, user_data: usize };

/// 待处理 accept 队列：使用固定容量环形队列替代 ArrayList.orderedRemove(0)，消除 O(N) 移动开销
const PendingAcceptQueue = struct {
    buf: []usize,
    head: usize = 0,
    tail: usize = 0,
    len: usize = 0,

    fn init(allocator: std.mem.Allocator, capacity: usize) !PendingAcceptQueue {
        const buf = try allocator.alloc(usize, capacity);
        return .{ .buf = buf };
    }

    fn deinit(self: *PendingAcceptQueue, allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
    }

    fn push(self: *PendingAcceptQueue, user_data: usize) bool {
        if (self.len >= self.buf.len) return false;
        self.buf[self.tail] = user_data;
        self.tail = (self.tail + 1) % self.buf.len;
        self.len += 1;
        return true;
    }

    fn pop(self: *PendingAcceptQueue) ?usize {
        if (self.len == 0) return null;
        const val = self.buf[self.head];
        self.head = (self.head + 1) % self.buf.len;
        self.len -= 1;
        return val;
    }

    fn pushFront(self: *PendingAcceptQueue, user_data: usize) bool {
        if (self.len >= self.buf.len) return false;
        self.head = (self.head + self.buf.len - 1) % self.buf.len;
        self.buf[self.head] = user_data;
        self.len += 1;
        return true;
    }
};

/// 槽位操作类型：accept 首包读 vs 连接后续 recv/send（均用 EVFILT_READ/WRITE + udata=slot_index）
const SlotOp = enum { accept_first_read, conn_recv, conn_send };

/// 槽位 SoA 字段：与 Linux SlotFields 对齐，热路径只摸 client_fd/user_data/chunk_index 连续数组，缓存友好
const SlotFields = struct {
    op_kind: SlotOp = .accept_first_read,
    user_data: usize = 0,
    chunk_index: usize = 0,
    client_fd: i32 = -1,
    send_buf_ptr: [*]const u8 = undefined,
    send_buf_len: usize = 0,
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
    /// 空闲块索引；Unmanaged 不存 allocator，init/deinit/append 显式传 allocator（01 §1.2）
    free_list: std.ArrayListUnmanaged(usize),
    /// 线程本地块缓存，take/release 绝大多数命中本地栈，空/满时与 free_list 批量交换（见 api.ThreadLocalChunkCache）
    chunk_cache: api.ThreadLocalChunkCache = undefined,

    /// 待处理 (listen_fd -> user_data 队列)；边缘触发时循环取、accept、直至 EAGAIN（01 §1.2 Unmanaged）
    pending_accepts: std.AutoHashMap(i32, PendingAcceptQueue),
    /// 已注册的监听器 FDs，热路径用线性扫描替代 HashMap 提升性能（监听器通常 < 8 个）
    listen_fds: []i32,
    listen_count: usize = 0,
    /// 槽位 SoA：ev.udata = slot_index，热路径只摸 client_fd 等连续数组（与 Linux 版一致）
    slot_data: std.MultiArrayList(SlotFields),
    /// 空闲槽位位图：每 bit 对应一槽位，1=空闲 0=占用；用 @ctz 快速找空闲索引（TZCNT）
    free_bitmap: []u64,
    free_scan_hint: usize = 0,
    free_count: usize,

    /// 预分配 changelist 缓冲区（固定大小，无扩容毛刺）；changelist_len 为当前有效长度
    changelist: []posix.Kevent,
    changelist_len: usize = 0,
    /// kevent 返回的 events 数组
    events: []posix.Kevent,

    /// 初始化 Darwin I/O 子系统：创建 kqueue、分配完成项/events/changelist/client 槽位（§4.1 每线程独立 kqueue）
    pub fn init(allocator: std.mem.Allocator, options: api.InitOptions) !HighPerfIO {
        const kq_fd = std.c.kqueue();
        if (kq_fd == -1) return error.SystemResources;
        errdefer _ = std.c.close(kq_fd);

        const completion_buffer = try allocator.alloc(api.Completion, options.max_completions);
        errdefer allocator.free(completion_buffer);

        const max_ev = options.max_connections * 2;
        const events = try allocator.alloc(posix.Kevent, max_ev);
        errdefer allocator.free(events);

        var slot_data = std.MultiArrayList(SlotFields){};
        errdefer slot_data.deinit(allocator);
        try slot_data.ensureTotalCapacity(allocator, options.max_connections);
        for (0..options.max_connections) |_| {
            slot_data.appendAssumeCapacity(.{ .op_kind = .accept_first_read, .client_fd = -1 });
        }

        const bitmap_words = (options.max_connections + 63) / 64;
        const free_bitmap = try allocator.alloc(u64, bitmap_words);
        errdefer allocator.free(free_bitmap);
        @memset(free_bitmap, std.math.maxInt(u64));
        if (options.max_connections % 64 != 0) {
            free_bitmap[bitmap_words - 1] &= (@as(u64, 1) << @as(u6, @intCast(options.max_connections % 64))) - 1;
        }

        const changelist_cap = options.max_connections * 4 + 32;
        const changelist = try allocator.alloc(posix.Kevent, changelist_cap);
        errdefer allocator.free(changelist);

        // 监听器 FDs 固定容量（通常服务器监听地址不多，32 足够，线性扫描比 HashMap 快）
        const listen_fds = try allocator.alloc(i32, 32);
        errdefer allocator.free(listen_fds);
        @memset(listen_fds, -1);

        return .{
            .allocator = allocator,
            .kq_fd = kq_fd,
            .completion_buffer = completion_buffer,
            .completion_count = 0,
            .max_connections = options.max_connections,
            .free_list = try std.ArrayListUnmanaged(usize).initCapacity(allocator, 0),
            .pending_accepts = std.AutoHashMap(i32, PendingAcceptQueue).init(allocator),
            .listen_fds = listen_fds,
            .listen_count = 0,
            .slot_data = slot_data,
            .free_bitmap = free_bitmap,
            .free_count = options.max_connections,
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
            if (fd >= 0 and op == .accept_first_read) _ = std.c.close(fd);
        }
        _ = std.c.close(self.kq_fd);
        self.allocator.free(self.completion_buffer);
        self.allocator.free(self.events);
        self.slot_data.deinit(self.allocator);
        self.free_list.deinit(self.allocator);
        var it = self.pending_accepts.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.pending_accepts.deinit();
        self.allocator.free(self.listen_fds);
        self.allocator.free(self.free_bitmap);
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
            self.free_list.appendAssumeCapacity(@as(usize, @intCast(i)));
        }
        self.chunk_cache = api.ThreadLocalChunkCache.init(&self.free_list, self.allocator);
    }

    /// 从位图中弹出一个空闲槽位索引；1=空闲，用 @ctz 找最低位（TZCNT），比栈 pop 更省内存访问
    inline fn popFreeSlot(self: *HighPerfIO) ?usize {
        if (self.free_count == 0) return null;
        const start = self.free_scan_hint;
        for (0..self.free_bitmap.len) |i| {
            const word_i = (start + i) % self.free_bitmap.len;
            const word = &self.free_bitmap[word_i];
            if (word.* != 0) {
                const bit_idx: u6 = @intCast(@ctz(word.*));
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
        if (word_i < self.free_scan_hint) self.free_scan_hint = word_i;
    }

    /// 提交「在 listen_fd 上接受一连接并将首包读入池中 buffer」请求；user_data 在完成时原样带回。EV_ADD 入 changelist，下次 pollCompletions 时批量提交
    pub fn submitAcceptWithBuffer(self: *HighPerfIO, listen_fd: i32, user_data: usize) void {
        var gop = self.pending_accepts.getOrPut(listen_fd) catch return;
        if (!gop.found_existing) {
            gop.value_ptr.* = PendingAcceptQueue.init(self.allocator, self.max_connections) catch return;
        }
        if (!gop.value_ptr.push(user_data)) return;

        var found = false;
        for (self.listen_fds[0..self.listen_count]) |fd| {
            if (fd == listen_fd) {
                found = true;
                break;
            }
        }

        if (!found and self.listen_count < self.listen_fds.len) {
            // Darwin 优化：如果监听器是非阻塞的，accept 返回的 socket 会继承该标志，
            // 从而在热路径中省掉每连接一次的 fcntl。
            setNonBlocking(listen_fd) catch {};

            _ = self.pushChangelist(.{
                .ident = @intCast(listen_fd),
                .filter = posix.system.EVFILT.READ,
                .flags = posix.system.EV.ADD | posix.system.EV.CLEAR,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            });
            self.listen_fds[self.listen_count] = listen_fd;
            self.listen_count += 1;
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

    // Hot-path
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
        const n = std.c.kevent(
            self.kq_fd,
            ch_slice.ptr,
            @as(c_int, @intCast(ch_slice.len)),
            self.events.ptr,
            @as(c_int, @intCast(self.events.len)),
            timeout_ptr,
        );
        if (n < 0) return self.completion_buffer[0..self.completion_count];
        self.changelist_len = 0;

        const pool_ptr = self.pool_ptr;
        const op_kinds = self.slot_data.items(.op_kind);
        const client_fds = self.slot_data.items(.client_fd);
        const n_u = @as(usize, @intCast(n));
        for (self.events[0..n_u]) |*ev| {
            const fd = @as(i32, @intCast(ev.ident));
            var is_listener = false;
            for (self.listen_fds[0..self.listen_count]) |lfd| {
                if (lfd == fd) {
                    is_listener = true;
                    break;
                }
            }

            if (is_listener) {
                self.handleListenReady(fd, pool_ptr);
            } else {
                const slot_index = ev.udata;
                if (slot_index < self.max_connections and client_fds[slot_index] >= 0) {
                    switch (op_kinds[slot_index]) {
                        .conn_recv => self.handleConnRecvReady(@intCast(slot_index), pool_ptr),
                        .conn_send => self.handleConnSendReady(@intCast(slot_index)),
                        .accept_first_read => self.handleClientReady(@intCast(slot_index), pool_ptr),
                    }
                }
            }
        }
        return self.completion_buffer[0..self.completion_count];
    }

    /// 边缘触发：循环 accept 直至 EAGAIN，每次成功取一 pending、占一 client 槽位、EV_ADD 入 changelist（udata=slot_index）
    fn handleListenReady(self: *HighPerfIO, listen_fd: i32, _: [*]const u8) void {
        const queue = self.pending_accepts.getPtr(listen_fd) orelse return;
        while (queue.len > 0) {
            const user_data = queue.pop() orelse break;

            const chunk_index = self.chunk_cache.take() orelse {
                self.pushCompletion(user_data, null, 0, error.SocketWrite, null);
                continue;
            };
            var addr: posix.sockaddr = undefined;
            var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
            const client_fd = std.c.accept(listen_fd, @ptrCast(&addr), @ptrCast(&addr_len));
            if (client_fd < 0) {
                if (std.c._errno().* == @intFromEnum(std.c.E.AGAIN)) {
                    _ = queue.pushFront(user_data);
                    self.chunk_cache.release(chunk_index);
                    return;
                }
                self.pushCompletion(user_data, null, 0, error.SocketWrite, null);
                self.chunk_cache.release(chunk_index);
                return;
            }
            // Darwin 优化：如果监听器是非阻塞的，accept 返回的 socket 会继承该标志，
            // 从而在此热路径中省掉每连接一次的 fcntl 及其内部 2 次系统调用。

            const slot_index = self.popFreeSlot() orelse {
                _ = std.c.close(client_fd);
                self.chunk_cache.release(chunk_index);
                _ = queue.pushFront(user_data);
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
                self.pushFreeSlot(slot_index);
                _ = std.c.close(client_fd);
                self.chunk_cache.release(chunk_index);
                _ = queue.pushFront(user_data);
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
        self.pushFreeSlot(slot_index);

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
        const client_stream: std.Io.net.Stream = .{ .socket = .{ .handle = @as(i32, @intCast(client_fd)), .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = 0 } } } };

        if (chunk_index >= self.chunk_count) {
            _ = std.c.close(client_fd);
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
        self.pushFreeSlot(slot_index);

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

    /// 连接 send 完成：写入数据，填 tag=send 的 completion，EV_DELETE 并归还槽位
    fn handleConnSendReady(self: *HighPerfIO, slot_index: usize) void {
        const slice = self.slot_data.slice();
        const client_fd = slice.items(.client_fd)[slot_index];
        const user_data = slice.items(.user_data)[slot_index];
        const send_buf_ptr = slice.items(.send_buf_ptr)[slot_index];
        const send_buf_len = slice.items(.send_buf_len)[slot_index];
        self.slot_data.set(slot_index, .{ .op_kind = .conn_send, .client_fd = -1 });
        self.pushFreeSlot(slot_index);

        _ = self.pushChangelist(.{
            .ident = @intCast(client_fd),
            .filter = posix.system.EVFILT.WRITE,
            .flags = posix.system.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        });

        const n = std.c.write(client_fd, send_buf_ptr, send_buf_len);
        if (n < 0) {
            self.pushCompletionSend(user_data, 0, error.SocketWrite);
            return;
        }
        self.pushCompletionSend(user_data, @as(usize, @intCast(n)), null);
    }

    // Hot-path
    /// 在连接上提交一次 recv；数据写入池块，完成时 tag=recv、chunk_index 有效，用毕须 releaseChunk
    pub fn submitRecv(self: *HighPerfIO, stream: std.Io.net.Stream, user_data: usize) void {
        const client_fd = stream.socket.handle;
        const chunk_index = self.chunk_cache.take() orelse return;
        const slot_index = self.popFreeSlot() orelse {
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

    // Hot-path
    /// 归还 recv 完成项占用的池块；须在下次 pollCompletions 前调用
    pub fn releaseChunk(self: *HighPerfIO, chunk_index: usize) void {
        self.chunk_cache.release(chunk_index);
    }

    // Hot-path
    /// 在连接上提交 send；data 在完成前须保持有效；完成时 tag=send、len=已发送字节数
    pub fn submitSend(self: *HighPerfIO, stream: std.Io.net.Stream, data: []const u8, user_data: usize) void {
        const client_fd = stream.socket.handle;
        const slot_index = self.popFreeSlot() orelse return;
        self.slot_data.set(slot_index, .{ .op_kind = .conn_send, .user_data = user_data, .client_fd = client_fd, .send_buf_ptr = data.ptr, .send_buf_len = data.len });
        _ = self.pushChangelist(.{
            .ident = @intCast(client_fd),
            .filter = posix.system.EVFILT.WRITE,
            .flags = posix.system.EV.ADD | posix.system.EV.CLEAR,
            .fflags = 0,
            .data = 0,
            .udata = slot_index,
        });
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

    inline fn pushCompletionSend(self: *HighPerfIO, user_data: usize, len: usize, err: ?api.SendFileError) void {
        if (self.completion_count >= self.completion_buffer.len) return;
        self.completion_buffer[self.completion_count] = .{
            .user_data = user_data,
            .buffer_ptr = @ptrCast(&[_]u8{}),
            .len = len,
            .err = err,
            .client_stream = null,
            .tag = .send,
            .chunk_index = null,
        };
        self.completion_count += 1;
    }
};

fn setNonBlocking(fd: i32) !void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return error.SocketWrite;
    if (std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, flags | 0x4)) < 0) return error.SocketWrite; // O_NONBLOCK on Darwin
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
pub fn sendFile(stream: std.Io.net.Stream, file: std.fs.File, offset: u64, count: u64) api.SendFileError!void {
    const file_fd = file.handle;
    const socket_fd = stream.socket.handle;
    var sent: u64 = 0;
    while (sent < count) {
        var len: i64 = @intCast(count - sent);
        const rc = std.c.sendfile(file_fd, socket_fd, @intCast(offset + sent), &len, null, 0);
        if (rc != 0) return error.SendfileFailed;
        if (len <= 0) return error.SendfileFailed;
        sent += @as(u64, @intCast(len));
    }
}

// 异步文件 I/O（AsyncFileIO）已迁至 io_core/file.zig，Darwin 实现为 file.zig 内 AsyncFileIODarwin，由 mod 统一导出 file.AsyncFileIO。

// ------------------------------------------------------------------------------
// NUMA：Darwin 无内核 mbind API（统一内存或单节点），no-op 以保持与 libs_io 接口一致
// ------------------------------------------------------------------------------

/// [Darwin] 本平台无 NUMA mbind；Apple 芯片为统一内存，Intel 单节点；no-op，调用无害，与 linux.zig/windows.zig 同签名
pub fn mbindToCurrentNode(ptr: [*]align(std.heap.page_size_min) const u8, len: usize) void {
    _ = ptr;
    _ = len;
}
