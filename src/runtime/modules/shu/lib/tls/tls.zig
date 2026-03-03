// TLS 服务端封装：options.tls 时在 accept 后做握手，再按明文流读写
// 依赖 C 封装 tls.c（OpenSSL），由 build_options.have_tls 控制是否编译

const std = @import("std");
const build_options = @import("build_options");

/// 当 have_tls 时的 TLS 上下文（cert/key 已加载）
pub const TlsContext = if (build_options.have_tls) struct {
    ptr: *opaque {},
    allocator: std.mem.Allocator,

    /// 从证书与私钥文件路径创建；路径为 UTF-8，失败返回 null
    pub fn create(allocator: std.mem.Allocator, cert_path: []const u8, key_path: []const u8) ?@This() {
        const cert_z = allocator.dupeZ(u8, cert_path) catch return null;
        defer allocator.free(cert_z);
        const key_z = allocator.dupeZ(u8, key_path) catch return null;
        defer allocator.free(key_z);
        const ctx = c.tls_ctx_create(cert_z.ptr, key_z.ptr);
        if (ctx == null) return null;
        return .{ .ptr = @ptrCast(ctx), .allocator = allocator };
    }

    pub fn destroy(self: *@This()) void {
        c.tls_ctx_free(@ptrCast(self.ptr));
        self.ptr = undefined;
    }

    const c = @cImport({
        @cInclude("tls.h");
    });
} else struct {
    pub fn create(_: std.mem.Allocator, _: []const u8, _: []const u8) ?@This() {
        return null;
    }
    pub fn destroy(_: *@This()) void {}
};

/// 当 have_tls 时的客户端 TLS 上下文：CA/校验选项，用于 tls_connect
pub const TlsClientContext = if (build_options.have_tls) struct {
    ptr: *opaque {},
    allocator: std.mem.Allocator,

    /// ca_path 为 CA 证书路径（PEM 文件或目录），null 表示用系统默认；verify_peer 为 true 时验证服务端证书
    pub fn create(allocator: std.mem.Allocator, ca_path: ?[]const u8, verify_peer: bool) ?@This() {
        const ca_z = if (ca_path) |p| allocator.dupeZ(u8, p) catch return null else null;
        defer if (ca_z) |z| allocator.free(z);
        const ca_ptr: [*]const u8 = if (ca_z) |z| z.ptr else @ptrCast("");
        const ctx = c.tls_client_ctx_create(ca_ptr, if (verify_peer) 1 else 0);
        if (ctx == null) return null;
        return .{ .ptr = @ptrCast(ctx), .allocator = allocator };
    }

    pub fn destroy(self: *@This()) void {
        c.tls_client_ctx_free(@ptrCast(self.ptr));
        self.ptr = undefined;
    }

    const c = @cImport({
        @cInclude("tls.h");
    });
} else struct {
    pub fn create(_: std.mem.Allocator, _: ?[]const u8, _: bool) ?@This() {
        return null;
    }
    pub fn destroy(_: *@This()) void {}
};

/// 当 have_tls 时的非阻塞握手中句柄：fd 须已 non-blocking，由 tlsAcceptStart 创建，step 推进或 free 释放
pub const TlsPending = if (build_options.have_tls) struct {
    ptr: *opaque {},
    const c = @cImport({
        @cInclude("tls.h");
    });

    /// 开始非阻塞握手；调用方须已对 fd 调用 setNonBlocking。失败返回 null（调用方需 close(fd)）
    pub fn start(ctx: *const TlsContext, fd: std.posix.socket_t) ?@This() {
        const p = c.tls_accept_start(@ptrCast(ctx.ptr), fd);
        if (p == null) return null;
        return .{ .ptr = @ptrCast(p) };
    }
    /// 查询当前是否需等待可读再 step
    pub fn wantRead(self: *const @This()) bool {
        return c.tls_pending_want_read(@ptrCast(self.ptr)) != 0;
    }
    /// 查询当前是否需等待可写再 step
    pub fn wantWrite(self: *const @This()) bool {
        return c.tls_pending_want_write(@ptrCast(self.ptr)) != 0;
    }
    /// 推进握手：返回 .done 且 out_conn 已写入时调用方取 TlsStream 并 tlsPendingFree；.again 需 poll 后再调；.err 表示失败
    pub fn step(self: *@This(), out_conn: *?*anyopaque) enum { done, again, err } {
        var conn_ptr: ?*anyopaque = null;
        const r = c.tls_accept_step(@ptrCast(self.ptr), @ptrCast(&conn_ptr));
        if (r == 1) {
            out_conn.* = conn_ptr;
            return .done;
        }
        if (r == 0) return .again;
        return .err;
    }
    /// 释放握手中句柄（不关 fd）；握手成功时由 step 内部释放，勿再调
    pub fn free(self: *@This()) void {
        c.tls_pending_free(@ptrCast(self.ptr));
        self.ptr = undefined;
    }
    /// BIO 模式：无 fd，由调用方用 feedRead/getSend 与 overlapped I/O 配合。失败返回 null
    pub fn startBio(ctx: *const TlsContext) ?@This() {
        const p = c.tls_accept_start_bio(@ptrCast(ctx.ptr));
        if (p == null) return null;
        return .{ .ptr = @ptrCast(p) };
    }
    /// BIO 模式：向握手中 SSL 读 BIO 喂入加密数据（WSARecv 完成后调用）
    pub fn feedRead(self: *@This(), buf: []const u8) bool {
        return c.tls_pending_feed_read(@ptrCast(self.ptr), buf.ptr, @intCast(buf.len)) == 0;
    }
    /// BIO 模式：取出待发送加密数据，用于 post WSASend；返回字节数
    pub fn getSend(self: *@This(), buf: []u8) usize {
        const n = c.tls_pending_get_send(@ptrCast(self.ptr), buf.ptr, @intCast(buf.len));
        return if (n > 0) @intCast(n) else 0;
    }
    /// BIO 模式：推进握手；.done 时 out_conn 已写入，pending 已内部释放；.again 需再喂/取后重试
    pub fn stepBio(self: *@This(), out_conn: *?*anyopaque) enum { done, again, err } {
        var conn_ptr: ?*anyopaque = null;
        const r = c.tls_pending_accept_step_bio(@ptrCast(self.ptr), @ptrCast(&conn_ptr));
        if (r == 1) {
            out_conn.* = conn_ptr;
            return .done;
        }
        if (r == 0) return .again;
        return .err;
    }
} else void;

