// shu:net — Node 风格 API：与 node:net 对齐
// createServer、server.listen(port|path|options)、close、address；
// socket：write/end/destroy、on('data'/'end')、remoteAddress 等；createConnection；isIP 等工具
//
// 0.16.0-dev：网络 API 已迁至 std.Io.net；当前仍使用 std.net 以保持与现有 io_core/server 一致，待 io_core 或 std.Io 稳定后迁移（见规则 03 §4、§0）。

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");
const errors = @import("errors");
const libs_process = @import("libs_process");
const tls = @import("tls");

/// 是否 Windows（comptime 分派，用于 Unix socket / 平台分支）
const is_windows = builtin.os.tag == .windows;

/// 0.16：std.Io.net 无 Address，用 sockaddr_storage 存 getpeername/getsockname 结果，供 Node 风格 remoteAddress/localAddress 格式化
const NodeNetAddress = struct {
    any: std.posix.sockaddr.storage,
    pub fn getPort(self: NodeNetAddress) u16 {
        if (self.any.family == std.posix.AF.INET) {
            const in4 = @as(*const std.posix.sockaddr.in, @ptrCast(&self.any));
            return @byteSwap(in4.port);
        }
        if (self.any.family == std.posix.AF.INET6) {
            const in6 = @as(*const std.posix.sockaddr.in6, @ptrCast(&self.any));
            return @byteSwap(in6.port);
        }
        return 0;
    }
};

/// 单条 net server 记录：listen 的 Server、connection 回调、server_id 与 address 信息；allowHalfOpen 等从 createServer(options) 传入
const NetServerEntry = struct {
    server: std.Io.net.Server,
    listener: jsc.JSValueRef,
    ctx: jsc.JSContextRef,
    server_id: u32,
    port: u16,
    host_len: usize,
    host_buf: [256]u8,
    is_unix: bool,
    path_len: usize,
    path_buf: [256]u8,
    allow_half_open: bool,
};

/// 全局 net server 列表；首次 listen 时用 current_allocator 创建
var g_net_servers: ?std.ArrayList(NetServerEntry) = null;
/// socket id -> stream，供 socket.write/end/destroy 使用
var g_net_sockets: ?std.AutoHashMap(u32, std.Io.net.Stream) = null;
/// socket id -> socket JS 对象（供 read tick 取 on('data') 等）
var g_net_socket_objs: ?std.AutoHashMap(u32, jsc.JSObjectRef) = null;
/// Node 兼容：每个 socket 的 bytesWritten/bytesRead 计数
var g_net_socket_meta: ?std.AutoHashMap(u32, SocketMeta) = null;
var g_next_socket_id: u32 = 1;
var g_next_server_id: u32 = 1;
/// 启用 TLS 时：socket id -> *TlsStream，升级后读写经 TLS；由 shu:tls 调用 setSocketTls 设置；未启用 TLS 时恒为 null
var g_net_socket_tls: ?std.AutoHashMap(u32, *tls.TlsStream) = null;

const SocketMeta = struct {
    bytes_written: u64,
    bytes_read: u64,
    last_activity_ms: u64, // 用于 setTimeout(timeout) 触发 'timeout' 事件
    ref_count: i32 = 1, // Node 兼容：ref()/unref()，>0 时该 socket 参与 has_work，阻止进程退出
    paused: bool = false, // Node 兼容：pause() 后暂停触发 'data'，resume() 恢复
};

/// Node 兼容：socket 的 remoteAddress/remotePort/localAddress/localPort/family，创建时写入 socket 对象
const SocketAddrInfo = struct {
    remote_address: []const u8,
    remote_port: u16,
    local_address: []const u8,
    local_port: u16,
    family: []const u8, // "IPv4" | "IPv6" | "Unix"
};

/// createConnection 异步结果：由工作线程 push，主线程在 netTick 中 drain 并调 connectListener；若 user_callback 非 null 则调用 user_callback(null, socket) 或 user_callback(err)
const PendingConnect = struct {
    stream: ?std.Io.net.Stream,
    err_msg: ?[]const u8, // 由主线程 free
    ctx: jsc.JSContextRef,
    callback: jsc.JSValueRef,
    allocator: std.mem.Allocator,
    user_callback: ?jsc.JSValueRef = null,
    timeout_ms: ?u32 = null, // createConnection(options) 的 options.timeout，连接成功后对 socket 设 setTimeout
};
var g_net_pending_mutex: std.Io.Mutex = .{ .state = std.atomic.Value(std.Io.Mutex.State).init(.unlocked) };
var g_net_pending_connects: ?std.ArrayList(PendingConnect) = null;
/// 未处理完的 createConnection 数量（spawn 时 +1，主线程处理一条时 -1），用于 has_work 调度
var g_net_pending_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

/// 将 fd 设为非阻塞（POSIX: fcntl O_NONBLOCK，Windows: ioctlsocket FIONBIO）。0.16：fcntl 在 std.c
fn setNonBlocking(fd: std.posix.socket_t) void {
    if (is_windows) {
        var mode: std.c.uint = 1;
        _ = std.c.ioctlsocket(@as(std.c.socket_t, @intCast(fd)), std.c.FIONBIO, &mode);
        return;
    }
    const flags = std.c.fcntl(fd, std.c.F.GETFL);
    _ = std.c.fcntl(fd, std.c.F.SETFL, flags | 0x4); // O_NONBLOCK
}

/// 从已连接的 stream 获取对端地址（Node 兼容：remoteAddress/remotePort），失败返回 null。0.16：Stream 为 .socket.handle
fn getStreamRemoteAddress(stream: std.Io.net.Stream) ?NodeNetAddress {
    var addr: NodeNetAddress = undefined;
    var len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    if (std.c.getpeername(stream.socket.handle, @ptrCast(&addr.any), &len) != 0) return null;
    return addr;
}

/// 从已连接的 stream 获取本端地址（Node 兼容：localAddress/localPort），失败返回 null
fn getStreamLocalAddress(stream: std.Io.net.Stream) ?NodeNetAddress {
    var addr: NodeNetAddress = undefined;
    var len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.storage);
    if (std.c.getsockname(stream.socket.handle, @ptrCast(&addr.any), &len) != 0) return null;
    return addr;
}

/// 将 NodeNetAddress 格式化为 Node 风格字符串（IPv4 "x.x.x.x"，IPv6 "[::1]" 等），allocator 分配且以 null 结尾，调用方负责 free
fn addressToNodeStringZ(allocator: std.mem.Allocator, addr: NodeNetAddress) []const u8 {
    var buf: [128]u8 = undefined;
    const s = switch (addr.any.family) {
        std.posix.AF.INET => blk: {
            const in4 = @as(*const std.posix.sockaddr.in, @ptrCast(&addr.any));
            const addr_bytes = std.mem.asBytes(&in4.addr);
            break :blk std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}", .{ addr_bytes[0], addr_bytes[1], addr_bytes[2], addr_bytes[3] }) catch "0.0.0.0";
        },
        std.posix.AF.INET6 => "::1",
        std.posix.AF.UNIX => "unix",
        else => "unknown",
    };
    return allocator.dupeZ(u8, s) catch allocator.dupeZ(u8, "unknown") catch "";
}

/// 根据 remote/local 两个 Address 构建 SocketAddrInfo，字符串由 allocator 分配且以 null 结尾，调用方负责 free 各 slice
fn getSocketAddrInfo(allocator: std.mem.Allocator, remote: NodeNetAddress, local: NodeNetAddress) SocketAddrInfo {
    const family_str = switch (remote.any.family) {
        std.posix.AF.INET => "IPv4",
        std.posix.AF.INET6 => "IPv6",
        std.posix.AF.UNIX => "Unix",
        else => "unknown",
    };
    const remote_str = addressToNodeStringZ(allocator, remote);
    const local_str = addressToNodeStringZ(allocator, local);
    const family_dup = allocator.dupeZ(u8, family_str) catch allocator.dupeZ(u8, "IPv4") catch "";
    return .{
        .remote_address = remote_str,
        .remote_port = remote.getPort(),
        .local_address = local_str,
        .local_port = local.getPort(),
        .family = family_dup,
    };
}

/// 返回 shu:net 的 exports：createServer、createConnection、connect、isIP、isIPv4、isIPv6、Socket、Server（Node 兼容）
pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    _ = allocator;
    const net_obj = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, net_obj, "createServer", createServerCallback);
    common.setMethod(ctx, net_obj, "createConnection", createConnectionCallback);
    common.setMethod(ctx, net_obj, "connect", createConnectionCallback);
    common.setMethod(ctx, net_obj, "isIP", netIsIPCallback);
    common.setMethod(ctx, net_obj, "isIPv4", netIsIPv4Callback);
    common.setMethod(ctx, net_obj, "isIPv6", netIsIPv6Callback);
    common.setMethod(ctx, net_obj, "Server", createServerCallback);
    common.setMethod(ctx, net_obj, "Socket", socketConstructorCallback);
    return net_obj;
}

/// 根据 socket id 取回 stream；供 shu:tls 在连接建立后做 TLS 握手（connect 需传入底层 stream）
pub fn getStreamById(socket_id: u32) ?std.Io.net.Stream {
    if (g_net_sockets) |*sockets| return sockets.get(socket_id) else return null;
}

/// 将已连接的 socket 升级为 TLS；供 shu:tls 在 TCP 连接建立后做客户端握手并设置。仅当 build_options.have_tls 时有效
pub fn setSocketTls(socket_id: u32, tls_stream: *tls.TlsStream) void {
    if (!build_options.have_tls) return;
    const allocator = globals.current_allocator orelse return;
    if (g_net_socket_tls == null) {
        g_net_socket_tls = std.AutoHashMap(u32, *tls.TlsStream).init(allocator);
    }
    g_net_socket_tls.?.put(socket_id, tls_stream) catch {};
}

