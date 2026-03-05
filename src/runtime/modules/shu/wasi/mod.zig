// shu:wasi — 与 node:wasi API 兼容；WASI 类可构造，start() 暂未对接 WASM 运行时
//
// ========== API 兼容情况 ==========
//
// | API   | 兼容 | 说明 |
// |-------|------|------|
// | WASI  | ✓    | 构造函数 new WASI(options)；实例有 start(instance)、getImportObject() |
// | start | ✓    | 暂抛 "WASI.start() is not implemented"（需 WASM 运行时） |
// | getImportObject | ✓ | 返回 { wasi_snapshot_preview1: {} } 等占位，供 WebAssembly.instantiate 不报错 |

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");

/// WASI 实例的 start(instance)：Node 会调用 instance 的 _start()；此处未实现 WASM 运行时，抛错
fn wasiStartCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    _ = argumentCount;
    _ = arguments;
    const msg = jsc.JSStringCreateWithUTF8CString("WASI.start() is not implemented");
    defer jsc.JSStringRelease(msg);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_err = jsc.JSStringCreateWithUTF8CString("Error");
    defer jsc.JSStringRelease(k_err);
    const err_ctor = jsc.JSObjectGetProperty(ctx, global, k_err, null);
    const err_obj = jsc.JSValueToObject(ctx, err_ctor, null) orelse return jsc.JSValueMakeUndefined(ctx);
    var args = [_]jsc.JSValueRef{jsc.JSValueMakeString(ctx, msg)};
    exception[0] = jsc.JSObjectCallAsConstructor(ctx, err_obj, 1, &args, null);
    return jsc.JSValueMakeUndefined(ctx);
}

/// WASI 实例的 getImportObject()：返回供 WebAssembly.instantiate 使用的 import 对象（占位）
fn wasiGetImportObjectCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const import_obj = jsc.JSObjectMake(ctx, null, null);
    const k_preview1 = jsc.JSStringCreateWithUTF8CString("wasi_snapshot_preview1");
    defer jsc.JSStringRelease(k_preview1);
    const wasi_import = jsc.JSObjectMake(ctx, null, null);
    _ = jsc.JSObjectSetProperty(ctx, import_obj, k_preview1, wasi_import, jsc.kJSPropertyAttributeNone, null);
    return import_obj;
}

/// WASI(options)：工厂函数，创建并返回 WASI 实例（new WASI() 与 WASI() 均可用；JSC 未暴露 JSObjectMakeConstructor，用普通函数返回实例）
fn wasiFactoryCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    _ = argumentCount;
    _ = arguments;
    const instance = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, instance, "start", wasiStartCallback);
    common.setMethod(ctx, instance, "getImportObject", wasiGetImportObjectCallback);
    return instance;
}

/// 返回 shu:wasi 的 exports：WASI 工厂函数（作为构造函数使用）
pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    _ = allocator;
    const exports = jsc.JSObjectMake(ctx, null, null);
    const k_wasi = jsc.JSStringCreateWithUTF8CString("WASI");
    defer jsc.JSStringRelease(k_wasi);
    const wasi_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_wasi, wasiFactoryCallback);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_wasi, wasi_fn, jsc.kJSPropertyAttributeNone, null);
    return exports;
}
