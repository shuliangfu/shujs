// performance / performance.now()：高精度计时（毫秒，与 epoch 无关，用于相对耗时）

const std = @import("std");
const jsc = @import("jsc");
const errors = @import("errors");
const libs_process = @import("libs_process");

/// 向全局注册 performance 对象及 performance.now()；allocator 统一传入（§1.1），本模块暂不使用
pub fn register(ctx: jsc.JSGlobalContextRef, allocator: ?std.mem.Allocator) void {
    _ = allocator;
    const global = jsc.JSContextGetGlobalObject(ctx);
    const name_perf = jsc.JSStringCreateWithUTF8CString("performance");
    defer jsc.JSStringRelease(name_perf);
    const existing = jsc.JSObjectGetProperty(ctx, global, name_perf, null);
    if (!jsc.JSValueIsUndefined(ctx, existing)) return;
    const perf_obj = jsc.JSObjectMake(ctx, null, null);
    setMethod(ctx, perf_obj, "now", performanceNowCallback);
    _ = jsc.JSObjectSetProperty(ctx, global, name_perf, perf_obj, jsc.kJSPropertyAttributeNone, null);
}

fn setMethod(ctx: jsc.JSGlobalContextRef, obj: jsc.JSObjectRef, name: [*]const u8, callback: jsc.JSObjectCallAsFunctionCallback) void {
    const name_ref = jsc.JSStringCreateWithUTF8CString(name);
    defer jsc.JSStringRelease(name_ref);
    const fn_ref = jsc.JSObjectMakeFunctionWithCallback(ctx, name_ref, callback);
    _ = jsc.JSObjectSetProperty(ctx, obj, name_ref, fn_ref, jsc.kJSPropertyAttributeNone, null);
}

/// performance.now()：返回高精度毫秒数（单调递增，用于测量耗时）
fn performanceNowCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const io = libs_process.getProcessIo() orelse return jsc.JSValueMakeNumber(ctx, 0);
    const ns = std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds;
    const ms = @as(f64, @floatFromInt(ns)) / 1_000_000.0;
    return jsc.JSValueMakeNumber(ctx, ms);
}
