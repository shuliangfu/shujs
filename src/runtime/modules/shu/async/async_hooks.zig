// shu:async_hooks — 异步资源生命周期钩子，对应 node:async_hooks
//
// ========== 已实现的 API（与 Node 兼容） ==========
//
//   - executionAsyncId()           当前执行上下文 async id（timers 回调内随上下文变化，否则为 1）
//   - triggerAsyncId()             触发当前回调的 async id（timers 回调内随上下文变化，否则为 0）
//   - createHook({ init, before, after, destroy, promiseResolve })  返回钩子实例；enable() 后 timers 会触发 init/before/after/destroy
//   - executionAsyncResource()     当前执行关联的资源（定时器回调内为 { type:'Timeout', id }，否则为 {}）
//   - AsyncResource                类：new AsyncResource(type[, { triggerAsyncId }])
//   - AsyncResource.prototype.asyncId()          返回本资源的 async id
//   - AsyncResource.prototype.runInAsyncScope(fn, thisArg, ...args) 在资源上下文中执行 fn.apply(thisArg, args)
//
// ========== 已与事件循环对接 ==========
//
//   - executionAsyncId / triggerAsyncId：已与 timers 对接，在 setTimeout/setInterval/setImmediate 回调内随当前 async 上下文变化。
//   - createHook：enable() 时注册到 context，timers 调度回调时会调用 init、before、after、destroy。
//   - executionAsyncResource()：在定时器回调内返回 { type: 'Timeout', id }，否则返回 {}。
//
// ========== 未实现 / 限制 ==========
//
//   - promiseResolve 钩子：未与 Promise 链对接，不会被调用。
//   - net、fs 等其它异步资源未对接 async_hooks，仅 timers 已对接。
//   - AsyncLocalStorage（node:async_context）未实现，可后续单独实现。

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
const async_context = @import("context.zig");

/// 全局自增 asyncId，用于 AsyncResource 分配 id
var g_async_id_next: std.atomic.Value(u64) = .{ .raw = 1 };

/// executionAsyncId()：返回当前执行上下文的 async id（与 timers 等对接后随回调变化）
fn executionAsyncIdCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    return jsc.JSValueMakeNumber(ctx, @floatFromInt(async_context.currentExecutionId()));
}

/// triggerAsyncId()：返回触发当前回调的资源的 async id
fn triggerAsyncIdCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    return jsc.JSValueMakeNumber(ctx, @floatFromInt(async_context.currentTriggerId()));
}

/// createHook 返回的实例的 enable()：标记为已启用并注册到 context，之后 timers 等调度时会触发 init/before/after/destroy
fn asyncHookEnableCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const k_enabled = jsc.JSStringCreateWithUTF8CString("_enabled");
    defer jsc.JSStringRelease(k_enabled);
    _ = jsc.JSObjectSetProperty(ctx, thisObject, k_enabled, jsc.JSValueMakeBoolean(ctx, true), jsc.kJSPropertyAttributeNone, null);
    async_context.registerHook(ctx, thisObject);
    return thisObject;
}

/// createHook 返回的实例的 disable()：标记为未启用并从 context 移除，不再收到 init/before/after/destroy
fn asyncHookDisableCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const k_enabled = jsc.JSStringCreateWithUTF8CString("_enabled");
    defer jsc.JSStringRelease(k_enabled);
    _ = jsc.JSObjectSetProperty(ctx, thisObject, k_enabled, jsc.JSValueMakeBoolean(ctx, false), jsc.kJSPropertyAttributeNone, null);
    async_context.unregisterHook(ctx, thisObject);
    return jsc.JSValueMakeUndefined(ctx);
}

