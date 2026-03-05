// shu:errors 内置：Node 风格系统错误类与错误码，供 require("shu:errors") / node:errors 兼容
// 导出 SystemError 构造函数与 errors.codes（ERR_* 及常见系统错误码），与 Node node:errors API 对齐

const std = @import("std");
const jsc = @import("jsc");

/// 从 options 对象读取字符串属性；若不存在或非字符串则返回 undefined。[Borrows] 返回值为 JSC 管理。
fn getOptionalStringFromObject(ctx: jsc.JSContextRef, obj: jsc.JSObjectRef, key: [*]const u8) jsc.JSValueRef {
    const k = jsc.JSStringCreateWithUTF8CString(key);
    defer jsc.JSStringRelease(k);
    const v = jsc.JSObjectGetProperty(ctx, obj, k, null);
    if (jsc.JSValueIsUndefined(ctx, v) or jsc.JSValueIsNull(ctx, v)) return jsc.JSValueMakeUndefined(ctx);
    if (!jsc.JSValueIsString(ctx, v)) return jsc.JSValueMakeUndefined(ctx);
    return v;
}

/// 从 options 对象读取数字属性；若不存在或为 null/undefined 则返回 undefined。调用方设置到 errno 时 JSC 会接受数值。
fn getOptionalNumberFromObject(ctx: jsc.JSContextRef, obj: jsc.JSObjectRef, key: [*]const u8) jsc.JSValueRef {
    const k = jsc.JSStringCreateWithUTF8CString(key);
    defer jsc.JSStringRelease(k);
    const v = jsc.JSObjectGetProperty(ctx, obj, k, null);
    if (jsc.JSValueIsUndefined(ctx, v) or jsc.JSValueIsNull(ctx, v)) return jsc.JSValueMakeUndefined(ctx);
    return v;
}

/// SystemError(message?, options?)：创建与 Node SystemError 兼容的实例（name/code/errno/syscall/path/dest）
fn systemErrorCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const message_js = if (argumentCount >= 1) arguments[0] else blk: {
        const empty = jsc.JSStringCreateWithUTF8CString("");
        defer jsc.JSStringRelease(empty);
        break :blk jsc.JSValueMakeString(ctx, empty);
    };
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_Error = jsc.JSStringCreateWithUTF8CString("Error");
    defer jsc.JSStringRelease(k_Error);
    const Error_ctor = jsc.JSObjectGetProperty(ctx, global, k_Error, null);
    const err_ctor_obj = jsc.JSValueToObject(ctx, Error_ctor, null) orelse return jsc.JSValueMakeUndefined(ctx);
    var exception: ?jsc.JSValueRef = null;
    var args: [1]jsc.JSValueRef = .{message_js};
    const err_instance = jsc.JSObjectCallAsConstructor(ctx, err_ctor_obj, 1, &args, @ptrCast(&exception));
    if (exception != null) return jsc.JSValueMakeUndefined(ctx);
    const err_obj = jsc.JSValueToObject(ctx, err_instance, null) orelse return jsc.JSValueMakeUndefined(ctx);

    const k_name = jsc.JSStringCreateWithUTF8CString("name");
    defer jsc.JSStringRelease(k_name);
    const v_name = jsc.JSStringCreateWithUTF8CString("SystemError");
    defer jsc.JSStringRelease(v_name);
    _ = jsc.JSObjectSetProperty(ctx, err_obj, k_name, jsc.JSValueMakeString(ctx, v_name), jsc.kJSPropertyAttributeNone, null);

    if (argumentCount >= 2) {
        const options = jsc.JSValueToObject(ctx, arguments[1], null);
        if (options != null) {
            const opts = options.?;
            const code = getOptionalStringFromObject(ctx, opts, "code");
            if (!jsc.JSValueIsUndefined(ctx, code)) {
                const k_code = jsc.JSStringCreateWithUTF8CString("code");
                defer jsc.JSStringRelease(k_code);
                _ = jsc.JSObjectSetProperty(ctx, err_obj, k_code, code, jsc.kJSPropertyAttributeNone, null);
            }
            const errno_v = getOptionalNumberFromObject(ctx, opts, "errno");
            if (!jsc.JSValueIsUndefined(ctx, errno_v)) {
                const k_errno = jsc.JSStringCreateWithUTF8CString("errno");
                defer jsc.JSStringRelease(k_errno);
                _ = jsc.JSObjectSetProperty(ctx, err_obj, k_errno, errno_v, jsc.kJSPropertyAttributeNone, null);
            }
            const syscall = getOptionalStringFromObject(ctx, opts, "syscall");
            if (!jsc.JSValueIsUndefined(ctx, syscall)) {
                const k_syscall = jsc.JSStringCreateWithUTF8CString("syscall");
                defer jsc.JSStringRelease(k_syscall);
                _ = jsc.JSObjectSetProperty(ctx, err_obj, k_syscall, syscall, jsc.kJSPropertyAttributeNone, null);
            }
            const path = getOptionalStringFromObject(ctx, opts, "path");
            if (!jsc.JSValueIsUndefined(ctx, path)) {
                const k_path = jsc.JSStringCreateWithUTF8CString("path");
                defer jsc.JSStringRelease(k_path);
                _ = jsc.JSObjectSetProperty(ctx, err_obj, k_path, path, jsc.kJSPropertyAttributeNone, null);
            }
            const dest = getOptionalStringFromObject(ctx, opts, "dest");
            if (!jsc.JSValueIsUndefined(ctx, dest)) {
                const k_dest = jsc.JSStringCreateWithUTF8CString("dest");
                defer jsc.JSStringRelease(k_dest);
                _ = jsc.JSObjectSetProperty(ctx, err_obj, k_dest, dest, jsc.kJSPropertyAttributeNone, null);
            }
        }
    }
    return err_instance;
}

