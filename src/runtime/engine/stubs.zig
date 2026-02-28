// 计划中内置的占位注册：调用时抛出 "Not implemented"，便于清单中「全部写上」
// 实现时移入独立模块（如 buffer.zig、require.zig、bun.zig、websocket.zig）并在此处改为调用真实 register

const std = @import("std");
const jsc = @import("jsc");

/// 占位：向全局注册 Buffer、require、WebSocket、Bun（Bun.serve / Bun.file / Bun.write）；allocator 统一传入（§1.1），本模块暂不使用
pub fn register(ctx: jsc.JSGlobalContextRef, allocator: ?std.mem.Allocator) void {
    _ = allocator;
    const global = jsc.JSContextGetGlobalObject(ctx);
    setGlobalFunction(ctx, global, "Buffer", bufferNotImplementedCallback);
    setGlobalFunction(ctx, global, "require", requireNotImplementedCallback);
    setGlobalFunction(ctx, global, "WebSocket", websocketNotImplementedCallback);
    registerBunStub(ctx, global);
}

fn setGlobalFunction(ctx: jsc.JSGlobalContextRef, global: jsc.JSObjectRef, name: [*]const u8, callback: jsc.JSObjectCallAsFunctionCallback) void {
    const name_ref = jsc.JSStringCreateWithUTF8CString(name);
    defer jsc.JSStringRelease(name_ref);
    const fn_ref = jsc.JSObjectMakeFunctionWithCallback(ctx, name_ref, callback);
    _ = jsc.JSObjectSetProperty(ctx, global, name_ref, fn_ref, jsc.kJSPropertyAttributeNone, null);
}

fn throwNotImplemented(ctx: jsc.JSContextRef, msg: []const u8) void {
    var script_buf: [256]u8 = undefined;
    const script = std.fmt.bufPrintZ(&script_buf, "throw new Error(\"{s}\");", .{msg}) catch return;
    const script_ref = jsc.JSStringCreateWithUTF8CString(script.ptr);
    defer jsc.JSStringRelease(script_ref);
    _ = jsc.JSEvaluateScript(ctx, script_ref, null, null, 1, null);
}

fn bufferNotImplementedCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    throwNotImplemented(ctx, "Buffer is not implemented");
    return jsc.JSValueMakeUndefined(ctx);
}

fn requireNotImplementedCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    throwNotImplemented(ctx, "require() is not implemented");
    return jsc.JSValueMakeUndefined(ctx);
}

fn websocketNotImplementedCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    throwNotImplemented(ctx, "WebSocket is not implemented");
    return jsc.JSValueMakeUndefined(ctx);
}

fn registerBunStub(ctx: jsc.JSGlobalContextRef, global: jsc.JSObjectRef) void {
    const name_bun = jsc.JSStringCreateWithUTF8CString("Bun");
    defer jsc.JSStringRelease(name_bun);
    const bun_obj = jsc.JSObjectMake(ctx, null, null);
    setMethod(ctx, bun_obj, "serve", bunServeNotImplementedCallback);
    setMethod(ctx, bun_obj, "file", bunFileNotImplementedCallback);
    setMethod(ctx, bun_obj, "write", bunWriteNotImplementedCallback);
    _ = jsc.JSObjectSetProperty(ctx, global, name_bun, bun_obj, jsc.kJSPropertyAttributeNone, null);
}

fn setMethod(ctx: jsc.JSGlobalContextRef, obj: jsc.JSObjectRef, method_name: [*]const u8, callback: jsc.JSObjectCallAsFunctionCallback) void {
    const name_ref = jsc.JSStringCreateWithUTF8CString(method_name);
    defer jsc.JSStringRelease(name_ref);
    const fn_ref = jsc.JSObjectMakeFunctionWithCallback(ctx, name_ref, callback);
    _ = jsc.JSObjectSetProperty(ctx, obj, name_ref, fn_ref, jsc.kJSPropertyAttributeNone, null);
}

fn bunServeNotImplementedCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    throwNotImplemented(ctx, "Bun.serve() is not implemented");
    return jsc.JSValueMakeUndefined(ctx);
}

fn bunFileNotImplementedCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    throwNotImplemented(ctx, "Bun.file() is not implemented");
    return jsc.JSValueMakeUndefined(ctx);
}

fn bunWriteNotImplementedCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    throwNotImplemented(ctx, "Bun.write() is not implemented");
    return jsc.JSValueMakeUndefined(ctx);
}
