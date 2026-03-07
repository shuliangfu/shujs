// shu:assert 内置：Zig 实现 Node 风格断言（strictEqual、deepStrictEqual、ok、fail、throws、doesNotThrow、rejects、doesNotReject）
// 供 require("shu:assert") / node:assert / shu:test 共用；失败时通过 C 回调的 exception 出参抛错，便于 test runner 正确捕获。

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");

/// 全局槽名：test runner 在跑用例前设此槽为 true 或注入 runner_global，assert 失败时除写 exception_out 外再写 __shu_assert_last_exc，供 runner 读取（纯 Zig 无内联 JS）。
const k_shu_assert_exc_slot = "__shu_assert_exc_slot";
const k_shu_assert_last_exc = "__shu_assert_last_exc";
const k_shu_assert_did_fail = "__shu_assert_did_fail";

/// test runner 在跑用例前注入的 global；assert 失败时优先写入此对象（与 runner 同对象），否则写 ctx global。调用方与 setAssertException 同线程。
var g_runner_global: ?jsc.JSObjectRef = null;
/// 本次用例内 assert 失败次数；setAssertException 时 +1，runner 读后清零，用于 runner 读不到 global 槽时仍判失败。
var g_assert_fail_count: u32 = 0;

/// 由 test runner 在跑单条用例前调用：传入 global 则 assert 失败时写该 global[__shu_assert_last_exc/did_fail]；传 null 则清除。
pub fn setRunnerGlobalForAssert(global: ?jsc.JSObjectRef) void {
    g_runner_global = global;
}

/// 返回本次用例 assert 失败次数并清零；runner 在读槽后调用，若 >0 且槽无值则用 makeAssertFailedError 走失败路径。
pub fn getAndClearAssertFailCount() u32 {
    const n = g_assert_fail_count;
    g_assert_fail_count = 0;
    return n;
}

/// 清除 runner 槽与 fail_count；在 assert.throws/assert.rejects 等「预期异常」分支调用，避免 runner 将预期异常误判为用例失败。
pub fn clearRunnerAssertSlot(ctx: jsc.JSContextRef) void {
    g_assert_fail_count = 0;
    const target = g_runner_global orelse return;
    const k_last = jsc.JSStringCreateWithUTF8CString(k_shu_assert_last_exc);
    defer jsc.JSStringRelease(k_last);
    const k_did = jsc.JSStringCreateWithUTF8CString(k_shu_assert_did_fail);
    defer jsc.JSStringRelease(k_did);
    const undef = jsc.JSValueMakeUndefined(ctx);
    _ = jsc.JSObjectSetProperty(ctx, target, k_last, undef, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, target, k_did, undef, jsc.kJSPropertyAttributeNone, null);
}

/// 在 ctx 中创建 Error(message_js) 并写入 exception_out[0]，供 assert 回调抛错；纯 Zig，无内联脚本。
/// 若 g_runner_global 已设则写其，否则若 global 上存在 __shu_assert_exc_slot 则写 ctx global，便于 runner 在 C 层读取并计入 failed。
pub fn setAssertException(ctx: jsc.JSContextRef, message_js: jsc.JSValueRef, exception_out: [*]jsc.JSValueRef) void {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_Error = jsc.JSStringCreateWithUTF8CString("Error");
    defer jsc.JSStringRelease(k_Error);
    const Error_ctor = jsc.JSObjectGetProperty(ctx, global, k_Error, null);
    if (jsc.JSValueIsUndefined(ctx, Error_ctor)) return;
    var args = [_]jsc.JSValueRef{message_js};
    const err_instance = jsc.JSObjectCallAsConstructor(ctx, @ptrCast(Error_ctor), 1, &args, null);
    if (jsc.JSValueIsUndefined(ctx, err_instance) or jsc.JSValueIsNull(ctx, err_instance)) return;
    exception_out[0] = err_instance;
    g_assert_fail_count += 1;
    const k_slot = jsc.JSStringCreateWithUTF8CString(k_shu_assert_exc_slot);
    defer jsc.JSStringRelease(k_slot);
    const slot_val = jsc.JSObjectGetProperty(ctx, global, k_slot, null);
    const slot_ok = !jsc.JSValueIsUndefined(ctx, slot_val) and !jsc.JSValueIsNull(ctx, slot_val);
    if (g_runner_global == null and !slot_ok) return;
    const k_last = jsc.JSStringCreateWithUTF8CString(k_shu_assert_last_exc);
    defer jsc.JSStringRelease(k_last);
    const k_did = jsc.JSStringCreateWithUTF8CString(k_shu_assert_did_fail);
    defer jsc.JSStringRelease(k_did);
    if (g_runner_global) |rg| {
        _ = jsc.JSObjectSetProperty(ctx, rg, k_last, err_instance, jsc.kJSPropertyAttributeNone, null);
        _ = jsc.JSObjectSetProperty(ctx, rg, k_did, jsc.JSValueMakeBoolean(ctx, true), jsc.kJSPropertyAttributeNone, null);
    }
    if (slot_ok) {
        _ = jsc.JSObjectSetProperty(ctx, global, k_last, err_instance, jsc.kJSPropertyAttributeNone, null);
        _ = jsc.JSObjectSetProperty(ctx, global, k_did, jsc.JSValueMakeBoolean(ctx, true), jsc.kJSPropertyAttributeNone, null);
    }
}

