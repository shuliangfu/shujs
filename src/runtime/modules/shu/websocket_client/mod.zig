// WebSocket 客户端：new WebSocket(url) 连接 ws://，同步 send / receiveSync / close
// 需 --allow-net；仅支持 ws://（不支持 wss://），Bun/Deno/Node 兼容层后续统一写

const std = @import("std");
const jsc = @import("jsc");
const errors = @import("errors");
const libs_process = @import("libs_process");
const globals = @import("../../../globals.zig");
const common = @import("../../../common.zig");
const run_options = @import("../../../run_options.zig");
const ws_proto = @import("../server/websocket.zig");
const parse = @import("../server/parse.zig");

/// 写帧临时缓冲大小（规范 §1.2 禁止栈上 64KB，改为堆分配）
const WS_CLIENT_WRITE_BUF_SIZE = 64 * 1024;

/// 单条 WebSocket 客户端连接状态（Zig 侧）
pub const ClientState = struct {
    stream: std.Io.net.Stream,
    allocator: std.mem.Allocator,
    /// 读缓冲：未消费的字节；有效数据为 items[read_off..]
    read_buf: std.ArrayList(u8),
    read_off: usize = 0,
    /// 写帧时用的临时缓冲（含 mask）；堆分配，deinit 时释放
    write_buf: []u8,

    /// 连接并完成握手后构造
    pub fn init(allocator: std.mem.Allocator, stream: std.Io.net.Stream) !ClientState {
        var read_buf = try std.ArrayList(u8).initCapacity(allocator, 4096);
        const write_buf = allocator.alloc(u8, WS_CLIENT_WRITE_BUF_SIZE) catch {
            read_buf.deinit(allocator);
            return error.OutOfMemory;
        };
        return .{
            .stream = stream,
            .allocator = allocator,
            .read_buf = read_buf,
            .write_buf = write_buf,
        };
    }

    /// 释放 read_buf、write_buf，关闭 stream。0.16：stream.close(io)
    pub fn deinit(self: *ClientState) void {
        self.read_buf.deinit(self.allocator);
        self.allocator.free(self.write_buf);
        const io = libs_process.getProcessIo() orelse return;
        self.stream.close(io);
    }

    /// 发送一帧（text 或 binary，带 mask）。0.16：io.randomSecure、stream.writer(io).writeVec
    pub fn sendFrame(self: *ClientState, opcode: ws_proto.Opcode, payload: []const u8) !void {
        const io = libs_process.getProcessIo() orelse return error.NoProcessIo;
        var key: [4]u8 = undefined;
        io.randomSecure(&key) catch return error.NoProcessIo;
        const n = try ws_proto.buildFrameMasked(self.write_buf, opcode, payload, key);
        var wbuf: [4096]u8 = undefined;
        var w = self.stream.writer(io, &wbuf);
        _ = try std.Io.Writer.writeVec(&w.interface, &.{self.write_buf[0..n]});
        try w.interface.flush();
    }

    /// 发送 close 帧：payload 为 2 字节大端 code + 可选 UTF-8 reason（RFC 6455）
    pub fn sendClose(self: *ClientState, code: u16, reason: []const u8) !void {
        var payload_buf: [128]u8 = undefined;
        std.mem.writeInt(u16, payload_buf[0..2], code, .big);
        const payload_len = 2 + @min(reason.len, payload_buf.len - 2);
        @memcpy(payload_buf[2..payload_len], reason);
        try self.sendFrame(.close, payload_buf[0..payload_len]);
    }

    /// 同步读一帧：阻塞直到收到完整一帧，返回 opcode + payload（payload 指向 read_buf 内，下次 receiveFrame 前有效）
    /// 返回 null 表示连接已关闭或收到 close 帧
    pub fn receiveFrame(self: *ClientState) !?struct { opcode: ws_proto.Opcode, payload: []const u8 } {
        while (true) {
            const active = self.read_buf.items[self.read_off..];
            if (active.len >= 2) {
                const parsed = ws_proto.parseFrame(@constCast(active)) catch |e| {
                    if (e == error.NeedMore) break;
                    return e;
                };
                const consumed = parsed.consumed;
                switch (parsed.opcode) {
                    .text, .binary => {
                        self.read_off += consumed;
                        return .{ .opcode = parsed.opcode, .payload = parsed.payload };
                    },
                    .close => return null,
                    .ping => {
                        const io = libs_process.getProcessIo() orelse return error.NoProcessIo;
                        var pong_buf: [128]u8 = undefined;
                        const len = ws_proto.buildFrame(&pong_buf, .pong, parsed.payload) catch 2;
                        var wbuf: [256]u8 = undefined;
                        var w = self.stream.writer(io, &wbuf);
                        _ = try std.Io.Writer.writeVec(&w.interface, &.{pong_buf[0..len]});
                        try w.interface.flush();
                        self.read_off += consumed;
                        continue;
                    },
                    .pong, .continuation => {
                        self.read_off += consumed;
                        continue;
                    },
                }
            }
            self.compactIfNeeded();
            const io = libs_process.getProcessIo() orelse return error.NoProcessIo;
            var buf: [4096]u8 = undefined;
            var rbuf: [4096]u8 = undefined;
            var r = self.stream.reader(io, &rbuf);
            var dest: [1][]u8 = .{buf[0..]};
            const n = std.Io.Reader.readVec(&r.interface, &dest) catch return error.ConnectionClosed;
            if (n == 0) return null;
            self.read_buf.appendSlice(self.allocator, buf[0..n]) catch return error.OutOfMemory;
        }
        return null;
    }

    /// read_off 大于 0 时把未消费数据移到头部并重置 read_off
    fn compactIfNeeded(self: *ClientState) void {
        if (self.read_off == 0) return;
        const rest = self.read_buf.items[self.read_off..];
        if (rest.len > 0) {
            @memcpy(self.read_buf.items[0..rest.len], rest);
        }
        self.read_buf.shrinkRetainingCapacity(rest.len);
        self.read_off = 0;
    }
};

