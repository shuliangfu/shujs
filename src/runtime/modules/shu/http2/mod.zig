//! shu:http2 — 对应 Node 的 node:http2，提供 HTTP/2 客户端与服务端 API（与 node:http2 对齐）。
//! 导出：connect、createServer、createSecureServer、constants、getDefaultSettings、getPackedSettings。
//! 客户端：connect(url[, options][, listener]) 返回 session；session.request([opts], callback) 单次 GET；session.close()。
//! 服务端：createServer/createSecureServer 返回带 .on('stream')、.listen() 的 server（createSecureServer.listen 可对接 Shu.server）。

const std = @import("std");
const jsc = @import("jsc");
const libs_io = @import("libs_io");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");

threadlocal var g_http2_allocator: ?std.mem.Allocator = null;

/// 在 obj 上设置字符串属性 name -> value（用于 constants 等）
fn setString(ctx: jsc.JSContextRef, obj: jsc.JSObjectRef, name: [*]const u8, value: [*]const u8) void {
    const k = jsc.JSStringCreateWithUTF8CString(name);
    defer jsc.JSStringRelease(k);
    const v = jsc.JSStringCreateWithUTF8CString(value);
    defer jsc.JSStringRelease(v);
    _ = jsc.JSObjectSetProperty(ctx, obj, k, jsc.JSValueMakeString(ctx, v), jsc.kJSPropertyAttributeNone, null);
}

/// 在 obj 上设置数字属性 name -> value
fn setNumber(ctx: jsc.JSContextRef, obj: jsc.JSObjectRef, name: [*]const u8, value: f64) void {
    const k = jsc.JSStringCreateWithUTF8CString(name);
    defer jsc.JSStringRelease(k);
    _ = jsc.JSObjectSetProperty(ctx, obj, k, jsc.JSValueMakeNumber(ctx, value), jsc.kJSPropertyAttributeNone, null);
}

/// 用全局 Error 构造函数创建 Error(message)，供 callback(err, result) 的 err 使用；与 test/mod.zig 等一致。message 需以 0 结尾或由调用方保证可读。
fn makeError(ctx: jsc.JSContextRef, message: [*:0]const u8) jsc.JSValueRef {
    const k_error = jsc.JSStringCreateWithUTF8CString("Error");
    defer jsc.JSStringRelease(k_error);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const Error_ctor = jsc.JSObjectGetProperty(ctx, global, k_error, null);
    if (jsc.JSValueIsUndefined(ctx, Error_ctor)) return jsc.JSValueMakeUndefined(ctx);
    const msg_js = jsc.JSStringCreateWithUTF8CString(message);
    defer jsc.JSStringRelease(msg_js);
    var args = [_]jsc.JSValueRef{jsc.JSValueMakeString(ctx, msg_js)};
    return jsc.JSObjectCallAsConstructor(ctx, @ptrCast(Error_ctor), 1, &args, null);
}

/// 全局 __shuHttp2Adapt / __shuHttp2CreateFetch 是否已注入（仅注入一次）
var g_http2_adapt_injected: bool = false;

/// 返回 shu:http2 的 exports：与 node:http2 对齐的 connect、createServer、createSecureServer、constants、getDefaultSettings、getPackedSettings。
pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    g_http2_allocator = allocator;
    const exports = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, exports, "connect", connectCallback);
    common.setMethod(ctx, exports, "createServer", createServerCallback);
    common.setMethod(ctx, exports, "createSecureServer", createSecureServerCallback);
    common.setMethod(ctx, exports, "getDefaultSettings", getDefaultSettingsCallback);
    common.setMethod(ctx, exports, "getPackedSettings", getPackedSettingsCallback);
    injectHttp2AdaptAndCreateFetch(ctx) catch {};
    const constants_obj = makeConstants(ctx);
    const k_constants = jsc.JSStringCreateWithUTF8CString("constants");
    defer jsc.JSStringRelease(k_constants);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_constants, constants_obj, jsc.kJSPropertyAttributeNone, null);
    return exports;
}