/// createHook(callbacks)：创建钩子实例，callbacks 可选 init、before、after、destroy、promiseResolve。返回带 enable/disable 的对象。
fn createHookCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const hook = jsc.JSObjectMake(ctx, null, null);
    const k_init = jsc.JSStringCreateWithUTF8CString("init");
    defer jsc.JSStringRelease(k_init);
    const k_before = jsc.JSStringCreateWithUTF8CString("before");
    defer jsc.JSStringRelease(k_before);
    const k_after = jsc.JSStringCreateWithUTF8CString("after");
    defer jsc.JSStringRelease(k_after);
    const k_destroy = jsc.JSStringCreateWithUTF8CString("destroy");
    defer jsc.JSStringRelease(k_destroy);
    const k_promiseResolve = jsc.JSStringCreateWithUTF8CString("promiseResolve");
    defer jsc.JSStringRelease(k_promiseResolve);
    if (argumentCount >= 1) {
        const opts = jsc.JSValueToObject(ctx, arguments[0], null);
        if (opts) |o| {
            _ = jsc.JSObjectSetProperty(ctx, hook, k_init, jsc.JSObjectGetProperty(ctx, o, k_init, null), jsc.kJSPropertyAttributeNone, null);
            _ = jsc.JSObjectSetProperty(ctx, hook, k_before, jsc.JSObjectGetProperty(ctx, o, k_before, null), jsc.kJSPropertyAttributeNone, null);
            _ = jsc.JSObjectSetProperty(ctx, hook, k_after, jsc.JSObjectGetProperty(ctx, o, k_after, null), jsc.kJSPropertyAttributeNone, null);
            _ = jsc.JSObjectSetProperty(ctx, hook, k_destroy, jsc.JSObjectGetProperty(ctx, o, k_destroy, null), jsc.kJSPropertyAttributeNone, null);
            _ = jsc.JSObjectSetProperty(ctx, hook, k_promiseResolve, jsc.JSObjectGetProperty(ctx, o, k_promiseResolve, null), jsc.kJSPropertyAttributeNone, null);
        }
    }
    common.setMethod(ctx, hook, "enable", asyncHookEnableCallback);
    common.setMethod(ctx, hook, "disable", asyncHookDisableCallback);
    const k_enabled = jsc.JSStringCreateWithUTF8CString("_enabled");
    defer jsc.JSStringRelease(k_enabled);
    _ = jsc.JSObjectSetProperty(ctx, hook, k_enabled, jsc.JSValueMakeBoolean(ctx, false), jsc.kJSPropertyAttributeNone, null);
    return hook;
}

/// executionAsyncResource()：返回当前执行上下文关联的资源对象；在定时器等回调内为 timers 传入的 resource（如 { type, id }），否则返回空对象 {}
fn executionAsyncResourceCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const resource = async_context.currentResource(ctx);
    if (jsc.JSValueIsUndefined(ctx, resource) or jsc.JSValueIsNull(ctx, resource)) return jsc.JSObjectMake(ctx, null, null);
    return resource;
}

/// AsyncResource 构造函数：new AsyncResource(type[, { triggerAsyncId }])
fn asyncResourceCtorCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const k_type = jsc.JSStringCreateWithUTF8CString("type");
    defer jsc.JSStringRelease(k_type);
    const k_asyncId = jsc.JSStringCreateWithUTF8CString("asyncId");
    defer jsc.JSStringRelease(k_asyncId);
    const k_triggerAsyncId = jsc.JSStringCreateWithUTF8CString("triggerAsyncId");
    defer jsc.JSStringRelease(k_triggerAsyncId);
    _ = jsc.JSObjectSetProperty(ctx, thisObject, k_type, if (argumentCount >= 1) arguments[0] else jsc.JSValueMakeUndefined(ctx), jsc.kJSPropertyAttributeNone, null);
    const id = g_async_id_next.fetchAdd(1, .monotonic);
    _ = jsc.JSObjectSetProperty(ctx, thisObject, k_asyncId, jsc.JSValueMakeNumber(ctx, @floatFromInt(id)), jsc.kJSPropertyAttributeNone, null);
    var trigger: f64 = 0;
    if (argumentCount >= 2) {
        const opts = jsc.JSValueToObject(ctx, arguments[1], null);
        if (opts) |o| {
            const tval = jsc.JSObjectGetProperty(ctx, o, k_triggerAsyncId, null);
            if (!jsc.JSValueIsUndefined(ctx, tval)) trigger = jsc.JSValueToNumber(ctx, tval, null);
        }
    }
    _ = jsc.JSObjectSetProperty(ctx, thisObject, k_triggerAsyncId, jsc.JSValueMakeNumber(ctx, trigger), jsc.kJSPropertyAttributeNone, null);
    return thisObject;
}

