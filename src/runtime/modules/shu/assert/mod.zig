// shu:assert 内置：Zig 实现 Node 风格断言（strictEqual、deepStrictEqual、ok、fail、throws）
// 供 require("shu:assert") / node:assert 共用，运行效率高于脚本实现

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");

/// 在 JS 侧抛错：用 Zig 创建 new Error(msg_js)，再 setThrowAndThrow（无内联 throw new Error 脚本）
fn throwAssertErrorWithJS(ctx: jsc.JSContextRef, msg_js: jsc.JSValueRef) jsc.JSValueRef {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_Error = jsc.JSStringCreateWithUTF8CString("Error");
    defer jsc.JSStringRelease(k_Error);
    const Error_ctor = jsc.JSObjectGetProperty(ctx, global, k_Error, null);
    const err_obj = jsc.JSValueToObject(ctx, Error_ctor, null) orelse return jsc.JSValueMakeUndefined(ctx);
    var args: [1]jsc.JSValueRef = .{msg_js};
    var exception: ?jsc.JSValueRef = null;
    const err_instance = jsc.JSObjectCallAsConstructor(ctx, err_obj, 1, &args, @ptrCast(&exception));
    if (exception != null) return jsc.JSValueMakeUndefined(ctx);
    return common.setThrowAndThrow(ctx, err_instance);
}

/// 纯 Zig 严格相等：===（同类型且同值；NaN !== NaN）
fn jsValueStrictEqual(ctx: jsc.JSContextRef, a: jsc.JSValueRef, b: jsc.JSValueRef) bool {
    if (a == b) return true;
    if (jsc.JSValueIsUndefined(ctx, a)) return jsc.JSValueIsUndefined(ctx, b);
    if (jsc.JSValueIsNull(ctx, a)) return jsc.JSValueIsNull(ctx, b);
    const na = jsc.JSValueToNumber(ctx, a, null);
    const nb = jsc.JSValueToNumber(ctx, b, null);
    if (na == na and nb == nb) return na == nb;
    const obj_a = jsc.JSValueToObject(ctx, a, null);
    const obj_b = jsc.JSValueToObject(ctx, b, null);
    if (obj_a != null and obj_b != null) return obj_a == obj_b;
    const sa = jsc.JSValueToStringCopy(ctx, a, null);
    defer jsc.JSStringRelease(sa);
    const sb = jsc.JSValueToStringCopy(ctx, b, null);
    defer jsc.JSStringRelease(sb);
    const len_a = jsc.JSStringGetMaximumUTF8CStringSize(sa);
    const len_b = jsc.JSStringGetMaximumUTF8CStringSize(sb);
    if (len_a != len_b or len_a == 0) return false;
    var buf_a: [256]u8 = undefined;
    var buf_b: [256]u8 = undefined;
    const slice_a = if (len_a <= buf_a.len) buf_a[0..] else buf_a[0..buf_a.len];
    const slice_b = if (len_b <= buf_b.len) buf_b[0..] else buf_b[0..buf_b.len];
    const n_a = jsc.JSStringGetUTF8CString(sa, slice_a.ptr, slice_a.len);
    const n_b = jsc.JSStringGetUTF8CString(sb, slice_b.ptr, slice_b.len);
    return n_a == n_b and std.mem.eql(u8, slice_a[0 .. n_a - 1], slice_b[0 .. n_b - 1]);
}

/// assert.strictEqual(actual, expected [, message])：纯 Zig 比较，不相等则 new Error(message) 并 throw
fn strictEqualCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    if (jsValueStrictEqual(ctx, arguments[0], arguments[1])) return jsc.JSValueMakeUndefined(ctx);
    const msg_js = if (argumentCount >= 3) arguments[2] else blk: {
        const ref = jsc.JSStringCreateWithUTF8CString("strictEqual");
        defer jsc.JSStringRelease(ref);
        break :blk jsc.JSValueMakeString(ctx, ref);
    };
    _ = throwAssertErrorWithJS(ctx, msg_js);
    return jsc.JSValueMakeUndefined(ctx);
}