/// node:http2.constants：伪头与常用 HTTP/2 头名常量（与 Node 一致）
fn makeConstants(ctx: jsc.JSContextRef) jsc.JSObjectRef {
    const obj = jsc.JSObjectMake(ctx, null, null);
    setString(ctx, obj, "HTTP2_HEADER_STATUS", ":status");
    setString(ctx, obj, "HTTP2_HEADER_METHOD", ":method");
    setString(ctx, obj, "HTTP2_HEADER_PATH", ":path");
    setString(ctx, obj, "HTTP2_HEADER_AUTHORITY", ":authority");
    setString(ctx, obj, "HTTP2_HEADER_SCHEME", ":scheme");
    setString(ctx, obj, "HTTP2_HEADER_ACCEPT", "accept");
    setString(ctx, obj, "HTTP2_HEADER_ACCEPT_ENCODING", "accept-encoding");
    setString(ctx, obj, "HTTP2_HEADER_CONTENT_TYPE", "content-type");
    setString(ctx, obj, "HTTP2_HEADER_CONTENT_LENGTH", "content-length");
    setString(ctx, obj, "HTTP2_HEADER_USER_AGENT", "user-agent");
    setNumber(ctx, obj, "DEFAULT_SETTINGS_ENABLE_PUSH", 1);
    setNumber(ctx, obj, "DEFAULT_SETTINGS_HEADER_TABLE_SIZE", 4096);
    setNumber(ctx, obj, "DEFAULT_SETTINGS_INITIAL_WINDOW_SIZE", 65535);
    setNumber(ctx, obj, "DEFAULT_SETTINGS_MAX_FRAME_SIZE", 16384);
    return obj;
}

/// 在 globalThis 上注入 __shuHttp2Adapt 与 __shuHttp2CreateFetch（仅执行一次），供 createSecureServer().listen 使用的 fetch 包装 stream 回调
fn injectHttp2AdaptAndCreateFetch(ctx: jsc.JSContextRef) !void {
    if (g_http2_adapt_injected) return;
    g_http2_adapt_injected = true;
    const global = jsc.JSContextGetGlobalObject(ctx);
    const name_adapt = jsc.JSStringCreateWithUTF8CString("__shuHttp2Adapt");
    defer jsc.JSStringRelease(name_adapt);
    const adapt_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, name_adapt, http2AdaptCallback);
    _ = jsc.JSObjectSetProperty(ctx, global, name_adapt, adapt_fn, jsc.kJSPropertyAttributeNone, null);
    const name_create = jsc.JSStringCreateWithUTF8CString("__shuHttp2CreateFetch");
    defer jsc.JSStringRelease(name_create);
    const create_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, name_create, http2CreateFetchCallback);
    _ = jsc.JSObjectSetProperty(ctx, global, name_create, create_fn, jsc.kJSPropertyAttributeNone, null);
}

/// __shuHttp2CreateFetch(streamListener) 返回的包装被调用时：取 callee.__streamListener，再调 __shuHttp2Adapt(req, listener)
fn http2CreateFetchWrapperCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    callee: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const k_listener = jsc.JSStringCreateWithUTF8CString("__streamListener");
    defer jsc.JSStringRelease(k_listener);
    const listener = jsc.JSObjectGetProperty(ctx, callee, k_listener, null);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_adapt = jsc.JSStringCreateWithUTF8CString("__shuHttp2Adapt");
    defer jsc.JSStringRelease(k_adapt);
    const adapt_fn = jsc.JSObjectGetProperty(ctx, global, k_adapt, null);
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(adapt_fn))) return jsc.JSValueMakeUndefined(ctx);
    var two: [2]jsc.JSValueRef = .{ arguments[0], listener };
    return jsc.JSObjectCallAsFunction(ctx, @ptrCast(adapt_fn), null, 2, &two, null);
}

/// __shuHttp2CreateFetch(streamListener)：返回带 __streamListener 的包装函数，供 Shu.server 的 fetch 使用
fn http2CreateFetchCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const listener = arguments[0];
    const name_wrapper = jsc.JSStringCreateWithUTF8CString("__shuHttp2CreateFetchWrapper");
    defer jsc.JSStringRelease(name_wrapper);
    const wrapper_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, name_wrapper, http2CreateFetchWrapperCallback);
    const k_listener = jsc.JSStringCreateWithUTF8CString("__streamListener");
    defer jsc.JSStringRelease(k_listener);
    _ = jsc.JSObjectSetProperty(ctx, wrapper_fn, k_listener, listener, jsc.kJSPropertyAttributeNone, null);
    return wrapper_fn;
}

