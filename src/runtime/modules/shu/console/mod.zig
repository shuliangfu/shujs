// 全局 console（log / warn / error / info / debug）注册；shu:console 协议返回同一 globalThis.console
// register 由 bindings 调用，getExports 供 require("shu:console")/node:console

const std = @import("std");
const jsc = @import("jsc");

/// 向全局对象注册 console 及其方法：log、warn、error、info、debug；由 bindings 调用；allocator 统一传入（§1.1），本模块暂不使用
pub fn register(ctx: jsc.JSGlobalContextRef, allocator: ?std.mem.Allocator) void {
    _ = allocator;
    const global = jsc.JSContextGetGlobalObject(ctx);
    const name_console = jsc.JSStringCreateWithUTF8CString("console");
    defer jsc.JSStringRelease(name_console);
    const console_obj = jsc.JSObjectMake(ctx, null, null);
    setMethod(ctx, console_obj, "log", logCallback);
    setMethod(ctx, console_obj, "warn", logCallback);
    setMethod(ctx, console_obj, "error", logCallback);
    setMethod(ctx, console_obj, "info", logCallback);
    setMethod(ctx, console_obj, "debug", logCallback);
    _ = jsc.JSObjectSetProperty(ctx, global, name_console, console_obj, jsc.kJSPropertyAttributeNone, null);
}

/// 在 obj 上设置名为 name 的方法，使用给定的 C 回调
fn setMethod(ctx: jsc.JSGlobalContextRef, obj: jsc.JSObjectRef, name: [*]const u8, callback: jsc.JSObjectCallAsFunctionCallback) void {
    const name_ref = jsc.JSStringCreateWithUTF8CString(name);
    defer jsc.JSStringRelease(name_ref);
    const fn_ref = jsc.JSObjectMakeFunctionWithCallback(ctx, name_ref, callback);
    _ = jsc.JSObjectSetProperty(ctx, obj, name_ref, fn_ref, jsc.kJSPropertyAttributeNone, null);
}

/// console.log / warn / error / info / debug 的共用实现：将参数转成字符串打印到 stdout，末尾换行
fn logCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    var buf: [4096]u8 = undefined;
    var i: usize = 0;
    while (i < argumentCount) : (i += 1) {
        if (i > 0) std.debug.print(" ", .{});
        const str_ref = jsc.JSValueToStringCopy(ctx, arguments[i], null);
        defer jsc.JSStringRelease(str_ref);
        const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(str_ref);
        if (max_sz > 0 and max_sz <= buf.len) {
            const n = jsc.JSStringGetUTF8CString(str_ref, &buf, max_sz);
            if (n > 0) std.debug.print("{s}", .{buf[0 .. n - 1]});
        }
    }
    std.debug.print("\n", .{});
    return jsc.JSValueMakeUndefined(ctx);
}

/// 返回 shu:console 的 exports（即 globalThis.console，与 register 注册的 console 同一引用）
pub fn getExports(ctx: jsc.JSContextRef, _: std.mem.Allocator) jsc.JSValueRef {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const name = jsc.JSStringCreateWithUTF8CString("console");
    defer jsc.JSStringRelease(name);
    const val = jsc.JSObjectGetProperty(ctx, global, name, null);
    return val;
}
