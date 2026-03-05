// Shu 子模块共用：在对象上挂方法、执行脚本返回 Promise 等；供 file、path、system、crond 等复用
// 放在 runtime/ 便于 engine 与 modules 共用

const jsc = @import("jsc");
const globals = @import("globals.zig");

/// 在 obj 上设置名为 name 的方法（C 回调）
pub fn setMethod(ctx: jsc.JSContextRef, obj: jsc.JSObjectRef, name: [*]const u8, callback: jsc.JSObjectCallAsFunctionCallback) void {
    const name_ref = jsc.JSStringCreateWithUTF8CString(name);
    defer jsc.JSStringRelease(name_ref);
    const fn_ref = jsc.JSObjectMakeFunctionWithCallback(ctx, name_ref, callback);
    _ = jsc.JSObjectSetProperty(ctx, obj, name_ref, fn_ref, jsc.kJSPropertyAttributeNone, null);
}

/// 将 error_value 设为 globalThis.__throw 并执行 throw（JSC C API 无直接“抛异常”接口，仅此一行脚本）；调用方在 Zig 中已创建 Error/TypeError/DOMException
pub fn setThrowAndThrow(ctx: jsc.JSContextRef, error_value: jsc.JSValueRef) jsc.JSValueRef {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k = jsc.JSStringCreateWithUTF8CString("__throw");
    defer jsc.JSStringRelease(k);
    _ = jsc.JSObjectSetProperty(ctx, global, k, error_value, jsc.kJSPropertyAttributeNone, null);
    const script = "throw globalThis.__throw;";
    const script_ref = jsc.JSStringCreateWithUTF8CString(script);
    defer jsc.JSStringRelease(script_ref);
    _ = jsc.JSEvaluateScript(ctx, script_ref, null, null, 1, null);
    return jsc.JSValueMakeUndefined(ctx);
}

/// 执行一段 JS 脚本并返回执行结果（用于异步 API 返回 Promise、crond 返回 { stop } 等）
pub fn evalPromiseScript(ctx: jsc.JSContextRef, script: []const u8) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const script_owned = allocator.dupeZ(u8, script) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(script_owned);
    const script_ref = jsc.JSStringCreateWithUTF8CString(script_owned.ptr);
    defer jsc.JSStringRelease(script_ref);
    const result = jsc.JSEvaluateScript(ctx, script_ref, null, null, 1, null);
    return result;
}