/// __shuHttp2Adapt(req, streamListener)：创建 stream（respond/end），调用 streamListener(stream, req.headers)，返回 stream（与 res 同形：status/headers/body）
fn http2AdaptCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const req = arguments[0];
    const stream_listener = arguments[1];
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(stream_listener))) return jsc.JSValueMakeUndefined(ctx);
    const stream = jsc.JSObjectMake(ctx, null, null);
    const k_status = jsc.JSStringCreateWithUTF8CString("status");
    defer jsc.JSStringRelease(k_status);
    const k_headers = jsc.JSStringCreateWithUTF8CString("headers");
    defer jsc.JSStringRelease(k_headers);
    const k_body = jsc.JSStringCreateWithUTF8CString("body");
    defer jsc.JSStringRelease(k_body);
    _ = jsc.JSObjectSetProperty(ctx, stream, k_status, jsc.JSValueMakeNumber(ctx, 200), jsc.kJSPropertyAttributeNone, null);
    const empty_headers = jsc.JSObjectMake(ctx, null, null);
    _ = jsc.JSObjectSetProperty(ctx, stream, k_headers, empty_headers, jsc.kJSPropertyAttributeNone, null);
    const empty_str = jsc.JSStringCreateWithUTF8CString("");
    defer jsc.JSStringRelease(empty_str);
    _ = jsc.JSObjectSetProperty(ctx, stream, k_body, jsc.JSValueMakeString(ctx, empty_str), jsc.kJSPropertyAttributeNone, null);
    common.setMethod(ctx, stream, "respond", streamRespondCallback);
    common.setMethod(ctx, stream, "end", streamEndCallback);
    const req_obj = jsc.JSValueToObject(ctx, req, null) orelse return stream;
    const k_req_headers = jsc.JSStringCreateWithUTF8CString("headers");
    defer jsc.JSStringRelease(k_req_headers);
    const req_headers = jsc.JSObjectGetProperty(ctx, req_obj, k_req_headers, null);
    var args = [_]jsc.JSValueRef{ stream, req_headers };
    _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(stream_listener), null, 2, &args, null);
    return stream;
}

/// stream.respond(headers)：从 headers 读 ':status' 写 this.status，并设 this.headers = headers（与 Shu.server 响应格式一致）
fn streamRespondCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const headers_obj = jsc.JSValueToObject(ctx, arguments[0], null);
    if (headers_obj != null) {
        const k_status_key = jsc.JSStringCreateWithUTF8CString(":status");
        defer jsc.JSStringRelease(k_status_key);
        const status_val = jsc.JSObjectGetProperty(ctx, headers_obj.?, k_status_key, null);
        const sc = jsc.JSValueToNumber(ctx, status_val, null);
        if (sc == sc and sc >= 100 and sc <= 599) {
            const k_status = jsc.JSStringCreateWithUTF8CString("status");
            defer jsc.JSStringRelease(k_status);
            _ = jsc.JSObjectSetProperty(ctx, this, k_status, jsc.JSValueMakeNumber(ctx, sc), jsc.kJSPropertyAttributeNone, null);
        }
        const k_headers = jsc.JSStringCreateWithUTF8CString("headers");
        defer jsc.JSStringRelease(k_headers);
        _ = jsc.JSObjectSetProperty(ctx, this, k_headers, arguments[0], jsc.kJSPropertyAttributeNone, null);
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// stream.end([chunk])：将 chunk 转为字符串写到 this.body，供 Shu.server 的 getResponseBody 读取
fn streamEndCallback(
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

/// createServer([options], [listener])：明文 HTTP/2 服务端；返回带 .on('stream')、.listen() 的 server。listen 当前抛 not implemented（浏览器多不支持明文 h2）。
fn createServerCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    _ = argumentCount;
    _ = arguments;
    const server = makeHttp2ServerObject(ctx);
    return server;
}

/// createSecureServer(options, [listener])：HTTPS HTTP/2 服务端；返回带 .on('stream')、.listen() 的 server。listen(port) 对接 Shu.server，options 需含 key/cert 路径。
fn createSecureServerCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const server = makeHttp2ServerObject(ctx);
    if (argumentCount >= 1 and !jsc.JSValueIsUndefined(ctx, arguments[0]) and jsc.JSValueToObject(ctx, arguments[0], null) != null) {
        const k_tls = jsc.JSStringCreateWithUTF8CString("_tlsOptions");
        defer jsc.JSStringRelease(k_tls);
        _ = jsc.JSObjectSetProperty(ctx, server, k_tls, arguments[0], jsc.kJSPropertyAttributeNone, null);
    }
    return server;
}

