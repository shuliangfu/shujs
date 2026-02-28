// shu:tls — Node 风格 API：createSecureContext(options)、createServer(options, secureConnectionListener)
// createServer 与 shu:https 一致，内部调 Shu.server 的 options.tls；secureConnectionListener 收到 (req, res) 即 HTTPS 请求

const std = @import("std");
const build_options = @import("build_options");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");
const shu_http = @import("../http/mod.zig");
const shu_net = @import("../net/mod.zig");
const tls_native = @import("tls");

/// Node 兼容常量：默认加密套件字符串（占位，与 node:tls 形参兼容）
const DEFAULT_CIPHERS = "TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256:TLS_AES_128_GCM_SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384";

/// §1.1 显式 allocator 收敛：getExports 时注入，回调内优先使用
threadlocal var g_tls_allocator: ?std.mem.Allocator = null;

/// 返回 shu:tls 的 exports：createSecureContext、createServer、getCiphers、常量（与 node:tls 对齐）
pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    g_tls_allocator = allocator;
    shu_http.ensureAdaptInjected(ctx, allocator);
    const tls_obj = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, tls_obj, "createSecureContext", createSecureContextCallback);
    common.setMethod(ctx, tls_obj, "createServer", createServerCallback);
    common.setMethod(ctx, tls_obj, "connect", tlsConnectCallback);
    common.setMethod(ctx, tls_obj, "getCiphers", getCiphersCallback);
    const k_ciphers = jsc.JSStringCreateWithUTF8CString("DEFAULT_CIPHERS");
    defer jsc.JSStringRelease(k_ciphers);
    const ciphers_js = jsc.JSStringCreateWithUTF8CString(DEFAULT_CIPHERS);
    defer jsc.JSStringRelease(ciphers_js);
    _ = jsc.JSObjectSetProperty(ctx, tls_obj, k_ciphers, jsc.JSValueMakeString(ctx, ciphers_js), jsc.kJSPropertyAttributeNone, null);
    return tls_obj;
}

/// getCiphers()：返回当前支持的加密套件名称数组（Node 兼容；当前返回占位列表）
fn getCiphersCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const names = [_][]const u8{ "TLS_AES_256_GCM_SHA384", "TLS_CHACHA20_POLY1305_SHA256", "TLS_AES_128_GCM_SHA256", "ECDHE-RSA-AES128-GCM-SHA256", "ECDHE-RSA-AES256-GCM-SHA384" };
    var vals: [5]jsc.JSValueRef = undefined;
    for (names, &vals) |name, *v| {
        const js_str = jsc.JSStringCreateWithUTF8CString(name.ptr);
        v.* = jsc.JSValueMakeString(ctx, js_str);
        jsc.JSStringRelease(js_str);
    }
    return jsc.JSObjectMakeArray(ctx, 5, &vals, null);
}