/// 常见 Node ERR_* 与系统错误码（与 Node errors.codes 对齐，子集）
const ERROR_CODES = [_][]const u8{
    "ERR_INVALID_ARG_TYPE",
    "ERR_OUT_OF_RANGE",
    "ERR_STREAM_WRITE_AFTER_END",
    "ERR_METHOD_NOT_IMPLEMENTED",
    "ERR_INVALID_THIS",
    "ERR_UNSUPPORTED_ESM_URL_SCHEME",
    "ERR_UNSUPPORTED_RESOLVE_REQUEST",
    "ERR_SYNTHETIC",
    "ERR_ACCESS_DENIED",
    "ERR_ALREADY_EXISTS",
    "ERR_BUFFER_OUT_OF_BOUNDS",
    "ERR_CLOSED_MESSAGE_PORT",
    "ERR_CONSTRUCT_CALL_REQUIRED",
    "ERR_CRYPTO_CUSTOM_ENGINE_NOT_SUPPORTED",
    "ERR_INVALID_ARG_VALUE",
    "ERR_NO_CRYPTO",
    "ERR_OPERATION_FAILED",
    "E2BIG",
    "EACCES",
    "EADDRINUSE",
    "EADDRNOTAVAIL",
    "EAFNOSUPPORT",
    "EAGAIN",
    "EALREADY",
    "EBADF",
    "EBUSY",
    "ECANCELED",
    "ECHILD",
    "ECONNABORTED",
    "ECONNREFUSED",
    "ECONNRESET",
    "EDEADLK",
    "EDESTADDRREQ",
    "EDOM",
    "EEXIST",
    "EFAULT",
    "EFBIG",
    "EHOSTUNREACH",
    "EINTR",
    "EINVAL",
    "EIO",
    "EISDIR",
    "EISCONN",
    "ELOOP",
    "EMFILE",
    "EMLINK",
    "EMSGSIZE",
    "ENAMETOOLONG",
    "ENETDOWN",
    "ENETUNREACH",
    "ENFILE",
    "ENOBUFS",
    "ENODEV",
    "ENOENT",
    "ENOMEM",
    "ENOTDIR",
    "ENOTEMPTY",
    "ENOTSUP",
    "ENOTCONN",
    "ENOTSOCK",
    "EPERM",
    "EPIPE",
    "EPROTO",
    "EPROTONOSUPPORT",
    "EROFS",
    "ESPIPE",
    "ESRCH",
    "ETIMEDOUT",
    "ETXTBSY",
    "EWOULDBLOCK",
};

/// 创建 errors.codes 对象：每个 key 与 value 均为同名字符串。[Borrows] 返回值由 JSC 管理。
fn makeCodesObject(ctx: jsc.JSContextRef) jsc.JSValueRef {
    const codes_obj = jsc.JSObjectMake(ctx, null, null);
    for (ERROR_CODES) |code| {
        const k = jsc.JSStringCreateWithUTF8CString(code.ptr);
        defer jsc.JSStringRelease(k);
        const v_str = jsc.JSStringCreateWithUTF8CString(code.ptr);
        defer jsc.JSStringRelease(v_str);
        _ = jsc.JSObjectSetProperty(ctx, codes_obj, k, jsc.JSValueMakeString(ctx, v_str), jsc.kJSPropertyAttributeNone, null);
    }
    return codes_obj;
}

/// 返回 shu:errors 的 exports：SystemError、codes，与 Node node:errors API 兼容。[Borrows] 返回值由 JSC 管理。
pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    _ = allocator;
    const exports = jsc.JSObjectMake(ctx, null, null);
    const k_system_error = jsc.JSStringCreateWithUTF8CString("SystemError");
    defer jsc.JSStringRelease(k_system_error);
    const system_error_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_system_error, systemErrorCallback);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_system_error, system_error_fn, jsc.kJSPropertyAttributeNone, null);
    const k_codes = jsc.JSStringCreateWithUTF8CString("codes");
    defer jsc.JSStringRelease(k_codes);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_codes, makeCodesObject(ctx), jsc.kJSPropertyAttributeNone, null);
    return exports;
}
