// AbortController / AbortSignal：与 fetch 等取消请求配合
// 最小实现：new AbortController() 得到 controller，controller.signal（只读），controller.abort() 设置 signal.aborted

const std = @import("std");
const jsc = @import("jsc");

/// 向全局注册 AbortController（若引擎未提供则宿主提供）；allocator 统一传入（§1.1），本模块暂不使用
pub fn register(ctx: jsc.JSGlobalContextRef, allocator: ?std.mem.Allocator) void {
    _ = allocator;
    const global = jsc.JSContextGetGlobalObject(ctx);
    const name_ac = jsc.JSStringCreateWithUTF8CString("AbortController");
    defer jsc.JSStringRelease(name_ac);
    const existing = jsc.JSObjectGetProperty(ctx, global, name_ac, null);
    if (!jsc.JSValueIsUndefined(ctx, existing)) return;
    setGlobalConstructor(ctx, global, "AbortController", abortControllerConstructorCallback);
}

fn setGlobalConstructor(ctx: jsc.JSGlobalContextRef, global: jsc.JSObjectRef, name: [*]const u8, callback: jsc.JSObjectCallAsFunctionCallback) void {
    const name_ref = jsc.JSStringCreateWithUTF8CString(name);
    defer jsc.JSStringRelease(name_ref);
    const fn_ref = jsc.JSObjectMakeFunctionWithCallback(ctx, name_ref, callback);
    _ = jsc.JSObjectSetProperty(ctx, global, name_ref, fn_ref, jsc.kJSPropertyAttributeNone, null);
}

fn setMethod(ctx: jsc.JSGlobalContextRef, obj: jsc.JSObjectRef, method_name: [*]const u8, callback: jsc.JSObjectCallAsFunctionCallback) void {
    const name_ref = jsc.JSStringCreateWithUTF8CString(method_name);
    defer jsc.JSStringRelease(name_ref);
    const fn_ref = jsc.JSObjectMakeFunctionWithCallback(ctx, name_ref, callback);
    _ = jsc.JSObjectSetProperty(ctx, obj, name_ref, fn_ref, jsc.kJSPropertyAttributeNone, null);
}

/// 内部：signal 对象上存储是否已 abort 的属性名
const aborted_key = "__aborted";

/// new AbortController()：返回 { signal, abort() }
fn abortControllerConstructorCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const signal_obj = jsc.JSObjectMake(ctx, null, null);
    const name_aborted = jsc.JSStringCreateWithUTF8CString(aborted_key);
    defer jsc.JSStringRelease(name_aborted);
    _ = jsc.JSObjectSetProperty(ctx, signal_obj, name_aborted, jsc.JSValueMakeBoolean(ctx, false), jsc.kJSPropertyAttributeNone, null);
    const name_aborted_pub = jsc.JSStringCreateWithUTF8CString("aborted");
    defer jsc.JSStringRelease(name_aborted_pub);
    _ = jsc.JSObjectSetProperty(ctx, signal_obj, name_aborted_pub, jsc.JSValueMakeBoolean(ctx, false), jsc.kJSPropertyAttributeNone, null);
    setMethod(ctx, signal_obj, "toString", abortSignalToStringCallback);
    const controller = jsc.JSObjectMake(ctx, null, null);
    const name_signal = jsc.JSStringCreateWithUTF8CString("signal");
    defer jsc.JSStringRelease(name_signal);
    _ = jsc.JSObjectSetProperty(ctx, controller, name_signal, signal_obj, jsc.kJSPropertyAttributeNone, null);
    setMethod(ctx, controller, "abort", abortControllerAbortCallback);
    _ = jsc.JSObjectSetProperty(ctx, controller, jsc.JSStringCreateWithUTF8CString("__signal"), signal_obj, jsc.kJSPropertyAttributeNone, null);
    return controller;
}

fn abortSignalToStringCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const ref = jsc.JSStringCreateWithUTF8CString("[object AbortSignal]");
    defer jsc.JSStringRelease(ref);
    return jsc.JSValueMakeString(ctx, ref);
}

/// controller.abort()：将 signal.__aborted 设为 true
fn abortControllerAbortCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const name_sig = jsc.JSStringCreateWithUTF8CString("__signal");
    defer jsc.JSStringRelease(name_sig);
    const sig_val = jsc.JSObjectGetProperty(ctx, this, name_sig, null);
    const sig_obj = jsc.JSValueToObject(ctx, sig_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const name_aborted = jsc.JSStringCreateWithUTF8CString(aborted_key);
    defer jsc.JSStringRelease(name_aborted);
    _ = jsc.JSObjectSetProperty(ctx, sig_obj, name_aborted, jsc.JSValueMakeBoolean(ctx, true), jsc.kJSPropertyAttributeNone, null);
    const name_aborted_pub = jsc.JSStringCreateWithUTF8CString("aborted");
    defer jsc.JSStringRelease(name_aborted_pub);
    _ = jsc.JSObjectSetProperty(ctx, sig_obj, name_aborted_pub, jsc.JSValueMakeBoolean(ctx, true), jsc.kJSPropertyAttributeNone, null);
    return jsc.JSValueMakeUndefined(ctx);
}