/// net.Socket()：Node 兼容构造器；返回带 connect(port[, host][, callback]) 的对象，connect 内部调 createConnection，callback(err, socket) 收到连接后的 socket
fn socketConstructorCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const socket = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, socket, "connect", socketConnectCallback);
    return socket;
}

/// socket.connect(port[, host][, callback])：内部 spawn 连接线程，callback 签名为 (err, socket)，与 createConnection 单参回调兼容
fn socketConnectCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    _ = this;
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const port_val = arguments[0];
    const host_val = if (argumentCount > 1) arguments[1] else jsc.JSValueMakeUndefined(ctx);
    const user_cb = if (argumentCount > 2) arguments[2] else if (argumentCount > 1 and jsc.JSObjectIsFunction(ctx, @ptrCast(arguments[1]))) arguments[1] else jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const port_n = jsc.JSValueToNumber(ctx, port_val, null);
    if (port_n != port_n or port_n < 1 or port_n > 65535) return jsc.JSValueMakeUndefined(ctx);
    const port = @as(u16, @intFromFloat(port_n));
    var host: []const u8 = "localhost";
    if (!jsc.JSValueIsUndefined(ctx, host_val) and !jsc.JSObjectIsFunction(ctx, @ptrCast(host_val))) {
        const js_str = jsc.JSValueToStringCopy(ctx, host_val, null);
        defer jsc.JSStringRelease(js_str);
        var host_buf: [256]u8 = undefined;
        const n = jsc.JSStringGetUTF8CString(js_str, host_buf[0..].ptr, host_buf.len);
        if (n > 0) host = allocator.dupe(u8, host_buf[0 .. n - 1]) catch "localhost";
    } else {
        host = allocator.dupe(u8, "localhost") catch return jsc.JSValueMakeUndefined(ctx);
    }
    const connect_listener = if (jsc.JSObjectIsFunction(ctx, @ptrCast(user_cb))) user_cb else return jsc.JSValueMakeUndefined(ctx);
    jsc.JSValueProtect(ctx, connect_listener);
    _ = g_net_pending_count.fetchAdd(1, .monotonic);
    if (g_net_pending_connects == null) {
        g_net_pending_connects = std.ArrayList(PendingConnect).initCapacity(allocator, 4) catch {
            jsc.JSValueUnprotect(ctx, connect_listener);
            _ = g_net_pending_count.fetchSub(1, .monotonic);
            if (host.len > 0) allocator.free(host);
            return jsc.JSValueMakeUndefined(ctx);
        };
    }
    const args = allocator.create(ConnectArgs) catch {
        jsc.JSValueUnprotect(ctx, connect_listener);
        _ = g_net_pending_count.fetchSub(1, .monotonic);
        if (host.len > 0) allocator.free(host);
        return jsc.JSValueMakeUndefined(ctx);
    };
    args.* = .{
        .allocator = allocator,
        .port = port,
        .host = host,
        .path = "",
        .is_unix = false,
        .ctx = ctx,
        .callback = connect_listener,
        .user_callback = connect_listener,
    };
    var thread = std.Thread.spawn(.{}, connectThreadMain, .{args}) catch {
        allocator.destroy(args);
        if (host.len > 0) allocator.free(host);
        jsc.JSValueUnprotect(ctx, connect_listener);
        _ = g_net_pending_count.fetchSub(1, .monotonic);
        return jsc.JSValueMakeUndefined(ctx);
    };
    thread.detach();
    scheduleNetTick(ctx);
    return jsc.JSValueMakeUndefined(ctx);
}

/// createServer([options], connectionListener)：Node 兼容。支持 createServer(connectionListener) 与 createServer(options, connectionListener)；options 可为 { allowHalfOpen } 等
fn createServerCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    var connectionListener: jsc.JSValueRef = undefined;
    if (argumentCount >= 2 and (jsc.JSValueToObject(ctx, arguments[0], null) != null) and !jsc.JSObjectIsFunction(ctx, @ptrCast(arguments[0]))) {
        // createServer(options, connectionListener)
        connectionListener = arguments[1];
        if (!jsc.JSObjectIsFunction(ctx, @ptrCast(connectionListener))) return jsc.JSValueMakeUndefined(ctx);
    } else {
        // createServer(connectionListener)
        connectionListener = arguments[0];
        if (!jsc.JSObjectIsFunction(ctx, @ptrCast(connectionListener))) return jsc.JSValueMakeUndefined(ctx);
    }
    const server = jsc.JSObjectMake(ctx, null, null);
    const k_listener = jsc.JSStringCreateWithUTF8CString("_connectionListener");
    defer jsc.JSStringRelease(k_listener);
    _ = jsc.JSObjectSetProperty(ctx, server, k_listener, connectionListener, jsc.kJSPropertyAttributeNone, null);
    if (argumentCount >= 2 and (jsc.JSValueToObject(ctx, arguments[0], null) != null) and !jsc.JSObjectIsFunction(ctx, @ptrCast(arguments[0]))) {
        const k_opts = jsc.JSStringCreateWithUTF8CString("_serverOptions");
        defer jsc.JSStringRelease(k_opts);
        _ = jsc.JSObjectSetProperty(ctx, server, k_opts, arguments[0], jsc.kJSPropertyAttributeNone, null);
    }
    common.setMethod(ctx, server, "listen", listenCallback);
    common.setMethod(ctx, server, "close", serverCloseCallback);
    common.setMethod(ctx, server, "address", serverAddressCallback);
    return server;
}

/// server.listen(port[, host][, callback]) 或 listen(path[, callback])：TCP/Unix listen，非阻塞 accept
fn listenCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const k_listener = jsc.JSStringCreateWithUTF8CString("_connectionListener");
    defer jsc.JSStringRelease(k_listener);
    const listener_val = jsc.JSObjectGetProperty(ctx, this, k_listener, null);
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(listener_val))) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    var server: std.Io.net.Server = undefined;
    var port: u16 = 0;
    var host_len: usize = 0;
    var host_buf: [256]u8 = undefined;
    var path_len: usize = 0;
    var path_buf: [256]u8 = undefined;
    const is_unix = blk: {
        const first = arguments[0];
        const port_n = jsc.JSValueToNumber(ctx, first, null);
        if (port_n == port_n and port_n >= 1 and port_n <= 65535) break :blk false;
        const js_str = jsc.JSValueToStringCopy(ctx, first, null);
        defer jsc.JSStringRelease(js_str);
        const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(js_str);
        if (max_sz == 0 or max_sz > path_buf.len) break :blk false;
        path_len = jsc.JSStringGetUTF8CString(js_str, path_buf[0..].ptr, path_buf.len);
        if (path_len == 0) break :blk false;
        path_len -= 1;
        break :blk true;
    };
    const proc_io = libs_process.getProcessIo() orelse return jsc.JSValueMakeUndefined(ctx);
    if (is_unix) {
        const path_z = path_buf[0..path_len];
        const path_null = allocator.dupeZ(u8, path_z) catch return jsc.JSValueMakeUndefined(ctx);
        defer allocator.free(path_null);
        var ua = std.Io.net.UnixAddress.init(path_null) catch |e| {
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "net.listen unix failed: {s}", .{@errorName(e)}) catch "net.listen failed";
            errors.reportToStderr(.{ .code = .unknown, .message = msg }) catch {};
            return jsc.JSValueMakeUndefined(ctx);
        };
        server = std.Io.net.UnixAddress.listen(&ua, proc_io, .{ .kernel_backlog = std.Io.net.default_kernel_backlog }) catch |e| {
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "net.listen unix failed: {s}", .{@errorName(e)}) catch "net.listen failed";
            errors.reportToStderr(.{ .code = .unknown, .message = msg }) catch {};
            return jsc.JSValueMakeUndefined(ctx);
        };
    } else {
        port = @as(u16, @intFromFloat(jsc.JSValueToNumber(ctx, arguments[0], null)));
        var host_slice: []const u8 = "0.0.0.0";
        if (argumentCount >= 2 and !jsc.JSValueIsUndefined(ctx, arguments[1])) {
            const js_str = jsc.JSValueToStringCopy(ctx, arguments[1], null);
            defer jsc.JSStringRelease(js_str);
            const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(js_str);
            if (max_sz > 0 and max_sz <= host_buf.len) {
                const n = jsc.JSStringGetUTF8CString(js_str, host_buf[0..].ptr, host_buf.len);
                if (n > 0) {
                    host_len = n - 1;
                    host_slice = host_buf[0..host_len];
                }
            }
        }
        if (host_len == 0 and host_slice.len <= host_buf.len) {
            @memcpy(host_buf[0..host_slice.len], host_slice);
            host_len = host_slice.len;
        }
        var addr_z_buf: [256]u8 = undefined;
        const host_z = std.fmt.bufPrintZ(&addr_z_buf, "{s}", .{host_slice}) catch return jsc.JSValueMakeUndefined(ctx);
        const addr = std.Io.net.IpAddress.parse(host_z, port) catch |e| {
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "net.listen failed: {s}", .{@errorName(e)}) catch "net.listen failed";
            errors.reportToStderr(.{ .code = .unknown, .message = msg }) catch {};
            return jsc.JSValueMakeUndefined(ctx);
        };
        server = std.Io.net.IpAddress.listen(addr, proc_io, .{ .kernel_backlog = std.Io.net.default_kernel_backlog }) catch |e| {
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "net.listen failed: {s}", .{@errorName(e)}) catch "net.listen failed";
            errors.reportToStderr(.{ .code = .unknown, .message = msg }) catch {};
            return jsc.JSValueMakeUndefined(ctx);
        };
    }
    setNonBlocking(server.socket.handle);
    if (g_net_servers == null) {
        const list = std.ArrayList(NetServerEntry).initCapacity(allocator, 4) catch {
            server.deinit(proc_io);
            return jsc.JSValueMakeUndefined(ctx);
        };
        g_net_servers = list;
    }
    if (g_net_sockets == null) {
        g_net_sockets = std.AutoHashMap(u32, std.Io.net.Stream).init(allocator);
    }
    if (g_net_socket_objs == null) {
        g_net_socket_objs = std.AutoHashMap(u32, jsc.JSObjectRef).init(allocator);
    }
    const server_id = g_next_server_id;
    g_next_server_id +%= 1;
    const k_sid = jsc.JSStringCreateWithUTF8CString("_serverId");
    defer jsc.JSStringRelease(k_sid);
    _ = jsc.JSObjectSetProperty(ctx, this, k_sid, jsc.JSValueMakeNumber(ctx, @floatFromInt(server_id)), jsc.kJSPropertyAttributeNone, null);
    jsc.JSValueProtect(ctx, listener_val);
    var allow_half_open: bool = false;
    const k_opts = jsc.JSStringCreateWithUTF8CString("_serverOptions");
    defer jsc.JSStringRelease(k_opts);
    const opts_val = jsc.JSObjectGetProperty(ctx, this, k_opts, null);
    if (jsc.JSValueToObject(ctx, opts_val, null)) |opts_obj| {
        const k_aho = jsc.JSStringCreateWithUTF8CString("allowHalfOpen");
        defer jsc.JSStringRelease(k_aho);
        allow_half_open = jsc.JSValueToBoolean(ctx, jsc.JSObjectGetProperty(ctx, opts_obj, k_aho, null));
    }
    const entry: NetServerEntry = .{
        .server = server,
        .listener = listener_val,
        .ctx = ctx,
        .server_id = server_id,
        .port = port,
        .host_len = host_len,
        .host_buf = host_buf,
        .is_unix = is_unix,
        .path_len = path_len,
        .path_buf = path_buf,
        .allow_half_open = allow_half_open,
    };
    g_net_servers.?.append(allocator, entry) catch {
        jsc.JSValueUnprotect(ctx, listener_val);
        server.deinit(proc_io);
        return jsc.JSValueMakeUndefined(ctx);
    };
    const k_listening = jsc.JSStringCreateWithUTF8CString("listening");
    defer jsc.JSStringRelease(k_listening);
    _ = jsc.JSObjectSetProperty(ctx, this, k_listening, jsc.JSValueMakeBoolean(ctx, true), jsc.kJSPropertyAttributeNone, null);
    const k_net_tick = jsc.JSStringCreateWithUTF8CString("__shuNetTick");
    defer jsc.JSStringRelease(k_net_tick);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const tick_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_net_tick, netTickCallback);
    const k_set_immediate = jsc.JSStringCreateWithUTF8CString("setImmediate");
    defer jsc.JSStringRelease(k_set_immediate);
    const set_immediate_val = jsc.JSObjectGetProperty(ctx, global, k_set_immediate, null);
    if (jsc.JSObjectIsFunction(ctx, @ptrCast(set_immediate_val))) {
        var tick_args = [_]jsc.JSValueRef{tick_fn};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(set_immediate_val), null, 1, &tick_args, null);
    }
    var cb_arg_idx: usize = 2;
    if (is_unix) cb_arg_idx = 1;
    if (argumentCount > cb_arg_idx and jsc.JSObjectIsFunction(ctx, @ptrCast(arguments[cb_arg_idx]))) {
        var cb_args = [_]jsc.JSValueRef{jsc.JSValueMakeUndefined(ctx)};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(arguments[cb_arg_idx]), this, 1, &cb_args, null);
    }
    return this;
}