/// 纯 Zig 严格相等：===（同类型且同值；NaN !== NaN）
fn jsValueStrictEqual(ctx: jsc.JSContextRef, a: jsc.JSValueRef, b: jsc.JSValueRef) bool {
    if (a == b) return true;
    const a_is_undef = jsc.JSValueIsUndefined(ctx, a);
    const b_is_undef = jsc.JSValueIsUndefined(ctx, b);
    if (a_is_undef or b_is_undef) return a_is_undef and b_is_undef;

    const a_is_null = jsc.JSValueIsNull(ctx, a);
    const b_is_null = jsc.JSValueIsNull(ctx, b);
    if (a_is_null or b_is_null) return a_is_null and b_is_null;

    const a_is_bool = jsc.JSValueIsBoolean(ctx, a);
    const b_is_bool = jsc.JSValueIsBoolean(ctx, b);
    if (a_is_bool or b_is_bool) {
        if (!(a_is_bool and b_is_bool)) return false;
        return jsc.JSValueToBoolean(ctx, a) == jsc.JSValueToBoolean(ctx, b);
    }

    const a_is_num = jsc.JSValueIsNumber(ctx, a);
    const b_is_num = jsc.JSValueIsNumber(ctx, b);
    if (a_is_num or b_is_num) {
        if (!(a_is_num and b_is_num)) return false;
        const na = jsc.JSValueToNumber(ctx, a, null);
        const nb = jsc.JSValueToNumber(ctx, b, null);
        if (std.math.isNan(na) and std.math.isNan(nb)) return true;
        return na == nb;
    }

    const a_is_str = jsc.JSValueIsString(ctx, a);
    const b_is_str = jsc.JSValueIsString(ctx, b);
    if (a_is_str or b_is_str) {
        if (!(a_is_str and b_is_str)) return false;
        const sa = jsc.JSValueToStringCopy(ctx, a, null);
        defer jsc.JSStringRelease(sa);
        const sb = jsc.JSValueToStringCopy(ctx, b, null);
        defer jsc.JSStringRelease(sb);
        var buf_a: [512]u8 = undefined;
        var buf_b: [512]u8 = undefined;
        const n_a = jsc.JSStringGetUTF8CString(sa, &buf_a, buf_a.len);
        const n_b = jsc.JSStringGetUTF8CString(sb, &buf_b, buf_b.len);
        if (n_a == 0 or n_b == 0) return false;
        return n_a == n_b and std.mem.eql(u8, buf_a[0 .. n_a - 1], buf_b[0 .. n_b - 1]);
    }

    const a_is_obj = jsc.JSValueIsObject(ctx, a);
    const b_is_obj = jsc.JSValueIsObject(ctx, b);
    if (a_is_obj or b_is_obj) {
        if (!(a_is_obj and b_is_obj)) return false;
        const obj_a = jsc.JSValueToObject(ctx, a, null);
        const obj_b = jsc.JSValueToObject(ctx, b, null);
        if (obj_a == null or obj_b == null) return false;
        return obj_a.? == obj_b.?;
    }

    return false;
}