/// 构造共用的 HTTP/2 server 对象：含 _events 与 on/emit/listen 方法（Node 风格 EventEmitter + listen）
fn makeHttp2ServerObject(ctx: jsc.JSContextRef) jsc.JSObjectRef {
    const server = jsc.JSObjectMake(ctx, null, null);
    const k_events = jsc.JSStringCreateWithUTF8CString("_events");
    defer jsc.JSStringRelease(k_events);
    _ = jsc.JSObjectSetProperty(ctx, server, k_events, jsc.JSObjectMake(ctx, null, null), jsc.kJSPropertyAttributeNone, null);
    common.setMethod(ctx, server, "on", serverOnCallback);
    common.setMethod(ctx, server, "listen", serverListenCallback);
    return server;
}

/// server.on(event, fn)：将 fn 挂到 this._events[event]，与 Node EventEmitter 一致
fn serverOnCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return this;
    const k_events = jsc.JSStringCreateWithUTF8CString("_events");
    defer jsc.JSStringRelease(k_events);
    const events_val = jsc.JSObjectGetProperty(ctx, this, k_events, null);
    const events = jsc.JSValueToObject(ctx, events_val, null) orelse return this;
    const name_str = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(name_str);
    const fn_val = arguments[1];
    const list_val = jsc.JSObjectGetProperty(ctx, events, name_str, null);
    const list_obj = jsc.JSValueToObject(ctx, list_val, null);
    if (list_obj == null) {
        var one: [1]jsc.JSValueRef = .{fn_val};
        const new_arr = jsc.JSObjectMakeArray(ctx, 1, &one, null);
        _ = jsc.JSObjectSetProperty(ctx, events, name_str, new_arr, jsc.kJSPropertyAttributeNone, null);
    } else {
        const global = jsc.JSContextGetGlobalObject(ctx);
        const k_Array = jsc.JSStringCreateWithUTF8CString("Array");
        defer jsc.JSStringRelease(k_Array);
        const k_prototype = jsc.JSStringCreateWithUTF8CString("prototype");
        defer jsc.JSStringRelease(k_prototype);
        const k_push = jsc.JSStringCreateWithUTF8CString("push");
        defer jsc.JSStringRelease(k_push);
        const Array_val = jsc.JSObjectGetProperty(ctx, global, k_Array, null);
        const Array_obj = jsc.JSValueToObject(ctx, Array_val, null) orelse return this;
        const proto_val = jsc.JSObjectGetProperty(ctx, Array_obj, k_prototype, null);
        const proto_obj = jsc.JSValueToObject(ctx, proto_val, null) orelse return this;
        const push_fn = jsc.JSObjectGetProperty(ctx, proto_obj, k_push, null);
        const push_obj = jsc.JSValueToObject(ctx, push_fn, null) orelse return this;
        var args: [1]jsc.JSValueRef = .{fn_val};
        _ = jsc.JSObjectCallAsFunction(ctx, push_obj, list_obj, 1, &args, null);
    }
    return this;
}

