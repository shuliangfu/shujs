// shu:tty — 与 node:tty API 兼容，纯 Zig 实现
//
// ========== API 兼容情况 ==========
//
// | API | 兼容 | 说明 |
// |-----|------|------|
// | isTTY(fd?) | ✅ 已实现 | fd 缺省为 1(stdout)；0/1/2 用 isatty() 判断是否 TTY |
// | ReadStream(fd?) | ✅ 已实现 | 返回 { fd, isTTY, read(), ... } 占位；fd 缺省 0 |
// | WriteStream(fd?) | ✅ 已实现 | 返回 { fd, isTTY, write(), ... } 占位；fd 缺省 1 |
//
// 读写方法为占位（调用抛 Not implemented），isTTY 为真实检测。

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");

/// 根据 fd (0/1/2) 检测是否 TTY；非 POSIX 或非 0/1/2 返回 false
fn isFdTty(fd: i32) bool {
    if (fd != 0 and fd != 1 and fd != 2) return false;
    return std.c.isatty(@intCast(fd)) != 0;
}

/// isTTY(fd?)：缺省 fd=1；返回 boolean
fn isTTYCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    var fd: i32 = 1;
    if (argumentCount >= 1) {
        const n = jsc.JSValueToNumber(ctx, arguments[0], null);
        if (n == n) fd = @intFromFloat(n);
    }
    return jsc.JSValueMakeBoolean(ctx, isFdTty(fd));
}

/// 创建流对象（ReadStream/WriteStream）：设置 fd、isTTY 属性，并挂 read/write 占位方法
fn makeStreamObject(ctx: jsc.JSContextRef, fd: i32) jsc.JSValueRef {
    const obj = jsc.JSObjectMake(ctx, null, null);
    const k_fd = jsc.JSStringCreateWithUTF8CString("fd");
    defer jsc.JSStringRelease(k_fd);
    const k_isTTY = jsc.JSStringCreateWithUTF8CString("isTTY");
    defer jsc.JSStringRelease(k_isTTY);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_fd, jsc.JSValueMakeNumber(ctx, @floatFromInt(fd)), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_isTTY, jsc.JSValueMakeBoolean(ctx, isFdTty(fd)), jsc.kJSPropertyAttributeNone, null);
    common.setMethod(ctx, obj, "read", streamNotImplementedCallback);
    common.setMethod(ctx, obj, "write", streamNotImplementedCallback);
    common.setMethod(ctx, obj, "resume", streamNotImplementedCallback);
    common.setMethod(ctx, obj, "pause", streamNotImplementedCallback);
    common.setMethod(ctx, obj, "setRawMode", streamNotImplementedCallback);
    return obj;
}

fn streamNotImplementedCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_err = jsc.JSStringCreateWithUTF8CString("Error");
    defer jsc.JSStringRelease(k_err);
    const err_ctor = jsc.JSObjectGetProperty(ctx, global, k_err, null);
    const err_obj = jsc.JSValueToObject(ctx, err_ctor, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const msg = jsc.JSStringCreateWithUTF8CString("shu:tty ReadStream/WriteStream read/write/setRawMode not implemented");
    defer jsc.JSStringRelease(msg);
    var args = [_]jsc.JSValueRef{jsc.JSValueMakeString(ctx, msg)};
    var exception: ?jsc.JSValueRef = null;
    const err_instance = jsc.JSObjectCallAsConstructor(ctx, err_obj, 1, &args, @ptrCast(&exception));
    if (exception != null) return jsc.JSValueMakeUndefined(ctx);
    _ = common.setThrowAndThrow(ctx, err_instance);
    return jsc.JSValueMakeUndefined(ctx);
}

/// ReadStream(fd?)：缺省 fd=0
fn readStreamCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    var fd: i32 = 0;
    if (argumentCount >= 1) {
        const n = jsc.JSValueToNumber(ctx, arguments[0], null);
        if (n == n) fd = @intFromFloat(n);
    }
    return makeStreamObject(ctx, fd);
}

/// WriteStream(fd?)：缺省 fd=1
fn writeStreamCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    var fd: i32 = 1;
    if (argumentCount >= 1) {
        const n = jsc.JSValueToNumber(ctx, arguments[0], null);
        if (n == n) fd = @intFromFloat(n);
    }
    return makeStreamObject(ctx, fd);
}

pub fn getExports(ctx: jsc.JSContextRef, _: std.mem.Allocator) jsc.JSValueRef {
    const exports = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, exports, "isTTY", isTTYCallback);
    common.setMethod(ctx, exports, "ReadStream", readStreamCallback);
    common.setMethod(ctx, exports, "WriteStream", writeStreamCallback);
    return exports;
}