/// 当 have_tls 时的 TLS 流：包装底层 TCP stream，读写经 TLS 加解密
pub const TlsStream = if (build_options.have_tls) struct {
    /// 底层 TCP 连接（close 时由本结构负责关闭）
    underlying: std.Io.net.Stream,
    /// C 层 TLS 连接句柄
    conn: *opaque {},

    /// 从非阻塞握手得到的 C conn 与底层 stream 构造 TlsStream（用于握手完成后；含 BIO 模式 conn）
    pub fn fromConn(underlying: std.Io.net.Stream, conn: *anyopaque) @This() {
        return .{ .underlying = underlying, .conn = @ptrCast(conn) };
    }

    /// 在已 accept 的 stream 上做服务端 TLS 握手（阻塞）；失败返回错误，调用方需 close(stream)
    pub fn accept(underlying: std.Io.net.Stream, ctx: *const TlsContext) !@This() {
        const fd = underlying.socket.handle;
        const conn = c.tls_accept(@ptrCast(ctx.ptr), fd);
        if (conn == null) return error.TlsHandshakeFailed;
        return .{ .underlying = underlying, .conn = @ptrCast(conn) };
    }

    /// 在已连接的 TCP stream 上做客户端 TLS 握手（阻塞）；servername 用于 SNI，可为 null；allocator 用于复制 servername 为 C 字符串
    pub fn connect(underlying: std.Io.net.Stream, client_ctx: *const TlsClientContext, servername: ?[]const u8, allocator: std.mem.Allocator) !@This() {
        const fd = underlying.socket.handle;
        const name_z = if (servername) |s| allocator.dupeZ(u8, s) catch return error.TlsHandshakeFailed else null;
        defer if (name_z) |z| allocator.free(z);
        const name_ptr: [*]const u8 = if (name_z) |z| z.ptr else @ptrCast("");
        const conn = c.tls_connect(@ptrCast(client_ctx.ptr), fd, name_ptr);
        if (conn == null) return error.TlsHandshakeFailed;
        return .{ .underlying = underlying, .conn = @ptrCast(conn) };
    }

    /// ALPN 协商结果：将协议名写入 buf，返回有效切片；未协商或非 h2 时返回 null（供判断是否走 HTTP/2）
    pub fn getAlpnSelected(self: *const @This(), buf: []u8) ?[]const u8 {
        if (buf.len == 0) return null;
        const n = c.tls_get_alpn_selected(@ptrCast(self.conn), buf.ptr, @intCast(buf.len));
        if (n <= 0) return null;
        return buf[0..@intCast(n)];
    }

    /// 实现 Reader：从 TLS 读入明文（阻塞式，内部重试 WANT_*）
    pub fn read(self: *@This(), buf: []u8) !usize {
        const n = c.tls_read(@ptrCast(self.conn), buf.ptr, @intCast(buf.len));
        if (n < 0) return error.TlsReadFailed;
        return @intCast(n);
    }

    /// 非阻塞读：返回字节数或 error.WantRead/error.WantWrite/error.TlsReadFailed；供多路复用 step 使用。BIO 模式时调用方须已 feedRead，此处仅 read_after_feed
    pub fn readNonblock(self: *@This(), buf: []u8) !usize {
        if (self.isBio()) {
            const n = c.tls_conn_read_after_feed(@ptrCast(self.conn), buf.ptr, @intCast(buf.len));
            if (n > 0) return @intCast(n);
            if (n == 0) return 0;
            if (n == -2) return error.WantRead;
            if (n == -3) return error.WantWrite;
            return error.TlsReadFailed;
        }
        const n = c.tls_read(@ptrCast(self.conn), buf.ptr, @intCast(buf.len));
        if (n > 0) return @intCast(n);
        if (n == 0) return 0;
        if (n == -2) return error.WantRead;
        if (n == -3) return error.WantWrite;
        return error.TlsReadFailed;
    }

    /// 非阻塞写：返回已写字节数或 error.WantRead/error.WantWrite/error.TlsWriteFailed；供多路复用 step 使用。BIO 模式时用 writeApp，调用方需随后 getSend 并 post WSASend
    pub fn writeNonblock(self: *@This(), buf: []const u8) !usize {
        if (self.isBio()) {
            const n = c.tls_conn_write_app(@ptrCast(self.conn), buf.ptr, @intCast(buf.len));
            if (n > 0) return @intCast(n);
            if (n == -2) return error.WantRead;
            if (n == -3) return error.WantWrite;
            return error.TlsWriteFailed;
        }
        const n = c.tls_write(@ptrCast(self.conn), buf.ptr, @intCast(buf.len));
        if (n > 0) return @intCast(n);
        if (n == -2) return error.WantRead;
        if (n == -3) return error.WantWrite;
        return error.TlsWriteFailed;
    }

    /// 上次 readNonblock/writeNonblock 返回 WantRead 后，当前是否仍待可读
    pub fn wantRead(self: *const @This()) bool {
        return c.tls_conn_want_read(@ptrCast(self.conn)) != 0;
    }
    /// 上次 readNonblock/writeNonblock 返回 WantWrite 后，当前是否仍待可写
    pub fn wantWrite(self: *const @This()) bool {
        return c.tls_conn_want_write(@ptrCast(self.conn)) != 0;
    }

    /// 是否为 BIO 模式（IOCP 驱动，无 fd 读写）
    pub fn isBio(self: *const @This()) bool {
        return c.tls_conn_is_bio(@ptrCast(self.conn)) != 0;
    }
    /// BIO 模式：向读 BIO 喂入加密数据（WSARecv 完成后调用）；随后可调 readNonblock/readAfterFeed
    pub fn feedRead(self: *@This(), buf: []const u8) bool {
        return c.tls_conn_feed_read(@ptrCast(self.conn), buf.ptr, @intCast(buf.len)) == 0;
    }
    /// BIO 模式：喂入后读明文；语义同 readNonblock（>0 字节数，0 关闭，WantRead/WantWrite/TlsReadFailed）
    pub fn readAfterFeed(self: *@This(), buf: []u8) !usize {
        const n = c.tls_conn_read_after_feed(@ptrCast(self.conn), buf.ptr, @intCast(buf.len));
        if (n > 0) return @intCast(n);
        if (n == 0) return 0;
        if (n == -2) return error.WantRead;
        if (n == -3) return error.WantWrite;
        return error.TlsReadFailed;
    }
    /// BIO 模式：取出待发送加密数据；返回字节数，用于 post WSASend
    pub fn getSend(self: *@This(), buf: []u8) usize {
        const n = c.tls_conn_get_send(@ptrCast(self.conn), buf.ptr, @intCast(buf.len));
        return if (n > 0) @intCast(n) else 0;
    }
    /// BIO 模式：应用层写明文；语义同 writeNonblock。可能使写 BIO 有数据，需 getSend 取出后 WSASend
    pub fn writeApp(self: *@This(), buf: []const u8) !usize {
        const n = c.tls_conn_write_app(@ptrCast(self.conn), buf.ptr, @intCast(buf.len));
        if (n > 0) return @intCast(n);
        if (n == -2) return error.WantRead;
        if (n == -3) return error.WantWrite;
        return error.TlsWriteFailed;
    }

    /// 实现 Writer：向 TLS 写入明文（阻塞式，内部重试 WANT_*）
    pub fn writeAll(self: *@This(), buf: []const u8) !void {
        var off: usize = 0;
        while (off < buf.len) {
            const n = c.tls_write(@ptrCast(self.conn), buf.ptr + off, @intCast(buf.len - off));
            if (n <= 0) return error.TlsWriteFailed;
            off += @intCast(n);
        }
    }

    /// 关闭 TLS 并关闭底层 stream。0.16：underlying.close(io)
    pub fn close(self: *@This(), io: std.Io) void {
        c.tls_close(@ptrCast(self.conn));
        self.conn = undefined;
        self.underlying.close(io);
    }

    const c = @cImport({
        @cInclude("tls.h");
    });
} else struct {
    underlying: std.Io.net.Stream,
    pub fn accept(_: std.Io.net.Stream, _: *const TlsContext) !@This() {
        return error.TlsNotCompiled;
    }
    pub fn read(_: *@This(), _: []u8) !usize {
        return error.TlsNotCompiled;
    }
    pub fn writeAll(_: *@This(), _: []const u8) !void {
        return error.TlsNotCompiled;
    }
    pub fn close(_: *@This(), _: std.Io) void {}
};