/// server.close([callback])：从 g_net_servers 移除并 deinit，调用 callback
fn serverCloseCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const k_sid = jsc.JSStringCreateWithUTF8CString("_serverId");
    defer jsc.JSStringRelease(k_sid);
    const sid_val = jsc.JSObjectGetProperty(ctx, this, k_sid, null);
    const sid_n = jsc.JSValueToNumber(ctx, sid_val, null);
    if (sid_n != sid_n) return jsc.JSValueMakeUndefined(ctx);
    const server_id = @as(u32, @intFromFloat(sid_n));
    if (g_net_servers == null) return jsc.JSValueMakeUndefined(ctx);
    const servers = &g_net_servers.?;
    var i: usize = 0;
    while (i < servers.items.len) : (i += 1) {
        if (servers.items[i].server_id == server_id) {
            var removed = servers.swapRemove(i);
            jsc.JSValueUnprotect(removed.ctx, removed.listener);
            const io = libs_process.getProcessIo() orelse return jsc.JSValueMakeUndefined(ctx);
            removed.server.deinit(io);
            _ = jsc.JSObjectSetProperty(ctx, this, k_sid, jsc.JSValueMakeUndefined(ctx), jsc.kJSPropertyAttributeNone, null);
            const k_listening = jsc.JSStringCreateWithUTF8CString("listening");
            defer jsc.JSStringRelease(k_listening);
            _ = jsc.JSObjectSetProperty(ctx, this, k_listening, jsc.JSValueMakeBoolean(ctx, false), jsc.kJSPropertyAttributeNone, null);
            if (argumentCount >= 1 and jsc.JSObjectIsFunction(ctx, @ptrCast(arguments[0]))) {
                var cb_args = [_]jsc.JSValueRef{jsc.JSValueMakeUndefined(ctx)};
                _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(arguments[0]), this, 1, &cb_args, null);
            }
            return jsc.JSValueMakeUndefined(ctx);
        }
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// server.address()：返回 { address, family, port }（TCP）或 { address: path }（Unix）
fn serverAddressCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const k_sid = jsc.JSStringCreateWithUTF8CString("_serverId");
    defer jsc.JSStringRelease(k_sid);
    const sid_val = jsc.JSObjectGetProperty(ctx, this, k_sid, null);
    const sid_n = jsc.JSValueToNumber(ctx, sid_val, null);
    if (sid_n != sid_n) return jsc.JSValueMakeUndefined(ctx);
    const server_id = @as(u32, @intFromFloat(sid_n));
    const servers = g_net_servers orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    for (servers.items) |*entry| {
        if (entry.server_id == server_id) {
            const obj = jsc.JSObjectMake(ctx, null, null);
            const k_addr = jsc.JSStringCreateWithUTF8CString("address");
            defer jsc.JSStringRelease(k_addr);
            const k_family = jsc.JSStringCreateWithUTF8CString("family");
            defer jsc.JSStringRelease(k_family);
            const k_port = jsc.JSStringCreateWithUTF8CString("port");
            defer jsc.JSStringRelease(k_port);
            if (entry.is_unix) {
                const path_z = allocator.dupeZ(u8, entry.path_buf[0..entry.path_len]) catch return jsc.JSValueMakeUndefined(ctx);
                defer allocator.free(path_z);
                const path_js = jsc.JSStringCreateWithUTF8CString(path_z.ptr);
                defer jsc.JSStringRelease(path_js);
                _ = jsc.JSObjectSetProperty(ctx, obj, k_addr, jsc.JSValueMakeString(ctx, path_js), jsc.kJSPropertyAttributeNone, null);
            } else {
                var host_z_buf: [256]u8 = undefined;
                const host_len = if (entry.host_len >= host_z_buf.len) host_z_buf.len - 1 else entry.host_len;
                @memcpy(host_z_buf[0..host_len], entry.host_buf[0..host_len]);
                host_z_buf[host_len] = 0;
                const host_js = jsc.JSStringCreateWithUTF8CString(host_z_buf[0..].ptr);
                defer jsc.JSStringRelease(host_js);
                const family_js = jsc.JSStringCreateWithUTF8CString("IPv4");
                defer jsc.JSStringRelease(family_js);
                _ = jsc.JSObjectSetProperty(ctx, obj, k_addr, jsc.JSValueMakeString(ctx, host_js), jsc.kJSPropertyAttributeNone, null);
                _ = jsc.JSObjectSetProperty(ctx, obj, k_family, jsc.JSValueMakeString(ctx, family_js), jsc.kJSPropertyAttributeNone, null);
                _ = jsc.JSObjectSetProperty(ctx, obj, k_port, jsc.JSValueMakeNumber(ctx, @floatFromInt(entry.port)), jsc.kJSPropertyAttributeNone, null);
            }
            return obj;
        }
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// 从 JS 对象读取可选字符串属性，用于 createConnection(options)；key 为 C 字符串，buf 为输出缓冲区
fn getOptStrFromObj(ctx: jsc.JSContextRef, obj: jsc.JSObjectRef, key: [*]const u8, buf: []u8) ?[]const u8 {
    const k = jsc.JSStringCreateWithUTF8CString(key);
    defer jsc.JSStringRelease(k);
    const v = jsc.JSObjectGetProperty(ctx, obj, k, null);
    if (jsc.JSValueIsUndefined(ctx, v)) return null;
    const js_str = jsc.JSValueToStringCopy(ctx, v, null);
    defer jsc.JSStringRelease(js_str);
    const n = jsc.JSStringGetUTF8CString(js_str, buf.ptr, buf.len);
    if (n == 0) return null;
    return buf[0 .. n - 1];
}

/// 从 g_net_pending_connects 取出所有已完成连接，成功则加入 g_net_sockets 并调 connectListener(socket)，失败则调 connectListener(err)
/// §4 持锁仅限「移入 taken」，回调与 JSC/stream 操作在锁外执行
fn drainPendingConnects(ctx: jsc.JSContextRef) void {
    const allocator = globals.current_allocator orelse return;
    const io = libs_process.getProcessIo() orelse return;
    var taken = std.ArrayList(PendingConnect).initCapacity(allocator, 0) catch return;
    defer taken.deinit(allocator);
    {
        g_net_pending_mutex.lock(io) catch return;
        defer g_net_pending_mutex.unlock(io);
        const pending_list = g_net_pending_connects orelse return;
        if (pending_list.items.len == 0) return;
        taken.ensureTotalCapacity(allocator, pending_list.items.len) catch return;
        const pending = &g_net_pending_connects.?;
        while (pending.items.len > 0) {
            const item = pending.swapRemove(pending.items.len - 1);
            taken.append(allocator, item) catch {
                if (item.err_msg) |m| allocator.free(m);
                jsc.JSValueUnprotect(ctx, item.callback);
                _ = g_net_pending_count.fetchSub(1, .monotonic);
            };
        }
    }
    for (taken.items) |item| {
        defer _ = g_net_pending_count.fetchSub(1, .monotonic);
        defer jsc.JSValueUnprotect(ctx, item.callback);
        if (item.stream) |stream| {
            if (g_net_sockets == null) {
                g_net_sockets = std.AutoHashMap(u32, std.Io.net.Stream).init(allocator);
            }
            if (g_net_socket_objs == null) {
                g_net_socket_objs = std.AutoHashMap(u32, jsc.JSObjectRef).init(allocator);
            }
            const sockets = &g_net_sockets.?;
            const objs = &g_net_socket_objs.?;
            const id = g_next_socket_id;
            g_next_socket_id +%= 1;
            setNonBlocking(stream.socket.handle);
            sockets.put(id, stream) catch {
                stream.close(io);
                continue;
            };
            if (g_net_socket_meta == null) g_net_socket_meta = std.AutoHashMap(u32, SocketMeta).init(allocator);
            const now_ms = @as(u64, @intCast(@divTrunc(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds, 1_000_000)));
            g_net_socket_meta.?.put(id, .{ .bytes_written = 0, .bytes_read = 0, .last_activity_ms = now_ms }) catch {};
            const remote_opt = getStreamRemoteAddress(stream);
            const local_opt = getStreamLocalAddress(stream);
            var socket_obj: jsc.JSObjectRef = undefined;
            if (remote_opt) |remote| {
                if (local_opt) |local| {
                    var info = getSocketAddrInfo(allocator, remote, local);
                    defer {
                        allocator.free(info.remote_address);
                        allocator.free(info.local_address);
                        allocator.free(info.family);
                    }
                    socket_obj = makeSocketObject(ctx, id, &info, false);
                } else {
                    socket_obj = makeSocketObject(ctx, id, null, false);
                }
            } else {
                socket_obj = makeSocketObject(ctx, id, null, false);
            }
            objs.put(id, socket_obj) catch {};
            if (item.timeout_ms) |ms| {
                const k_t = jsc.JSStringCreateWithUTF8CString("_timeout");
                defer jsc.JSStringRelease(k_t);
                _ = jsc.JSObjectSetProperty(ctx, socket_obj, k_t, jsc.JSValueMakeNumber(ctx, @floatFromInt(ms)), jsc.kJSPropertyAttributeNone, null);
            }
            if (item.user_callback) |ucb| {
                var two_args = [_]jsc.JSValueRef{ jsc.JSValueMakeUndefined(ctx), socket_obj };
                _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(ucb), null, 2, &two_args, null);
            } else {
                var one_arg = [_]jsc.JSValueRef{socket_obj};
                _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(item.callback), null, 1, &one_arg, null);
            }
        } else if (item.err_msg) |msg| {
            const err_obj = makeJsError(ctx, msg);
            if (item.user_callback) |ucb| {
                var two_args = [_]jsc.JSValueRef{ err_obj, jsc.JSValueMakeUndefined(ctx) };
                _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(ucb), null, 2, &two_args, null);
            } else {
                var one_arg = [_]jsc.JSValueRef{err_obj};
                _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(item.callback), null, 1, &one_arg, null);
            }
            allocator.free(msg);
        }
    }
}

