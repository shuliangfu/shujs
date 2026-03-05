// 从 JS options 对象解析配置：getOptional*、clampSize、protect/unprotect WsOptions
// updateStateFromOptions 因依赖 ServerState 仍保留在 mod.zig，此处仅提供基础 getOptional* 供其调用

const jsc = @import("jsc");
const types = @import("types.zig");

/// 从 options 中读取可选字符串；若不存在或非字符串则返回 default_value；结果写入 buf
pub fn getOptionalString(ctx: jsc.JSContextRef, obj: jsc.JSObjectRef, key: [*]const u8, default_value: []const u8, buf: []u8) ?[]const u8 {
    const k = jsc.JSStringCreateWithUTF8CString(key);
    defer jsc.JSStringRelease(k);
    const v = jsc.JSObjectGetProperty(ctx, obj, k, null);
    if (jsc.JSValueIsUndefined(ctx, v)) return default_value;
    const js_str = jsc.JSValueToStringCopy(ctx, v, null);
    defer jsc.JSStringRelease(js_str);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(js_str);
    if (max_sz == 0 or max_sz > buf.len) return default_value;
    const n = jsc.JSStringGetUTF8CString(js_str, buf.ptr, max_sz);
    if (n == 0) return default_value;
    return buf[0 .. n - 1];
}

/// 将 size 限制在 [min_val, max_val] 范围内，用于缓冲/容量配置
pub fn clampSize(val: u32, min_val: usize, max_val: usize) usize {
    const v = @as(usize, val);
    if (v < min_val) return min_val;
    if (v > max_val) return max_val;
    return v;
}

/// 从 options.webSocket 对象中取可选数字；若 webSocket 不存在或 key 不存在/非数字则返回 default_val
pub fn getOptionalNumberFromWebSocket(ctx: jsc.JSContextRef, options_obj: jsc.JSObjectRef, key: [*]const u8, default_val: u32) u32 {
    const k_ws = jsc.JSStringCreateWithUTF8CString("webSocket");
    defer jsc.JSStringRelease(k_ws);
    const v = jsc.JSObjectGetProperty(ctx, options_obj, k_ws, null);
    if (jsc.JSValueIsUndefined(ctx, v)) return default_val;
    const obj = jsc.JSValueToObject(ctx, v, null) orelse return default_val;
    return getOptionalNumber(ctx, obj, key, default_val);
}

/// 从 options 中取可选数字；若不存在或非数字则返回 default_val
pub fn getOptionalNumber(ctx: jsc.JSContextRef, obj: jsc.JSObjectRef, key: [*]const u8, default_val: u32) u32 {
    const k = jsc.JSStringCreateWithUTF8CString(key);
    defer jsc.JSStringRelease(k);
    const v = jsc.JSObjectGetProperty(ctx, obj, k, null);
    if (jsc.JSValueIsUndefined(ctx, v)) return default_val;
    const n = jsc.JSValueToNumber(ctx, v, null);
    if (n != n or n < 0) return default_val;
    return @intFromFloat(n);
}

/// 从 options 中取可选数字；若 key 不存在或非数字则返回 null，用于表示「未设置」（如 linuxSqThreadCpu）
pub fn getOptionalNumberOptional(ctx: jsc.JSContextRef, obj: jsc.JSObjectRef, key: [*]const u8) ?u32 {
    const k = jsc.JSStringCreateWithUTF8CString(key);
    defer jsc.JSStringRelease(k);
    const v = jsc.JSObjectGetProperty(ctx, obj, k, null);
    if (jsc.JSValueIsUndefined(ctx, v)) return null;
    const n = jsc.JSValueToNumber(ctx, v, null);
    if (n != n or n < 0) return null;
    return @intFromFloat(n);
}

/// 从 options 中取可选布尔；若不存在或非布尔则返回 false
pub fn getOptionalBool(ctx: jsc.JSContextRef, obj: jsc.JSObjectRef, key: [*]const u8) bool {
    const k = jsc.JSStringCreateWithUTF8CString(key);
    defer jsc.JSStringRelease(k);
    const v = jsc.JSObjectGetProperty(ctx, obj, k, null);
    if (jsc.JSValueIsUndefined(ctx, v)) return false;
    return jsc.JSValueToBoolean(ctx, v);
}