/// createSecureContext(options)：从 options.key / options.cert（文件路径）创建上下文对象，供 createServer 使用；兼容 options.ca、options.ciphers（可存或忽略）；编译时未启用 TLS 则返回带 __stub 的占位对象
fn createSecureContextCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const options = arguments[0];
    const options_obj = jsc.JSValueToObject(ctx, options, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const context_obj = jsc.JSObjectMake(ctx, null, null);
    if (!build_options.have_tls) {
        const k_stub = jsc.JSStringCreateWithUTF8CString("__stub");
        defer jsc.JSStringRelease(k_stub);
        _ = jsc.JSObjectSetProperty(ctx, context_obj, k_stub, jsc.JSValueMakeBoolean(ctx, true), jsc.kJSPropertyAttributeNone, null);
        return context_obj;
    }
    var cert_buf: [512]u8 = undefined;
    var key_buf: [512]u8 = undefined;
    var ca_buf: [512]u8 = undefined;
    var ciphers_buf: [256]u8 = undefined;
    if (getOptStr(ctx, options_obj, "ca", &ca_buf)) |_| {
        const k_ca_opt = jsc.JSStringCreateWithUTF8CString("ca");
        defer jsc.JSStringRelease(k_ca_opt);
        const ca_val = jsc.JSObjectGetProperty(ctx, options_obj, k_ca_opt, null);
        const k_ca = jsc.JSStringCreateWithUTF8CString("_ca");
        defer jsc.JSStringRelease(k_ca);
        _ = jsc.JSObjectSetProperty(ctx, context_obj, k_ca, ca_val, jsc.kJSPropertyAttributeNone, null);
    }
    if (getOptStr(ctx, options_obj, "ciphers", &ciphers_buf)) |_| {
        const k_ciphers_opt = jsc.JSStringCreateWithUTF8CString("ciphers");
        defer jsc.JSStringRelease(k_ciphers_opt);
        const v = jsc.JSObjectGetProperty(ctx, options_obj, k_ciphers_opt, null);
        const k_c = jsc.JSStringCreateWithUTF8CString("_ciphers");
        defer jsc.JSStringRelease(k_c);
        _ = jsc.JSObjectSetProperty(ctx, context_obj, k_c, v, jsc.kJSPropertyAttributeNone, null);
    }
    const cert_slice = getOptStr(ctx, options_obj, "cert", &cert_buf);
    const key_slice = getOptStr(ctx, options_obj, "key", &key_buf);
    if (cert_slice == null or key_slice == null) return context_obj;
    const k_cert = jsc.JSStringCreateWithUTF8CString("_cert");
    defer jsc.JSStringRelease(k_cert);
    const k_key = jsc.JSStringCreateWithUTF8CString("_key");
    defer jsc.JSStringRelease(k_key);
    const allocator = g_tls_allocator orelse globals.current_allocator orelse return context_obj;
    const cert_dup = allocator.dupeZ(u8, cert_slice.?) catch return context_obj;
    defer allocator.free(cert_dup);
    const key_dup = allocator.dupeZ(u8, key_slice.?) catch return context_obj;
    defer allocator.free(key_dup);
    const cert_js = jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(cert_dup.ptr));
    const key_js = jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(key_dup.ptr));
    _ = jsc.JSObjectSetProperty(ctx, context_obj, k_cert, cert_js, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, context_obj, k_key, key_js, jsc.kJSPropertyAttributeNone, null);
    return context_obj;
}

fn getOptStr(ctx: jsc.JSContextRef, obj: jsc.JSObjectRef, key: [*]const u8, buf: []u8) ?[]const u8 {
    const k = jsc.JSStringCreateWithUTF8CString(key);
    defer jsc.JSStringRelease(k);
    const v = jsc.JSObjectGetProperty(ctx, obj, k, null);
    if (jsc.JSValueIsUndefined(ctx, v)) return null;
    const js_str = jsc.JSValueToStringCopy(ctx, v, null);
    defer jsc.JSStringRelease(js_str);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(js_str);
    if (max_sz == 0 or max_sz > buf.len) return null;
    const n = jsc.JSStringGetUTF8CString(js_str, buf.ptr, buf.len);
    if (n == 0) return null;
    return buf[0 .. n - 1];
}

