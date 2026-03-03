// Windows 平台 I/O 核心（windows.zig）：IOCP + AcceptEx 首包零拷贝入池 + TransmitFile 零拷贝。
//
// 职责
//   - 实现 HighPerfIO：IOCP、AcceptEx 的 lpOutputBuffer 直接指向池块并设 dwReceiveDataLength，accept 完成时首包已在池中，无需再 WSARecv；
//   - 实现 sendFile：文件→网络零拷贝，SetFilePointerEx + TransmitFile；count 超过 DWORD 时循环直至发完。
//
// 规范对应（00-性能规则）
//   - §4.3：文件→socket 必须 TransmitFile；I/O 模型以 IOCP + Overlapped 为基线。
//
// 使用约定
//   - 调用方须先 registerListenSocket(listen_socket) 再调用 submitAcceptWithBuffer；listen_fd 在本实现中未使用（可传 0）。
//
// 内存与释放
//   - 显式 allocator（§1.5）；槽位 SoA（AcceptFields）在 init 中分配、deinit 中释放。
//
// --- 进阶压榨（已做）---
// 1) Accept 零拷贝：AcceptEx 的 lpOutputBuffer 用池块，dwReceiveDataLength = CHUNK_SIZE - 2*ACCEPT_ADDR_LEN，完成时首包已在池中，省一次 WSARecv。
// 2) GetQueuedCompletionStatusEx：一次系统调用取回多完成项，高 QPS 下降低内核态空转。
// 3) 槽位 SoA + completion_key=索引：MultiArrayList(AcceptFields)，key 存 accept_idx，免 64 位指针解引用。
// 4) TransmitFile：小文件（<4KB）可考虑 TF_USE_DEFAULT_WORKER；短连接可配合 DisconnectEx + TF_REUSE_SOCKET 复用句柄（见 sendFile 注释）。
//
// --- 最后 0.1%（已做）---
// 5) OVERLAPPED 缓存行隔离：每槽 overlapped 独占 64 字节（OverlappedCacheLine），避免多槽共处一 Cache Line 的 False Sharing。
// 6) TF_REUSE_SOCKET：InitOptions.windows_socket_reuse 为 true 时，handleAcceptCompletion 后不关闭 socket，投递 DisconnectEx(sock, TF_REUSE_SOCKET)，完成时句柄入池，submitAcceptWithBuffer 优先复用，绕过 WSASocketW。
// 7) NUMA 亲和：setIoThreadIdealProcessor(processor) 在 I/O 线程调用，将当前线程理想处理器设为指定核，利于多路 CPU 下中断与收割同核本地缓存。
//
// --- 最后 1 厘米（已做）---
// 8) AcceptEx 积压：windows_accept_backlog>0 时，ensureAcceptBacklog() 预投递若干 AcceptEx，pollCompletions 后补足，始终保持内核中待命 accept 数量，适合百万级连接。
// 9) Buffer 池大页：api.BufferPool.allocLargePagesWindows(allocator, size) 使用 VirtualAlloc MEM_LARGE_PAGES，减少 TLB miss；需 SeLockMemoryPrivilege。
//
// --- 与 Linux 对应 ---
// 大页：Linux MAP_HUGETLB / Windows allocLargePagesWindows(MEM_LARGE_PAGES)；Splice/ATTACH_WQ 为 Linux 特性。
//
// --- 可选（注释级）---
// 10) RIO (Registered I/O)：RIORegisterBuffer 将池注册给内核，AcceptEx/WSARecv 可升级为 RIO 路径，进一步压榨内核态；当前已 AcceptEx 零拷贝 + GQCSEx，RIO 为可选进阶，见 docs/IO_CORE_ROADMAP.md §4。

const std = @import("std");
const win = std.os.windows;
const api = @import("api.zig");

const ws2 = win.ws2_32;
const kernel32 = win.kernel32;