/// assert.strictEqual(actual, expected [, message])：纯 Zig 比较，不相等则通过 exception_out 抛 Error
fn strictEqualCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception_out: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    if (jsValueStrictEqual(ctx, arguments[0], arguments[1])) return jsc.JSValueMakeUndefined(ctx);
    const msg_js = if (argumentCount >= 3) arguments[2] else blk: {
        const ref = jsc.JSStringCreateWithUTF8CString("strictEqual");
        defer jsc.JSStringRelease(ref);
        break :blk jsc.JSValueMakeString(ctx, ref);
    };
    setAssertException(ctx, msg_js, exception_out);
    return jsc.JSValueMakeUndefined(ctx);
}

/// 递归深度比较（纯 Zig）：a === b 直接 true；非对象或 null 用严格相等；对象则比较 key 数量与每 key 的 hasOwnProperty + 递归
fn jsValueDeepStrictEqual(ctx: jsc.JSContextRef, a: jsc.JSValueRef, b: jsc.JSValueRef) bool {
    if (jsValueStrictEqual(ctx, a, b)) return true;
    // 仅对象值做结构比较；原始值在 strictEqual 失败后应直接判不等。
    if (!jsc.JSValueIsObject(ctx, a) or !jsc.JSValueIsObject(ctx, b)) return false;
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
    const hasOwn_obj = jsc.JSValueToObject(ctx, hasOwn_fn, null) orelse return false;
    var i: usize = 0;
    while (i < count_a) : (i += 1) {
        const key = jsc.JSPropertyNameArrayGetNameAtIndex(names_a, i);
        var key_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeString(ctx, key)};
        var exc: jsc.JSValueRef = jsc.JSValueMakeUndefined(ctx);
        const has = jsc.JSObjectCallAsFunction(ctx, hasOwn_obj, obj_b.?, 1, &key_arg, @ptrCast(&exc));
        if (!jsc.JSValueIsUndefined(ctx, exc) and !jsc.JSValueIsNull(ctx, exc)) return false;
        if (!jsc.JSValueToBoolean(ctx, has)) return false;
        const val_a = jsc.JSObjectGetProperty(ctx, obj_a.?, key, null);
        const val_b = jsc.JSObjectGetProperty(ctx, obj_b.?, key, null);
        if (!jsValueDeepStrictEqual(ctx, val_a, val_b)) return false;
    }
    return true;
}

/// assert.deepStrictEqual(actual, expected [, message])：纯 Zig 深度比较，不相等则通过 exception_out 抛 Error
fn deepStrictEqualCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception_out: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    if (jsValueDeepStrictEqual(ctx, arguments[0], arguments[1])) return jsc.JSValueMakeUndefined(ctx);
    const ref = jsc.JSStringCreateWithUTF8CString("deepStrictEqual");
    defer jsc.JSStringRelease(ref);
    setAssertException(ctx, jsc.JSValueMakeString(ctx, ref), exception_out);
    return jsc.JSValueMakeUndefined(ctx);
}

/// assert.ok(value [, message])：value 为 falsy 时通过 exception_out 抛 Error
fn okCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception_out: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    if (jsc.JSValueToBoolean(ctx, arguments[0])) return jsc.JSValueMakeUndefined(ctx);
    const msg_js = if (argumentCount >= 2) arguments[1] else blk: {
        const ref = jsc.JSStringCreateWithUTF8CString("Assertion failed");
        defer jsc.JSStringRelease(ref);
        break :blk jsc.JSValueMakeString(ctx, ref);
    };
    setAssertException(ctx, msg_js, exception_out);
    return jsc.JSValueMakeUndefined(ctx);
}