/// 全局：id -> *ClientState。Unmanaged，put 显式传 allocator（01 §1.2）
var g_ws_map: std.AutoHashMapUnmanaged(u32, *ClientState) = .{};
var g_ws_next_id: u32 = 1;
var g_ws_initialized: bool = false;

fn ensureMap(allocator: std.mem.Allocator) void {
    if (!g_ws_initialized) {
        g_ws_map = .{};
        g_ws_initialized = true;
    }
    _ = allocator;
}

/// 解析 ws://host:port/path，仅支持 ws；返回的 host/path 指向栈上 buffer，调用方需立即使用
fn parseWsUrl(allocator: std.mem.Allocator, url: []const u8) !struct { host: []const u8, port: u16, path: []const u8 } {
    _ = allocator;
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    if (uri.scheme.len > 0 and (uri.scheme.len != 2 or uri.scheme[0] != 'w' or uri.scheme[1] != 's')) return error.OnlyWsSupported;
    var host_buf: [256]u8 = undefined;
    const host = (uri.host orelse return error.MissingHost).toRaw(&host_buf) catch return error.MissingHost;
    const port: u16 = if (uri.port) |p| @intCast(p) else 80;
    var path_buf: [1024]u8 = undefined;
    const path_slice = uri.path.toRaw(&path_buf) catch path_buf[0..0];
    const path = if (path_slice.len > 0) path_slice else "/";
    return .{ .host = host, .port = port, .path = path };
}

/// 生成 Sec-WebSocket-Key：16 字节随机数 base64。0.16：用 io.randomSecure
fn generateKey(allocator: std.mem.Allocator) ![]const u8 {
    const io = libs_process.getProcessIo() orelse return error.NoProcessIo;
    var bytes: [16]u8 = undefined;
    io.randomSecure(&bytes) catch return error.NoProcessIo;
    const out = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(16));
    _ = std.base64.standard.Encoder.encode(out, &bytes);
    return out;
}

