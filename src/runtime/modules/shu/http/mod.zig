// shu:http — Node 风格 API：createServer(requestListener)、server.listen(port[, host][, callback])
// 内部委托 Shu.server(options)，requestListener(req, res) 的 res 适配为 { status, headers, body } 供底层使用

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");

/// 全局 __shuHttpAdapt 是否已注入（仅注入一次）
var g_http_adapt_injected: bool = false;

/// §1.1 显式 allocator 收敛：getExports 时注入，listen 等回调优先使用
threadlocal var g_http_allocator: ?std.mem.Allocator = null;

/// 返回 shu:http 的 exports：createServer、以及供 listen 内部用的 __shuHttpAdapt / __shuHttpCreateFetch
pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    g_http_allocator = allocator;
    const http_obj = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, http_obj, "createServer", createServerCallback);
    injectAdaptAndCreateFetch(ctx, allocator) catch return http_obj;
    return http_obj;
}

/// 供 shu:https 等复用：确保 __shuHttpAdapt / __shuHttpCreateFetch 已注入（仅执行一次）
pub fn ensureAdaptInjected(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) void {
    injectAdaptAndCreateFetch(ctx, allocator) catch {};
}

/// 在 globalThis 上注入 __shuHttpAdapt 与 __shuHttpCreateFetch（仅执行一次）
fn injectAdaptAndCreateFetch(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) !void {
    if (g_http_adapt_injected) return;
    g_http_adapt_injected = true;
    const global = jsc.JSContextGetGlobalObject(ctx);
    const name_adapt = jsc.JSStringCreateWithUTF8CString("__shuHttpAdapt");
    defer jsc.JSStringRelease(name_adapt);
    const adapt_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, name_adapt, adaptCallback);
    _ = jsc.JSObjectSetProperty(ctx, global, name_adapt, adapt_fn, jsc.kJSPropertyAttributeNone, null);
    const script =
        "(function(){ globalThis.__shuHttpCreateFetch = function(listener){ return function(req){ return globalThis.__shuHttpAdapt(req, listener); }; }; })()";
    const script_z = try allocator.dupeZ(u8, script);
    defer allocator.free(script_z);
    const script_ref = jsc.JSStringCreateWithUTF8CString(script_z.ptr);
    defer jsc.JSStringRelease(script_ref);
    _ = jsc.JSEvaluateScript(ctx, script_ref, global, null, 0, null);
}

/// createServer([options], requestListener)：仅支持 createServer(requestListener)，返回带 listen 的 server 对象
fn createServerCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const requestListener = arguments[0];
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(requestListener)))
        return jsc.JSValueMakeUndefined(ctx);
    const server = jsc.JSObjectMake(ctx, null, null);
    const k_listener = jsc.JSStringCreateWithUTF8CString("_requestListener");
    defer jsc.JSStringRelease(k_listener);
    _ = jsc.JSObjectSetProperty(ctx, server, k_listener, requestListener, jsc.kJSPropertyAttributeNone, null);
    common.setMethod(ctx, server, "listen", listenCallback);
    return server;
}

/// server.listen(port[, host][, callback])：从 globalThis.Shu.server 取函数，用 { port, host, fetch } 调用并合并 stop/reload/restart
fn listenCallback(
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
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(listener_val))) return jsc.JSValueMakeUndefined(ctx);
    const port_val = arguments[0];
    const port_n = jsc.JSValueToNumber(ctx, port_val, null);
    if (port_n != port_n or port_n < 1 or port_n > 65535) return jsc.JSValueMakeUndefined(ctx);
    const port = @as(u16, @intFromFloat(port_n));
    const allocator = g_http_allocator orelse globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const name_create = jsc.JSStringCreateWithUTF8CString("__shuHttpCreateFetch");
    defer jsc.JSStringRelease(name_create);
    const create_val = jsc.JSObjectGetProperty(ctx, global, name_create, null);
    const create_fn = jsc.JSValueToObject(ctx, create_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    var listener_args = [_]jsc.JSValueRef{listener_val};
    const fetch_val = jsc.JSObjectCallAsFunction(ctx, create_fn, null, 1, &listener_args, null);
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(fetch_val))) return jsc.JSValueMakeUndefined(ctx);
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