/// tls.connect 的包装回调：TCP 连接建立后做客户端 TLS 握手并调用用户 callback(null, socket) 或 callback(err)
fn tlsConnectWrapperCallback(
    ctx: jsc.JSContextRef,
    wrapper: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const err_val = arguments[0];
    const socket_val = arguments[1];
    const k_cb = jsc.JSStringCreateWithUTF8CString("_tlsConnectCb");
    defer jsc.JSStringRelease(k_cb);
    const k_opts = jsc.JSStringCreateWithUTF8CString("_tlsConnectOpts");
    defer jsc.JSStringRelease(k_opts);
    const user_cb = jsc.JSObjectGetProperty(ctx, wrapper, k_cb, null);
    const opts_val = jsc.JSObjectGetProperty(ctx, wrapper, k_opts, null);
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(user_cb))) return jsc.JSValueMakeUndefined(ctx);
    if (!jsc.JSValueIsNull(ctx, err_val) or jsc.JSValueIsUndefined(ctx, socket_val)) {
        var args = [_]jsc.JSValueRef{ err_val, socket_val };
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(user_cb), null, 2, &args, null);
        return jsc.JSValueMakeUndefined(ctx);
    }
    if (!build_options.have_tls) {
        var args = [_]jsc.JSValueRef{ err_val, socket_val };
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(user_cb), null, 2, &args, null);
        return jsc.JSValueMakeUndefined(ctx);
    }
    const socket_obj = jsc.JSValueToObject(ctx, socket_val, null) orelse {
        var args = [_]jsc.JSValueRef{ err_val, socket_val };
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(user_cb), null, 2, &args, null);
        return jsc.JSValueMakeUndefined(ctx);
    };
    const k_sid = jsc.JSStringCreateWithUTF8CString("_socketId");
    defer jsc.JSStringRelease(k_sid);
    const sid_val = jsc.JSObjectGetProperty(ctx, socket_obj, k_sid, null);
    const sid_n = jsc.JSValueToNumber(ctx, sid_val, null);
    if (sid_n != sid_n or sid_n < 0) {
        var args = [_]jsc.JSValueRef{ err_val, socket_val };
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(user_cb), null, 2, &args, null);
        return jsc.JSValueMakeUndefined(ctx);
    }
    const socket_id = @as(u32, @intFromFloat(sid_n));
    const stream = shu_net.getStreamById(socket_id) orelse {
        var args = [_]jsc.JSValueRef{ err_val, socket_val };
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(user_cb), null, 2, &args, null);
        return jsc.JSValueMakeUndefined(ctx);
    };
    const allocator = g_tls_allocator orelse globals.current_allocator orelse {
        var args = [_]jsc.JSValueRef{ err_val, socket_val };
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(user_cb), null, 2, &args, null);
        return jsc.JSValueMakeUndefined(ctx);
    };
    var ca_buf: [512]u8 = undefined;
    var servername_buf: [256]u8 = undefined;
    const opts_obj = jsc.JSValueToObject(ctx, opts_val, null);
    const ca_path: ?[]const u8 = if (opts_obj != null) getOptStr(ctx, opts_obj.?, "ca", &ca_buf) else null;
    const servername_slice: ?[]const u8 = if (opts_obj != null) getOptStr(ctx, opts_obj.?, "servername", &servername_buf) else null;
    var verify_peer = true;
    if (opts_obj != null) {
        const k_reject = jsc.JSStringCreateWithUTF8CString("rejectUnauthorized");
        defer jsc.JSStringRelease(k_reject);
        const v = jsc.JSObjectGetProperty(ctx, opts_obj.?, k_reject, null);
        if (!jsc.JSValueIsUndefined(ctx, v)) verify_peer = jsc.JSValueToBoolean(ctx, v);
    }
    var client_ctx = tls_native.TlsClientContext.create(allocator, ca_path, verify_peer) orelse {
        const k_err = jsc.JSStringCreateWithUTF8CString("Error");
        defer jsc.JSStringRelease(k_err);
        const global = jsc.JSContextGetGlobalObject(ctx);
        const ErrCtor = jsc.JSObjectGetProperty(ctx, global, k_err, null);
        const msg = jsc.JSStringCreateWithUTF8CString("TLS client context creation failed");
        defer jsc.JSStringRelease(msg);
        var err_obj_args = [_]jsc.JSValueRef{jsc.JSValueMakeString(ctx, msg)};
        const err_obj = jsc.JSObjectCallAsConstructor(ctx, @ptrCast(ErrCtor), 1, &err_obj_args, null);
        var args = [_]jsc.JSValueRef{ err_obj, jsc.JSValueMakeUndefined(ctx) };
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(user_cb), null, 2, &args, null);
        return jsc.JSValueMakeUndefined(ctx);
    };
    defer client_ctx.destroy();
    const tls_stream = tls_native.TlsStream.connect(stream, &client_ctx, servername_slice, allocator) catch |e| {
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "TLS handshake failed: {s}", .{@errorName(e)}) catch "TLS handshake failed";
        // 栈上构造以 null 结尾的字符串，避免在错误路径上分配
        const buf_ptr: [*]const u8 = @ptrCast(&msg_buf);
        const msg_z_ptr: [*]const u8 = if (msg.ptr == buf_ptr) blk: {
            if (msg.len < msg_buf.len) msg_buf[msg.len] = 0;
            break :blk buf_ptr;
        } else @ptrCast("TLS handshake failed");
        const k_err = jsc.JSStringCreateWithUTF8CString("Error");
        defer jsc.JSStringRelease(k_err);
        const global = jsc.JSContextGetGlobalObject(ctx);
        const ErrCtor = jsc.JSObjectGetProperty(ctx, global, k_err, null);
        const js_msg = jsc.JSStringCreateWithUTF8CString(msg_z_ptr);
        defer jsc.JSStringRelease(js_msg);
        var err_obj_args = [_]jsc.JSValueRef{jsc.JSValueMakeString(ctx, js_msg)};
        const err_obj = jsc.JSObjectCallAsConstructor(ctx, @ptrCast(ErrCtor), 1, &err_obj_args, null);
        var args = [_]jsc.JSValueRef{ err_obj, jsc.JSValueMakeUndefined(ctx) };
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(user_cb), null, 2, &args, null);
        return jsc.JSValueMakeUndefined(ctx);
    };
    const box = allocator.create(tls_native.TlsStream) catch {
        @constCast(&tls_stream).close();
        var args = [_]jsc.JSValueRef{ err_val, socket_val };
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(user_cb), null, 2, &args, null);
        return jsc.JSValueMakeUndefined(ctx);
    };
    box.* = tls_stream;
    shu_net.setSocketTls(socket_id, box);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_null = jsc.JSStringCreateWithUTF8CString("null");
    defer jsc.JSStringRelease(k_null);
    const null_val = jsc.JSObjectGetProperty(ctx, global, k_null, null);
    var args = [_]jsc.JSValueRef{ null_val, socket_val };
    _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(user_cb), null, 2, &args, null);
    return jsc.JSValueMakeUndefined(ctx);
}