/// 递归深度比较（纯 Zig）：a === b 直接 true；非对象或 null 用严格相等；对象则比较 key 数量与每 key 的 hasOwnProperty + 递归
fn jsValueDeepStrictEqual(ctx: jsc.JSContextRef, a: jsc.JSValueRef, b: jsc.JSValueRef) bool {
    if (jsValueStrictEqual(ctx, a, b)) return true;
    const obj_a = jsc.JSValueToObject(ctx, a, null);
    const obj_b = jsc.JSValueToObject(ctx, b, null);
    if (obj_a == null or obj_b == null) return false;
    const names_a = jsc.JSObjectCopyPropertyNames(ctx, obj_a.?);
    defer jsc.JSPropertyNameArrayRelease(names_a);
    const names_b = jsc.JSObjectCopyPropertyNames(ctx, obj_b.?);
    defer jsc.JSPropertyNameArrayRelease(names_b);
    const count_a = jsc.JSPropertyNameArrayGetCount(names_a);
    const count_b = jsc.JSPropertyNameArrayGetCount(names_b);
    if (count_a != count_b) return false;
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_Object = jsc.JSStringCreateWithUTF8CString("Object");
    defer jsc.JSStringRelease(k_Object);
    const k_prototype = jsc.JSStringCreateWithUTF8CString("prototype");
    defer jsc.JSStringRelease(k_prototype);
    const k_hasOwnProperty = jsc.JSStringCreateWithUTF8CString("hasOwnProperty");
    defer jsc.JSStringRelease(k_hasOwnProperty);
    const Object_ctor = jsc.JSObjectGetProperty(ctx, global, k_Object, null);
    const proto = jsc.JSObjectGetProperty(ctx, @ptrCast(Object_ctor), k_prototype, null);
    const hasOwn_fn = jsc.JSObjectGetProperty(ctx, @ptrCast(proto), k_hasOwnProperty, null);
    var i: usize = 0;
    while (i < count_a) : (i += 1) {
        const key = jsc.JSPropertyNameArrayGetNameAtIndex(names_a, i);
        var key_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeString(ctx, key)};
        var exc: ?jsc.JSValueRef = null;
        const has = jsc.JSObjectCallAsFunction(ctx, @ptrCast(hasOwn_fn), @ptrCast(obj_b.?), 1, &key_arg, @ptrCast(&exc));
        if (!jsc.JSValueToBoolean(ctx, has)) return false;
        const val_a = jsc.JSObjectGetProperty(ctx, obj_a.?, key, null);
        const val_b = jsc.JSObjectGetProperty(ctx, obj_b.?, key, null);
        if (!jsValueDeepStrictEqual(ctx, val_a, val_b)) return false;
    }
    return true;
}

/// assert.deepStrictEqual(actual, expected [, message])：纯 Zig 深度比较，不相等则 new Error 并 throw
fn deepStrictEqualCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    if (jsValueDeepStrictEqual(ctx, arguments[0], arguments[1])) return jsc.JSValueMakeUndefined(ctx);
    const ref = jsc.JSStringCreateWithUTF8CString("deepStrictEqual");
    defer jsc.JSStringRelease(ref);
    _ = throwAssertErrorWithJS(ctx, jsc.JSValueMakeString(ctx, ref));
    return jsc.JSValueMakeUndefined(ctx);
}

/// assert.ok(value [, message])
fn okCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    if (!jsc.JSValueToBoolean(ctx, arguments[0])) {
        const msg_js = if (argumentCount >= 2) arguments[1] else blk: {
            const ref = jsc.JSStringCreateWithUTF8CString("assert.ok");
            defer jsc.JSStringRelease(ref);
            break :blk jsc.JSValueMakeString(ctx, ref);
        };
        _ = throwAssertErrorWithJS(ctx, msg_js);
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// assert.fail([message])
fn failCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const msg_js = if (argumentCount >= 1) arguments[0] else blk: {
        const ref = jsc.JSStringCreateWithUTF8CString("fail");
        defer jsc.JSStringRelease(ref);
        break :blk jsc.JSValueMakeString(ctx, ref);
    };
    _ = throwAssertErrorWithJS(ctx, msg_js);
    return jsc.JSValueMakeUndefined(ctx);
}

/// assert.throws(fn [, message])：fn 必须抛错，否则抛 AssertionError
fn throwsCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1 or !jsc.JSObjectIsFunction(ctx, @ptrCast(arguments[0]))) return jsc.JSValueMakeUndefined(ctx);
    const fn_ref = arguments[0];
    var no_args: [0]jsc.JSValueRef = undefined;
    _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(fn_ref), null, 0, &no_args, null);
    // 若能执行到这里说明 fn 未抛错，需抛 assert.throws 错误
    const msg_js = if (argumentCount >= 2) arguments[1] else blk: {
        const ref = jsc.JSStringCreateWithUTF8CString("throws");
        defer jsc.JSStringRelease(ref);
        break :blk jsc.JSValueMakeString(ctx, ref);
    };
    _ = throwAssertErrorWithJS(ctx, msg_js);
    return jsc.JSValueMakeUndefined(ctx);
}

/// 返回 shu:assert 的 exports 对象（strictEqual、deepStrictEqual、ok、fail、throws）
pub fn getExports(ctx: jsc.JSContextRef, _: std.mem.Allocator) jsc.JSValueRef {
    const obj = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, obj, "strictEqual", strictEqualCallback);
    common.setMethod(ctx, obj, "deepStrictEqual", deepStrictEqualCallback);
    common.setMethod(ctx, obj, "ok", okCallback);
    common.setMethod(ctx, obj, "fail", failCallback);
    common.setMethod(ctx, obj, "throws", throwsCallback);
    return obj;
}