/// TCP 连接 + HTTP Upgrade 握手；仅 ws://，校验 101 与 Sec-WebSocket-Accept
fn connectAndHandshake(allocator: std.mem.Allocator, host: []const u8, port: u16, path: []const u8) !std.Io.net.Stream {
    const io = libs_process.getProcessIo() orelse return error.NoProcessIo;
    const addr = try std.Io.net.IpAddress.resolve(io, host, port);
    var stream = try std.Io.net.IpAddress.connect(addr, io, .{ .mode = .stream });
    const key_b64 = try generateKey(allocator);
    defer allocator.free(key_b64);
    var req_buf: [2048]u8 = undefined;
    const path_safe = if (path.len > 0) path else "/";
    const req_len = (std.fmt.bufPrint(&req_buf,
        \\GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n
    , .{ path_safe, host, port, key_b64 }) catch return error.BufferTooSmall).len;
    var wbuf: [4096]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    _ = try std.Io.Writer.writeVec(&w.interface, &.{req_buf[0..req_len]});
    try w.interface.flush();
    var resp_buf: [4096]u8 = undefined;
    var total: usize = 0;
    var rbuf: [4096]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    while (total < 4 or resp_buf[total - 4] != '\r' or resp_buf[total - 3] != '\n' or resp_buf[total - 2] != '\r' or resp_buf[total - 1] != '\n') {
        if (total >= resp_buf.len) return error.ResponseTooLong;
        var dest: [1][]u8 = .{resp_buf[total..]};
        const n = std.Io.Reader.readVec(&r.interface, &dest) catch return error.ConnectionClosed;
        if (n == 0) return error.ConnectionClosed;
        total += n;
    }
    const head = resp_buf[0..total];
    if (head.len < 12 or !std.mem.startsWith(u8, head, "HTTP/1.1 101")) return error.BadHandshake;
    const accept_val = parse.getHeader(head, "sec-websocket-accept") orelse return error.BadHandshake;
    const accept_expected = try ws_proto.computeAcceptKey(key_b64);
    if (accept_val.len != 28) return error.BadHandshake;
    var a: [32]u8 align(8) = undefined;
    var b: [32]u8 align(8) = undefined;
    @memcpy(a[0..28], accept_val);
    @memcpy(b[0..28], &accept_expected);
    a[28..32].* = .{ 0, 0, 0, 0 };
    b[28..32].* = .{ 0, 0, 0, 0 };
    const pa = @as(*const [4]u64, @ptrCast(&a));
    const pb = @as(*const [4]u64, @ptrCast(&b));
    if (pa[0] != pb[0] or pa[1] != pb[1] or pa[2] != pb[2] or pa[3] != pb[3]) return error.BadHandshake;
    return stream;
}

/// 向全局注册 WebSocket（覆盖 stubs）；需 options != null 且 allow_net
/// 对齐浏览器：readyState、url、close(code?, reason?)、onopen/onmessage/onerror/onclose，及 WebSocket.CONNECTING/OPEN/CLOSING/CLOSED
pub fn register(ctx: jsc.JSGlobalContextRef, allocator: std.mem.Allocator, options: *const run_options.RunOptions) void {
    if (!options.permissions.allow_net) return;
    ensureMap(allocator);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const name = jsc.JSStringCreateWithUTF8CString("WebSocket");
    defer jsc.JSStringRelease(name);
    const fn_ref = jsc.JSObjectMakeFunctionWithCallback(ctx, name, websocketConstructorCallback);
    _ = jsc.JSObjectSetProperty(ctx, global, name, fn_ref, jsc.kJSPropertyAttributeNone, null);
    setNumberProperty(ctx, fn_ref, "CONNECTING", 0);
    setNumberProperty(ctx, fn_ref, "OPEN", 1);
    setNumberProperty(ctx, fn_ref, "CLOSING", 2);
    setNumberProperty(ctx, fn_ref, "CLOSED", 3);
}

fn setNumberProperty(ctx: jsc.JSContextRef, obj: jsc.JSObjectRef, name_str: []const u8, value: i32) void {
    const name_ref = jsc.JSStringCreateWithUTF8CString(name_str.ptr);
    defer jsc.JSStringRelease(name_ref);
    _ = jsc.JSObjectSetProperty(ctx, obj, name_ref, jsc.JSValueMakeNumber(ctx, @floatFromInt(value)), jsc.kJSPropertyAttributeNone, null);
}

fn setStringProperty(ctx: jsc.JSContextRef, obj: jsc.JSObjectRef, name_str: []const u8, value: []const u8) void {
    const name_ref = jsc.JSStringCreateWithUTF8CString(name_str.ptr);
    defer jsc.JSStringRelease(name_ref);
    const value_ref = jsc.JSStringCreateWithUTF8CString(if (value.len > 0) value.ptr else "");
    defer jsc.JSStringRelease(value_ref);
    _ = jsc.JSObjectSetProperty(ctx, obj, name_ref, jsc.JSValueMakeString(ctx, value_ref), jsc.kJSPropertyAttributeNone, null);
}

