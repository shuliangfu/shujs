// shu:cluster — 与 node:cluster API 兼容，纯 Zig 实现
//
// ========== API 兼容情况 ==========
//
// | API | 兼容 | 说明 |
// |-----|------|------|
// | isPrimary | ✅ 已实现 | 当前恒为 true（单进程模式，无 cluster fork） |
// | isMaster | ✅ 已实现 | 同 isPrimary（别名） |
// | isWorker | ✅ 已实现 | 恒为 false |
// | workers | ✅ 已实现 | 空对象 {}（无子 worker） |
// | settings | ✅ 已实现 | 空对象 {} |
// | fork() | ⚠ 占位 | 抛 "shu:cluster fork not implemented"；可后续用 Shu.system.fork 实现 |
// | setupPrimary() | ✅ 已实现 | 无操作 |
// | disconnect() | ✅ 已实现 | 无操作 |
//

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
const node_compat = @import("../node_compat/mod.zig");

/// fork() 未实现：当前为单进程，抛 "shu:cluster not implemented"
fn forkNotImplemented(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    this_obj: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    var no_args: [0]jsc.JSValueRef = undefined;
    var exc: jsc.JSValueRef = undefined;
    return node_compat.notImplementedCallback(ctx, this_obj, this_obj, 0, &no_args, @ptrCast(&exc));
}

/// setupPrimary() 无操作，返回 undefined
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

pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    _ = allocator;
    const exports = jsc.JSObjectMake(ctx, null, null);
    const k_name = jsc.JSStringCreateWithUTF8CString("__moduleName");
    defer jsc.JSStringRelease(k_name);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_name, jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString("cluster")), jsc.kJSPropertyAttributeNone, null);
    const k_primary = jsc.JSStringCreateWithUTF8CString("isPrimary");
    defer jsc.JSStringRelease(k_primary);
    const k_master = jsc.JSStringCreateWithUTF8CString("isMaster");
    defer jsc.JSStringRelease(k_master);
    const k_worker = jsc.JSStringCreateWithUTF8CString("isWorker");
    defer jsc.JSStringRelease(k_worker);
    const k_workers = jsc.JSStringCreateWithUTF8CString("workers");
    defer jsc.JSStringRelease(k_workers);
    const k_settings = jsc.JSStringCreateWithUTF8CString("settings");
    defer jsc.JSStringRelease(k_settings);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_primary, jsc.JSValueMakeBoolean(ctx, true), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_master, jsc.JSValueMakeBoolean(ctx, true), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_worker, jsc.JSValueMakeBoolean(ctx, false), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_workers, jsc.JSObjectMake(ctx, null, null), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_settings, jsc.JSObjectMake(ctx, null, null), jsc.kJSPropertyAttributeNone, null);
    common.setMethod(ctx, exports, "fork", forkNotImplemented);
    common.setMethod(ctx, exports, "setupPrimary", noOpCallback);
    common.setMethod(ctx, exports, "disconnect", noOpCallback);
    return exports;
}