/// assert.fail([message])：直接以 message（默认 "Assertion failed"）通过 exception_out 抛错
fn failCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception_out: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const msg_js = if (argumentCount >= 1) arguments[0] else blk: {
        const ref = jsc.JSStringCreateWithUTF8CString("Assertion failed");
        defer jsc.JSStringRelease(ref);
        break :blk jsc.JSValueMakeString(ctx, ref);
    };
    setAssertException(ctx, msg_js, exception_out);
    return jsc.JSValueMakeUndefined(ctx);
}

/// assert.throws(fn [, message])：调用 fn()，若未抛错则通过 exception_out 抛 Error；若抛错则清除 exception 并返回 undefined
fn throwsCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception_out: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1 or !jsc.JSObjectIsFunction(ctx, @ptrCast(arguments[0]))) return jsc.JSValueMakeUndefined(ctx);
    var no_args: [0]jsc.JSValueRef = undefined;
    // 使用本地异常槽，避免直接读取宿主传入 exception_out 的未初始化内容。
    var inner_exc: jsc.JSValueRef = jsc.JSValueMakeUndefined(ctx);
    _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(arguments[0]), null, 0, &no_args, @ptrCast(&inner_exc));
    if (!jsc.JSValueIsUndefined(ctx, inner_exc) and !jsc.JSValueIsNull(ctx, inner_exc)) {
        clearRunnerAssertSlot(ctx);
        return jsc.JSValueMakeUndefined(ctx);
    }
    const msg_js = if (argumentCount >= 2) arguments[1] else blk: {
        const ref = jsc.JSStringCreateWithUTF8CString("Expected function to throw");
        defer jsc.JSStringRelease(ref);
        break :blk jsc.JSValueMakeString(ctx, ref);
    };
    setAssertException(ctx, msg_js, exception_out);
    return jsc.JSValueMakeUndefined(ctx);
}

/// 判断值是否为 thenable（有 then 方法且为函数）
fn isThenable(ctx: jsc.JSContextRef, val: jsc.JSValueRef) bool {
    if (jsc.JSValueIsUndefined(ctx, val) or jsc.JSValueIsNull(ctx, val)) return false;
    const obj = jsc.JSValueToObject(ctx, val, null) orelse return false;
    const k_then = jsc.JSStringCreateWithUTF8CString("then");
    defer jsc.JSStringRelease(k_then);
    const then_val = jsc.JSObjectGetProperty(ctx, obj, k_then, null);
    return jsc.JSObjectIsFunction(ctx, @ptrCast(then_val));
}

const promise_mod = @import("../promise.zig");

/// 从函数对象属性读取 inner/msg/mode，并调用 inner.then(onFulfill, onReject)；
/// 供 assert.rejects/doesNotReject 的 Promise executor 使用。
fn rejectsExecutorCallback(
    ctx: jsc.JSContextRef,
    function_obj: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const k_inner = jsc.JSStringCreateWithUTF8CString("__shu_rejects_inner");
    defer jsc.JSStringRelease(k_inner);
    const k_msg = jsc.JSStringCreateWithUTF8CString("__shu_rejects_msg");
    defer jsc.JSStringRelease(k_msg);
    const k_mode = jsc.JSStringCreateWithUTF8CString("__shu_rejects_mode");
    defer jsc.JSStringRelease(k_mode);
    const inner = jsc.JSObjectGetProperty(ctx, function_obj, k_inner, null);
    if (jsc.JSValueIsUndefined(ctx, inner) or !isThenable(ctx, inner)) return jsc.JSValueMakeUndefined(ctx);
    const mode_val = jsc.JSObjectGetProperty(ctx, function_obj, k_mode, null);
    const msg_val = jsc.JSObjectGetProperty(ctx, function_obj, k_msg, null);
    const k_then = jsc.JSStringCreateWithUTF8CString("then");
    defer jsc.JSStringRelease(k_then);
    const inner_obj = jsc.JSValueToObject(ctx, inner, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const then_fn = jsc.JSObjectGetProperty(ctx, inner_obj, k_then, null);
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(then_fn))) return jsc.JSValueMakeUndefined(ctx);
    const k_onf = jsc.JSStringCreateWithUTF8CString("__rejects_onf");
    defer jsc.JSStringRelease(k_onf);
    const k_onr = jsc.JSStringCreateWithUTF8CString("__rejects_onr");
    defer jsc.JSStringRelease(k_onr);
    const on_fulfill = jsc.JSObjectMakeFunctionWithCallback(ctx, k_onf, rejectsOnFulfillCallback);
    const on_reject = jsc.JSObjectMakeFunctionWithCallback(ctx, k_onr, rejectsOnRejectCallback);

    const k_resolve = jsc.JSStringCreateWithUTF8CString("__shu_rejects_resolve");
    defer jsc.JSStringRelease(k_resolve);
    const k_reject = jsc.JSStringCreateWithUTF8CString("__shu_rejects_reject");
    defer jsc.JSStringRelease(k_reject);
    _ = jsc.JSObjectSetProperty(ctx, on_fulfill, k_resolve, arguments[0], jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, on_fulfill, k_reject, arguments[1], jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, on_fulfill, k_msg, msg_val, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, on_fulfill, k_mode, mode_val, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, on_reject, k_resolve, arguments[0], jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, on_reject, k_reject, arguments[1], jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, on_reject, k_msg, msg_val, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, on_reject, k_mode, mode_val, jsc.kJSPropertyAttributeNone, null);

    // 固定传入 (onFulfilled, onRejected)；具体在回调内部按 mode 决定 resolve/reject 方向。
    var then_args = [_]jsc.JSValueRef{ on_fulfill, on_reject };
    _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(then_fn), inner, 2, &then_args, null);
    return jsc.JSValueMakeUndefined(ctx);
}

