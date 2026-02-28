// shu:async_context — 异步上下文存储，对应 node:async_context
// 导出 AsyncLocalStorage：run(store, callback)、getStore()、enterWith(store)、exit(callback)、snapshot()、disable()
// 依赖 async/context.zig 的 storage 与 push/pop 栈，与 timers 等事件循环已对接

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");
const ctx = @import("context.zig");

/// §1.1 显式 allocator 收敛：getExports 时注入，run/ALS 等回调优先使用
threadlocal var g_async_context_allocator: ?std.mem.Allocator = null;

/// 从 ALS 实例（thisObject）上读取 _storageId
fn getStorageIdFromThis(ctx_ref: jsc.JSContextRef, thisObject: jsc.JSObjectRef) u32 {
    const k = jsc.JSStringCreateWithUTF8CString("_storageId");
    defer jsc.JSStringRelease(k);
    const val = jsc.JSObjectGetProperty(ctx_ref, thisObject, k, null);
    if (jsc.JSValueIsUndefined(ctx_ref, val)) return 0;
    return @intFromFloat(jsc.JSValueToNumber(ctx_ref, val, null));
}

/// 内部：在指定 store 的上下文中执行 callback，并返回 callback 的返回值
fn runWithStore(ctx_ref: jsc.JSContextRef, storage_id: u32, store: jsc.JSValueRef, callback: jsc.JSValueRef) jsc.JSValueRef {
    ctx.init(g_async_context_allocator orelse globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx_ref));
    const ids = ctx.allocId();
    if (ids.async_id == 0) return jsc.JSValueMakeUndefined(ctx_ref);
    ctx.pushContext(ctx_ref, ids.async_id, ids.trigger_async_id, jsc.JSValueMakeUndefined(ctx_ref));
    ctx.setStorageStore(ctx_ref, storage_id, ids.async_id, store);
    const empty_args: [0]jsc.JSValueRef = .{};
    const result = jsc.JSObjectCallAsFunction(ctx_ref, @ptrCast(callback), null, 0, &empty_args, null);
    ctx.deleteStorageStore(ctx_ref, storage_id, ids.async_id);
    ctx.popContext(ctx_ref);
    return result;
}

/// AsyncLocalStorage 构造函数：new AsyncLocalStorage([options])，options 可选 name、defaultValue 等，本实现仅分配 storageId
fn asyncLocalStorageCtor(
    ctx_ref: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    ctx.init(g_async_context_allocator orelse globals.current_allocator orelse return thisObject);
    const sid = ctx.allocStorageId();
    const k = jsc.JSStringCreateWithUTF8CString("_storageId");
    defer jsc.JSStringRelease(k);
    _ = jsc.JSObjectSetProperty(ctx_ref, thisObject, k, jsc.JSValueMakeNumber(ctx_ref, @floatFromInt(sid)), jsc.kJSPropertyAttributeNone, null);
    return thisObject;
}

/// run(store, callback)：在 callback 及其后续异步调用中 getStore() 返回 store；返回 callback 的返回值
fn alsRun(
    ctx_ref: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx_ref);
    const storage_id = getStorageIdFromThis(ctx_ref, thisObject);
    if (storage_id == 0) return jsc.JSValueMakeUndefined(ctx_ref);
    return runWithStore(ctx_ref, storage_id, arguments[0], arguments[1]);
}

/// getStore()：返回当前异步上下文中本实例的 store，无则 undefined
fn alsGetStore(
    ctx_ref: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const storage_id = getStorageIdFromThis(ctx_ref, thisObject);
    if (storage_id == 0) return jsc.JSValueMakeUndefined(ctx_ref);
    return ctx.getStorageStore(ctx_ref, storage_id);
}

/// enterWith(store)：将当前执行上下文（及后续异步）绑定为 store
fn alsEnterWith(
    ctx_ref: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx_ref);
    const storage_id = getStorageIdFromThis(ctx_ref, thisObject);
    if (storage_id == 0) return jsc.JSValueMakeUndefined(ctx_ref);
    const async_id = ctx.currentExecutionId();
    ctx.setStorageStore(ctx_ref, storage_id, async_id, arguments[0]);
    return jsc.JSValueMakeUndefined(ctx_ref);
}

/// exit(callback)：在“无 store”的上下文中执行 callback，执行完后恢复原 store；返回 callback 的返回值
fn alsExit(
    ctx_ref: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx_ref);
    const storage_id = getStorageIdFromThis(ctx_ref, thisObject);
    if (storage_id == 0) return jsc.JSValueMakeUndefined(ctx_ref);
    const async_id = ctx.currentExecutionId();
    const saved = ctx.getStorageStore(ctx_ref, storage_id);
    ctx.deleteStorageStore(ctx_ref, storage_id, async_id);
    const result = jsc.JSObjectCallAsFunction(ctx_ref, @ptrCast(arguments[0]), null, 0, &[_]jsc.JSValueRef{}, null);
    if (!jsc.JSValueIsUndefined(ctx_ref, saved)) ctx.setStorageStore(ctx_ref, storage_id, async_id, saved);
    return result;
}