/// __shuHttpAdapt(req, requestListener)：创建 res（writeHead/end），调用 requestListener(req, res)，返回 res（即 { status, headers, body }）
fn adaptCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const req = arguments[0];
    const requestListener = arguments[1];
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(requestListener))) return jsc.JSValueMakeUndefined(ctx);
    const res = jsc.JSObjectMake(ctx, null, null);
    const k_status = jsc.JSStringCreateWithUTF8CString("status");
    defer jsc.JSStringRelease(k_status);
    const k_headers = jsc.JSStringCreateWithUTF8CString("headers");
    defer jsc.JSStringRelease(k_headers);
    const k_body = jsc.JSStringCreateWithUTF8CString("body");
    defer jsc.JSStringRelease(k_body);
    _ = jsc.JSObjectSetProperty(ctx, res, k_status, jsc.JSValueMakeNumber(ctx, 200), jsc.kJSPropertyAttributeNone, null);
    const empty_headers = jsc.JSObjectMake(ctx, null, null);
    _ = jsc.JSObjectSetProperty(ctx, res, k_headers, empty_headers, jsc.kJSPropertyAttributeNone, null);
    const empty_str = jsc.JSStringCreateWithUTF8CString("");
    defer jsc.JSStringRelease(empty_str);
    _ = jsc.JSObjectSetProperty(ctx, res, k_body, jsc.JSValueMakeString(ctx, empty_str), jsc.kJSPropertyAttributeNone, null);
    common.setMethod(ctx, res, "writeHead", resWriteHeadCallback);
    common.setMethod(ctx, res, "end", resEndCallback);
    var args = [_]jsc.JSValueRef{ req, res };
    _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(requestListener), null, 2, &args, null);
    return res;
}

/// res.writeHead(statusCode[, statusMessage][, headers])：将 status/headers 写到 this（res）
fn resWriteHeadCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const sc = jsc.JSValueToNumber(ctx, arguments[0], null);
    if (sc == sc and sc >= 100 and sc <= 599) {
        const k_status = jsc.JSStringCreateWithUTF8CString("status");
        defer jsc.JSStringRelease(k_status);
        _ = jsc.JSObjectSetProperty(ctx, this, k_status, jsc.JSValueMakeNumber(ctx, sc), jsc.kJSPropertyAttributeNone, null);
    }
    if (argumentCount >= 2) {
        const v1 = arguments[1];
        if (jsc.JSValueToObject(ctx, v1, null) != null) {
            const k_headers = jsc.JSStringCreateWithUTF8CString("headers");
            defer jsc.JSStringRelease(k_headers);
            _ = jsc.JSObjectSetProperty(ctx, this, k_headers, v1, jsc.kJSPropertyAttributeNone, null);
        }
    }
    if (argumentCount >= 3) {
        const v2 = arguments[2];
        if (jsc.JSValueToObject(ctx, v2, null) != null) {
            const k_headers = jsc.JSStringCreateWithUTF8CString("headers");
            defer jsc.JSStringRelease(k_headers);
            _ = jsc.JSObjectSetProperty(ctx, this, k_headers, v2, jsc.kJSPropertyAttributeNone, null);
        }
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// res.end([chunk])：将 chunk 转为字符串写到 this.body
fn resEndCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const k_body = jsc.JSStringCreateWithUTF8CString("body");
    defer jsc.JSStringRelease(k_body);
    if (argumentCount >= 1 and !jsc.JSValueIsUndefined(ctx, arguments[0])) {
        const str = jsc.JSValueToStringCopy(ctx, arguments[0], null);
        defer jsc.JSStringRelease(str);
        _ = jsc.JSObjectSetProperty(ctx, this, k_body, jsc.JSValueMakeString(ctx, str), jsc.kJSPropertyAttributeNone, null);
    } else {
        const empty_str = jsc.JSStringCreateWithUTF8CString("");
        defer jsc.JSStringRelease(empty_str);
        _ = jsc.JSObjectSetProperty(ctx, this, k_body, jsc.JSValueMakeString(ctx, empty_str), jsc.kJSPropertyAttributeNone, null);
    }
    return jsc.JSValueMakeUndefined(ctx);
}