/// server.listen(port[, host][, callback])：createSecureServer 时对接 Shu.server（tls + fetch）；createServer（明文）抛 not implemented
fn serverListenCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const k_tls = jsc.JSStringCreateWithUTF8CString("_tlsOptions");
    defer jsc.JSStringRelease(k_tls);
    const tls_opts_val = jsc.JSObjectGetProperty(ctx, this, k_tls, null);
    if (jsc.JSValueIsUndefined(ctx, tls_opts_val) or jsc.JSValueIsNull(ctx, tls_opts_val)) {
        const err = makeError(ctx, "http2.server.listen: plain (createServer) not implemented; use createSecureServer for HTTP/2 over TLS".ptr);
        _ = common.setThrowAndThrow(ctx, err);
        return jsc.JSValueMakeUndefined(ctx);
    }
    const tls_opts = jsc.JSValueToObject(ctx, tls_opts_val, null) orelse {
        const err = makeError(ctx, "http2.server.listen: _tlsOptions invalid".ptr);
        _ = common.setThrowAndThrow(ctx, err);
        return jsc.JSValueMakeUndefined(ctx);
    };
    const k_events = jsc.JSStringCreateWithUTF8CString("_events");
    defer jsc.JSStringRelease(k_events);
    const events_val = jsc.JSObjectGetProperty(ctx, this, k_events, null);
    const events = jsc.JSValueToObject(ctx, events_val, null) orelse {
        const err = makeError(ctx, "http2.server.listen: missing _events".ptr);
        _ = common.setThrowAndThrow(ctx, err);
        return jsc.JSValueMakeUndefined(ctx);
    };
    const k_stream = jsc.JSStringCreateWithUTF8CString("stream");
    defer jsc.JSStringRelease(k_stream);
    const stream_list_val = jsc.JSObjectGetProperty(ctx, events, k_stream, null);
    const stream_list = jsc.JSValueToObject(ctx, stream_list_val, null);
    if (stream_list == null) {
        const err = makeError(ctx, "http2.server.listen: no 'stream' listener; call server.on('stream', (stream, headers) => { ... }) first".ptr);
        _ = common.setThrowAndThrow(ctx, err);
        return jsc.JSValueMakeUndefined(ctx);
    }
    const k_length = jsc.JSStringCreateWithUTF8CString("length");
    defer jsc.JSStringRelease(k_length);
    const len_val = jsc.JSObjectGetProperty(ctx, stream_list.?, k_length, null);
    const len_n = jsc.JSValueToNumber(ctx, len_val, null);
    if (len_n < 1) {
        const err = makeError(ctx, "http2.server.listen: no 'stream' listener".ptr);
        _ = common.setThrowAndThrow(ctx, err);
        return jsc.JSValueMakeUndefined(ctx);
    }
    const k_0 = jsc.JSStringCreateWithUTF8CString("0");
    defer jsc.JSStringRelease(k_0);
    const stream_listener = jsc.JSObjectGetProperty(ctx, stream_list.?, k_0, null);
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(stream_listener))) {
        const err = makeError(ctx, "http2.server.listen: _events.stream[0] is not a function".ptr);
        _ = common.setThrowAndThrow(ctx, err);
        return jsc.JSValueMakeUndefined(ctx);
    }
    const global = jsc.JSContextGetGlobalObject(ctx);
    const name_create = jsc.JSStringCreateWithUTF8CString("__shuHttp2CreateFetch");
    defer jsc.JSStringRelease(name_create);
    const create_val = jsc.JSObjectGetProperty(ctx, global, name_create, null);
    const create_fn = jsc.JSValueToObject(ctx, create_val, null) orelse {
        const err = makeError(ctx, "http2.server.listen: __shuHttp2CreateFetch not found".ptr);
        _ = common.setThrowAndThrow(ctx, err);
        return jsc.JSValueMakeUndefined(ctx);
    };
    var listener_args = [_]jsc.JSValueRef{stream_listener};
    const fetch_val = jsc.JSObjectCallAsFunction(ctx, create_fn, null, 1, &listener_args, null);
    if (jsc.JSValueIsUndefined(ctx, fetch_val) or jsc.JSValueIsNull(ctx, fetch_val)) return jsc.JSValueMakeUndefined(ctx);
    const fetch_obj = jsc.JSValueToObject(ctx, fetch_val, null);
    if (fetch_obj == null or !jsc.JSObjectIsFunction(ctx, fetch_obj.?)) return jsc.JSValueMakeUndefined(ctx);
    const port_val = arguments[0];
    const port_n = jsc.JSValueToNumber(ctx, port_val, null);
    if (port_n != port_n or port_n < 1 or port_n > 65535) return jsc.JSValueMakeUndefined(ctx);
    const port = @as(u16, @intFromFloat(port_n));
    const allocator = g_http2_allocator orelse globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
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
    var cert_buf: [512]u8 = undefined;
    var key_buf: [512]u8 = undefined;
    const k_cert = jsc.JSStringCreateWithUTF8CString("cert");
    defer jsc.JSStringRelease(k_cert);
    const k_key = jsc.JSStringCreateWithUTF8CString("key");
    defer jsc.JSStringRelease(k_key);
    const cert_v = jsc.JSObjectGetProperty(ctx, tls_opts, k_cert, null);
    const key_v = jsc.JSObjectGetProperty(ctx, tls_opts, k_key, null);
    const cert_js = jsc.JSValueToStringCopy(ctx, cert_v, null);
    defer jsc.JSStringRelease(cert_js);
    const key_js = jsc.JSValueToStringCopy(ctx, key_v, null);
    defer jsc.JSStringRelease(key_js);
    const n_cert = jsc.JSStringGetUTF8CString(cert_js, cert_buf[0..].ptr, cert_buf.len);
    const n_key = jsc.JSStringGetUTF8CString(key_js, key_buf[0..].ptr, key_buf.len);
    if (n_cert <= 1 or n_key <= 1) {
        const err = makeError(ctx, "http2.server.listen: options must have cert and key (file path strings)".ptr);
        _ = common.setThrowAndThrow(ctx, err);
        return jsc.JSValueMakeUndefined(ctx);
    }
    const opts = jsc.JSObjectMake(ctx, null, null);
    const k_port = jsc.JSStringCreateWithUTF8CString("port");
    defer jsc.JSStringRelease(k_port);
    const k_host = jsc.JSStringCreateWithUTF8CString("host");
    defer jsc.JSStringRelease(k_host);
    const k_fetch = jsc.JSStringCreateWithUTF8CString("fetch");
    defer jsc.JSStringRelease(k_fetch);
    const k_tls_opt = jsc.JSStringCreateWithUTF8CString("tls");
    defer jsc.JSStringRelease(k_tls_opt);
    _ = jsc.JSObjectSetProperty(ctx, opts, k_port, jsc.JSValueMakeNumber(ctx, @floatFromInt(port)), jsc.kJSPropertyAttributeNone, null);
    const host_js = jsc.JSStringCreateWithUTF8CString(host_z.ptr);
    defer jsc.JSStringRelease(host_js);
    _ = jsc.JSObjectSetProperty(ctx, opts, k_host, jsc.JSValueMakeString(ctx, host_js), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, opts, k_fetch, fetch_val, jsc.kJSPropertyAttributeNone, null);
    const tls_obj = jsc.JSObjectMake(ctx, null, null);
    const cert_js_out = jsc.JSStringCreateWithUTF8CString(cert_buf[0..].ptr);
    defer jsc.JSStringRelease(cert_js_out);
    const key_js_out = jsc.JSStringCreateWithUTF8CString(key_buf[0..].ptr);
    defer jsc.JSStringRelease(key_js_out);
    _ = jsc.JSObjectSetProperty(ctx, tls_obj, k_cert, jsc.JSValueMakeString(ctx, cert_js_out), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, tls_obj, k_key, jsc.JSValueMakeString(ctx, key_js_out), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, opts, k_tls_opt, tls_obj, jsc.kJSPropertyAttributeNone, null);
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
    if (argumentCount >= 3) {
        const cb_obj = jsc.JSValueToObject(ctx, arguments[2], null);
        if (cb_obj != null and jsc.JSObjectIsFunction(ctx, cb_obj.?)) {
            var no_args: [1]jsc.JSValueRef = .{jsc.JSValueMakeUndefined(ctx)};
            _ = jsc.JSObjectCallAsFunction(ctx, cb_obj.?, this, 1, &no_args, null);
        }
    }
    return this;
}