fn websocketConstructorCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    if (!opts.permissions.allow_net) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "WebSocket requires --allow-net" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    if (argumentCount < 1) {
        errors.reportToStderr(.{ .code = .type_error, .message = "WebSocket(url) requires 1 argument" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    const url_js = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(url_js);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(url_js);
    if (max_sz == 0 or max_sz > 2048) return jsc.JSValueMakeUndefined(ctx);
    const url_buf = allocator.alloc(u8, max_sz) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(url_buf);
    const n = jsc.JSStringGetUTF8CString(url_js, url_buf.ptr, max_sz);
    if (n == 0) return jsc.JSValueMakeUndefined(ctx);
    const url = url_buf[0 .. n - 1];
    const parsed = parseWsUrl(allocator, url) catch |e| {
        const msg = switch (e) {
            error.InvalidUrl => "WebSocket: invalid URL",
            error.OnlyWsSupported => "WebSocket: only ws:// is supported (wss:// not yet)",
            error.MissingHost => "WebSocket: missing host",
        };
        errors.reportToStderr(.{ .code = .unknown, .message = msg }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    };
    const stream = connectAndHandshake(allocator, parsed.host, parsed.port, parsed.path) catch |e| {
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&msg_buf, "WebSocket: connect failed ({s})", .{@errorName(e)}) catch "WebSocket: connect failed";
        errors.reportToStderr(.{ .code = .unknown, .message = msg }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    };
    const io = libs_process.getProcessIo() orelse return jsc.JSValueMakeUndefined(ctx);
    var state = allocator.create(ClientState) catch {
        stream.close(io);
        return jsc.JSValueMakeUndefined(ctx);
    };
    state.* = ClientState.init(allocator, stream) catch {
        stream.close(io);
        allocator.destroy(state);
        errors.reportToStderr(.{ .code = .unknown, .message = "WebSocket: init failed" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    };
    const id = g_ws_next_id;
    g_ws_next_id += 1;
    g_ws_map.put(allocator, id, state) catch {
        state.deinit();
        allocator.destroy(state);
        return jsc.JSValueMakeUndefined(ctx);
    };
    const obj = jsc.JSObjectMake(ctx, null, null);
    const name_id = jsc.JSStringCreateWithUTF8CString("_wsId");
    defer jsc.JSStringRelease(name_id);
    _ = jsc.JSObjectSetProperty(ctx, obj, name_id, jsc.JSValueMakeNumber(ctx, @floatFromInt(id)), jsc.kJSPropertyAttributeNone, null);
    setNumberProperty(ctx, obj, "readyState", 1);
    const url_str_ref = jsc.JSStringCreateWithUTF8CString(url_buf.ptr);
    defer jsc.JSStringRelease(url_str_ref);
    setPropertyWithValue(ctx, obj, "url", jsc.JSValueMakeString(ctx, url_str_ref));
    if (argumentCount >= 2) {
        if (jsc.JSValueToObject(ctx, arguments[1], null)) |opts_obj| {
            copyHandlerProperty(ctx, obj, opts_obj, "onopen");
            copyHandlerProperty(ctx, obj, opts_obj, "onmessage");
            copyHandlerProperty(ctx, obj, opts_obj, "onerror");
            copyHandlerProperty(ctx, obj, opts_obj, "onclose");
        }
    }
    common.setMethod(ctx, obj, "send", wsSendCallback);
    common.setMethod(ctx, obj, "close", wsCloseCallback);
    common.setMethod(ctx, obj, "receiveSync", wsReceiveSyncCallback);
    callOnOpenIfSet(ctx, obj);
    return obj;
}

fn setPropertyWithValue(ctx: jsc.JSContextRef, obj: jsc.JSObjectRef, name_str: []const u8, value: jsc.JSValueRef) void {
    const name_ref = jsc.JSStringCreateWithUTF8CString(name_str.ptr);
    defer jsc.JSStringRelease(name_ref);
    _ = jsc.JSObjectSetProperty(ctx, obj, name_ref, value, jsc.kJSPropertyAttributeNone, null);
}

fn copyHandlerProperty(ctx: jsc.JSContextRef, target: jsc.JSObjectRef, source: jsc.JSObjectRef, key: []const u8) void {
    const key_ref = jsc.JSStringCreateWithUTF8CString(key.ptr);
    defer jsc.JSStringRelease(key_ref);
    const val = jsc.JSObjectGetProperty(ctx, source, key_ref, null);
    if (!jsc.JSValueIsUndefined(ctx, val))
        _ = jsc.JSObjectSetProperty(ctx, target, key_ref, val, jsc.kJSPropertyAttributeNone, null);
}

fn callOnOpenIfSet(ctx: jsc.JSContextRef, obj: jsc.JSObjectRef) void {
    const name_ref = jsc.JSStringCreateWithUTF8CString("onopen");
    defer jsc.JSStringRelease(name_ref);
    const onopen = jsc.JSObjectGetProperty(ctx, obj, name_ref, null);
    if (jsc.JSObjectIsFunction(ctx, @ptrCast(onopen))) {
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(onopen), obj, 0, undefined, null);
    }
}

/// 从 JS 对象上读取 _wsId，用于 fetchRemove
fn getIdFromThis(ctx: jsc.JSContextRef, this: jsc.JSObjectRef) ?u32 {
    const name_id = jsc.JSStringCreateWithUTF8CString("_wsId");
    defer jsc.JSStringRelease(name_id);
    const val = jsc.JSObjectGetProperty(ctx, this, name_id, null);
    if (jsc.JSValueIsUndefined(ctx, val)) return null;
    const id_f = jsc.JSValueToNumber(ctx, val, null);
    return @intFromFloat(id_f);
}

fn getStateFromThis(ctx: jsc.JSContextRef, this: jsc.JSObjectRef) ?*ClientState {
    const id = getIdFromThis(ctx, this) orelse return null;
    return g_ws_map.get(id);
}

fn wsSendCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const state = getStateFromThis(ctx, this) orelse return jsc.JSValueMakeUndefined(ctx);
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const str_js = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(str_js);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(str_js);
    if (max_sz == 0 or max_sz > 64 * 1024) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const buf = allocator.alloc(u8, max_sz) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(buf);
    const n = jsc.JSStringGetUTF8CString(str_js, buf.ptr, max_sz);
    if (n == 0) return jsc.JSValueMakeUndefined(ctx);
    const payload = buf[0 .. n - 1];
    state.sendFrame(.text, payload) catch return jsc.JSValueMakeUndefined(ctx);
    return jsc.JSValueMakeUndefined(ctx);
}

/// close(code?, reason?)：发送 close 帧、设 readyState=3、调用 onclose({ code, reason, wasClean })
fn wsCloseCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const state = getStateFromThis(ctx, this) orelse return jsc.JSValueMakeUndefined(ctx);
    var code: u16 = 1000;
    var reason_buf: [128]u8 = undefined;
    var reason_len: usize = 0;
    if (argumentCount >= 1 and !jsc.JSValueIsUndefined(ctx, arguments[0])) {
        const num = jsc.JSValueToNumber(ctx, arguments[0], null);
        if (num == num) code = @intFromFloat(@min(@max(0, num), 65535));
    }
    if (argumentCount >= 2 and !jsc.JSValueIsUndefined(ctx, arguments[1])) {
        const str_ref = jsc.JSValueToStringCopy(ctx, arguments[1], null);
        defer jsc.JSStringRelease(str_ref);
        const max_n = jsc.JSStringGetMaximumUTF8CStringSize(str_ref);
        if (max_n > 0 and max_n <= reason_buf.len) {
            reason_len = jsc.JSStringGetUTF8CString(str_ref, &reason_buf, reason_buf.len);
            if (reason_len > 0) reason_len -= 1;
        }
    }
    state.sendClose(code, reason_buf[0..reason_len]) catch {};
    const id = getIdFromThis(ctx, this) orelse return jsc.JSValueMakeUndefined(ctx);
    if (g_ws_map.fetchRemove(id)) |kv| {
        kv.value.deinit();
        globals.current_allocator.?.destroy(kv.value);
    }
    setNumberProperty(ctx, this, "readyState", 3);
    callOnCloseWith(ctx, this, code, reason_buf[0..reason_len], true);
    return jsc.JSValueMakeUndefined(ctx);
}

/// 若 obj 上设置了 onclose，则调用 onclose({ code, reason, wasClean })
fn callOnCloseWith(ctx: jsc.JSContextRef, obj: jsc.JSObjectRef, code: u16, reason: []const u8, was_clean: bool) void {
    const name_ref = jsc.JSStringCreateWithUTF8CString("onclose");
    defer jsc.JSStringRelease(name_ref);
    const onclose = jsc.JSObjectGetProperty(ctx, obj, name_ref, null);
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(onclose))) return;
    const event = jsc.JSObjectMake(ctx, null, null);
    setNumberProperty(ctx, event, "code", @intCast(code));
    var reason_js: jsc.JSStringRef = undefined;
    if (reason.len > 0) {
        var z_buf: [256]u8 = undefined;
        const copy_len = @min(reason.len, z_buf.len - 1);
        @memcpy(z_buf[0..copy_len], reason);
        z_buf[copy_len] = 0;
        reason_js = jsc.JSStringCreateWithUTF8CString(&z_buf);
    } else {
        reason_js = jsc.JSStringCreateWithUTF8CString("");
    }
    defer jsc.JSStringRelease(reason_js);
    setPropertyWithValue(ctx, event, "reason", jsc.JSValueMakeString(ctx, reason_js));
    const k_was = jsc.JSStringCreateWithUTF8CString("wasClean");
    defer jsc.JSStringRelease(k_was);
    _ = jsc.JSObjectSetProperty(ctx, event, k_was, jsc.JSValueMakeBoolean(ctx, was_clean), jsc.kJSPropertyAttributeNone, null);
    var argv = [_]jsc.JSValueRef{event};
    _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(onclose), obj, 1, &argv, null);
}