/// 用 message 创建 JS Error 对象并返回
fn makeJsError(ctx: jsc.JSContextRef, message: []const u8) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const z = allocator.dupeZ(u8, message) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(z);
    const k_error = jsc.JSStringCreateWithUTF8CString("Error");
    defer jsc.JSStringRelease(k_error);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const ErrorCtor = jsc.JSObjectGetProperty(ctx, global, k_error, null);
    const js_msg = jsc.JSStringCreateWithUTF8CString(z.ptr);
    defer jsc.JSStringRelease(js_msg);
    const msg_val = jsc.JSValueMakeString(ctx, js_msg);
    var args = [_]jsc.JSValueRef{msg_val};
    const err_obj = jsc.JSObjectCallAsConstructor(ctx, @ptrCast(ErrorCtor), 1, &args, null);
    return err_obj;
}

/// setImmediate 每轮调用：drain 已完成连接、accept、读 socket、再 setImmediate（仅当 has_work 时）。0.16：accept(io)、stream.close(io)、stream.socket.handle
fn netTickCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    drainPendingConnects(ctx);
    const allocator = globals.current_allocator orelse {
        if (g_net_pending_count.load(.monotonic) > 0) scheduleNetTick(ctx);
        return jsc.JSValueMakeUndefined(ctx);
    };
    const io = libs_process.getProcessIo() orelse {
        if (g_net_pending_count.load(.monotonic) > 0) scheduleNetTick(ctx);
        return jsc.JSValueMakeUndefined(ctx);
    };
    if (g_net_servers == null) {
        if (g_net_pending_count.load(.monotonic) > 0) scheduleNetTick(ctx);
        return jsc.JSValueMakeUndefined(ctx);
    }
    const servers = &g_net_servers.?;
    // 有 server 时确保 g_net_sockets/g_net_socket_objs/g_net_socket_meta 已初始化，以便 accept 可放入 socket
    if (g_net_sockets == null) {
        g_net_sockets = std.AutoHashMap(u32, std.Io.net.Stream).init(allocator);
        g_net_socket_objs = std.AutoHashMap(u32, jsc.JSObjectRef).init(allocator);
        g_net_socket_meta = std.AutoHashMap(u32, SocketMeta).init(allocator);
    }
    const sockets = &g_net_sockets.?;
    const now_ms = @as(u64, @intCast(@divTrunc(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds, 1_000_000)));
    var i: usize = 0;
    while (i < servers.items.len) : (i += 1) {
        const entry = &servers.items[i];
        var accept_count: u32 = 0;
        while (accept_count < 32) {
            const accepted = entry.server.accept(io) catch |e| {
                if (e == error.WouldBlock) break;
                continue;
            };
            accept_count += 1;
            setNonBlocking(accepted.socket.handle);
            const id = g_next_socket_id;
            g_next_socket_id +%= 1;
            sockets.put(id, accepted) catch {
                accepted.close(io);
                continue;
            };
            if (g_net_socket_meta == null) g_net_socket_meta = std.AutoHashMap(u32, SocketMeta).init(allocator);
            g_net_socket_meta.?.put(id, .{ .bytes_written = 0, .bytes_read = 0, .last_activity_ms = now_ms }) catch {};
            var socket_obj: jsc.JSObjectRef = undefined;
            if (getStreamLocalAddress(accepted)) |local_addr| {
                const remote_addr = getStreamRemoteAddress(accepted) orelse {
                    accepted.close(io);
                    _ = sockets.remove(id);
                    continue;
                };
                var info = getSocketAddrInfo(allocator, remote_addr, local_addr);
                defer {
                    allocator.free(info.remote_address);
                    allocator.free(info.local_address);
                    allocator.free(info.family);
                }
                socket_obj = makeSocketObject(ctx, id, &info, entry.allow_half_open);
            } else {
                socket_obj = makeSocketObject(ctx, id, null, entry.allow_half_open);
            }
            if (g_net_socket_objs) |*objs| objs.put(id, socket_obj) catch {};
            var args = [_]jsc.JSValueRef{socket_obj};
            _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(entry.listener), null, 1, &args, null);
        }
    }
    netTickRead(ctx);
    // Node 兼容：仅 ref_count > 0 的 socket 参与 has_work（unref 后不阻止进程退出）
    var socket_ref_count: usize = 0;
    if (g_net_socket_meta) |*meta_map| {
        var it = meta_map.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.ref_count > 0) socket_ref_count += 1;
        }
    }
    const has_work = servers.items.len > 0 or socket_ref_count > 0 or g_net_pending_count.load(.monotonic) > 0;
    if (has_work) scheduleNetTick(ctx);
    return jsc.JSValueMakeUndefined(ctx);
}

/// 调度下一轮 netTick（setImmediate）
fn scheduleNetTick(ctx: jsc.JSContextRef) void {
    const k_net_tick = jsc.JSStringCreateWithUTF8CString("__shuNetTick");
    defer jsc.JSStringRelease(k_net_tick);
    const tick_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_net_tick, netTickCallback);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_set_immediate = jsc.JSStringCreateWithUTF8CString("setImmediate");
    defer jsc.JSStringRelease(k_set_immediate);
    const set_immediate_val = jsc.JSObjectGetProperty(ctx, global, k_set_immediate, null);
    if (jsc.JSObjectIsFunction(ctx, @ptrCast(set_immediate_val))) {
        var tick_args = [_]jsc.JSValueRef{tick_fn};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(set_immediate_val), null, 1, &tick_args, null);
    }
}

