// shu:https — Node 风格 API：createServer(options, requestListener)、server.listen(port[, host][, callback])
// options.key / options.cert 为证书与私钥文件路径，透传为 Shu.server 的 options.tls；内部委托 Shu.server

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");
const shu_http = @import("../http/mod.zig");

/// 返回 shu:https 的 exports：createServer(options, requestListener)，listen 时将 options.key/cert 透传为 tls
pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    shu_http.ensureAdaptInjected(ctx, allocator);
    const https_obj = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, https_obj, "createServer", createServerHttpsCallback);
    return https_obj;
}

/// createServer(options, requestListener)：options 可含 key、cert（文件路径），存入 server 供 listen 时透传 tls
fn createServerHttpsCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const options = arguments[0];
    const requestListener = arguments[1];
    if (jsc.JSValueToObject(ctx, options, null) == null) return jsc.JSValueMakeUndefined(ctx);
    if (jsc.JSValueIsUndefined(ctx, requestListener) or jsc.JSValueIsNull(ctx, requestListener)) return jsc.JSValueMakeUndefined(ctx);
    const listener_obj = jsc.JSValueToObject(ctx, requestListener, null);
    if (listener_obj == null or !jsc.JSObjectIsFunction(ctx, listener_obj.?)) return jsc.JSValueMakeUndefined(ctx);
    const server = jsc.JSObjectMake(ctx, null, null);
    const k_listener = jsc.JSStringCreateWithUTF8CString("_requestListener");
    defer jsc.JSStringRelease(k_listener);
    const k_opts = jsc.JSStringCreateWithUTF8CString("_httpsOptions");
    defer jsc.JSStringRelease(k_opts);
    _ = jsc.JSObjectSetProperty(ctx, server, k_listener, requestListener, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, server, k_opts, options, jsc.kJSPropertyAttributeNone, null);
    common.setMethod(ctx, server, "listen", listenHttpsCallback);
    return server;
}