/// tls.connect(options[, callback]) / tls.connect(port[, host][, options][, callback])：Node 兼容；先 net.createConnection，连接建立后在回调中做 TLS 客户端握手并升级 socket，再调用户 callback(null, socket)
fn tlsConnectCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const allocator = g_tls_allocator orelse globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const net_exports = shu_net.getExports(ctx, allocator);
    const k_connect = jsc.JSStringCreateWithUTF8CString("createConnection");
    defer jsc.JSStringRelease(k_connect);
    const connect_fn = jsc.JSObjectGetProperty(ctx, net_exports, k_connect, null);
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(connect_fn))) return jsc.JSValueMakeUndefined(ctx);
    const user_cb = if (argumentCount >= 1 and jsc.JSObjectIsFunction(ctx, @ptrCast(arguments[argumentCount - 1]))) arguments[argumentCount - 1] else null;
    if (user_cb == null) return jsc.JSValueMakeUndefined(ctx);
    const k_wrapper = jsc.JSStringCreateWithUTF8CString("__tlsConnectWrapper");
    defer jsc.JSStringRelease(k_wrapper);
    const wrapper = jsc.JSObjectMakeFunctionWithCallback(ctx, k_wrapper, tlsConnectWrapperCallback);
    const wrapper_obj = jsc.JSValueToObject(ctx, wrapper, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const k_cb = jsc.JSStringCreateWithUTF8CString("_tlsConnectCb");
    defer jsc.JSStringRelease(k_cb);
    const k_opts = jsc.JSStringCreateWithUTF8CString("_tlsConnectOpts");
    defer jsc.JSStringRelease(k_opts);
    _ = jsc.JSObjectSetProperty(ctx, wrapper_obj, k_cb, user_cb.?, jsc.kJSPropertyAttributeNone, null);
    const opts_val = if (argumentCount >= 2 and (jsc.JSValueToObject(ctx, arguments[0], null) != null) and !jsc.JSObjectIsFunction(ctx, @ptrCast(arguments[0]))) arguments[0] else if (argumentCount >= 4) arguments[2] else arguments[0];
    _ = jsc.JSObjectSetProperty(ctx, wrapper_obj, k_opts, opts_val, jsc.kJSPropertyAttributeNone, null);
    var args = allocator.alloc(jsc.JSValueRef, argumentCount) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(args);
    for (arguments[0..argumentCount], args) |src, *dst| dst.* = src;
    args[argumentCount - 1] = wrapper;
    return jsc.JSObjectCallAsFunction(ctx, @ptrCast(connect_fn), null, argumentCount, args.ptr, null);
}