/// getDefaultSettings()：返回 Node 兼容的默认 SETTINGS 对象
fn getDefaultSettingsCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    _ = argumentCount;
    _ = arguments;
    const obj = jsc.JSObjectMake(ctx, null, null);
    setNumber(ctx, obj, "headerTableSize", 4096);
    setNumber(ctx, obj, "enablePush", 1);
    setNumber(ctx, obj, "initialWindowSize", 65535);
    setNumber(ctx, obj, "maxFrameSize", 16384);
    setNumber(ctx, obj, "maxConcurrentStreams", 4294967295);
    setNumber(ctx, obj, "maxHeaderListSize", 65535);
    return obj;
}

/// getPackedSettings(settings)：将 settings 对象打包为 Buffer；当前返回空 Buffer 占位
fn getPackedSettingsCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    _ = argumentCount;
    _ = arguments;
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_Buffer = jsc.JSStringCreateWithUTF8CString("Buffer");
    defer jsc.JSStringRelease(k_Buffer);
    const Buffer_val = jsc.JSObjectGetProperty(ctx, global, k_Buffer, null);
    const Buffer_obj = jsc.JSValueToObject(ctx, Buffer_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const k_alloc = jsc.JSStringCreateWithUTF8CString("alloc");
    defer jsc.JSStringRelease(k_alloc);
    const alloc_fn = jsc.JSObjectGetProperty(ctx, Buffer_obj, k_alloc, null);
    var zero: [1]jsc.JSValueRef = .{jsc.JSValueMakeNumber(ctx, 0)};
    return jsc.JSObjectCallAsFunction(ctx, jsc.JSValueToObject(ctx, alloc_fn, null) orelse return jsc.JSValueMakeUndefined(ctx), null, 1, &zero, null);
}