/// 对 g_net_sockets 中每个 stream 做非阻塞 read，有数据则触发对应 socket 的 on('data')，读关闭则触发 on('end')。0.16：stream.close(io)
fn netTickRead(ctx: jsc.JSContextRef) void {
    const io = libs_process.getProcessIo() orelse return;
    if (g_net_sockets == null or g_net_socket_objs == null) return;
    const sockets = &g_net_sockets.?;
    const objs = &g_net_socket_objs.?;
    var read_buf: [8192]u8 = undefined;
    const allocator = globals.current_allocator orelse return;
    var to_remove = std.ArrayList(u32).initCapacity(allocator, 0) catch return;
    defer to_remove.deinit(allocator);
    var it = sockets.iterator();
    while (it.next()) |kv| {
        const id = kv.key_ptr.*;
        const stream = kv.value_ptr.*;
        if (g_net_socket_meta) |*meta_map| {
            if (meta_map.getPtr(id)) |m| if (m.paused) continue;
        }
        const n: usize = blk: {
            if (build_options.have_tls and g_net_socket_tls != null) {
                if (g_net_socket_tls.?.get(id)) |tls_ptr| {
                    const r = tls_ptr.readNonblock(read_buf[0..]) catch |e| {
                        if (e == error.WantRead or e == error.WantWrite) continue;
                        if (objs.get(id)) |socket_obj| emitSocketEvent(ctx, socket_obj, "error", jsc.JSValueMakeUndefined(ctx));
                        to_remove.append(allocator, id) catch {};
                        tls_ptr.close(io);
                        if (g_net_socket_tls) |*tls_map| _ = tls_map.fetchRemove(id);
                        continue;
                    };
                    break :blk r;
                }
            }
            break :blk blk2: {
                var io_buf: [4096]u8 = undefined;
                var r = stream.reader(io, &io_buf);
                var dest: [1][]u8 = .{read_buf[0..]};
                break :blk2 std.Io.Reader.readVec(&r.interface, &dest) catch |e| {
                    if (e == error.WouldBlock) continue;
                    if (objs.get(id)) |socket_obj| emitSocketEvent(ctx, socket_obj, "error", jsc.JSValueMakeUndefined(ctx));
                    to_remove.append(allocator, id) catch {};
                    stream.close(io);
                    continue;
                };
            };
        };
        if (n == 0) {
            if (objs.get(id)) |socket_obj| {
                emitSocketEvent(ctx, socket_obj, "end", jsc.JSValueMakeUndefined(ctx));
                const k_aho = jsc.JSStringCreateWithUTF8CString("_allowHalfOpen");
                defer jsc.JSStringRelease(k_aho);
                const aho_val = jsc.JSObjectGetProperty(ctx, socket_obj, k_aho, null);
                if (jsc.JSValueToBoolean(ctx, aho_val)) {
                    continue;
                }
            }
            to_remove.append(allocator, id) catch {};
            if (g_net_socket_meta) |*meta| _ = meta.fetchRemove(id);
            var closed_tls = false;
            if (build_options.have_tls and g_net_socket_tls != null) {
                if (g_net_socket_tls.?.fetchRemove(id)) |tls_kv| {
                    tls_kv.value.close(io);
                    closed_tls = true;
                }
            }
            if (!closed_tls) stream.close(io);
            continue;
        }
        if (g_net_socket_meta) |*meta| {
            if (meta.getPtr(id)) |m| {
                m.bytes_read += n;
                m.last_activity_ms = @intCast(@divTrunc(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds, 1_000_000));
            }
        }
        if (objs.get(id)) |socket_obj| {
            if (g_net_socket_meta) |*meta| {
                if (meta.get(id)) |m| {
                    const k_br = jsc.JSStringCreateWithUTF8CString("bytesRead");
                    defer jsc.JSStringRelease(k_br);
                    _ = jsc.JSObjectSetProperty(ctx, socket_obj, k_br, jsc.JSValueMakeNumber(ctx, @floatFromInt(m.bytes_read)), jsc.kJSPropertyAttributeNone, null);
                }
            }
            const data_val = makeDataForSocket(ctx, socket_obj, read_buf[0..n]);
            emitSocketEvent(ctx, socket_obj, "data", data_val);
        }
    }
    for (to_remove.items) |id| {
        var had_tls = false;
        if (build_options.have_tls and g_net_socket_tls != null) {
            if (g_net_socket_tls.?.fetchRemove(id)) |tls_kv| {
                tls_kv.value.close(io);
                had_tls = true;
            }
        }
        _ = objs.fetchRemove(id);
        if (g_net_socket_meta) |*meta| _ = meta.fetchRemove(id);
        if (sockets.fetchRemove(id)) |kv| {
            if (!had_tls) kv.value.close(io);
        }
    }
    netTickTimeoutCheck(ctx);
}

/// 检查各 socket 的 _timeout，超时未收到数据则触发 'timeout' 事件并刷新 last_activity_ms
fn netTickTimeoutCheck(ctx: jsc.JSContextRef) void {
    if (g_net_socket_objs == null or g_net_socket_meta == null) return;
    const io = libs_process.getProcessIo() orelse return;
    const objs = &g_net_socket_objs.?;
    const meta = &g_net_socket_meta.?;
    const now_ms: u64 = @intCast(@divTrunc(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds, 1_000_000));
    const k_timeout = jsc.JSStringCreateWithUTF8CString("_timeout");
    defer jsc.JSStringRelease(k_timeout);
    var it = objs.iterator();
    while (it.next()) |kv| {
        const id = kv.key_ptr.*;
        const socket_obj = kv.value_ptr.*;
        const timeout_val = jsc.JSObjectGetProperty(ctx, socket_obj, k_timeout, null);
        if (jsc.JSValueIsUndefined(ctx, timeout_val)) continue;
        const timeout_ms = jsc.JSValueToNumber(ctx, timeout_val, null);
        if (timeout_ms != timeout_ms or timeout_ms <= 0) continue;
        const m = meta.getPtr(id) orelse continue;
        const elapsed = if (now_ms >= m.last_activity_ms) now_ms - m.last_activity_ms else 0;
        if (elapsed >= @as(u64, @intFromFloat(timeout_ms))) {
            m.last_activity_ms = now_ms;
            emitSocketEvent(ctx, socket_obj, "timeout", jsc.JSValueMakeUndefined(ctx));
        }
    }
}

/// 根据 socket 的 _encoding 将数据转为 JS 字符串（encoding='utf8'）或 Buffer/字符串（默认）；Node 兼容 setEncoding('utf8'）
fn makeDataForSocket(ctx: jsc.JSContextRef, socket_obj: jsc.JSObjectRef, slice: []const u8) jsc.JSValueRef {
    const k_enc = jsc.JSStringCreateWithUTF8CString("_encoding");
    defer jsc.JSStringRelease(k_enc);
    const enc_val = jsc.JSObjectGetProperty(ctx, socket_obj, k_enc, null);
    if (jsc.JSValueIsUndefined(ctx, enc_val)) return makeBufferOrString(ctx, slice);
    const enc_str = jsc.JSValueToStringCopy(ctx, enc_val, null);
    defer jsc.JSStringRelease(enc_str);
    var buf: [16]u8 = undefined;
    const n = jsc.JSStringGetUTF8CString(enc_str, buf[0..].ptr, buf.len);
    if (n > 0 and std.mem.eql(u8, buf[0 .. n - 1], "utf8")) return makeBufferOrString(ctx, slice);
    return makeBufferOrString(ctx, slice);
}

fn makeBufferOrString(ctx: jsc.JSContextRef, slice: []const u8) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const z = allocator.dupeZ(u8, slice) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(z);
    const js_str = jsc.JSStringCreateWithUTF8CString(z.ptr);
    defer jsc.JSStringRelease(js_str);
    return jsc.JSValueMakeString(ctx, js_str);
}

/// socket 事件名集合固定；按长度分派后比较，comptime 友好（§2.1），返回对应 _on* 属性名（null 结尾）
fn socketEventToPropNameZ(event: []const u8) ?[*:0]const u8 {
    return switch (event.len) {
        3 => if (std.mem.eql(u8, event, "end")) "_onEnd" else null,
        4 => if (std.mem.eql(u8, event, "data")) "_onData" else null,
        5 => if (std.mem.eql(u8, event, "error")) "_onError" else null,
        7 => if (std.mem.eql(u8, event, "timeout")) "_onTimeout" else null,
        else => null,
    };
}

/// 触发 socket 上 on('data'/'end'/'error'/'timeout') 注册的回调；event 为 "data" | "end" | "error" | "timeout"
fn emitSocketEvent(ctx: jsc.JSContextRef, socket_obj: jsc.JSObjectRef, event: []const u8, arg: jsc.JSValueRef) void {
    const prop_z = socketEventToPropNameZ(event) orelse return;
    const k = jsc.JSStringCreateWithUTF8CString(prop_z);
    defer jsc.JSStringRelease(k);
    const fn_val = jsc.JSObjectGetProperty(ctx, socket_obj, k, null);
    if (jsc.JSObjectIsFunction(ctx, @ptrCast(fn_val))) {
        var args = [_]jsc.JSValueRef{arg};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(fn_val), socket_obj, 1, &args, null);
    }
}