/// 从 options 中取可选布尔；若 key 不存在则返回 default_value，存在则按 JS 值转布尔
pub fn getOptionalBoolDefault(ctx: jsc.JSContextRef, obj: jsc.JSObjectRef, key: [*]const u8, default_value: bool) bool {
    const k = jsc.JSStringCreateWithUTF8CString(key);
    defer jsc.JSStringRelease(k);
    const v = jsc.JSObjectGetProperty(ctx, obj, k, null);
    if (jsc.JSValueIsUndefined(ctx, v)) return default_value;
    return jsc.JSValueToBoolean(ctx, v);
}

/// 从 options 中取指定名的可选回调（若存在且为函数则返回其 JSValueRef）
/// 必须先 JSValueToObject 再调 JSObjectIsFunction，否则 JSC 的 tagged 值被当指针会 segfault。
pub fn getOptionalCallback(ctx: jsc.JSContextRef, options_obj: jsc.JSObjectRef, key: [*]const u8) ?jsc.JSValueRef {
    const k_ref = jsc.JSStringCreateWithUTF8CString(key);
    defer jsc.JSStringRelease(k_ref);
    const v = jsc.JSObjectGetProperty(ctx, options_obj, k_ref, null);
    if (jsc.JSValueIsUndefined(ctx, v) or jsc.JSValueIsNull(ctx, v)) return null;
    const obj = jsc.JSValueToObject(ctx, v, null);
    if (obj == null or !jsc.JSObjectIsFunction(ctx, obj.?)) return null;
    return v;
}

/// 从 options 中取 options.signal（AbortSignal）；若存在且为对象则返回其 JSValueRef
pub fn getOptionalAbortSignal(ctx: jsc.JSContextRef, options_obj: jsc.JSObjectRef) ?jsc.JSValueRef {
    const k = jsc.JSStringCreateWithUTF8CString("signal");
    defer jsc.JSStringRelease(k);
    const v = jsc.JSObjectGetProperty(ctx, options_obj, k, null);
    if (jsc.JSValueIsUndefined(ctx, v)) return null;
    if (jsc.JSValueToObject(ctx, v, null) == null) return null;
    return v;
}

/// 判断 AbortSignal 是否已触发（读取 signal.aborted）
pub fn isSignalAborted(ctx: jsc.JSContextRef, signal_ref: jsc.JSValueRef) bool {
    const obj = jsc.JSValueToObject(ctx, signal_ref, null) orelse return false;
    const k = jsc.JSStringCreateWithUTF8CString("aborted");
    defer jsc.JSStringRelease(k);
    const v = jsc.JSObjectGetProperty(ctx, obj, k, null);
    return jsc.JSValueToBoolean(ctx, v);
}

/// 保护 WsOptions 内所有 JS 引用，避免被 GC 回收
pub fn protectWsOptions(ctx: jsc.JSContextRef, opts: *const types.WsOptions) void {
    if (opts.on_open) |v| jsc.JSValueProtect(ctx, v);
    jsc.JSValueProtect(ctx, opts.on_message);
    if (opts.on_close) |v| jsc.JSValueProtect(ctx, v);
    if (opts.on_error) |v| jsc.JSValueProtect(ctx, v);
}

/// 取消保护 WsOptions 内所有 JS 引用（reload/stop 时调用）
pub fn unprotectWsOptions(ctx: jsc.JSContextRef, opts: *const types.WsOptions) void {
    if (opts.on_open) |v| jsc.JSValueUnprotect(ctx, v);
    jsc.JSValueUnprotect(ctx, opts.on_message);
    if (opts.on_close) |v| jsc.JSValueUnprotect(ctx, v);
    if (opts.on_error) |v| jsc.JSValueUnprotect(ctx, v);
}

/// 从 options 中取 options.tls: { cert, key }（证书与私钥文件路径），写入 cert_buf/key_buf，返回切片；否则返回 null
pub fn getOptionalTlsOptions(
    ctx: jsc.JSContextRef,
    options_obj: jsc.JSObjectRef,
    cert_buf: []u8,
    key_buf: []u8,
) ?struct { cert: []const u8, key: []const u8 } {
    const k_tls = jsc.JSStringCreateWithUTF8CString("tls");
    defer jsc.JSStringRelease(k_tls);
    const tls_val = jsc.JSObjectGetProperty(ctx, options_obj, k_tls, null);
    if (jsc.JSValueIsUndefined(ctx, tls_val)) return null;
    const tls_obj = jsc.JSValueToObject(ctx, tls_val, null) orelse return null;
    const cert_slice = getOptionalString(ctx, tls_obj, "cert", "", cert_buf) orelse return null;
    const key_slice = getOptionalString(ctx, tls_obj, "key", "", key_buf) orelse return null;
    if (cert_slice.len == 0 or key_slice.len == 0) return null;
    return .{ .cert = cert_slice, .key = key_slice };
}