/// connect(url)：创建并返回 session 对象，session 持有 url，供 request() 使用。
fn connectCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const url_val = arguments[0];
    if (!jsc.JSValueIsString(ctx, url_val)) return jsc.JSValueMakeUndefined(ctx);
    const url_js = jsc.JSValueToStringCopy(ctx, url_val, null);
    defer jsc.JSStringRelease(url_js);
    var url_buf: [2048]u8 = undefined;
    const n = jsc.JSStringGetUTF8CString(url_js, url_buf[0..].ptr, url_buf.len);
    if (n == 0) return jsc.JSValueMakeUndefined(ctx);
    const url_slice = url_buf[0 .. n - 1];
    const allocator = g_http2_allocator orelse globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const url_z = allocator.dupeZ(u8, url_slice) catch return jsc.JSValueMakeUndefined(ctx);
    const session = jsc.JSObjectMake(ctx, null, null);
    const k_url = jsc.JSStringCreateWithUTF8CString("__url");
    defer jsc.JSStringRelease(k_url);
    const url_str = jsc.JSStringCreateWithUTF8CString(url_z.ptr);
    defer jsc.JSStringRelease(url_str);
    _ = jsc.JSObjectSetProperty(ctx, session, k_url, jsc.JSValueMakeString(ctx, url_str), jsc.kJSPropertyAttributeNone, null);
    allocator.free(url_z);
    common.setMethod(ctx, session, "request", requestCallback);
    common.setMethod(ctx, session, "close", sessionCloseCallback);
    return session;
}