/// server.listen(port[, host][, callback])：与 http 相同，另将 _httpsOptions.key/cert 写入 opts.tls 后调 Shu.server
fn listenHttpsCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const k_listener = jsc.JSStringCreateWithUTF8CString("_requestListener");
    defer jsc.JSStringRelease(k_listener);
    const listener_val = jsc.JSObjectGetProperty(ctx, this, k_listener, null);
    if (jsc.JSValueIsUndefined(ctx, listener_val) or jsc.JSValueIsNull(ctx, listener_val)) return jsc.JSValueMakeUndefined(ctx);
    const listener_obj = jsc.JSValueToObject(ctx, listener_val, null);
    if (listener_obj == null or !jsc.JSObjectIsFunction(ctx, listener_obj.?)) return jsc.JSValueMakeUndefined(ctx);
    const port_n = jsc.JSValueToNumber(ctx, arguments[0], null);
    if (port_n != port_n or port_n < 1 or port_n > 65535) return jsc.JSValueMakeUndefined(ctx);
    const port = @as(u16, @intFromFloat(port_n));
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const name_create = jsc.JSStringCreateWithUTF8CString("__shuHttpCreateFetch");
    defer jsc.JSStringRelease(name_create);
    const create_val = jsc.JSObjectGetProperty(ctx, global, name_create, null);
    const create_fn = jsc.JSValueToObject(ctx, create_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    var listener_args = [_]jsc.JSValueRef{listener_val};
    const fetch_val = jsc.JSObjectCallAsFunction(ctx, create_fn, null, 1, &listener_args, null);
    if (jsc.JSValueIsUndefined(ctx, fetch_val) or jsc.JSValueIsNull(ctx, fetch_val)) return jsc.JSValueMakeUndefined(ctx);
    const fetch_obj = jsc.JSValueToObject(ctx, fetch_val, null);
    if (fetch_obj == null or !jsc.JSObjectIsFunction(ctx, fetch_obj.?)) return jsc.JSValueMakeUndefined(ctx);
    var host_buf: [256]u8 = undefined;
    const host_slice: []const u8 = blk: {
        if (argumentCount < 2 or jsc.JSValueIsUndefined(ctx, arguments[1])) break :blk "0.0.0.0";
        const js_str = jsc.JSValueToStringCopy(ctx, arguments[1], null);
        defer jsc.JSStringRelease(js_str);
        const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(js_str);
        if (max_sz == 0 or max_sz > host_buf.len) break :blk "0.0.0.0";
        const n = jsc.JSStringGetUTF8CString(js_str, host_buf[0..].ptr, host_buf.len);
        if (n == 0) break :blk "0.0.0.0";
        break :blk host_buf[0 .. n - 1];
    };
    const host_z = allocator.dupeZ(u8, host_slice) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(host_z);
    const opts = jsc.JSObjectMake(ctx, null, null);
    const k_port = jsc.JSStringCreateWithUTF8CString("port");
    defer jsc.JSStringRelease(k_port);
    const k_host = jsc.JSStringCreateWithUTF8CString("host");
    defer jsc.JSStringRelease(k_host);
    const k_fetch = jsc.JSStringCreateWithUTF8CString("fetch");
    defer jsc.JSStringRelease(k_fetch);
    _ = jsc.JSObjectSetProperty(ctx, opts, k_port, jsc.JSValueMakeNumber(ctx, @floatFromInt(port)), jsc.kJSPropertyAttributeNone, null);
    const host_js = jsc.JSStringCreateWithUTF8CString(host_z.ptr);
    defer jsc.JSStringRelease(host_js);
    _ = jsc.JSObjectSetProperty(ctx, opts, k_host, jsc.JSValueMakeString(ctx, host_js), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, opts, k_fetch, fetch_val, jsc.kJSPropertyAttributeNone, null);
    const k_opts = jsc.JSStringCreateWithUTF8CString("_httpsOptions");
    defer jsc.JSStringRelease(k_opts);
    const https_opts_val = jsc.JSObjectGetProperty(ctx, this, k_opts, null);
    const https_opts_obj = jsc.JSValueToObject(ctx, https_opts_val, null);
    if (https_opts_obj != null) {
        const k_key = jsc.JSStringCreateWithUTF8CString("key");
        defer jsc.JSStringRelease(k_key);
        const k_cert = jsc.JSStringCreateWithUTF8CString("cert");
        defer jsc.JSStringRelease(k_cert);
        const key_val = jsc.JSObjectGetProperty(ctx, https_opts_obj.?, k_key, null);
        const cert_val = jsc.JSObjectGetProperty(ctx, https_opts_obj.?, k_cert, null);
        if (!jsc.JSValueIsUndefined(ctx, key_val) and !jsc.JSValueIsUndefined(ctx, cert_val)) {
            const tls_obj = jsc.JSObjectMake(ctx, null, null);
            _ = jsc.JSObjectSetProperty(ctx, tls_obj, k_key, key_val, jsc.kJSPropertyAttributeNone, null);
            _ = jsc.JSObjectSetProperty(ctx, tls_obj, k_cert, cert_val, jsc.kJSPropertyAttributeNone, null);
            const k_tls = jsc.JSStringCreateWithUTF8CString("tls");
            defer jsc.JSStringRelease(k_tls);
            _ = jsc.JSObjectSetProperty(ctx, opts, k_tls, tls_obj, jsc.kJSPropertyAttributeNone, null);
        }
    }
    const name_shu = jsc.JSStringCreateWithUTF8CString("Shu");
    defer jsc.JSStringRelease(name_shu);
    const shu_val = jsc.JSObjectGetProperty(ctx, global, name_shu, null);
    const shu_obj = jsc.JSValueToObject(ctx, shu_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const name_server = jsc.JSStringCreateWithUTF8CString("server");
    defer jsc.JSStringRelease(name_server);
    const server_fn_val = jsc.JSObjectGetProperty(ctx, shu_obj, name_server, null);
    const server_fn = jsc.JSValueToObject(ctx, server_fn_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    var opts_arr = [_]jsc.JSValueRef{opts};
    const result = jsc.JSObjectCallAsFunction(ctx, server_fn, shu_obj, 1, &opts_arr, null);
    const result_obj = jsc.JSValueToObject(ctx, result, null) orelse return result;
    const k_stop = jsc.JSStringCreateWithUTF8CString("stop");
    defer jsc.JSStringRelease(k_stop);
    const k_reload = jsc.JSStringCreateWithUTF8CString("reload");
    defer jsc.JSStringRelease(k_reload);
    const k_restart = jsc.JSStringCreateWithUTF8CString("restart");
    defer jsc.JSStringRelease(k_restart);
    const v_stop = jsc.JSObjectGetProperty(ctx, result_obj, k_stop, null);
    if (!jsc.JSValueIsUndefined(ctx, v_stop)) _ = jsc.JSObjectSetProperty(ctx, this, k_stop, v_stop, jsc.kJSPropertyAttributeNone, null);
    const v_reload = jsc.JSObjectGetProperty(ctx, result_obj, k_reload, null);
    if (!jsc.JSValueIsUndefined(ctx, v_reload)) _ = jsc.JSObjectSetProperty(ctx, this, k_reload, v_reload, jsc.kJSPropertyAttributeNone, null);
    const v_restart = jsc.JSObjectGetProperty(ctx, result_obj, k_restart, null);
    if (!jsc.JSValueIsUndefined(ctx, v_restart)) _ = jsc.JSObjectSetProperty(ctx, this, k_restart, v_restart, jsc.kJSPropertyAttributeNone, null);
    if (argumentCount >= 3 and jsc.JSObjectIsFunction(ctx, @ptrCast(arguments[2]))) {
        const cb_args = [_]jsc.JSValueRef{jsc.JSValueMakeUndefined(ctx)};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(arguments[2]), this, 1, &cb_args, null);
    }
    return this;
}
