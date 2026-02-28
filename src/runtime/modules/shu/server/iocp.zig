// Windows I/O Completion Port：仅当 build_options.use_iocp 且目标为 Windows 时生效
// 支持仅 accept（pollAccept）或全 IOCP（getCompletion + postRecv/postSend）
const std = @import("std");
const build_options = @import("build_options");
const builtin = @import("builtin");

const win = std.os.windows;

/// 单次完成项：getCompletion 返回，overlapped 用于区分 accept vs 连接读写
pub const IocpCompletion = struct {
    overlapped: *win.OVERLAPPED,
    bytes_transferred: win.DWORD,
    completion_key: win.ULONG_PTR,
    success: bool,
};

/// AcceptEx 单次投递的上下文：OVERLAPPED 必须在首字段以便从完成回调取回
const IocpAcceptCtx = struct {
    overlapped: win.OVERLAPPED,
    listen_socket: win.ws2_32.SOCKET,
    accept_socket: win.ws2_32.SOCKET,
    /// AcceptEx 要求的地址缓冲（本地+远端），至少 2*(sizeof(sockaddr_storage)+16）
    buffer: [256]u8,
};

/// IOCP 状态：仅 Windows 且 use_iocp 时有效
pub const IocpState = if (builtin.os.tag == .windows and build_options.use_iocp) struct {
    port: win.HANDLE,
    allocator: std.mem.Allocator,
    /// 当前一次未完成的 AcceptEx 上下文（完成时复用并重投）
    accept_ctx: *IocpAcceptCtx,

    /// 创建完成端口并关联 listen_socket，投递一次 AcceptEx；失败返回 null，调用方需 close(listen_socket)
    pub fn init(allocator: std.mem.Allocator, listen_socket: win.ws2_32.SOCKET) ?@This() {
        const port = win.kernel32.CreateIoCompletionPort(
            listen_socket,
            null,
            0,
            0,
        ) orelse return null;
        errdefer _ = win.kernel32.CloseHandle(port);

        const ctx = allocator.create(IocpAcceptCtx) catch {
            _ = win.kernel32.CloseHandle(port);
            return null;
        };
        errdefer allocator.destroy(ctx);
        ctx.overlapped = .{
            .Internal = 0,
            .InternalHigh = 0,
            .Union = .{ .Pointer = null },
            .hEvent = null,
        };
        ctx.listen_socket = listen_socket;
        ctx.accept_socket = win.ws2_32.INVALID_SOCKET;

        const accept_socket = win.ws2_32.WSASocketW(
            win.ws2_32.AF.INET,
            win.ws2_32.SOCK.STREAM,
            win.ws2_32.IPPROTO.TCP,
            null,
            0,
            win.ws2_32.WSA_FLAG_OVERLAPPED,
        );
        if (accept_socket == win.ws2_32.INVALID_SOCKET) {
            allocator.destroy(ctx);
            _ = win.kernel32.CloseHandle(port);
            return null;
        }
        ctx.accept_socket = accept_socket;

        if (win.kernel32.CreateIoCompletionPort(accept_socket, port, 1, 0) == null) {
            _ = win.ws2_32.closesocket(accept_socket);
            allocator.destroy(ctx);
            _ = win.kernel32.CloseHandle(port);
            return null;
        }

        var bytes_received: win.DWORD = 0;
        const ok = win.ws2_32.AcceptEx(
            listen_socket,
            accept_socket,
            &ctx.buffer,
            0,
            @intCast((@sizeOf(win.ws2_32.sockaddr_in) + 16)),
            @intCast((@sizeOf(win.ws2_32.sockaddr_in) + 16)),
            &bytes_received,
            @ptrCast(&ctx.overlapped),
        );
        if (ok == 0) {
            const err = win.ws2_32.WSAGetLastError();
            if (err != win.ws2_32.WSA_IO_PENDING) {
                _ = win.ws2_32.closesocket(accept_socket);
                allocator.destroy(ctx);
                _ = win.kernel32.CloseHandle(port);
                return null;
            }
        }

        return .{
            .port = port,
            .allocator = allocator,
            .accept_ctx = ctx,
        };
    }

    /// 释放端口与上下文；不关 listen_socket（由调用方关）
    pub fn deinit(self: *@This()) void {
        _ = win.ws2_32.closesocket(self.accept_ctx.accept_socket);
        self.accept_ctx.accept_socket = win.ws2_32.INVALID_SOCKET;
        self.allocator.destroy(self.accept_ctx);
        _ = win.kernel32.CloseHandle(self.port);
        self.port = null;
    }

    /// 取一次完成：超时 0 即非阻塞。返回新连接的 socket（调用方负责 setsockopt SO_UPDATE_ACCEPT_CONTEXT、setNonBlocking、close）；无完成返回 null
    pub fn pollAccept(self: *@This()) ?win.ws2_32.SOCKET {
        var bytes: win.DWORD = 0;
        var key: win.ULONG_PTR = 0;
        var ov: ?*win.OVERLAPPED = null;
        const got = win.kernel32.GetQueuedCompletionStatus(
            self.port,
            &bytes,
            &key,
            &ov,
            0,
        );
        if (got == 0 or ov == null) return null;
        const ctx = @as(*IocpAcceptCtx, @ptrCast(@alignCast(ov)));
        const new_socket = ctx.accept_socket;

        if (win.ws2_32.setsockopt(
            new_socket,
            win.ws2_32.SOL.SOCKET,
            win.ws2_32.SO.UPDATE_ACCEPT_CONTEXT,
            std.mem.asBytes(&ctx.listen_socket),
            @sizeOf(win.ws2_32.SOCKET),
        ) != 0) {
            _ = win.ws2_32.closesocket(new_socket);
            _ = self.repostAccept(ctx);
            return null;
        }

        const next_socket = win.ws2_32.WSASocketW(
            win.ws2_32.AF.INET,
            win.ws2_32.SOCK.STREAM,
            win.ws2_32.IPPROTO.TCP,
            null,
            0,
            win.ws2_32.WSA_FLAG_OVERLAPPED,
        );
        if (next_socket == win.ws2_32.INVALID_SOCKET) {
            _ = win.ws2_32.closesocket(new_socket);
            _ = self.repostAccept(ctx);
            return null;
        }
        ctx.accept_socket = next_socket;
        if (win.kernel32.CreateIoCompletionPort(next_socket, self.port, 1, 0) == null) {
            _ = win.ws2_32.closesocket(next_socket);
            _ = win.ws2_32.closesocket(new_socket);
            _ = self.repostAccept(ctx);
            return null;
        }
        ctx.overlapped = .{
            .Internal = 0,
            .InternalHigh = 0,
            .Union = .{ .Pointer = null },
            .hEvent = null,
        };
        var bytes_recv: win.DWORD = 0;
        const ok = win.ws2_32.AcceptEx(
            ctx.listen_socket,
            next_socket,
            &ctx.buffer,
            0,
            @intCast((@sizeOf(win.ws2_32.sockaddr_in) + 16)),
            @intCast((@sizeOf(win.ws2_32.sockaddr_in) + 16)),
            &bytes_recv,
            @ptrCast(&ctx.overlapped),
        );
        if (ok == 0 and win.ws2_32.WSAGetLastError() != win.ws2_32.WSA_IO_PENDING) {
            _ = win.ws2_32.closesocket(next_socket);
        }
        return new_socket;
    }

    fn repostAccept(self: *@This(), ctx: *IocpAcceptCtx) void {
        const next = win.ws2_32.WSASocketW(
            win.ws2_32.AF.INET,
            win.ws2_32.SOCK.STREAM,
            win.ws2_32.IPPROTO.TCP,
            null,
            0,
            win.ws2_32.WSA_FLAG_OVERLAPPED,
        );
        if (next == win.ws2_32.INVALID_SOCKET) return;
        ctx.accept_socket = next;
        if (win.kernel32.CreateIoCompletionPort(next, self.port, 1, 0) == null) {
            _ = win.ws2_32.closesocket(next);
            return;
        }
        ctx.overlapped = .{
            .Internal = 0,
            .InternalHigh = 0,
            .Union = .{ .Pointer = null },
            .hEvent = null,
        };
        var bytes_recv: win.DWORD = 0;
        if (win.ws2_32.AcceptEx(
            ctx.listen_socket,
            next,
            &ctx.buffer,
            0,
            @intCast((@sizeOf(win.ws2_32.sockaddr_in) + 16)),
            @intCast((@sizeOf(win.ws2_32.sockaddr_in) + 16)),
            &bytes_recv,
            @ptrCast(&ctx.overlapped),
        ) == 0 and win.ws2_32.WSAGetLastError() != win.ws2_32.WSA_IO_PENDING) {
            _ = win.ws2_32.closesocket(next);
        }
    }

    // ---------- 全 IOCP：连接 recv/send 也走完成端口 ----------
    /// 判断完成项是否为 accept（用于与连接读写区分）
    pub fn isAcceptOverlapped(self: *const @This(), ov: *const win.OVERLAPPED) bool {
        return ov == &self.accept_ctx.overlapped;
    }

    /// 从完成端口取任意一项完成；timeout_ms=0 非阻塞。返回 null 表示无完成或超时
    pub fn getCompletion(self: *@This(), timeout_ms: win.DWORD) ?IocpCompletion {
        var bytes: win.DWORD = 0;
        var key: win.ULONG_PTR = 0;
        var ov: ?*win.OVERLAPPED = null;
        const got = win.kernel32.GetQueuedCompletionStatus(
            self.port,
            &bytes,
            &key,
            &ov,
            timeout_ms,
        );
        if (ov == null) return null;
        return .{
            .overlapped = ov.?,
            .bytes_transferred = bytes,
            .completion_key = key,
            .success = got != 0,
        };
    }

    /// 处理 accept 完成：与 pollAccept 相同逻辑，调用前需确认 comp.overlapped 为 accept_ctx。返回新 socket 或 null
    pub fn handleAcceptCompletion(self: *@This()) ?win.ws2_32.SOCKET {
        const ctx = self.accept_ctx;
        const new_socket = ctx.accept_socket;
        if (win.ws2_32.setsockopt(
            new_socket,
            win.ws2_32.SOL.SOCKET,
            win.ws2_32.SO.UPDATE_ACCEPT_CONTEXT,
            std.mem.asBytes(&ctx.listen_socket),
            @sizeOf(win.ws2_32.SOCKET),
        ) != 0) {
            _ = win.ws2_32.closesocket(new_socket);
            self.repostAccept(ctx);
            return null;
        }
        const next_socket = win.ws2_32.WSASocketW(
            win.ws2_32.AF.INET,
            win.ws2_32.SOCK.STREAM,
            win.ws2_32.IPPROTO.TCP,
            null,
            0,
            win.ws2_32.WSA_FLAG_OVERLAPPED,
        );
        if (next_socket == win.ws2_32.INVALID_SOCKET) {
            _ = win.ws2_32.closesocket(new_socket);
            self.repostAccept(ctx);
            return null;
        }
        ctx.accept_socket = next_socket;
        if (win.kernel32.CreateIoCompletionPort(next_socket, self.port, 1, 0) == null) {
            _ = win.ws2_32.closesocket(next_socket);
            _ = win.ws2_32.closesocket(new_socket);
            self.repostAccept(ctx);
            return null;
        }
        ctx.overlapped = .{
            .Internal = 0,
            .InternalHigh = 0,
            .Union = .{ .Pointer = null },
            .hEvent = null,
        };
        var bytes_recv: win.DWORD = 0;
        const ok = win.ws2_32.AcceptEx(
            ctx.listen_socket,
            next_socket,
            &ctx.buffer,
            0,
            @intCast((@sizeOf(win.ws2_32.sockaddr_in) + 16)),
            @intCast((@sizeOf(win.ws2_32.sockaddr_in) + 16)),
            &bytes_recv,
            @ptrCast(&ctx.overlapped),
        );
        if (ok == 0 and win.ws2_32.WSAGetLastError() != win.ws2_32.WSA_IO_PENDING) {
            _ = win.ws2_32.closesocket(next_socket);
        }
        return new_socket;
    }

    /// 将已连接的 socket 关联到本完成端口；key 用于完成时区分（如传 conn 指针）
    pub fn associateSocket(self: *@This(), socket: win.ws2_32.SOCKET, key: win.ULONG_PTR) bool {
        return win.kernel32.CreateIoCompletionPort(socket, self.port, key, 0) != null;
    }

    /// 投递 overlapped recv；buf 在完成前不得释放。成功返回 true，WSA_IO_PENDING 视为成功
    pub fn postRecv(self: *@This(), socket: win.ws2_32.SOCKET, overlapped: *win.OVERLAPPED, buf: []u8) bool {
        _ = self;
        var wsa_buf = win.ws2_32.WSABUF{
            .len = @intCast(buf.len),
            .buf = buf.ptr,
        };
        var flags: win.DWORD = 0;
        const ret = win.ws2_32.WSARecv(
            socket,
            @ptrCast(&wsa_buf),
            1,
            null,
            &flags,
            @ptrCast(overlapped),
            null,
        );
        if (ret == 0) return true;
        return win.ws2_32.WSAGetLastError() == win.ws2_32.WSA_IO_PENDING;
    }

    /// 投递 overlapped send；buf 在完成前不得释放
    pub fn postSend(self: *@This(), socket: win.ws2_32.SOCKET, overlapped: *win.OVERLAPPED, buf: []const u8) bool {
        _ = self;
        var wsa_buf = win.ws2_32.WSABUF{
            .len = @intCast(buf.len),
            .buf = @constCast(buf.ptr),
        };
        const ret = win.ws2_32.WSASend(
            socket,
            @ptrCast(&wsa_buf),
            1,
            null,
            0,
            @ptrCast(overlapped),
            null,
        );
        if (ret == 0) return true;
        return win.ws2_32.WSAGetLastError() == win.ws2_32.WSA_IO_PENDING;
    }
} else struct {
    pub fn init(_: std.mem.Allocator, _: std.posix.socket_t) ?@This() {
        return null;
    }
    pub fn deinit(_: *@This()) void {}
    pub fn pollAccept(_: *@This()) ?std.posix.socket_t {
        return null;
    }
    pub fn isAcceptOverlapped(_: *const @This(), _: *const win.OVERLAPPED) bool {
        return false;
    }
    pub fn getCompletion(_: *@This(), _: win.DWORD) ?IocpCompletion {
        return null;
    }
    pub fn handleAcceptCompletion(_: *@This()) ?std.posix.socket_t {
        return null;
    }
    pub fn associateSocket(_: *@This(), _: std.posix.socket_t, _: win.ULONG_PTR) bool {
        return false;
    }
    pub fn postRecv(_: *@This(), _: std.posix.socket_t, _: *win.OVERLAPPED, _: []u8) bool {
        return false;
    }
    pub fn postSend(_: *@This(), _: std.posix.socket_t, _: *win.OVERLAPPED, _: []const u8) bool {
        return false;
    }
};