/// session.close([callback])：关闭会话；当前实现为无连接复用，close 为 no-op，若传 callback 则调用。
fn sessionCloseCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount >= 1) {
        const cb = arguments[0];
        const cb_obj = jsc.JSValueToObject(ctx, cb, null);
        if (cb_obj != null and jsc.JSObjectIsFunction(ctx, cb_obj.?)) {
            var no_args: [0]jsc.JSValueRef = .{};
            _ = jsc.JSObjectCallAsFunction(ctx, cb_obj.?, null, 0, &no_args, null);
        }
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// session.request([opts], callback)：发起单次 HTTP/2 GET，callback(err, response)。response 为 { statusCode, headers, body }。
/// 当前 opts 未使用（路径由 connect 时的 url 决定）；阻塞主线程执行。
fn requestCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const k_url = jsc.JSStringCreateWithUTF8CString("__url");
    defer jsc.JSStringRelease(k_url);
    const url_val = jsc.JSObjectGetProperty(ctx, this, k_url, null);
    if (jsc.JSValueIsUndefined(ctx, url_val) or !jsc.JSValueIsString(ctx, url_val)) return jsc.JSValueMakeUndefined(ctx);
    var url_buf: [2048]u8 = undefined;
    const url_js = jsc.JSValueToStringCopy(ctx, url_val, null);
    defer jsc.JSStringRelease(url_js);
    const n = jsc.JSStringGetUTF8CString(url_js, url_buf[0..].ptr, url_buf.len);
    if (n == 0) return jsc.JSValueMakeUndefined(ctx);
    const url_slice = url_buf[0 .. n - 1];

    const argc = argumentCount;
    const cb_val = if (argc >= 2) arguments[1] else arguments[0];
    const cb_obj = jsc.JSValueToObject(ctx, cb_val, null);
    if (cb_obj == null or !jsc.JSObjectIsFunction(ctx, cb_obj.?)) return jsc.JSValueMakeUndefined(ctx);

    const allocator = g_http2_allocator orelse globals.current_allocator orelse {
        const err = makeError(ctx, "no allocator".ptr);
        var two: [2]jsc.JSValueRef = .{ err, jsc.JSValueMakeUndefined(ctx) };
        _ = jsc.JSObjectCallAsFunction(ctx, cb_obj.?, this, 2, &two, null);
        return jsc.JSValueMakeUndefined(ctx);
    };

    const result = libs_io.http.requestH2(allocator, url_slice, .{ .method = .GET }) catch |e| {
        const err_name = @errorName(e);
        const err_obj = makeError(ctx, @ptrCast(err_name.ptr));
        var two: [2]jsc.JSValueRef = .{ err_obj, jsc.JSValueMakeUndefined(ctx) };
        _ = jsc.JSObjectCallAsFunction(ctx, cb_obj.?, this, 2, &two, null);
        return jsc.JSValueMakeUndefined(ctx);
    };
    defer {
        allocator.free(result.body);
        if (result.status_text_is_allocated) allocator.free(result.status_text);
    }

    const resp_obj = jsc.JSObjectMake(ctx, null, null);
    const k_status = jsc.JSStringCreateWithUTF8CString("statusCode");
    defer jsc.JSStringRelease(k_status);
    const k_headers = jsc.JSStringCreateWithUTF8CString("headers");
    defer jsc.JSStringRelease(k_headers);
    const k_body = jsc.JSStringCreateWithUTF8CString("body");
    defer jsc.JSStringRelease(k_body);
    _ = jsc.JSObjectSetProperty(ctx, resp_obj, k_status, jsc.JSValueMakeNumber(ctx, @floatFromInt(result.status)), jsc.kJSPropertyAttributeNone, null);
    const headers_obj = jsc.JSObjectMake(ctx, null, null);
    const k_content_type = jsc.JSStringCreateWithUTF8CString("content-type");
    defer jsc.JSStringRelease(k_content_type);
    if (result.content_encoding) |enc| {
        const k_ce = jsc.JSStringCreateWithUTF8CString("content-encoding");
        defer jsc.JSStringRelease(k_ce);
        const enc_js = jsc.JSStringCreateWithUTF8CString(enc.ptr);
        defer jsc.JSStringRelease(enc_js);
        _ = jsc.JSObjectSetProperty(ctx, headers_obj, k_ce, jsc.JSValueMakeString(ctx, enc_js), jsc.kJSPropertyAttributeNone, null);
    }
    _ = jsc.JSObjectSetProperty(ctx, resp_obj, k_headers, headers_obj, jsc.kJSPropertyAttributeNone, null);
    const body_js = if (result.body.len > 0)
        jsc.JSStringCreateWithUTF8CString(result.body.ptr)
    else
        jsc.JSStringCreateWithUTF8CString("");
    defer jsc.JSStringRelease(body_js);
    _ = jsc.JSObjectSetProperty(ctx, resp_obj, k_body, jsc.JSValueMakeString(ctx, body_js), jsc.kJSPropertyAttributeNone, null);

    var two: [2]jsc.JSValueRef = .{ jsc.JSValueMakeUndefined(ctx), resp_obj };
    _ = jsc.JSObjectCallAsFunction(ctx, cb_obj.?, this, 2, &two, null);
    return jsc.JSValueMakeUndefined(ctx);
}