/// 创建带 write/end/destroy/on 及 setEncoding/setTimeout/setNoDelay/ref/unref 的 socket 对象；内部用 _socketId 查 g_net_sockets。
/// allow_half_open：为 true 时对端关闭后只触发 'end' 不关闭写端（Node allowHalfOpen）；addr_info 非 null 时设置地址属性
fn makeSocketObject(ctx: jsc.JSContextRef, id: u32, addr_info: ?*const SocketAddrInfo, allow_half_open: bool) jsc.JSObjectRef {
    const socket = jsc.JSObjectMake(ctx, null, null);
    const k_id = jsc.JSStringCreateWithUTF8CString("_socketId");
    defer jsc.JSStringRelease(k_id);
    _ = jsc.JSObjectSetProperty(ctx, socket, k_id, jsc.JSValueMakeNumber(ctx, @floatFromInt(id)), jsc.kJSPropertyAttributeNone, null);
    const k_bw = jsc.JSStringCreateWithUTF8CString("bytesWritten");
    defer jsc.JSStringRelease(k_bw);
    const k_br = jsc.JSStringCreateWithUTF8CString("bytesRead");
    defer jsc.JSStringRelease(k_br);
    _ = jsc.JSObjectSetProperty(ctx, socket, k_bw, jsc.JSValueMakeNumber(ctx, 0), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, socket, k_br, jsc.JSValueMakeNumber(ctx, 0), jsc.kJSPropertyAttributeNone, null);
    common.setMethod(ctx, socket, "write", socketWriteCallback);
    common.setMethod(ctx, socket, "end", socketEndCallback);
    common.setMethod(ctx, socket, "destroy", socketDestroyCallback);
    common.setMethod(ctx, socket, "on", socketOnCallback);
    common.setMethod(ctx, socket, "setEncoding", socketSetEncodingCallback);
    common.setMethod(ctx, socket, "setTimeout", socketSetTimeoutCallback);
    common.setMethod(ctx, socket, "setNoDelay", socketSetNoDelayCallback);
    common.setMethod(ctx, socket, "ref", socketRefCallback);
    common.setMethod(ctx, socket, "unref", socketUnrefCallback);
    common.setMethod(ctx, socket, "address", socketAddressCallback);
    common.setMethod(ctx, socket, "pause", socketPauseCallback);
    common.setMethod(ctx, socket, "resume", socketResumeCallback);
    const k_connecting = jsc.JSStringCreateWithUTF8CString("connecting");
    defer jsc.JSStringRelease(k_connecting);
    const k_destroyed = jsc.JSStringCreateWithUTF8CString("destroyed");
    defer jsc.JSStringRelease(k_destroyed);
    _ = jsc.JSObjectSetProperty(ctx, socket, k_connecting, jsc.JSValueMakeBoolean(ctx, false), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, socket, k_destroyed, jsc.JSValueMakeBoolean(ctx, false), jsc.kJSPropertyAttributeNone, null);
    if (addr_info) |info| {
        const k_remote = jsc.JSStringCreateWithUTF8CString("remoteAddress");
        defer jsc.JSStringRelease(k_remote);
        const k_local = jsc.JSStringCreateWithUTF8CString("localAddress");
        defer jsc.JSStringRelease(k_local);
        const k_family = jsc.JSStringCreateWithUTF8CString("family");
        defer jsc.JSStringRelease(k_family);
        const k_remote_port = jsc.JSStringCreateWithUTF8CString("remotePort");
        defer jsc.JSStringRelease(k_remote_port);
        const k_local_port = jsc.JSStringCreateWithUTF8CString("localPort");
        defer jsc.JSStringRelease(k_local_port);
        const js_remote = jsc.JSStringCreateWithUTF8CString(info.remote_address.ptr);
        defer jsc.JSStringRelease(js_remote);
        const js_local = jsc.JSStringCreateWithUTF8CString(info.local_address.ptr);
        defer jsc.JSStringRelease(js_local);
        const js_family = jsc.JSStringCreateWithUTF8CString(@ptrCast(info.family.ptr));
        defer jsc.JSStringRelease(js_family);
        _ = jsc.JSObjectSetProperty(ctx, socket, k_remote, jsc.JSValueMakeString(ctx, js_remote), jsc.kJSPropertyAttributeNone, null);
        _ = jsc.JSObjectSetProperty(ctx, socket, k_local, jsc.JSValueMakeString(ctx, js_local), jsc.kJSPropertyAttributeNone, null);
        _ = jsc.JSObjectSetProperty(ctx, socket, k_family, jsc.JSValueMakeString(ctx, js_family), jsc.kJSPropertyAttributeNone, null);
        _ = jsc.JSObjectSetProperty(ctx, socket, k_remote_port, jsc.JSValueMakeNumber(ctx, @floatFromInt(info.remote_port)), jsc.kJSPropertyAttributeNone, null);
        _ = jsc.JSObjectSetProperty(ctx, socket, k_local_port, jsc.JSValueMakeNumber(ctx, @floatFromInt(info.local_port)), jsc.kJSPropertyAttributeNone, null);
    }
    const k_aho = jsc.JSStringCreateWithUTF8CString("_allowHalfOpen");
    defer jsc.JSStringRelease(k_aho);
    _ = jsc.JSObjectSetProperty(ctx, socket, k_aho, jsc.JSValueMakeBoolean(ctx, allow_half_open), jsc.kJSPropertyAttributeNone, null);
    return socket;
}

fn getSocketIdFromThis(ctx: jsc.JSContextRef, this: jsc.JSObjectRef) ?u32 {
    const k_id = jsc.JSStringCreateWithUTF8CString("_socketId");
    defer jsc.JSStringRelease(k_id);
    const v = jsc.JSObjectGetProperty(ctx, this, k_id, null);
    const n = jsc.JSValueToNumber(ctx, v, null);
    if (n != n or n < 0) return null;
    return @as(u32, @intFromFloat(n));
}

/// socket.on(eventName, callback)：支持 'data'/'end'/'error'，将 callback 存到 _onData/_onEnd/_onError
fn socketOnCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const event_val = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(event_val);
    var buf: [32]u8 = undefined;
    const n = jsc.JSStringGetUTF8CString(event_val, buf[0..].ptr, buf.len);
    if (n == 0) return @ptrCast(this);
    const event_slice = buf[0 .. n - 1];
    const prop_z = socketEventToPropNameZ(event_slice) orelse return @ptrCast(this);
    const k = jsc.JSStringCreateWithUTF8CString(prop_z);
    defer jsc.JSStringRelease(k);
    _ = jsc.JSObjectSetProperty(ctx, this, k, arguments[1], jsc.kJSPropertyAttributeNone, null);
    return @ptrCast(this);
}

/// socket.write(data)：从 g_net_sockets 取 stream（或 TLS）并同步写入
fn socketWriteCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const id = getSocketIdFromThis(ctx, this) orelse return jsc.JSValueMakeUndefined(ctx);
    const sockets = g_net_sockets orelse return jsc.JSValueMakeUndefined(ctx);
    const stream_ptr = sockets.getPtr(id) orelse return jsc.JSValueMakeUndefined(ctx);
    const js_str = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(js_str);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(js_str);
    if (max_sz == 0 or max_sz > 1024 * 1024) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const buf = allocator.alloc(u8, max_sz) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(buf);
    const n = jsc.JSStringGetUTF8CString(js_str, buf.ptr, max_sz);
    if (n == 0) return jsc.JSValueMakeUndefined(ctx);
    const written = buf[0 .. n - 1].len;
    const io = libs_process.getProcessIo() orelse return jsc.JSValueMakeUndefined(ctx);
    if (build_options.have_tls and g_net_socket_tls != null) {
        if (g_net_socket_tls.?.get(id)) |tls_ptr| {
            tls_ptr.writeAll(buf[0 .. n - 1]) catch return jsc.JSValueMakeUndefined(ctx);
        } else {
            var wbuf: [4096]u8 = undefined;
            var w = stream_ptr.writer(io, &wbuf);
            _ = std.Io.Writer.writeVec(&w.interface, &.{buf[0 .. n - 1]}) catch return jsc.JSValueMakeUndefined(ctx);
        }
    } else {
        var wbuf: [4096]u8 = undefined;
        var w = stream_ptr.writer(io, &wbuf);
        _ = std.Io.Writer.writeVec(&w.interface, &.{buf[0 .. n - 1]}) catch return jsc.JSValueMakeUndefined(ctx);
    }
    if (g_net_socket_meta) |*meta| {
        if (meta.getPtr(id)) |m| {
            m.bytes_written += written;
            const k_bw = jsc.JSStringCreateWithUTF8CString("bytesWritten");
            defer jsc.JSStringRelease(k_bw);
            _ = jsc.JSObjectSetProperty(ctx, this, k_bw, jsc.JSValueMakeNumber(ctx, @floatFromInt(m.bytes_written)), jsc.kJSPropertyAttributeNone, null);
        }
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// socket.end([data])：若有 data 则先 write，再 shutdown 写端并关闭 stream、从 map 移除
fn socketEndCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount >= 1 and !jsc.JSValueIsUndefined(ctx, arguments[0])) {
        var args = [_]jsc.JSValueRef{arguments[0]};
        var exc: ?jsc.JSValueRef = null;
        _ = socketWriteCallback(ctx, this, this, 1, &args, @ptrCast(&exc));
    }
    const id = getSocketIdFromThis(ctx, this) orelse return jsc.JSValueMakeUndefined(ctx);
    const k_destroyed = jsc.JSStringCreateWithUTF8CString("destroyed");
    defer jsc.JSStringRelease(k_destroyed);
    _ = jsc.JSObjectSetProperty(ctx, this, k_destroyed, jsc.JSValueMakeBoolean(ctx, true), jsc.kJSPropertyAttributeNone, null);
    const io = libs_process.getProcessIo() orelse return jsc.JSValueMakeUndefined(ctx);
    var had_tls = false;
    if (build_options.have_tls and g_net_socket_tls != null) {
        if (g_net_socket_tls.?.fetchRemove(id)) |tls_kv| {
            tls_kv.value.close(io);
            had_tls = true;
        }
    }
    if (g_net_sockets) |*sockets| {
        if (sockets.fetchRemove(id)) |kv| {
            if (!had_tls) {
                kv.value.shutdown(io, .send) catch {};
                kv.value.close(io);
            }
        }
    }
    if (g_net_socket_objs) |*objs| _ = objs.fetchRemove(id);
    if (g_net_socket_meta) |*meta| _ = meta.fetchRemove(id);
    return jsc.JSValueMakeUndefined(ctx);
}

/// socket.destroy()：关闭 stream 并从 map 移除（含 g_net_socket_objs）；Node 兼容设置 destroyed = true
fn socketDestroyCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const id = getSocketIdFromThis(ctx, this) orelse return jsc.JSValueMakeUndefined(ctx);
    const k_destroyed = jsc.JSStringCreateWithUTF8CString("destroyed");
    defer jsc.JSStringRelease(k_destroyed);
    _ = jsc.JSObjectSetProperty(ctx, this, k_destroyed, jsc.JSValueMakeBoolean(ctx, true), jsc.kJSPropertyAttributeNone, null);
    const io = libs_process.getProcessIo() orelse return jsc.JSValueMakeUndefined(ctx);
    var had_tls = false;
    if (build_options.have_tls and g_net_socket_tls != null) {
        if (g_net_socket_tls.?.fetchRemove(id)) |tls_kv| {
            tls_kv.value.close(io);
            had_tls = true;
        }
    }
    if (g_net_sockets) |*sockets| {
        if (sockets.fetchRemove(id)) |kv| {
            if (!had_tls) kv.value.close(io);
        }
    }
    if (g_net_socket_objs) |*objs| _ = objs.fetchRemove(id);
    if (g_net_socket_meta) |*meta| _ = meta.fetchRemove(id);
    return jsc.JSValueMakeUndefined(ctx);
}

