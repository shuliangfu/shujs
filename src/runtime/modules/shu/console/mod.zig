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
    var i: usize = 0;
    while (i < argumentCount) : (i += 1) {
        if (i > 0) std.debug.print(" ", .{});
        printConsoleValue(ctx, arguments[i]);
    }
    std.debug.print("\n", .{});
    return jsc.JSValueMakeUndefined(ctx);
}

/// 将 JSValue 以 console 友好的方式打印：
/// 1) string / null / undefined 直接走 JS 的 ToString 语义；
/// 2) 其他值优先尝试 JSON.stringify（让普通对象显示为 JSON）；
/// 3) stringify 失败或返回 undefined 时回退 ToString，保证不丢输出。
fn printConsoleValue(ctx: jsc.JSContextRef, value: jsc.JSValueRef) void {
    if (jsc.JSValueIsString(ctx, value) or jsc.JSValueIsNull(ctx, value) or jsc.JSValueIsUndefined(ctx, value)) {
        printJsValueAsString(ctx, value);
        return;
    }
    if (tryPrintViaJsonStringify(ctx, value)) return;
    printJsValueAsString(ctx, value);
}

/// 尝试通过 globalThis.JSON.stringify(value) 打印；成功返回 true，失败返回 false。
/// 该路径用于把普通对象输出为可读 JSON，而不是 [object Object]。
fn tryPrintViaJsonStringify(ctx: jsc.JSContextRef, value: jsc.JSValueRef) bool {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_json = jsc.JSStringCreateWithUTF8CString("JSON");
    defer jsc.JSStringRelease(k_json);
    const json_val = jsc.JSObjectGetProperty(ctx, global, k_json, null);
    if (jsc.JSValueIsUndefined(ctx, json_val) or jsc.JSValueIsNull(ctx, json_val)) return false;
    const json_obj = jsc.JSValueToObject(ctx, json_val, null) orelse return false;

    const k_stringify = jsc.JSStringCreateWithUTF8CString("stringify");
    defer jsc.JSStringRelease(k_stringify);
    const stringify_val = jsc.JSObjectGetProperty(ctx, json_obj, k_stringify, null);
    if (jsc.JSValueIsUndefined(ctx, stringify_val) or jsc.JSValueIsNull(ctx, stringify_val)) return false;
    const stringify_fn = jsc.JSValueToObject(ctx, stringify_val, null) orelse return false;

    var argv = [_]jsc.JSValueRef{value};
    var exc_call: jsc.JSValueRef = jsc.JSValueMakeUndefined(ctx);
    const json_text = jsc.JSObjectCallAsFunction(ctx, stringify_fn, json_obj, 1, &argv, @ptrCast(&exc_call));
    if (!jsc.JSValueIsUndefined(ctx, exc_call) and !jsc.JSValueIsNull(ctx, exc_call)) return false;
    if (jsc.JSValueIsUndefined(ctx, json_text) or jsc.JSValueIsNull(ctx, json_text)) return false;
    printJsValueAsString(ctx, json_text);
    return true;
}

/// 按 JS ToString 语义把单个值转换为 UTF-8 并输出到 stdout。
fn printJsValueAsString(ctx: jsc.JSContextRef, value: jsc.JSValueRef) void {
    var buf: [4096]u8 = undefined;
    const str_ref = jsc.JSValueToStringCopy(ctx, value, null);
    defer jsc.JSStringRelease(str_ref);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(str_ref);
    if (max_sz == 0 or max_sz > buf.len) return;
    const n = jsc.JSStringGetUTF8CString(str_ref, &buf, max_sz);
    if (n > 0) std.debug.print("{s}", .{buf[0 .. n - 1]});
}

/// 返回 shu:console 的 exports（即 globalThis.console，与 register 注册的 console 同一引用）
pub fn getExports(ctx: jsc.JSContextRef, _: std.mem.Allocator) jsc.JSValueRef {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const name = jsc.JSStringCreateWithUTF8CString("console");
    defer jsc.JSStringRelease(name);
    const val = jsc.JSObjectGetProperty(ctx, global, name, null);
    return val;
}