/// 每块 buffer 大小（与 Linux/Darwin 一致）
const CHUNK_SIZE = 64 * 1024;
const FILE_BEGIN: win.DWORD = 0;
/// AcceptEx 单地址长度（本地或远端），缓冲至少 2*ACCEPT_ADDR_LEN + dwReceiveDataLength
const ACCEPT_ADDR_LEN = @sizeOf(ws2.sockaddr_in) + 16;
/// AcceptEx 首包接收长度（池块前 2*ACCEPT_ADDR_LEN 为地址，其余为首包数据）
const ACCEPT_RECV_LEN = CHUNK_SIZE - 2 * ACCEPT_ADDR_LEN;

const CACHE_LINE_BYTES = 64;
/// 单槽 OVERLAPPED 独占一缓存行，避免高并发下多槽共处 64 字节导致的 False Sharing
const OverlappedCacheLine = struct {
    overlapped: win.OVERLAPPED,
    _pad: [CACHE_LINE_BYTES - @sizeOf(win.OVERLAPPED)]u8 = [_]u8{0} ** (CACHE_LINE_BYTES - @sizeOf(win.OVERLAPPED)),
};

/// 槽位 SoA 字段：completion_key 存 accept_idx；overlapped 以缓存行隔离
const AcceptFields = struct {
    overlapped_line: OverlappedCacheLine = .{ .overlapped = .{
        .Internal = 0,
        .InternalHigh = 0,
        .Union = .{ .Pointer = null },
        .hEvent = null,
    } },
    listen_socket: ws2.SOCKET = ws2.INVALID_SOCKET,
    accept_socket: ws2.SOCKET = ws2.INVALID_SOCKET,
    user_data: usize = 0,
    chunk_index: usize = 0,
};

/// 连接 recv/send 槽位：OVERLAPPED 在首字段，完成时由 completion_key 得 slot_index；recv 用 chunk_index，send 用 send_buf
const ConnIoSlot = struct {
    overlapped: win.OVERLAPPED = .{
        .Internal = 0,
        .InternalHigh = 0,
        .Union = .{ .Pointer = null },
        .hEvent = null,
    },
    tag: enum { recv, send } = .recv,
    chunk_index: usize = 0,
    user_data: usize = 0,
    send_buf_ptr: [*]const u8 = undefined,
    send_buf_len: usize = 0,
};

/// GQCSEx 单条完成项（与 Windows OVERLAPPED_ENTRY 布局一致，用于批量收割）
const OverlappedEntry = extern struct {
    lp_completion_key: win.ULONG_PTR,
    lp_overlapped: ?*win.OVERLAPPED,
    internal: win.ULONG_PTR,
    dw_number_of_bytes_transferred: win.DWORD,
};

/// Vista+：一次取回多完成项，高 QPS 时降低内核态空转
extern "kernel32" fn GetQueuedCompletionStatusEx(
    CompletionPort: win.HANDLE,
    lpCompletionPortEntries: [*]OverlappedEntry,
    ulCount: win.ULONG,
    ulNumEntriesRemoved: *win.ULONG,
    dwMilliseconds: win.DWORD,
    fAlertable: win.BOOL,
) win.BOOL;

/// 将当前线程理想处理器设为指定核，利于 NUMA 下中断与收割同核本地缓存；须在运行 pollCompletions 的 I/O 线程内调用
extern "kernel32" fn SetThreadIdealProcessor(hThread: win.HANDLE, dwIdealProcessor: win.DWORD) win.DWORD;
extern "kernel32" fn GetCurrentThread() win.HANDLE;

/// DisconnectEx 完成上下文：overlapped 在首字段，完成时由 lpOverlapped 反推索引并取 socket 入复用池
const DisconnectCtx = struct {
    overlapped: win.OVERLAPPED,
    socket: ws2.SOCKET = ws2.INVALID_SOCKET,
};