/// socket.setEncoding(encoding)：Node 兼容；支持 'utf8'，存到 _encoding
fn socketSetEncodingCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const k_enc = jsc.JSStringCreateWithUTF8CString("_encoding");
    defer jsc.JSStringRelease(k_enc);
    if (argumentCount >= 1 and !jsc.JSValueIsUndefined(ctx, arguments[0])) {
        _ = jsc.JSObjectSetProperty(ctx, this, k_enc, arguments[0], jsc.kJSPropertyAttributeNone, null);
    } else {
        _ = jsc.JSObjectSetProperty(ctx, this, k_enc, jsc.JSValueMakeUndefined(ctx), jsc.kJSPropertyAttributeNone, null);
    }
    return @ptrCast(this);
}

/// socket.setTimeout(ms[, callback])：Node 兼容；存 _timeout（ms），可选 callback 一次调用
fn socketSetTimeoutCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const k_t = jsc.JSStringCreateWithUTF8CString("_timeout");
    defer jsc.JSStringRelease(k_t);
    if (argumentCount >= 1) {
        const ms = jsc.JSValueToNumber(ctx, arguments[0], null);
        _ = jsc.JSObjectSetProperty(ctx, this, k_t, jsc.JSValueMakeNumber(ctx, ms), jsc.kJSPropertyAttributeNone, null);
        if (argumentCount >= 2 and jsc.JSObjectIsFunction(ctx, @ptrCast(arguments[1]))) {
            var args = [_]jsc.JSValueRef{this};
            _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(arguments[1]), this, 1, &args, null);
        }
    }
    return @ptrCast(this);
}

/// socket.setNoDelay(noDelay)：设置 TCP_NODELAY，Node 兼容
fn socketSetNoDelayCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const id = getSocketIdFromThis(ctx, this) orelse return @ptrCast(this);
    const sockets = g_net_sockets orelse return @ptrCast(this);
    const stream_ptr = sockets.getPtr(id) orelse return @ptrCast(this);
    const enable: c_int = if (argumentCount < 1 or jsc.JSValueToBoolean(ctx, arguments[0])) 1 else 0;
    if (!is_windows) {
        std.posix.setsockopt(stream_ptr.socket.handle, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, std.mem.asBytes(&enable)) catch {};
    }
    return @ptrCast(this);
}

/// socket.ref()：Node 兼容；增加 ref_count，使该 socket 参与 has_work（阻止进程退出）
fn socketRefCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const id = getSocketIdFromThis(ctx, this) orelse return @ptrCast(this);
    if (g_net_socket_meta) |*meta_map| {
        if (meta_map.getPtr(id)) |m| m.ref_count += 1;
    }
    return @ptrCast(this);
}

/// socket.address()：Node 兼容；返回本端地址 { address, port, family }
fn socketAddressCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const id = getSocketIdFromThis(ctx, this) orelse return jsc.JSValueMakeUndefined(ctx);
    const sockets = g_net_sockets orelse return jsc.JSValueMakeUndefined(ctx);
    const stream = sockets.get(id) orelse return jsc.JSValueMakeUndefined(ctx);
    const local = getStreamLocalAddress(stream) orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const addr_str = addressToNodeStringZ(allocator, local);
    defer allocator.free(addr_str);
    const family_str = switch (local.any.family) {
        std.posix.AF.INET => "IPv4",
        std.posix.AF.INET6 => "IPv6",
        std.posix.AF.UNIX => "Unix",
        else => "unknown",
    };
    const family_z = allocator.dupeZ(u8, family_str) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(family_z);
    const obj = jsc.JSObjectMake(ctx, null, null);
    const k_addr = jsc.JSStringCreateWithUTF8CString("address");
    defer jsc.JSStringRelease(k_addr);
    const k_port = jsc.JSStringCreateWithUTF8CString("port");
    defer jsc.JSStringRelease(k_port);
    const k_family = jsc.JSStringCreateWithUTF8CString("family");
    defer jsc.JSStringRelease(k_family);
    const js_addr = jsc.JSStringCreateWithUTF8CString(addr_str.ptr);
    defer jsc.JSStringRelease(js_addr);
    const js_fam = jsc.JSStringCreateWithUTF8CString(family_z.ptr);
    defer jsc.JSStringRelease(js_fam);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_addr, jsc.JSValueMakeString(ctx, js_addr), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_port, jsc.JSValueMakeNumber(ctx, @floatFromInt(local.getPort())), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_family, jsc.JSValueMakeString(ctx, js_fam), jsc.kJSPropertyAttributeNone, null);
    return obj;
}

/// socket.pause()：Node 兼容；暂停触发 'data' 事件
fn socketPauseCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const id = getSocketIdFromThis(ctx, this) orelse return @ptrCast(this);
    if (g_net_socket_meta) |*meta_map| {
        if (meta_map.getPtr(id)) |m| m.paused = true;
    }
    return @ptrCast(this);
}

/// socket.resume()：Node 兼容；恢复触发 'data' 事件
fn socketResumeCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const id = getSocketIdFromThis(ctx, this) orelse return @ptrCast(this);
    if (g_net_socket_meta) |*meta_map| {
        if (meta_map.getPtr(id)) |m| m.paused = false;
    }
    return @ptrCast(this);
}

/// socket.unref()：Node 兼容；减少 ref_count，为 0 时该 socket 不参与 has_work
fn socketUnrefCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const id = getSocketIdFromThis(ctx, this) orelse return @ptrCast(this);
    if (g_net_socket_meta) |*meta_map| {
        if (meta_map.getPtr(id)) |m| {
            m.ref_count -= 1;
            if (m.ref_count < 0) m.ref_count = 0;
        }
    }
    return @ptrCast(this);
}

/// 工作线程参数：连接完成后 push 到 g_net_pending_connects，由主线程 drain 并回调
const ConnectArgs = struct {
    allocator: std.mem.Allocator,
    port: u16,
    host: []const u8,
    path: []const u8,
    is_unix: bool,
    ctx: jsc.JSContextRef,
    callback: jsc.JSValueRef,
    user_callback: ?jsc.JSValueRef = null,
    timeout_ms: ?u32 = null,
    /// Node 兼容：createConnection(options) 的 localAddress/localPort，连接前先 bind 到本地地址
    local_address: ?[]const u8 = null,
    local_port: ?u16 = null,
};

fn connectThreadMain(args: *ConnectArgs) void {
    const io = libs_process.getProcessIo() orelse return;
    defer {
        if (args.is_unix) args.allocator.free(args.path) else args.allocator.free(args.host);
        if (args.local_address) |la| args.allocator.free(la);
        args.allocator.destroy(args);
    }
    var result: PendingConnect = .{
        .stream = null,
        .err_msg = null,
        .ctx = args.ctx,
        .callback = args.callback,
        .allocator = args.allocator,
        .user_callback = args.user_callback,
        .timeout_ms = args.timeout_ms,
    };
    if (args.is_unix) {
        var ua = std.Io.net.UnixAddress.init(args.path) catch |e| {
            result.err_msg = std.fmt.allocPrint(args.allocator, "connect {s}: {s}", .{ args.path, @errorName(e) }) catch null;
            g_net_pending_mutex.lock(io) catch return;
            defer g_net_pending_mutex.unlock(io);
            if (g_net_pending_connects) |*list| list.append(args.allocator, result) catch {};
            return;
        };
        const stream = std.Io.net.UnixAddress.connect(&ua, io) catch |e| {
            result.err_msg = std.fmt.allocPrint(args.allocator, "connect {s}: {s}", .{ args.path, @errorName(e) }) catch null;
            g_net_pending_mutex.lock(io) catch return;
            defer g_net_pending_mutex.unlock(io);
            if (g_net_pending_connects) |*list| list.append(args.allocator, result) catch {};
            return;
        };
        result.stream = stream;
    } else {
        // 0.16：IpAddress.resolve + connect；localAddress/localPort 暂不实现
        const addr = std.Io.net.IpAddress.resolve(io, args.host, args.port) catch |e| {
            result.err_msg = std.fmt.allocPrint(args.allocator, "connect {s}:{d}: {s}", .{ args.host, args.port, @errorName(e) }) catch null;
            g_net_pending_mutex.lock(io) catch return;
            defer g_net_pending_mutex.unlock(io);
            if (g_net_pending_connects) |*list| list.append(args.allocator, result) catch {};
            return;
        };
        result.stream = std.Io.net.IpAddress.connect(addr, io, .{ .mode = .stream }) catch |e| {
            result.err_msg = std.fmt.allocPrint(args.allocator, "connect {s}:{d}: {s}", .{ args.host, args.port, @errorName(e) }) catch null;
            g_net_pending_mutex.lock(io) catch return;
            defer g_net_pending_mutex.unlock(io);
            if (g_net_pending_connects) |*list| list.append(args.allocator, result) catch {};
            return;
        };
    }
    g_net_pending_mutex.lock(io) catch return;
    defer g_net_pending_mutex.unlock(io);
    if (g_net_pending_connects) |*list| list.append(args.allocator, result) catch {
        if (result.stream) |s| s.close(io);
    };
}