/// assert.rejects 时：inner 被 fulfill 则用 message reject 返回的 Promise；assert.doesNotReject 时：inner 被 fulfill 则 resolve(value)
fn rejectsOnFulfillCallback(
    ctx: jsc.JSContextRef,
    function_obj: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const k_reject = jsc.JSStringCreateWithUTF8CString("__shu_rejects_reject");
    defer jsc.JSStringRelease(k_reject);
    const k_resolve = jsc.JSStringCreateWithUTF8CString("__shu_rejects_resolve");
    defer jsc.JSStringRelease(k_resolve);
    const k_msg = jsc.JSStringCreateWithUTF8CString("__shu_rejects_msg");
    defer jsc.JSStringRelease(k_msg);
    const k_mode = jsc.JSStringCreateWithUTF8CString("__shu_rejects_mode");
    defer jsc.JSStringRelease(k_mode);
    const mode_val = jsc.JSObjectGetProperty(ctx, function_obj, k_mode, null);
    const is_rejects = jsc.JSValueToBoolean(ctx, mode_val);
    if (is_rejects) {
        const reject_fn = jsc.JSObjectGetProperty(ctx, function_obj, k_reject, null);
        const msg = jsc.JSObjectGetProperty(ctx, function_obj, k_msg, null);
        var one = [_]jsc.JSValueRef{if (jsc.JSValueIsUndefined(ctx, msg)) blk: {
            const k = jsc.JSStringCreateWithUTF8CString("Expected rejection");
            defer jsc.JSStringRelease(k);
            break :blk jsc.JSValueMakeString(ctx, k);
        } else msg};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(reject_fn), null, 1, &one, null);
    } else {
        const resolve_fn = jsc.JSObjectGetProperty(ctx, function_obj, k_resolve, null);
        var one = [_]jsc.JSValueRef{if (argumentCount > 0) arguments[0] else jsc.JSValueMakeUndefined(ctx)};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(resolve_fn), null, 1, &one, null);
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// assert.rejects 时：inner 被 reject 则 resolve(err)；assert.doesNotReject 时：inner 被 reject 则 reject(msg 或 err)
fn rejectsOnRejectCallback(
    ctx: jsc.JSContextRef,
    function_obj: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const k_resolve = jsc.JSStringCreateWithUTF8CString("__shu_rejects_resolve");
    defer jsc.JSStringRelease(k_resolve);
    const k_reject = jsc.JSStringCreateWithUTF8CString("__shu_rejects_reject");
    defer jsc.JSStringRelease(k_reject);
    const k_msg = jsc.JSStringCreateWithUTF8CString("__shu_rejects_msg");
    defer jsc.JSStringRelease(k_msg);
    const k_mode = jsc.JSStringCreateWithUTF8CString("__shu_rejects_mode");
    defer jsc.JSStringRelease(k_mode);
    const mode_val = jsc.JSObjectGetProperty(ctx, function_obj, k_mode, null);
    const is_rejects = jsc.JSValueToBoolean(ctx, mode_val);
    if (is_rejects) {
        clearRunnerAssertSlot(ctx);
        const resolve_fn = jsc.JSObjectGetProperty(ctx, function_obj, k_resolve, null);
        var one = [_]jsc.JSValueRef{if (argumentCount > 0) arguments[0] else jsc.JSValueMakeUndefined(ctx)};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(resolve_fn), null, 1, &one, null);
    } else {
        const reject_fn = jsc.JSObjectGetProperty(ctx, function_obj, k_reject, null);
        const msg = jsc.JSObjectGetProperty(ctx, function_obj, k_msg, null);
        var one = [_]jsc.JSValueRef{if (!jsc.JSValueIsUndefined(ctx, msg)) msg else if (argumentCount > 0) arguments[0] else jsc.JSValueMakeUndefined(ctx)};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(reject_fn), null, 1, &one, null);
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// assert.doesNotThrow(fn [, message])：调用 fn()，若抛错则用该错误或 message 通过 exception 出参抛错
fn doesNotThrowCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception_out: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1 or !jsc.JSObjectIsFunction(ctx, @ptrCast(arguments[0]))) return jsc.JSValueMakeUndefined(ctx);
    var no_args: [0]jsc.JSValueRef = undefined;
    // 使用本地异常槽，避免把脏 exception_out 误判为异常。
    var inner_exc: jsc.JSValueRef = jsc.JSValueMakeUndefined(ctx);
    _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(arguments[0]), null, 0, &no_args, @ptrCast(&inner_exc));
    if (jsc.JSValueIsUndefined(ctx, inner_exc) or jsc.JSValueIsNull(ctx, inner_exc))
        return jsc.JSValueMakeUndefined(ctx);
    const msg_js = if (argumentCount >= 2) arguments[1] else inner_exc;
    setAssertException(ctx, msg_js, exception_out);
    return jsc.JSValueMakeUndefined(ctx);
}

