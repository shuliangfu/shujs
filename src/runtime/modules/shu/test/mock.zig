//! # shu:test mock — 与 node:test mock 兼容的桩实现
//!
//! 纯 Zig 实现，不执行内联 JS，状态全部挂在 JSC 对象属性上。
//!
//! ## 当前已实现
//!
//! - **mock.fn([implementation])**：无参或传入一个函数。返回的 mock 函数具有：
//!   - **.calls**：数组，第 i 次调用对应 calls[i]（该次调用的参数组成的数组）；
//!   - **.callCount**：调用次数（每次调用后更新）。
//!   - 若传入 implementation，每次调用会先记录再转发到 implementation，并返回其返回值。
//!
//! ## 可做的 mock 测试（仅凭 mock.fn）
//!
//! - **调用次数**：`assert.strictEqual(mockFn.callCount, 1)`；
//! - **某次调用的参数**：`assert.strictEqual(mockFn.calls.length, 1)`、
//!   `assert.deepStrictEqual(mockFn.calls[0], [arg1, arg2])`；
//! - **注入回调**：将 `mock.fn()` 作为回调传给被测代码，执行后断言 callCount / calls；
//! - **带实现的 spy**：`mock.fn(realImpl)` 既记录调用又执行真实逻辑，可断言调用后再断言返回值。
//!
//! ## 与 node:test 对比、后续可扩展
//!
//! - **mock.method(object, methodName [, options])**：已实现；替换 object[methodName] 为 mock（原方法作 impl），返回 mock。
//! - **mock.timers**：未实现；用于 mock setTimeout/setInterval/setImmediate/Date（enable/tick/setTime/reset）。

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");

// 内部属性名，用于在 mock 函数对象上挂状态（避免与用户属性冲突）
const k_calls = "__shu_mock_calls";
const k_callCount = "__shu_mock_callCount";
const k_impl = "__shu_mock_impl";
// 对外暴露的只读名
const k_calls_pub = "calls";
const k_callCount_pub = "callCount";

/// 向 JS 数组 arr 末尾追加 elem（设置 arr[idx]=elem 并更新 length）
fn arrayAppend(ctx: jsc.JSContextRef, arr: jsc.JSObjectRef, idx: usize, elem: jsc.JSValueRef) void {
    var buf: [16]u8 = undefined;
    const slice = std.fmt.bufPrintZ(&buf, "{d}", .{idx}) catch return;
    const k_idx = jsc.JSStringCreateWithUTF8CString(slice.ptr);
    defer jsc.JSStringRelease(k_idx);
    _ = jsc.JSObjectSetProperty(ctx, arr, k_idx, elem, jsc.kJSPropertyAttributeNone, null);
    const k_len = jsc.JSStringCreateWithUTF8CString("length");
    defer jsc.JSStringRelease(k_len);
    _ = jsc.JSObjectSetProperty(ctx, arr, k_len, jsc.JSValueMakeNumber(ctx, @floatFromInt(idx + 1)), jsc.kJSPropertyAttributeNone, null);
}

/// 内部：创建带 .calls、.callCount 的 mock 函数，可选 impl_val 作为实现（undefined 表示纯记录不调用）
fn createMockFn(ctx: jsc.JSContextRef, impl_val: jsc.JSValueRef) jsc.JSObjectRef {
    const k_fn = jsc.JSStringCreateWithUTF8CString("fn");
    defer jsc.JSStringRelease(k_fn);
    const mock_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_fn, mockInstanceCallback);
    const empty: [0]jsc.JSValueRef = .{};
    const calls_arr = jsc.JSObjectMakeArray(ctx, 0, &empty, null);
    const k_calls_js = jsc.JSStringCreateWithUTF8CString(k_calls);
    defer jsc.JSStringRelease(k_calls_js);
    const k_count_js = jsc.JSStringCreateWithUTF8CString(k_callCount);
    defer jsc.JSStringRelease(k_count_js);
    const k_impl_js = jsc.JSStringCreateWithUTF8CString(k_impl);
    defer jsc.JSStringRelease(k_impl_js);
    const k_calls_pub_js = jsc.JSStringCreateWithUTF8CString(k_calls_pub);
    defer jsc.JSStringRelease(k_calls_pub_js);
    const k_callCount_pub_js = jsc.JSStringCreateWithUTF8CString(k_callCount_pub);
    defer jsc.JSStringRelease(k_callCount_pub_js);
    _ = jsc.JSObjectSetProperty(ctx, mock_fn, k_calls_js, calls_arr, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, mock_fn, k_count_js, jsc.JSValueMakeNumber(ctx, 0), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, mock_fn, k_impl_js, impl_val, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, mock_fn, k_calls_pub_js, calls_arr, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, mock_fn, k_callCount_pub_js, jsc.JSValueMakeNumber(ctx, 0), jsc.kJSPropertyAttributeNone, null);
    return mock_fn;
}