/// 从 options 中取 options.webSocket: { onOpen?, onMessage, onClose?, onError? }；onMessage 必填且为函数
pub fn getOptionalWebSocket(ctx: jsc.JSContextRef, options_obj: jsc.JSObjectRef) ?types.WsOptions {
    const k_ws = jsc.JSStringCreateWithUTF8CString("webSocket");
    defer jsc.JSStringRelease(k_ws);
    const v = jsc.JSObjectGetProperty(ctx, options_obj, k_ws, null);
    if (jsc.JSValueIsUndefined(ctx, v)) return null;
    const obj = jsc.JSValueToObject(ctx, v, null) orelse return null;
    const k_msg = jsc.JSStringCreateWithUTF8CString("onMessage");
    defer jsc.JSStringRelease(k_msg);
    const on_msg = jsc.JSObjectGetProperty(ctx, obj, k_msg, null);
    const on_msg_obj = jsc.JSValueToObject(ctx, on_msg, null);
    if (on_msg_obj == null or !jsc.JSObjectIsFunction(ctx, on_msg_obj.?)) return null;
    const k_open = jsc.JSStringCreateWithUTF8CString("onOpen");
    defer jsc.JSStringRelease(k_open);
    const k_close = jsc.JSStringCreateWithUTF8CString("onClose");
    defer jsc.JSStringRelease(k_close);
    const k_err = jsc.JSStringCreateWithUTF8CString("onError");
    defer jsc.JSStringRelease(k_err);
    const on_open = jsc.JSObjectGetProperty(ctx, obj, k_open, null);
    const on_close = jsc.JSObjectGetProperty(ctx, obj, k_close, null);
    const on_error = jsc.JSObjectGetProperty(ctx, obj, k_err, null);
    const on_open_obj = jsc.JSValueToObject(ctx, on_open, null);
    const on_close_obj = jsc.JSValueToObject(ctx, on_close, null);
    const on_error_obj = jsc.JSValueToObject(ctx, on_error, null);
    return .{
        .on_open = if (on_open_obj != null and jsc.JSObjectIsFunction(ctx, on_open_obj.?)) on_open else null,
        .on_message = on_msg,
        .on_close = if (on_close_obj != null and jsc.JSObjectIsFunction(ctx, on_close_obj.?)) on_close else null,
        .on_error = if (on_error_obj != null and jsc.JSObjectIsFunction(ctx, on_error_obj.?)) on_error else null,
    };
}

/// 从 options 中取 options.fetch 或 options.handler，且为函数则返回其 JSValueRef。
/// 仅当值非 undefined/null 时才调用 JSValueToObject，避免对原始类型调用导致崩溃。
pub fn getHandlerFromOptions(ctx: jsc.JSContextRef, options_obj: jsc.JSObjectRef) ?jsc.JSValueRef {
    const k_fetch = jsc.JSStringCreateWithUTF8CString("fetch");
    defer jsc.JSStringRelease(k_fetch);
    const k_handler = jsc.JSStringCreateWithUTF8CString("handler");
    defer jsc.JSStringRelease(k_handler);
    const fetch_val = jsc.JSObjectGetProperty(ctx, options_obj, k_fetch, null);
    if (!jsc.JSValueIsUndefined(ctx, fetch_val) and !jsc.JSValueIsNull(ctx, fetch_val)) {
        const fetch_obj = jsc.JSValueToObject(ctx, fetch_val, null);
        if (fetch_obj != null and jsc.JSObjectIsFunction(ctx, fetch_obj.?)) return fetch_val;
    }
    const handler_val = jsc.JSObjectGetProperty(ctx, options_obj, k_handler, null);
    if (!jsc.JSValueIsUndefined(ctx, handler_val) and !jsc.JSValueIsNull(ctx, handler_val)) {
        const handler_obj = jsc.JSValueToObject(ctx, handler_val, null);
        if (handler_obj != null and jsc.JSObjectIsFunction(ctx, handler_obj.?)) return handler_val;
    }
    return null;
}