/// assert.rejects(promiseOrFn [, message])：返回 Promise，inner 被 reject 则 resolve(err)，被 fulfill 则 reject(message)；约定：勿并发多路 assert.rejects 不 await，单槽全局。
fn rejectsCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    var inner: jsc.JSValueRef = arguments[0];
    const first_obj = jsc.JSValueToObject(ctx, inner, null);
    if (first_obj != null and jsc.JSObjectIsFunction(ctx, first_obj.?)) {
        var no_args: [0]jsc.JSValueRef = undefined;
        // 使用本地异常槽，避免 exception_out 残留导致错误短路。
        var inner_exc: jsc.JSValueRef = jsc.JSValueMakeUndefined(ctx);
        inner = jsc.JSObjectCallAsFunction(ctx, first_obj.?, null, 0, &no_args, @ptrCast(&inner_exc));
        if (!jsc.JSValueIsUndefined(ctx, inner_exc) and !jsc.JSValueIsNull(ctx, inner_exc)) return jsc.JSValueMakeUndefined(ctx);
    }
    const Promise_ctor = promise_mod.getPromiseConstructor(ctx) orelse return jsc.JSValueMakeUndefined(ctx);
    const k_exec = jsc.JSStringCreateWithUTF8CString("");
    defer jsc.JSStringRelease(k_exec);
    const exec_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_exec, rejectsExecutorCallback);
    const k_inner = jsc.JSStringCreateWithUTF8CString("__shu_rejects_inner");
    defer jsc.JSStringRelease(k_inner);
    const k_msg = jsc.JSStringCreateWithUTF8CString("__shu_rejects_msg");
    defer jsc.JSStringRelease(k_msg);
    const k_mode = jsc.JSStringCreateWithUTF8CString("__shu_rejects_mode");
    defer jsc.JSStringRelease(k_mode);
    _ = jsc.JSObjectSetProperty(ctx, exec_fn, k_inner, inner, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, exec_fn, k_msg, if (argumentCount >= 2) arguments[1] else jsc.JSValueMakeUndefined(ctx), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, exec_fn, k_mode, jsc.JSValueMakeBoolean(ctx, true), jsc.kJSPropertyAttributeNone, null);
    var args = [_]jsc.JSValueRef{exec_fn};
    return jsc.JSObjectCallAsConstructor(ctx, Promise_ctor, 1, &args, null);
}