/// mock.fn([implementation]) 创建时的回调：无参或一参（实现函数）；返回带 .calls、.callCount 的 mock 函数
fn mockFnCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const impl_val = if (argumentCount >= 1 and jsc.JSObjectIsFunction(ctx, @ptrCast(arguments[0]))) arguments[0] else jsc.JSValueMakeUndefined(ctx);
    return createMockFn(ctx, impl_val);
}

/// mock.method(object, methodName [, options])：将 object[methodName] 替换为 mock 函数（原方法作为 impl 实现，即 spy）；返回该 mock，具 .calls、.callCount。options 暂未解析。
fn mockMethodCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const obj = jsc.JSValueToObject(ctx, arguments[0], null) orelse return jsc.JSValueMakeUndefined(ctx);
    const name_ref = jsc.JSValueToStringCopy(ctx, arguments[1], null);
    defer jsc.JSStringRelease(name_ref);
    const original = jsc.JSObjectGetProperty(ctx, obj, name_ref, null);
    const original_impl = if (jsc.JSObjectIsFunction(ctx, @ptrCast(original))) original else jsc.JSValueMakeUndefined(ctx);
    const mock_fn = createMockFn(ctx, original_impl);
    _ = jsc.JSObjectSetProperty(ctx, obj, name_ref, mock_fn, jsc.kJSPropertyAttributeNone, null);
    return mock_fn;
}

/// 每次调用 mock 函数时执行：记录参数到 .calls、递增 .callCount，若有实现则调用并返回其返回值
fn mockInstanceCallback(
    ctx: jsc.JSContextRef,
    function_obj: jsc.JSObjectRef,
    thisObject: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const k_calls_js = jsc.JSStringCreateWithUTF8CString(k_calls);
    defer jsc.JSStringRelease(k_calls_js);
    const k_count_js = jsc.JSStringCreateWithUTF8CString(k_callCount);
    defer jsc.JSStringRelease(k_count_js);
    const k_impl_js = jsc.JSStringCreateWithUTF8CString(k_impl);
    defer jsc.JSStringRelease(k_impl_js);
    const k_callCount_pub_js = jsc.JSStringCreateWithUTF8CString(k_callCount_pub);
    defer jsc.JSStringRelease(k_callCount_pub_js);
    const calls_val = jsc.JSObjectGetProperty(ctx, function_obj, k_calls_js, null);
    const calls_obj = jsc.JSValueToObject(ctx, calls_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const count_val = jsc.JSObjectGetProperty(ctx, function_obj, k_count_js, null);
    const current_count_f = jsc.JSValueToNumber(ctx, count_val, null);
    const current_count: usize = if (current_count_f >= 0 and std.math.isFinite(current_count_f)) @intFromFloat(current_count_f) else 0;
    const args_arr = if (argumentCount == 0) blk: {
        const empty: [0]jsc.JSValueRef = .{};
        break :blk jsc.JSObjectMakeArray(ctx, 0, &empty, null);
    } else jsc.JSObjectMakeArray(ctx, argumentCount, arguments, null);
    arrayAppend(ctx, calls_obj, current_count, args_arr);
    const new_count = current_count + 1;
    _ = jsc.JSObjectSetProperty(ctx, function_obj, k_count_js, jsc.JSValueMakeNumber(ctx, @floatFromInt(new_count)), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, function_obj, k_callCount_pub_js, jsc.JSValueMakeNumber(ctx, @floatFromInt(new_count)), jsc.kJSPropertyAttributeNone, null);
    const impl_val = jsc.JSObjectGetProperty(ctx, function_obj, k_impl_js, null);
    if (jsc.JSValueIsUndefined(ctx, impl_val)) return jsc.JSValueMakeUndefined(ctx);
    const impl_fn = jsc.JSValueToObject(ctx, impl_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    return jsc.JSObjectCallAsFunction(ctx, impl_fn, thisObject, argumentCount, arguments, exception);
}

/// [Borrows] 返回的 mock 对象由 ctx 所在全局生命周期持有；allocator 暂未使用，预留 timers 等扩展
/// 当前提供 mock.fn([implementation])、mock.method(object, methodName [, options])
pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSObjectRef {
    _ = allocator;
    const obj = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, obj, "fn", mockFnCallback);
    common.setMethod(ctx, obj, "method", mockMethodCallback);
    return obj;
}
