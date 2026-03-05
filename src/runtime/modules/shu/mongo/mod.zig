// shu:mongo — MongoDB 客户端占位；Node 无 node:mongo，通常用 npm mongodb；此处提供 MongoClient 形状便于后续接真实实现或存在性检测。
//
// ========== API 点位 ==========
//
// | 导出           | 说明 |
// |----------------|------|
// | MongoClient    | 构造函数，new MongoClient(uri[, options])；实例 connect/db/close 等占位抛 not implemented |

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");

/// 统一抛错：shu:mongo not implemented
fn throwNotImplemented(ctx: jsc.JSContextRef, exception: [*]jsc.JSValueRef) void {
    const msg = jsc.JSStringCreateWithUTF8CString("shu:mongo not implemented");
    defer jsc.JSStringRelease(msg);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_err = jsc.JSStringCreateWithUTF8CString("Error");
    defer jsc.JSStringRelease(k_err);
    const err_ctor = jsc.JSObjectGetProperty(ctx, global, k_err, null);
    const err_obj = jsc.JSValueToObject(ctx, err_ctor, null) orelse return;
    var args = [_]jsc.JSValueRef{jsc.JSValueMakeString(ctx, msg)};
    exception[0] = jsc.JSObjectCallAsConstructor(ctx, err_obj, 1, &args, null);
}

fn mongoStubCallback(
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

/// new MongoClient(uri[, options])：返回带 connect、db、close 等占位方法的实例
fn mongoClientConstructorCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    exception: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    _ = exception;
    const instance = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, instance, "connect", mongoStubCallback);
    common.setMethod(ctx, instance, "db", mongoStubCallback);
    common.setMethod(ctx, instance, "close", mongoStubCallback);
    return instance;
}

/// 返回 shu:mongo 的 exports：MongoClient 构造函数占位
pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    _ = allocator;
    const exports = jsc.JSObjectMake(ctx, null, null);
    const k_MongoClient = jsc.JSStringCreateWithUTF8CString("MongoClient");
    defer jsc.JSStringRelease(k_MongoClient);
    const ctor = jsc.JSObjectMakeFunctionWithCallback(ctx, k_MongoClient, mongoClientConstructorCallback);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_MongoClient, ctor, jsc.kJSPropertyAttributeNone, null);
    return exports;
}
