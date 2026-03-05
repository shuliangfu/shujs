// 计划中内置的占位注册：调用时抛出 "Not implemented"，便于清单中「全部写上」
// 实现时移入独立模块（如 buffer.zig、require.zig、bun.zig、websocket.zig）并在此处改为调用真实 register

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../common.zig");

/// 占位：向全局注册 Buffer、require、WebSocket、Bun、reportError、MessageChannel、BroadcastChannel；allocator 统一传入（§1.1），本模块暂不使用
pub fn register(ctx: jsc.JSGlobalContextRef, allocator: ?std.mem.Allocator) void {
    _ = allocator;
    const global = jsc.JSContextGetGlobalObject(ctx);
    setGlobalFunction(ctx, global, "Buffer", bufferNotImplementedCallback);
    setGlobalFunction(ctx, global, "require", requireNotImplementedCallback);
    setGlobalFunction(ctx, global, "WebSocket", websocketNotImplementedCallback);
    setGlobalFunction(ctx, global, "reportError", reportErrorCallback);
    setGlobalFunction(ctx, global, "MessageChannel", messageChannelCallback);
    setGlobalFunction(ctx, global, "BroadcastChannel", broadcastChannelNotImplementedCallback);
    registerBunStub(ctx, global);
}

fn setGlobalFunction(ctx: jsc.JSGlobalContextRef, global: jsc.JSObjectRef, name: [*]const u8, callback: jsc.JSObjectCallAsFunctionCallback) void {
    const name_ref = jsc.JSStringCreateWithUTF8CString(name);
    defer jsc.JSStringRelease(name_ref);
    const fn_ref = jsc.JSObjectMakeFunctionWithCallback(ctx, name_ref, callback);
    _ = jsc.JSObjectSetProperty(ctx, global, name_ref, fn_ref, jsc.kJSPropertyAttributeNone, null);
}

/// 纯 Zig：new Error(msg) 后 setThrowAndThrow，无内联 throw new Error 脚本
fn throwNotImplemented(ctx: jsc.JSContextRef, msg: []const u8) void {
    var buf: [256]u8 = undefined;
    if (msg.len >= buf.len) return;
    @memcpy(buf[0..msg.len], msg);
    buf[msg.len] = 0;
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_Error = jsc.JSStringCreateWithUTF8CString("Error");
    defer jsc.JSStringRelease(k_Error);
    const Error_ctor = jsc.JSObjectGetProperty(ctx, global, k_Error, null);
    const err_obj = jsc.JSValueToObject(ctx, Error_ctor, null) orelse return;
    const msg_js = jsc.JSStringCreateWithUTF8CString(buf[0..].ptr);
    defer jsc.JSStringRelease(msg_js);
    var args: [1]jsc.JSValueRef = .{jsc.JSValueMakeString(ctx, msg_js)};
    var exception: ?jsc.JSValueRef = null;
    const err_instance = jsc.JSObjectCallAsConstructor(ctx, err_obj, 1, &args, @ptrCast(&exception));
    if (exception != null) return;
    _ = common.setThrowAndThrow(ctx, err_instance);
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

/// reportError(err)：Web 标准；委托 console.error(err)，若 console 不存在则忽略
fn reportErrorCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount == 0) return jsc.JSValueMakeUndefined(ctx);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_console = jsc.JSStringCreateWithUTF8CString("console");
    defer jsc.JSStringRelease(k_console);
    const console_val = jsc.JSObjectGetProperty(ctx, global, k_console, null);
    if (jsc.JSValueIsUndefined(ctx, console_val) or jsc.JSValueIsNull(ctx, console_val)) return jsc.JSValueMakeUndefined(ctx);
    const console_obj = jsc.JSValueToObject(ctx, console_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const k_error = jsc.JSStringCreateWithUTF8CString("error");
    defer jsc.JSStringRelease(k_error);
    const error_fn = jsc.JSObjectGetProperty(ctx, console_obj, k_error, null);
    if (jsc.JSValueIsUndefined(ctx, error_fn) or jsc.JSValueIsNull(ctx, error_fn)) return jsc.JSValueMakeUndefined(ctx);
    const error_obj = jsc.JSValueToObject(ctx, error_fn, null) orelse return jsc.JSValueMakeUndefined(ctx);
    var exception: ?jsc.JSValueRef = null;
    const args: [1]jsc.JSValueRef = .{arguments[0]};
    _ = jsc.JSObjectCallAsFunction(ctx, error_obj, console_obj, 1, &args, @ptrCast(&exception));
    return jsc.JSValueMakeUndefined(ctx);
}

/// MessageChannel 占位：返回 { port1, port2 }，各 port 有 postMessage（调用抛 not implemented）与 onmessage（初始为 undefined）
fn messageChannelPortPostMessageCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    throwNotImplemented(ctx, "MessageChannel port.postMessage is not implemented");
    return jsc.JSValueMakeUndefined(ctx);
}

fn makeMessagePort(ctx: jsc.JSContextRef) jsc.JSObjectRef {
    const port = jsc.JSObjectMake(ctx, null, null);
    setMethod(ctx, port, "postMessage", messageChannelPortPostMessageCallback);
    const k_onmessage = jsc.JSStringCreateWithUTF8CString("onmessage");
    defer jsc.JSStringRelease(k_onmessage);
    _ = jsc.JSObjectSetProperty(ctx, port, k_onmessage, jsc.JSValueMakeUndefined(ctx), jsc.kJSPropertyAttributeNone, null);
    return port;
}

fn messageChannelCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const channel = jsc.JSObjectMake(ctx, null, null);
    const k_port1 = jsc.JSStringCreateWithUTF8CString("port1");
    defer jsc.JSStringRelease(k_port1);
    const k_port2 = jsc.JSStringCreateWithUTF8CString("port2");
    defer jsc.JSStringRelease(k_port2);
    _ = jsc.JSObjectSetProperty(ctx, channel, k_port1, makeMessagePort(ctx), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, channel, k_port2, makeMessagePort(ctx), jsc.kJSPropertyAttributeNone, null);
    return channel;
}

fn broadcastChannelNotImplementedCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    throwNotImplemented(ctx, "BroadcastChannel is not implemented");
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