/// snapshot()：捕获当前 store，返回函数 fn => this.run(capturedStore, fn)
fn alsSnapshot(
    ctx_ref: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const storage_id = getStorageIdFromThis(ctx_ref, thisObject);
    if (storage_id == 0) return jsc.JSValueMakeUndefined(ctx_ref);
    const store = ctx.getStorageStore(ctx_ref, storage_id);
    const k_sid = jsc.JSStringCreateWithUTF8CString("__snapshot_storage_id");
    defer jsc.JSStringRelease(k_sid);
    const k_store = jsc.JSStringCreateWithUTF8CString("__snapshot_store");
    defer jsc.JSStringRelease(k_store);
    const k_als = jsc.JSStringCreateWithUTF8CString("__snapshot_als");
    defer jsc.JSStringRelease(k_als);
    const k_name = jsc.JSStringCreateWithUTF8CString("snapshot");
    defer jsc.JSStringRelease(k_name);
    const fn_obj = jsc.JSObjectMakeFunctionWithCallback(ctx_ref, k_name, alsSnapshotCallback);
    _ = jsc.JSObjectSetProperty(ctx_ref, fn_obj, k_sid, jsc.JSValueMakeNumber(ctx_ref, @floatFromInt(storage_id)), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx_ref, fn_obj, k_store, store, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx_ref, fn_obj, k_als, thisObject, jsc.kJSPropertyAttributeNone, null);
    return fn_obj;
}

/// snapshot() 返回的函数被调用时：run(__snapshot_store, arguments[0])
fn alsSnapshotCallback(
    ctx_ref: jsc.JSContextRef,
    callee: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const k_sid = jsc.JSStringCreateWithUTF8CString("__snapshot_storage_id");
    defer jsc.JSStringRelease(k_sid);
    const k_store = jsc.JSStringCreateWithUTF8CString("__snapshot_store");
    defer jsc.JSStringRelease(k_store);
    const sid_val = jsc.JSObjectGetProperty(ctx_ref, callee, k_sid, null);
    const store_val = jsc.JSObjectGetProperty(ctx_ref, callee, k_store, null);
    if (jsc.JSValueIsUndefined(ctx_ref, sid_val) or argumentCount < 1) return jsc.JSValueMakeUndefined(ctx_ref);
    const storage_id: u32 = @intFromFloat(jsc.JSValueToNumber(ctx_ref, sid_val, null));
    return runWithStore(ctx_ref, storage_id, store_val, arguments[0]);
}

/// disable()：禁用实例，不再传播上下文；本实现仅 no-op，便于 GC 前调用
fn alsDisable(
    ctx_ref: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    return jsc.JSValueMakeUndefined(ctx_ref);
}

/// 返回 require('shu:async_context') 的 exports；仅导出 AsyncLocalStorage
pub fn getExports(ctx_ref: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    g_async_context_allocator = allocator;
    ctx.init(allocator);
    const exports = jsc.JSObjectMake(ctx_ref, null, null);
    const k_AsyncLocalStorage = jsc.JSStringCreateWithUTF8CString("AsyncLocalStorage");
    defer jsc.JSStringRelease(k_AsyncLocalStorage);
    const ctor = jsc.JSObjectMakeFunctionWithCallback(ctx_ref, k_AsyncLocalStorage, asyncLocalStorageCtor);
    const k_proto = jsc.JSStringCreateWithUTF8CString("prototype");
    defer jsc.JSStringRelease(k_proto);
    const proto = jsc.JSObjectGetProperty(ctx_ref, ctor, k_proto, null);
    const proto_obj = jsc.JSValueToObject(ctx_ref, proto, null) orelse return exports;
    common.setMethod(ctx_ref, proto_obj, "run", alsRun);
    common.setMethod(ctx_ref, proto_obj, "getStore", alsGetStore);
    common.setMethod(ctx_ref, proto_obj, "enterWith", alsEnterWith);
    common.setMethod(ctx_ref, proto_obj, "exit", alsExit);
    common.setMethod(ctx_ref, proto_obj, "snapshot", alsSnapshot);
    common.setMethod(ctx_ref, proto_obj, "disable", alsDisable);
    _ = jsc.JSObjectSetProperty(ctx_ref, exports, k_AsyncLocalStorage, ctor, jsc.kJSPropertyAttributeNone, null);
    return exports;
}