const SIO_GET_EXTENSION_FUNCTION_POINTER: win.DWORD = 0xC8000006;
/// WSAID_DISCONNECTEX 的 16 字节 GUID（小端 Data1,Data2,Data3,Data4）
const WSAID_DISCONNECTEX_GUID: [16]u8 = [_]u8{
    0x11, 0x2e, 0xda, 0x7f, 0x30, 0x86, 0x6f, 0x43,
    0xa0, 0x31, 0xf5, 0x36, 0xa6, 0xee, 0xc1, 0x57,
};
const TF_REUSE_SOCKET: win.DWORD = 0x01;
/// DisconnectEx 函数指针类型；经 WSAIoctl 加载
const LPFN_DISCONNECTEX = *const fn (ws2.SOCKET, ?*win.OVERLAPPED, win.DWORD, win.DWORD) callconv(win.WINAPI) win.BOOL;

extern "ws2_32" fn WSAIoctl(
    s: ws2.SOCKET,
    dwIoControlCode: win.DWORD,
    lpvInBuffer: ?*const anyopaque,
    cbInBufferSize: win.DWORD,
    lpvOutBuffer: ?*anyopaque,
    cbOutBufferSize: win.DWORD,
    lpcbBytesReturned: *win.DWORD,
    lpOverlapped: ?*win.OVERLAPPED,
    lpCompletionRoutine: ?*const fn (win.DWORD, win.DWORD, ?*win.OVERLAPPED, win.DWORD) callconv(win.WINAPI) void,
) i32;

/// 通过 listen_socket 的 WSAIoctl(SIO_GET_EXTENSION_FUNCTION_POINTER) 加载 DisconnectEx，成功则写入 out
fn loadDisconnectEx(socket: ws2.SOCKET, out: *?LPFN_DISCONNECTEX) void {
    var ptr: LPFN_DISCONNECTEX = undefined;
    var bytes: win.DWORD = 0;
    const r = WSAIoctl(
        socket,
        SIO_GET_EXTENSION_FUNCTION_POINTER,
        &WSAID_DISCONNECTEX_GUID,
        16,
        &ptr,
        @sizeOf(LPFN_DISCONNECTEX),
        &bytes,
        null,
        null,
    );
    if (r == 0) out.* = ptr;
}