/// AsyncResource.prototype.asyncId()：返回本资源的 async id
fn asyncResourceAsyncIdCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const k_asyncId = jsc.JSStringCreateWithUTF8CString("asyncId");
    defer jsc.JSStringRelease(k_asyncId);
    const val = jsc.JSObjectGetProperty(ctx, thisObject, k_asyncId, null);
    return val;
}

/// AsyncResource.prototype.runInAsyncScope(fn, thisArg, ...args)：在“本资源”上下文中执行 fn.apply(thisArg, args)
fn asyncResourceRunInAsyncScopeCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const fn_val = arguments[0];
    const this_arg = if (argumentCount >= 2) arguments[1] else jsc.JSValueMakeUndefined(ctx);
    const n_args = if (argumentCount >= 2) argumentCount - 2 else 0;
    const k_apply = jsc.JSStringCreateWithUTF8CString("apply");
    defer jsc.JSStringRelease(k_apply);
    const apply_val = jsc.JSObjectGetProperty(ctx, jsc.JSValueToObject(ctx, fn_val, null) orelse return jsc.JSValueMakeUndefined(ctx), k_apply, null);
    if (jsc.JSValueIsUndefined(ctx, apply_val)) return jsc.JSValueMakeUndefined(ctx);
    var args_buf: [16]jsc.JSValueRef = undefined;
    const args_ptr = if (n_args <= 16) args_buf[0..] else (g_alloc.alloc(jsc.JSValueRef, n_args) catch return jsc.JSValueMakeUndefined(ctx));
    defer if (n_args > 16) g_alloc.free(args_ptr);
    var i: usize = 0;
    while (i < n_args) : (i += 1) args_ptr[i] = arguments[2 + i];
    if (n_args == 0) {
        var empty: [0]jsc.JSValueRef = .{};
        var two: [2]jsc.JSValueRef = .{ this_arg, jsc.JSObjectMakeArray(ctx, 0, &empty, null) };
        return jsc.JSObjectCallAsFunction(ctx, @ptrCast(apply_val), @ptrCast(fn_val), 2, &two, null);
    }
    const arr = jsc.JSObjectMakeArray(ctx, n_args, args_ptr.ptr, null);
    var two: [2]jsc.JSValueRef = .{ this_arg, arr };
    return jsc.JSObjectCallAsFunction(ctx, @ptrCast(apply_val), @ptrCast(fn_val), 2, &two, null);
}

var g_alloc: std.mem.Allocator = undefined;

/// 返回 require('shu:async_hooks') 的 exports；首次加载时初始化 async_context 以便 timers 等可调用 push/pop/emitInit/emitDestroy
pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    g_alloc = allocator;
    async_context.init(allocator);
    const exports = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, exports, "executionAsyncId", executionAsyncIdCallback);
    common.setMethod(ctx, exports, "triggerAsyncId", triggerAsyncIdCallback);
    common.setMethod(ctx, exports, "createHook", createHookCallback);
    common.setMethod(ctx, exports, "executionAsyncResource", executionAsyncResourceCallback);

    const k_AsyncResource = jsc.JSStringCreateWithUTF8CString("AsyncResource");
    defer jsc.JSStringRelease(k_AsyncResource);
    const ctor = jsc.JSObjectMakeFunctionWithCallback(ctx, k_AsyncResource, asyncResourceCtorCallback);
    const k_proto = jsc.JSStringCreateWithUTF8CString("prototype");
    defer jsc.JSStringRelease(k_proto);
    const proto = jsc.JSObjectGetProperty(ctx, ctor, k_proto, null);
    const proto_obj = jsc.JSValueToObject(ctx, proto, null) orelse return exports;
    common.setMethod(ctx, proto_obj, "asyncId", asyncResourceAsyncIdCallback);
    common.setMethod(ctx, proto_obj, "runInAsyncScope", asyncResourceRunInAsyncScopeCallback);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_AsyncResource, ctor, jsc.kJSPropertyAttributeNone, null);

    return exports;
}