/// JSC 回收 NoCopy TypedArray 时调用的空实现；payload 来自 read_buf，由下次 receiveFrame 前有效，不释放
fn wsClientNoOpDeallocator(_: *anyopaque, _: ?*anyopaque) callconv(.c) void {}

/// receiveSync()：收一条消息；若有 onmessage 则先调用 onmessage({ data })；binary 帧零拷贝传 Uint8Array，text 帧传字符串
/// 若连接关闭则设 readyState=3 并调用 onclose(1006, "", false)
fn wsReceiveSyncCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const state = getStateFromThis(ctx, this) orelse return jsc.JSValueMakeUndefined(ctx);
    const result = state.receiveFrame() catch return jsc.JSValueMakeUndefined(ctx);
    if (result == null) {
        setNumberProperty(ctx, this, "readyState", 3);
        const id = getIdFromThis(ctx, this) orelse return jsc.JSValueMakeUndefined(ctx);
        if (g_ws_map.fetchRemove(id)) |kv| {
            kv.value.deinit();
            globals.current_allocator.?.destroy(kv.value);
        }
        callOnCloseWith(ctx, this, 1006, "", false);
        return jsc.JSValueMakeUndefined(ctx);
    }
    const data_val = blk: {
        if (result.?.opcode == .binary) {
            const payload = result.?.payload;
            var exc: jsc.JSValueRef = undefined;
            const arr = jsc.JSObjectMakeTypedArrayWithBytesNoCopy(
                ctx,
                .Uint8Array,
                @ptrCast(@constCast(payload.ptr)),
                payload.len,
                wsClientNoOpDeallocator,
                null,
                @ptrCast(&exc),
            );
            break :blk if (arr != null) @as(jsc.JSValueRef, @ptrCast(arr.?)) else jsc.JSValueMakeUndefined(ctx);
        } else {
            const payload = result.?.payload;
            const str = jsc.JSStringCreateWithUTF8CString(if (payload.len > 0) payload.ptr else "");
            defer jsc.JSStringRelease(str);
            break :blk jsc.JSValueMakeString(ctx, str);
        }
    };
    const onmsg_name = jsc.JSStringCreateWithUTF8CString("onmessage");
    defer jsc.JSStringRelease(onmsg_name);
    const onmessage = jsc.JSObjectGetProperty(ctx, this, onmsg_name, null);
    if (jsc.JSObjectIsFunction(ctx, @ptrCast(onmessage))) {
        const event = jsc.JSObjectMake(ctx, null, null);
        const k_data = jsc.JSStringCreateWithUTF8CString("data");
        defer jsc.JSStringRelease(k_data);
        _ = jsc.JSObjectSetProperty(ctx, event, k_data, data_val, jsc.kJSPropertyAttributeNone, null);
        var argv = [_]jsc.JSValueRef{event};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(onmessage), this, 1, &argv, null);
    }
    return data_val;
}
