// shu:kv — Deno KV 风格占位；与 Deno.openKv() / Deno.Kv API 对齐，后续写兼容时接真实实现。
//
// ========== API 点位（照搬 Deno KV） ==========
//
// | 导出    | 说明 |
// |---------|------|
// | openKv  | (path?: string) => Promise<Kv>；占位返回 resolve(KvStub)，KvStub 上 get/set/delete/list/getMany/atomic/close/enqueue/listenQueue/watch 等调用抛 not implemented |
//
// Deno.Kv 实例方法：get、getMany、set、delete、list、atomic、close、commitVersionstamp、enqueue、listenQueue、watch。

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");

/// 统一抛错：shu:kv not implemented
fn throwNotImplemented(ctx: jsc.JSContextRef, exception: [*]jsc.JSValueRef) void {
    const msg = jsc.JSStringCreateWithUTF8CString("shu:kv not implemented");
    defer jsc.JSStringRelease(msg);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_err = jsc.JSStringCreateWithUTF8CString("Error");
    defer jsc.JSStringRelease(k_err);
    const err_ctor = jsc.JSObjectGetProperty(ctx, global, k_err, null);
    const err_obj = jsc.JSValueToObject(ctx, err_ctor, null) orelse return;
    var args = [_]jsc.JSValueRef{jsc.JSValueMakeString(ctx, msg)};
    exception[0] = jsc.JSObjectCallAsConstructor(ctx, err_obj, 1, &args, null);
}

fn kvStubCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    exception: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    throwNotImplemented(ctx, exception);
    return jsc.JSValueMakeUndefined(ctx);
}

/// 创建 Deno.Kv 形状的占位对象：get、getMany、set、delete、list、atomic、close、commitVersionstamp、enqueue、listenQueue、watch
fn makeKvStub(ctx: jsc.JSContextRef) jsc.JSObjectRef {
    const stub = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, stub, "get", kvStubCallback);
    common.setMethod(ctx, stub, "getMany", kvStubCallback);
    common.setMethod(ctx, stub, "set", kvStubCallback);
    common.setMethod(ctx, stub, "delete", kvStubCallback);
    common.setMethod(ctx, stub, "list", kvStubCallback);
    common.setMethod(ctx, stub, "atomic", kvStubCallback);
    common.setMethod(ctx, stub, "close", kvStubCallback);
    common.setMethod(ctx, stub, "commitVersionstamp", kvStubCallback);
    common.setMethod(ctx, stub, "enqueue", kvStubCallback);
    common.setMethod(ctx, stub, "listenQueue", kvStubCallback);
    common.setMethod(ctx, stub, "watch", kvStubCallback);
    return stub;
}

/// openKv(path?: string)：返回 Promise<Kv>；占位实现 resolve(KvStub)，调用 Kv 方法时抛 not implemented
fn openKvCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    exception: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    _ = exception;
    const kv_stub = makeKvStub(ctx);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k = jsc.JSStringCreateWithUTF8CString("__kvStub");
    defer jsc.JSStringRelease(k);
    _ = jsc.JSObjectSetProperty(ctx, global, k, kv_stub, jsc.kJSPropertyAttributeNone, null);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const script = "Promise.resolve(globalThis.__kvStub)";
    const script_z = allocator.dupeZ(u8, script) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(script_z);
    const script_ref = jsc.JSStringCreateWithUTF8CString(script_z.ptr);
    defer jsc.JSStringRelease(script_ref);
    const promise = jsc.JSEvaluateScript(ctx, script_ref, null, null, 1, null);
    _ = jsc.JSObjectSetProperty(ctx, global, k, jsc.JSValueMakeUndefined(ctx), jsc.kJSPropertyAttributeNone, null);
    return promise;
}

/// 返回 shu:kv 的 exports：openKv（Deno KV 兼容占位）
pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    _ = allocator;
    const exports = jsc.JSObjectMake(ctx, null, null);
    const k_openKv = jsc.JSStringCreateWithUTF8CString("openKv");
    defer jsc.JSStringRelease(k_openKv);
    const openKv_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_openKv, openKvCallback);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_openKv, openKv_fn, jsc.kJSPropertyAttributeNone, null);
    return exports;
}