/// assert.doesNotReject(promiseOrFn [, message])：返回 Promise，inner 被 fulfill 则 resolve(value)，被 reject 则 reject(msg 或 err)
fn doesNotRejectCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    var inner: jsc.JSValueRef = arguments[0];
    const first_obj = jsc.JSValueToObject(ctx, inner, null);
    if (first_obj != null and jsc.JSObjectIsFunction(ctx, first_obj.?)) {
        var no_args: [0]jsc.JSValueRef = undefined;
        // 使用本地异常槽，避免 exception_out 残留导致错误短路。
        var inner_exc: jsc.JSValueRef = jsc.JSValueMakeUndefined(ctx);
        inner = jsc.JSObjectCallAsFunction(ctx, first_obj.?, null, 0, &no_args, @ptrCast(&inner_exc));
        if (!jsc.JSValueIsUndefined(ctx, inner_exc) and !jsc.JSValueIsNull(ctx, inner_exc)) return jsc.JSValueMakeUndefined(ctx);
    }
    const Promise_ctor = promise_mod.getPromiseConstructor(ctx) orelse return jsc.JSValueMakeUndefined(ctx);
    const k_exec = jsc.JSStringCreateWithUTF8CString("");
    defer jsc.JSStringRelease(k_exec);
    const exec_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_exec, rejectsExecutorCallback);
    const k_inner = jsc.JSStringCreateWithUTF8CString("__shu_rejects_inner");
    defer jsc.JSStringRelease(k_inner);
    const k_msg = jsc.JSStringCreateWithUTF8CString("__shu_rejects_msg");
    defer jsc.JSStringRelease(k_msg);
    const k_mode = jsc.JSStringCreateWithUTF8CString("__shu_rejects_mode");
    defer jsc.JSStringRelease(k_mode);
    _ = jsc.JSObjectSetProperty(ctx, exec_fn, k_inner, inner, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, exec_fn, k_msg, if (argumentCount >= 2) arguments[1] else jsc.JSValueMakeUndefined(ctx), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, exec_fn, k_mode, jsc.JSValueMakeBoolean(ctx, false), jsc.kJSPropertyAttributeNone, null);
    var args = [_]jsc.JSValueRef{exec_fn};
    return jsc.JSObjectCallAsConstructor(ctx, Promise_ctor, 1, &args, null);
}

/// 返回 shu:assert 的 exports 对象：ok、strictEqual、deepStrictEqual、throws、doesNotThrow、fail、rejects、doesNotReject；Deno 别名 assertEquals/assertStrictEquals/assertThrows/assertRejects
pub fn getExports(ctx: jsc.JSContextRef, _: std.mem.Allocator) jsc.JSValueRef {
    const obj = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, obj, "ok", okCallback);
    common.setMethod(ctx, obj, "strictEqual", strictEqualCallback);
    common.setMethod(ctx, obj, "deepStrictEqual", deepStrictEqualCallback);
    common.setMethod(ctx, obj, "throws", throwsCallback);
    common.setMethod(ctx, obj, "doesNotThrow", doesNotThrowCallback);
    common.setMethod(ctx, obj, "fail", failCallback);
    common.setMethod(ctx, obj, "rejects", rejectsCallback);
    common.setMethod(ctx, obj, "doesNotReject", doesNotRejectCallback);
    common.setMethod(ctx, obj, "assertEquals", deepStrictEqualCallback);
    common.setMethod(ctx, obj, "assertStrictEquals", strictEqualCallback);
    common.setMethod(ctx, obj, "assertThrows", throwsCallback);
    common.setMethod(ctx, obj, "assertRejects", rejectsCallback);
    return obj;
}