/// createConnection(port[, host][, connectListener])、createConnection(path[, connectListener]) 或 createConnection(options[, connectListener])；options 支持 port/host/path/timeout/localAddress/localPort（timeout/local 暂仅解析）
fn createConnectionCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const first = arguments[0];
    const opts_obj = jsc.JSValueToObject(ctx, first, null);
    const use_options = opts_obj != null and !jsc.JSObjectIsFunction(ctx, @ptrCast(first));
    var connect_listener: jsc.JSValueRef = undefined;
    var port: u16 = 0;
    var host: []const u8 = "localhost";
    var path: []const u8 = "";
    var is_unix: bool = false;
    var options_timeout_ms: ?u32 = null;
    var options_local_address: ?[]const u8 = null;
    var options_local_port: ?u16 = null;
    if (use_options and opts_obj != null) {
        var port_buf: [32]u8 = undefined;
        var host_buf: [256]u8 = undefined;
        var path_buf: [512]u8 = undefined;
        var local_address_buf: [256]u8 = undefined;
        const port_slice = getOptStrFromObj(ctx, opts_obj.?, "port", &port_buf);
        const path_slice = getOptStrFromObj(ctx, opts_obj.?, "path", &path_buf);
        const k_timeout = jsc.JSStringCreateWithUTF8CString("timeout");
        defer jsc.JSStringRelease(k_timeout);
        const timeout_val = jsc.JSObjectGetProperty(ctx, opts_obj.?, k_timeout, null);
        if (!jsc.JSValueIsUndefined(ctx, timeout_val)) {
            const t = jsc.JSValueToNumber(ctx, timeout_val, null);
            if (t == t and t > 0 and t <= 0x7fffffff) options_timeout_ms = @intFromFloat(t);
        }
        const local_addr_slice = getOptStrFromObj(ctx, opts_obj.?, "localAddress", &local_address_buf);
        if (local_addr_slice) |la| options_local_address = allocator.dupe(u8, la) catch null;
        const k_local_port = jsc.JSStringCreateWithUTF8CString("localPort");
        defer jsc.JSStringRelease(k_local_port);
        const local_port_val = jsc.JSObjectGetProperty(ctx, opts_obj.?, k_local_port, null);
        if (!jsc.JSValueIsUndefined(ctx, local_port_val)) {
            const lp = jsc.JSValueToNumber(ctx, local_port_val, null);
            if (lp == lp and lp >= 0 and lp <= 65535) options_local_port = @as(u16, @intFromFloat(lp));
        }
        if (path_slice) |p| {
            is_unix = true;
            path = allocator.dupe(u8, p) catch return jsc.JSValueMakeUndefined(ctx);
            host = "";
        } else if (port_slice) |ps| {
            const port_n = std.fmt.parseUnsigned(u16, ps, 10) catch 0;
            if (port_n >= 1 and port_n <= 65535) {
                port = port_n;
                const host_slice = getOptStrFromObj(ctx, opts_obj.?, "host", &host_buf);
                host = if (host_slice) |h| allocator.dupe(u8, h) catch "localhost" else allocator.dupe(u8, "localhost") catch return jsc.JSValueMakeUndefined(ctx);
            }
        }
        connect_listener = if (argumentCount > 1) arguments[1] else jsc.JSValueMakeUndefined(ctx);
        if (!is_unix and port == 0) {
            allocator.free(host);
            if (options_local_address) |la| allocator.free(la);
            return jsc.JSValueMakeUndefined(ctx);
        }
    } else {
        const port_n = jsc.JSValueToNumber(ctx, first, null);
        is_unix = blk: {
            if (port_n == port_n and port_n >= 1 and port_n <= 65535) break :blk false;
            const js_str = jsc.JSValueToStringCopy(ctx, first, null);
            defer jsc.JSStringRelease(js_str);
            const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(js_str);
            if (max_sz == 0 or max_sz > 512) break :blk false;
            break :blk true;
        };
        if (is_unix) {
            const js_str = jsc.JSValueToStringCopy(ctx, first, null);
            defer jsc.JSStringRelease(js_str);
            var path_buf: [512]u8 = undefined;
            const n = jsc.JSStringGetUTF8CString(js_str, path_buf[0..].ptr, path_buf.len);
            if (n == 0) return jsc.JSValueMakeUndefined(ctx);
            path = allocator.dupe(u8, path_buf[0 .. n - 1]) catch return jsc.JSValueMakeUndefined(ctx);
            host = "";
            connect_listener = if (argumentCount > 1) arguments[1] else jsc.JSValueMakeUndefined(ctx);
        } else {
            port = @intFromFloat(port_n);
            if (argumentCount > 1 and !jsc.JSObjectIsFunction(ctx, @ptrCast(arguments[1]))) {
                const js_str = jsc.JSValueToStringCopy(ctx, arguments[1], null);
                defer jsc.JSStringRelease(js_str);
                var host_buf: [256]u8 = undefined;
                const n = jsc.JSStringGetUTF8CString(js_str, host_buf[0..].ptr, host_buf.len);
                if (n > 0) host = allocator.dupe(u8, host_buf[0 .. n - 1]) catch "localhost";
            } else {
                host = allocator.dupe(u8, "localhost") catch return jsc.JSValueMakeUndefined(ctx);
            }
            connect_listener = if (argumentCount > 2) arguments[2] else if (argumentCount > 1 and jsc.JSObjectIsFunction(ctx, @ptrCast(arguments[1]))) arguments[1] else jsc.JSValueMakeUndefined(ctx);
        }
    }
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(connect_listener))) {
        if (!is_unix) allocator.free(host);
        if (is_unix) allocator.free(path);
        return jsc.JSValueMakeUndefined(ctx);
    }
    jsc.JSValueProtect(ctx, connect_listener);
    _ = g_net_pending_count.fetchAdd(1, .monotonic);
    if (g_net_pending_connects == null) {
        g_net_pending_connects = std.ArrayList(PendingConnect).initCapacity(allocator, 4) catch {
            jsc.JSValueUnprotect(ctx, connect_listener);
            _ = g_net_pending_count.fetchSub(1, .monotonic);
            if (!is_unix) allocator.free(host);
            if (is_unix) allocator.free(path);
            return jsc.JSValueMakeUndefined(ctx);
        };
    }
    const args = allocator.create(ConnectArgs) catch {
        jsc.JSValueUnprotect(ctx, connect_listener);
        _ = g_net_pending_count.fetchSub(1, .monotonic);
        if (!is_unix) allocator.free(host);
        if (is_unix) allocator.free(path);
        return jsc.JSValueMakeUndefined(ctx);
    };
    args.* = .{
        .allocator = allocator,
        .port = port,
        .host = host,
        .path = path,
        .is_unix = is_unix,
        .ctx = ctx,
        .callback = connect_listener,
        .timeout_ms = options_timeout_ms,
        .local_address = options_local_address,
        .local_port = options_local_port,
    };
    var thread = std.Thread.spawn(.{}, connectThreadMain, .{args}) catch {
        allocator.destroy(args);
        if (!is_unix) allocator.free(host);
        if (is_unix) allocator.free(path);
        if (options_local_address) |la| allocator.free(la);
        jsc.JSValueUnprotect(ctx, connect_listener);
        _ = g_net_pending_count.fetchSub(1, .monotonic);
        return jsc.JSValueMakeUndefined(ctx);
    };
    thread.detach();
    scheduleNetTick(ctx);
    return jsc.JSValueMakeUndefined(ctx);
}

/// 解析字符串是否为 IPv4：是则返回 true
fn parseIsIPv4(s: []const u8) bool {
    var parts: [4][]const u8 = undefined;
    var count: u32 = 0;
    var start: usize = 0;
    for (s, 0..) |c, i| {
        if (c == '.') {
            if (count >= 4 or start >= i) return false;
            parts[count] = s[start..i];
            count += 1;
            start = i + 1;
        } else if (c >= '0' and c <= '9') {} else return false;
    }
    if (count != 3 or start >= s.len) return false;
    parts[3] = s[start..];
    for (parts) |part| {
        if (part.len == 0 or part.len > 3) return false;
        var num: u32 = 0;
        for (part) |d| {
            if (d < '0' or d > '9') return false;
            num = num * 10 + @as(u32, d - '0');
        }
        if (num > 255) return false;
    }
    return true;
}

/// 解析字符串是否为 IPv6（简化：含 ':' 且每段为十六进制即可；支持 [addr] 形式）
fn parseIsIPv6(s: []const u8) bool {
    var input = s;
    if (s.len >= 2 and s[0] == '[' and s[s.len - 1] == ']') input = s[1 .. s.len - 1];
    if (input.len < 2 or input.len > 45) return false;
    var segment_count: u32 = 0;
    var i: usize = 0;
    while (i < input.len) {
        const start = i;
        while (i < input.len and input[i] != ':') : (i += 1) {}
        if (i > start) {
            if (i - start > 4) return false;
            for (input[start..i]) |c| {
                if (std.ascii.isHex(c)) {} else return false;
            }
        }
        segment_count += 1;
        if (i < input.len) i += 1;
    }
    return segment_count >= 2 and segment_count <= 8;
}

/// net.isIP(input)：返回 4 / 6 / 0（Node 约定）
fn netIsIPCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeNumber(ctx, 0);
    const js_str = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(js_str);
    var buf: [256]u8 = undefined;
    const n = jsc.JSStringGetUTF8CString(js_str, buf[0..].ptr, buf.len);
    if (n == 0) return jsc.JSValueMakeNumber(ctx, 0);
    const s = buf[0 .. n - 1];
    if (parseIsIPv4(s)) return jsc.JSValueMakeNumber(ctx, 4);
    if (parseIsIPv6(s)) return jsc.JSValueMakeNumber(ctx, 6);
    return jsc.JSValueMakeNumber(ctx, 0);
}

/// net.isIPv4(input)：返回 boolean
fn netIsIPv4Callback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeBoolean(ctx, false);
    const js_str = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(js_str);
    var buf: [256]u8 = undefined;
    const n = jsc.JSStringGetUTF8CString(js_str, buf[0..].ptr, buf.len);
    if (n == 0) return jsc.JSValueMakeBoolean(ctx, false);
    return jsc.JSValueMakeBoolean(ctx, parseIsIPv4(buf[0 .. n - 1]));
}

/// net.isIPv6(input)：返回 boolean
fn netIsIPv6Callback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeBoolean(ctx, false);
    const js_str = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(js_str);
    var buf: [256]u8 = undefined;
    const n = jsc.JSStringGetUTF8CString(js_str, buf[0..].ptr, buf.len);
    if (n == 0) return jsc.JSValueMakeBoolean(ctx, false);
    return jsc.JSValueMakeBoolean(ctx, parseIsIPv6(buf[0 .. n - 1]));
}