/// createServer(options, secureConnectionListener)：options 为 { key, cert } 或 { secureContext }；兼容 requestCert、rejectUnauthorized 等（存于 _tlsOptions）；listen 时与 HTTPS 相同
fn createServerCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const options = arguments[0];
    const secureConnectionListener = arguments[1];
    if (jsc.JSValueToObject(ctx, options, null) == null or !jsc.JSObjectIsFunction(ctx, @ptrCast(secureConnectionListener)))
        return jsc.JSValueMakeUndefined(ctx);
    const server = jsc.JSObjectMake(ctx, null, null);
    const k_listener = jsc.JSStringCreateWithUTF8CString("_requestListener");
    defer jsc.JSStringRelease(k_listener);
    const k_opts = jsc.JSStringCreateWithUTF8CString("_tlsOptions");
    defer jsc.JSStringRelease(k_opts);
    _ = jsc.JSObjectSetProperty(ctx, server, k_listener, secureConnectionListener, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, server, k_opts, options, jsc.kJSPropertyAttributeNone, null);
    common.setMethod(ctx, server, "listen", listenTlsCallback);
    return server;
}

/// server.listen(port[, host][, callback])：从 _tlsOptions 或 _tlsOptions.secureContext 取 key/cert，写入 opts.tls 后调 Shu.server（与 HTTPS 一致）
fn listenTlsCallback(
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
    const port_n = jsc.JSValueToNumber(ctx, arguments[0], null);
    if (port_n != port_n or port_n < 1 or port_n > 65535) return jsc.JSValueMakeUndefined(ctx);
    const port = @as(u16, @intFromFloat(port_n));
    const allocator = g_tls_allocator orelse globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
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
    const k_opts = jsc.JSStringCreateWithUTF8CString("_tlsOptions");
    defer jsc.JSStringRelease(k_opts);
    const tls_opts_val = jsc.JSObjectGetProperty(ctx, this, k_opts, null);
    const tls_opts_obj = jsc.JSValueToObject(ctx, tls_opts_val, null);
    if (tls_opts_obj != null) {
        var key_cert: struct { key: jsc.JSValueRef, cert: jsc.JSValueRef } = .{ .key = jsc.JSValueMakeUndefined(ctx), .cert = jsc.JSValueMakeUndefined(ctx) };
        const k_key = jsc.JSStringCreateWithUTF8CString("key");
        defer jsc.JSStringRelease(k_key);
        const k_cert = jsc.JSStringCreateWithUTF8CString("cert");
        defer jsc.JSStringRelease(k_cert);
        const k_ctx = jsc.JSStringCreateWithUTF8CString("secureContext");
        defer jsc.JSStringRelease(k_ctx);
        const key_direct = jsc.JSObjectGetProperty(ctx, tls_opts_obj.?, k_key, null);
        const cert_direct = jsc.JSObjectGetProperty(ctx, tls_opts_obj.?, k_cert, null);
        if (!jsc.JSValueIsUndefined(ctx, key_direct) and !jsc.JSValueIsUndefined(ctx, cert_direct)) {
            key_cert.key = key_direct;
            key_cert.cert = cert_direct;
        } else {
            const ctx_val = jsc.JSObjectGetProperty(ctx, tls_opts_obj.?, k_ctx, null);
            const ctx_obj = jsc.JSValueToObject(ctx, ctx_val, null);
            if (ctx_obj != null) {
                const k_k = jsc.JSStringCreateWithUTF8CString("_key");
                defer jsc.JSStringRelease(k_k);
                const k_c = jsc.JSStringCreateWithUTF8CString("_cert");
                defer jsc.JSStringRelease(k_c);
                key_cert.key = jsc.JSObjectGetProperty(ctx, ctx_obj.?, k_k, null);
                key_cert.cert = jsc.JSObjectGetProperty(ctx, ctx_obj.?, k_c, null);
            }
        }
        if (!jsc.JSValueIsUndefined(ctx, key_cert.key) and !jsc.JSValueIsUndefined(ctx, key_cert.cert)) {
            const tls_obj = jsc.JSObjectMake(ctx, null, null);
            _ = jsc.JSObjectSetProperty(ctx, tls_obj, k_key, key_cert.key, jsc.kJSPropertyAttributeNone, null);
            _ = jsc.JSObjectSetProperty(ctx, tls_obj, k_cert, key_cert.cert, jsc.kJSPropertyAttributeNone, null);
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
        var cb_args = [_]jsc.JSValueRef{jsc.JSValueMakeUndefined(ctx)};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(arguments[2]), this, 1, &cb_args, null);
    }
    return this;
}