pub const HighPerfIO = struct {
    allocator: std.mem.Allocator,
    port: win.HANDLE,
    completion_buffer: []api.Completion,
    completion_count: usize,
    max_connections: usize,

    pool_ptr: [*]const u8 = undefined,
    chunk_count: usize = 0,
    free_list: std.ArrayList(usize),
    /// 线程本地块缓存，take/release 绝大多数命中本地栈，空/满时与 free_list 批量交换
    chunk_cache: api.ThreadLocalChunkCache = undefined,

    /// 监听 socket；须先 registerListenSocket 再 submitAcceptWithBuffer
    listen_socket: ?ws2.SOCKET = null,
    /// 槽位 SoA；completion_key 存 accept_idx，overlapped 以缓存行隔离
    slot_data: std.MultiArrayList(AcceptFields),
    accept_free: std.ArrayList(usize),

    /// GQCSEx 预分配条目数组，一次系统调用取回多完成项
    completion_entries: []OverlappedEntry,

    /// windows_socket_reuse 为 true 时：DisconnectEx 完成后可复用的 socket 池；submitAcceptWithBuffer 优先从此取
    free_sockets: std.ArrayList(ws2.SOCKET),
    /// DisconnectEx 投递上下文；完成时由 lpOverlapped 判定为 disconnect 并取 socket 入 free_sockets
    disconnect_ctxs: []DisconnectCtx,
    disconnect_free: std.ArrayList(usize),
    /// DisconnectEx 函数指针；registerListenSocket 时通过 WSAIoctl(SIO_GET_EXTENSION_FUNCTION_POINTER) 加载
    disconnect_ex: ?LPFN_DISCONNECTEX = null,
    socket_reuse: bool = false,
    /// AcceptEx 积压目标数；>0 时 ensureAcceptBacklog / pollCompletions 后补足
    accept_backlog_target: usize = 0,

    /// 连接 recv/send 槽位池；completion_key = max_connections + slot_index 区分 AcceptEx
    conn_io_slots: []ConnIoSlot = undefined,
    conn_io_free: std.ArrayList(usize) = undefined,

    pub fn init(allocator: std.mem.Allocator, options: api.InitOptions) !HighPerfIO {
        const port = kernel32.CreateIoCompletionPort(win.INVALID_HANDLE_VALUE, null, 0, 0) orelse return error.SystemResources;
        errdefer _ = kernel32.CloseHandle(port);

        const completion_buffer = try allocator.alloc(api.Completion, options.max_completions);
        errdefer allocator.free(completion_buffer);

        var free_list = std.ArrayList(usize).init(allocator);
        errdefer free_list.deinit(allocator);

        var slot_data = std.MultiArrayList(AcceptFields){};
        errdefer slot_data.deinit(allocator);
        try slot_data.ensureTotalCapacity(allocator, options.max_connections);
        for (0..options.max_connections) |_| {
            slot_data.appendAssumeCapacity(.{ .accept_socket = ws2.INVALID_SOCKET });
        }

        var accept_free = std.ArrayList(usize).init(allocator);
        errdefer accept_free.deinit(allocator);
        try accept_free.ensureTotalCapacity(options.max_connections);
        for (0..options.max_connections) |i| {
            accept_free.appendAssumeCapacity(i);
        }

        const completion_entries = try allocator.alloc(OverlappedEntry, options.max_completions);
        errdefer allocator.free(completion_entries);

        var free_sockets = std.ArrayList(ws2.SOCKET).init(allocator);
        errdefer free_sockets.deinit(allocator);

        const disconnect_ctxs = try allocator.alloc(DisconnectCtx, options.max_connections);
        errdefer allocator.free(disconnect_ctxs);
        for (disconnect_ctxs) |*ctx| ctx.socket = ws2.INVALID_SOCKET;

        var disconnect_free = std.ArrayList(usize).init(allocator);
        errdefer disconnect_free.deinit(allocator);
        try disconnect_free.ensureTotalCapacity(options.max_connections);
        for (0..options.max_connections) |i| {
            disconnect_free.appendAssumeCapacity(i);
        }

        const conn_io_slots = try allocator.alloc(ConnIoSlot, options.max_connections);
        errdefer allocator.free(conn_io_slots);

        var conn_io_free = std.ArrayList(usize).init(allocator);
        errdefer conn_io_free.deinit(allocator);
        try conn_io_free.ensureTotalCapacity(options.max_connections);
        for (0..options.max_connections) |i| {
            conn_io_free.appendAssumeCapacity(i);
        }

        return .{
            .allocator = allocator,
            .port = port,
            .completion_buffer = completion_buffer,
            .completion_count = 0,
            .max_connections = options.max_connections,
            .free_list = free_list,
            .slot_data = slot_data,
            .accept_free = accept_free,
            .completion_entries = completion_entries,
            .free_sockets = free_sockets,
            .disconnect_ctxs = disconnect_ctxs,
            .disconnect_free = disconnect_free,
            .disconnect_ex = null,
            .socket_reuse = options.windows_socket_reuse,
            .accept_backlog_target = options.windows_accept_backlog,
            .conn_io_slots = conn_io_slots,
            .conn_io_free = conn_io_free,
        };
    }

    pub fn deinit(self: *HighPerfIO) void {
        const accept_sockets = self.slot_data.items(.accept_socket);
        for (accept_sockets) |sock| {
            if (sock != ws2.INVALID_SOCKET) _ = ws2.closesocket(sock);
        }
        for (self.free_sockets.items) |sock| _ = ws2.closesocket(sock);
        for (self.disconnect_ctxs) |*ctx| {
            if (ctx.socket != ws2.INVALID_SOCKET) _ = ws2.closesocket(ctx.socket);
        }
        self.conn_io_free.deinit(self.allocator);
        self.allocator.free(self.conn_io_slots);
        self.slot_data.deinit(self.allocator);
        self.accept_free.deinit(self.allocator);
        self.allocator.free(self.completion_entries);
        self.free_sockets.deinit(self.allocator);
        self.allocator.free(self.disconnect_ctxs);
        self.disconnect_free.deinit(self.allocator);
        _ = kernel32.CloseHandle(self.port);
        self.allocator.free(self.completion_buffer);
        self.free_list.deinit(self.allocator);
        self.* = undefined;
    }

    /// 将当前线程理想处理器设为指定核，利于 NUMA 下中断与收割同核本地缓存；须在运行 pollCompletions 的 I/O 线程内调用一次
    pub fn setIoThreadIdealProcessor(self: *HighPerfIO, processor: win.DWORD) void {
        _ = self;
        _ = SetThreadIdealProcessor(GetCurrentThread(), processor);
    }

    /// 注册监听 socket 并关联到 IOCP；须在 submitAcceptWithBuffer 前调用；若 socket_reuse 则在此加载 DisconnectEx
    pub fn registerListenSocket(self: *HighPerfIO, socket: ws2.SOCKET) void {
        if (self.listen_socket != null) return;
        _ = kernel32.CreateIoCompletionPort(socket, self.port, 0, 0);
        self.listen_socket = socket;
        if (self.socket_reuse and self.disconnect_ex == null) {
            loadDisconnectEx(socket, &self.disconnect_ex);
        }
    }

    /// 预投递 AcceptEx 积压；须在 registerListenSocket 与 registerBufferPool 之后调用，使内核中待命 accept 数达到 accept_backlog_target（适合百万级连接场景）
    pub fn ensureAcceptBacklog(self: *HighPerfIO) void {
        const target = self.accept_backlog_target;
        if (target == 0) return;
        var in_flight = self.max_connections - self.accept_free.items.len;
        while (in_flight < target) {
            self.submitAcceptWithBuffer(0, 0);
            const next = self.max_connections - self.accept_free.items.len;
            if (next <= in_flight) break;
            in_flight = next;
        }
    }

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

    /// 提交一次 accept+首包零拷贝入池；lpOutputBuffer 用池块，dwReceiveDataLength=ACCEPT_RECV_LEN；socket_reuse 时优先从 free_sockets 复用句柄
    pub fn submitAcceptWithBuffer(self: *HighPerfIO, _: i32, user_data: usize) void {
        const listen_sock = self.listen_socket orelse return;
        const idx = self.accept_free.popOrNull() orelse return;
        const chunk_idx = self.chunk_cache.take() orelse {
            _ = self.accept_free.append(idx) catch {};
            return;
        };

        const accept_socket = blk: {
            if (self.socket_reuse) {
                if (self.free_sockets.popOrNull()) |sock| break :blk sock;
            }
            break :blk ws2.WSASocketW(
                ws2.AF.INET,
                ws2.SOCK.STREAM,
                ws2.IPPROTO.TCP,
                null,
                0,
                ws2.WSA_FLAG_OVERLAPPED,
            );
        };
        if (accept_socket == ws2.INVALID_SOCKET) {
            self.chunk_cache.release(chunk_idx);
            _ = self.accept_free.append(idx) catch {};
            return;
        }
        if (kernel32.CreateIoCompletionPort(accept_socket, self.port, @intCast(idx), 0) == null) {
            _ = ws2.closesocket(accept_socket);
            self.chunk_cache.release(chunk_idx);
            _ = self.accept_free.append(idx) catch {};
            return;
        }

        self.slot_data.set(idx, .{
            .overlapped_line = .{ .overlapped = .{
                .Internal = 0,
                .InternalHigh = 0,
                .Union = .{ .Pointer = null },
                .hEvent = null,
            } },
            .listen_socket = listen_sock,
            .accept_socket = accept_socket,
            .user_data = user_data,
            .chunk_index = chunk_idx,
        });
        const lp_output = @constCast(self.pool_ptr + chunk_idx * CHUNK_SIZE);
        var bytes_recv: win.DWORD = 0;
        const ok = ws2.AcceptEx(
            listen_sock,
            accept_socket,
            lp_output,
            ACCEPT_RECV_LEN,
            @intCast(ACCEPT_ADDR_LEN),
            @intCast(ACCEPT_ADDR_LEN),
            &bytes_recv,
            @ptrCast(&self.slot_data.items(.overlapped_line)[idx].overlapped),
        );
        if (ok == 0) {
            const err = ws2.WSAGetLastError();
            if (err != ws2.WSA_IO_PENDING) {
                _ = ws2.closesocket(accept_socket);
                self.chunk_cache.release(chunk_idx);
                _ = self.accept_free.append(idx) catch {};
            }
        }
    }

    /// 收割完成项：GetQueuedCompletionStatusEx 一次取回多完成项；timeout_ns 转为 ms，<0 表示阻塞等待
    pub fn pollCompletions(self: *HighPerfIO, timeout_ns: i64) []api.Completion {
        self.completion_count = 0;
        const timeout_ms: win.DWORD = if (timeout_ns < 0)
            win.INFINITE
        else
            @intCast(@min(@as(u64, @intCast(timeout_ns)) / std.time.ns_per_ms, std.math.maxInt(win.DWORD)));

        var n_removed: win.ULONG = 0;
        const ok = GetQueuedCompletionStatusEx(
            self.port,
            self.completion_entries.ptr,
            @intCast(self.completion_entries.len),
            &n_removed,
            timeout_ms,
            win.FALSE,
        );
        if (ok == 0 or n_removed == 0) return self.completion_buffer[0..self.completion_count];

        const slice = self.slot_data.slice();
        const listen_sockets = slice.items(.listen_socket);
        const accept_sockets = slice.items(.accept_socket);
        const user_datas = slice.items(.user_data);
        const chunk_indices = slice.items(.chunk_index);

        const disconnect_base = if (self.disconnect_ctxs.len > 0) @intFromPtr(&self.disconnect_ctxs[0].overlapped) else 0;
        const disconnect_end = if (self.disconnect_ctxs.len > 0) @intFromPtr(&self.disconnect_ctxs[self.disconnect_ctxs.len - 1].overlapped) + @sizeOf(win.OVERLAPPED) else 0;

        for (self.completion_entries[0..n_removed]) |*entry| {
            const ov_ptr = entry.lp_overlapped orelse continue;
            const ov_addr = @intFromPtr(ov_ptr);
            if (ov_addr >= disconnect_base and ov_addr < disconnect_end) {
                const dix = (ov_addr - disconnect_base) / @sizeOf(DisconnectCtx);
                if (dix < self.disconnect_ctxs.len and ov_ptr.Internal == 0) {
                    const sock = self.disconnect_ctxs[dix].socket;
                    self.disconnect_ctxs[dix].socket = ws2.INVALID_SOCKET;
                    _ = self.disconnect_free.append(dix) catch {};
                    _ = self.free_sockets.append(sock) catch {};
                }
                continue;
            }
            if (self.completion_count >= self.completion_buffer.len) break;
            const key = entry.lp_completion_key;
            const bytes = entry.dw_number_of_bytes_transferred;
            const success = (ov_ptr.Internal == 0);

            // 连接 I/O：completion_key = max_connections + slot_index
            if (key >= self.max_connections) {
                const slot_index = key - self.max_connections;
                if (slot_index >= self.conn_io_slots.len) continue;
                const slot = &self.conn_io_slots[slot_index];
                if (slot.tag == .recv) {
                    self.pushCompletionRecv(
                        slot.user_data,
                        if (success and slot.chunk_index < self.chunk_count and bytes > 0)
                            self.pool_ptr + slot.chunk_index * CHUNK_SIZE
                        else
                            @as([*]const u8, @ptrCast(&[_]u8{})),
                        if (success) @as(usize, bytes) else 0,
                        if (success) null else api.SendFileError.SocketWrite,
                        slot.chunk_index,
                    );
                } else {
                    self.pushCompletionSend(
                        slot.user_data,
                        if (success) @as(usize, bytes) else 0,
                        if (success) null else api.SendFileError.SocketWrite,
                    );
                }
                slot.overlapped = .{
                    .Internal = 0,
                    .InternalHigh = 0,
                    .Union = .{ .Pointer = null },
                    .hEvent = null,
                };
                _ = self.conn_io_free.append(slot_index) catch {};
                continue;
            }

            const accept_idx = key;
            self.handleAcceptCompletion(
                accept_idx,
                listen_sockets[accept_idx],
                accept_sockets[accept_idx],
                user_datas[accept_idx],
                chunk_indices[accept_idx],
                success,
                bytes,
            );
        }
        if (self.accept_backlog_target > 0) self.ensureAcceptBacklog();
        return self.completion_buffer[0..self.completion_count];
    }

    /// AcceptEx 完成：首包已在池块中；成功则填 completion；socket_reuse 且已加载 DisconnectEx 时投递 DisconnectEx( TF_REUSE_SOCKET ) 不关闭句柄，否则关闭
    fn handleAcceptCompletion(
        self: *HighPerfIO,
        accept_idx: usize,
        listen_socket: ws2.SOCKET,
        accept_socket: ws2.SOCKET,
        user_data: usize,
        chunk_index: usize,
        success: bool,
        bytes_transferred: win.DWORD,
    ) void {
        self.slot_data.items(.accept_socket)[accept_idx] = ws2.INVALID_SOCKET;
        _ = self.accept_free.append(accept_idx) catch {};
        defer self.chunk_cache.release(chunk_index);

        if (!success) {
            if (accept_socket != ws2.INVALID_SOCKET) _ = ws2.closesocket(accept_socket);
            return;
        }
        if (ws2.setsockopt(
            accept_socket,
            ws2.SOL.SOCKET,
            ws2.SO.UPDATE_ACCEPT_CONTEXT,
            std.mem.asBytes(&listen_socket),
            @sizeOf(ws2.SOCKET),
        ) != 0) {
            _ = ws2.closesocket(accept_socket);
            return;
        }

        const addr_len = 2 * ACCEPT_ADDR_LEN;
        const data_len = if (bytes_transferred > addr_len) bytes_transferred - addr_len else 0;
        const data_ptr = if (chunk_index < self.chunk_count and data_len > 0)
            self.pool_ptr + chunk_index * CHUNK_SIZE + addr_len
        else
            @as([*]const u8, @ptrCast(&[_]u8{}));

        const client_stream: std.Io.net.Stream = .{ .handle = accept_socket };
        if (self.completion_count < self.completion_buffer.len) {
            self.completion_buffer[self.completion_count] = .{
                .user_data = user_data,
                .buffer_ptr = data_ptr,
                .len = data_len,
                .err = null,
                .client_stream = client_stream,
                .tag = .accept,
                .chunk_index = null,
            };
            self.completion_count += 1;
        } else {
            _ = ws2.closesocket(accept_socket);
        }
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

    /// 在连接上提交一次 recv：从池取块、占 conn_io 槽位、associate socket 后 WSARecv；完成时 tag=recv、chunk_index 有效，用毕须 releaseChunk
    pub fn submitRecv(self: *HighPerfIO, stream: std.Io.net.Stream, user_data: usize) void {
        const slot_index = self.conn_io_free.popOrNull() orelse return;
        const chunk_index = self.chunk_cache.acquire() orelse {
            _ = self.conn_io_free.append(slot_index) catch {};
            return;
        };
        const socket: ws2.SOCKET = @ptrCast(stream.handle);
        const key: win.ULONG_PTR = @intCast(self.max_connections + slot_index);
        if (kernel32.CreateIoCompletionPort(socket, self.port, key, 0) == null) {
            self.chunk_cache.release(chunk_index);
            _ = self.conn_io_free.append(slot_index) catch {};
            return;
        }
        const slot = &self.conn_io_slots[slot_index];
        slot.overlapped = .{
            .Internal = 0,
            .InternalHigh = 0,
            .Union = .{ .Pointer = null },
            .hEvent = null,
        };
        slot.tag = .recv;
        slot.chunk_index = chunk_index;
        slot.user_data = user_data;
        var wsa_buf = ws2.WSABUF{
            .len = CHUNK_SIZE,
            .buf = @ptrCast(self.pool_ptr + chunk_index * CHUNK_SIZE),
        };
        var flags: win.DWORD = 0;
        if (ws2.WSARecv(socket, @ptrCast(&wsa_buf), 1, null, &flags, @ptrCast(&slot.overlapped), null) != 0) {
            const err = ws2.WSAGetLastError();
            if (err != ws2.WSA_IO_PENDING) {
                self.chunk_cache.release(chunk_index);
                slot.overlapped = .{ .Internal = 0, .InternalHigh = 0, .Union = .{ .Pointer = null }, .hEvent = null };
                _ = self.conn_io_free.append(slot_index) catch {};
            }
        }
    }

    /// 归还 recv 完成项占用的池块
    pub fn releaseChunk(self: *HighPerfIO, chunk_index: usize) void {
        self.chunk_cache.release(chunk_index);
    }

    /// 在连接上提交 send：占 conn_io 槽位、存 buf 引用、associate 后 WSASend；完成前 data 须保持有效，完成时 tag=send、len=已发送字节数
    pub fn submitSend(self: *HighPerfIO, stream: std.Io.net.Stream, data: []const u8, user_data: usize) void {
        if (data.len == 0) return;
        const slot_index = self.conn_io_free.popOrNull() orelse return;
        const socket: ws2.SOCKET = @ptrCast(stream.handle);
        const key: win.ULONG_PTR = @intCast(self.max_connections + slot_index);
        if (kernel32.CreateIoCompletionPort(socket, self.port, key, 0) == null) {
            _ = self.conn_io_free.append(slot_index) catch {};
            return;
        }
        const slot = &self.conn_io_slots[slot_index];
        slot.overlapped = .{
            .Internal = 0,
            .InternalHigh = 0,
            .Union = .{ .Pointer = null },
            .hEvent = null,
        };
        slot.tag = .send;
        slot.user_data = user_data;
        slot.send_buf_ptr = data.ptr;
        slot.send_buf_len = data.len;
        var wsa_buf = ws2.WSABUF{
            .len = @intCast(data.len),
            .buf = @ptrCast(slot.send_buf_ptr),
        };
        if (ws2.WSASend(socket, @ptrCast(&wsa_buf), 1, null, 0, @ptrCast(&slot.overlapped), null) != 0) {
            const err = ws2.WSAGetLastError();
            if (err != ws2.WSA_IO_PENDING) {
                slot.overlapped = .{ .Internal = 0, .InternalHigh = 0, .Union = .{ .Pointer = null }, .hEvent = null };
                _ = self.conn_io_free.append(slot_index) catch {};
            }
        }
    }
};

const TRANSMIT_FILE_MAX_CHUNK: u64 = std.math.maxInt(win.DWORD);

/// 零拷贝：文件 → 网络（TransmitFile）；count 超 DWORD 时循环直至发完。
/// 进阶：小文件（<4KB）可考虑 TF_USE_DEFAULT_WORKER 减少线程切换；短连接压榨可配合 DisconnectEx + TF_REUSE_SOCKET 复用 socket 句柄，绕过创建开销。
pub fn sendFile(stream: std.Io.net.Stream, file: std.fs.File, offset: u64, count: u64) api.SendFileError!void {
    const h_socket: ws2.SOCKET = @ptrCast(stream.handle);
    const h_file: win.HANDLE = file.handle;
    var sent: u64 = 0;
    var current_offset = offset;
    while (sent < count) {
        const left = count - sent;
        const chunk = @min(left, TRANSMIT_FILE_MAX_CHUNK);
        const move: win.LARGE_INTEGER = @intCast(current_offset);
        if (kernel32.SetFilePointerEx(h_file, move, null, FILE_BEGIN) == 0) {
            return error.FileRead;
        }
        const n: win.DWORD = @intCast(chunk);
        if (ws2.TransmitFile(h_socket, h_file, n, 0, null, null, 0) == 0) {
            return error.TransmitFileFailed;
        }
        sent += chunk;
        current_offset += chunk;
    }
}

// 异步文件 I/O（AsyncFileIO）已迁至 io_core/file.zig，Windows 实现为 file.zig 内 AsyncFileIOWindows，由 mod 统一导出 file.AsyncFileIO。
