// shu:tracing — 与 node:tracing API 兼容，no-op 实现
//
// ========== API 兼容情况 ==========
//
// | API           | 兼容     | 说明 |
// |---------------|----------|------|
// | createTracing | ✅ 已实现 | 返回 { enable(), disable() } 无操作，不采集追踪数据 |
// | trace         | ✅ 已实现 | 执行传入的 fn()，不记录 trace 事件 |
//

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");

fn noOpCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    return jsc.JSValueMakeUndefined(ctx);
}

/// trace(category, fn)：执行 fn()，不记录 trace；category 忽略
fn traceCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argc: usize,
    argv: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argc < 2) return jsc.JSValueMakeUndefined(ctx);
    const fn_val = argv[1];
    if (jsc.JSValueIsUndefined(ctx, fn_val) or jsc.JSValueIsNull(ctx, fn_val)) return jsc.JSValueMakeUndefined(ctx);
    const fn_obj = jsc.JSValueToObject(ctx, fn_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    if (jsc.JSObjectIsFunction(ctx, fn_obj)) {
        var no_args: [0]jsc.JSValueRef = undefined;
        _ = jsc.JSObjectCallAsFunction(ctx, fn_obj, null, 0, &no_args, null);
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// createTracing({ categories })：返回 { enable, disable } 无操作对象
fn createTracingCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const obj = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, obj, "enable", noOpCallback);
    common.setMethod(ctx, obj, "disable", noOpCallback);
    return obj;
}

pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    _ = allocator;
    const exports = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, exports, "trace", traceCallback);
    common.setMethod(ctx, exports, "createTracing", createTracingCallback);
    return exports;
}
