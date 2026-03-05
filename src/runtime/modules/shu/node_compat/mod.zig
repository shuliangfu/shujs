// 与 Node 同名的 shu: 模块 API 占位：导出与 node:xxx 一致的接口名，调用时抛 "Not implemented"，纯 Zig 实现
// 供 repl、test、inspector、wasi、report、tracing、tty、permissions、intl、webcrypto、webstreams、cluster、debugger 等使用

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");

/// 从 thisObject 上读取 __moduleName（字符串），用于构造错误信息；若缺失则返回 "unknown"
fn getModuleNameFromThis(ctx: jsc.JSContextRef, this_obj: jsc.JSObjectRef, buf: []u8) []const u8 {
    const k = jsc.JSStringCreateWithUTF8CString("__moduleName");
    defer jsc.JSStringRelease(k);
    const val = jsc.JSObjectGetProperty(ctx, this_obj, k, null);
    if (jsc.JSValueIsUndefined(ctx, val)) return "unknown";
    const str_ref = jsc.JSValueToStringCopy(ctx, val, null);
    defer jsc.JSStringRelease(str_ref);
    const n = jsc.JSStringGetUTF8CString(str_ref, buf.ptr, buf.len);
    if (n == 0) return "unknown";
    return buf[0 .. n - 1];
}

/// 通用「未实现」回调：读取 this 的 __moduleName 后执行 throw new Error("shu:xxx not implemented")
pub fn notImplementedCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    thisObject: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    var name_buf: [64]u8 = undefined;
    var msg_buf: [128]u8 = undefined;
    const name = getModuleNameFromThis(ctx, thisObject, &name_buf);
    const msg_z = std.fmt.bufPrintZ(&msg_buf, "shu:{s} not implemented", .{name}) catch "shu: not implemented";
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_err = jsc.JSStringCreateWithUTF8CString("Error");
    defer jsc.JSStringRelease(k_err);
    const err_ctor = jsc.JSObjectGetProperty(ctx, global, k_err, null);
    const err_obj = jsc.JSValueToObject(ctx, err_ctor, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const msg_js = jsc.JSStringCreateWithUTF8CString(msg_z.ptr);
    defer jsc.JSStringRelease(msg_js);
    var args = [_]jsc.JSValueRef{jsc.JSValueMakeString(ctx, msg_js)};
    var exception: ?jsc.JSValueRef = null;
    const err_instance = jsc.JSObjectCallAsConstructor(ctx, err_obj, 1, &args, @ptrCast(&exception));
    if (exception != null) return jsc.JSValueMakeUndefined(ctx);
    _ = common.setThrowAndThrow(ctx, err_instance);
    return jsc.JSValueMakeUndefined(ctx);
}

/// 在 obj 上设置 __moduleName 为 module_name，并将 method_names 中每个名字设为 notImplementedCallback
fn setStubMethods(ctx: jsc.JSContextRef, obj: jsc.JSObjectRef, module_name: []const u8, method_names: []const []const u8) void {
    const k_name = jsc.JSStringCreateWithUTF8CString("__moduleName");
    defer jsc.JSStringRelease(k_name);
    const name_js = jsc.JSStringCreateWithUTF8CString(module_name.ptr);
    defer jsc.JSStringRelease(name_js);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_name, jsc.JSValueMakeString(ctx, name_js), jsc.kJSPropertyAttributeNone, null);
    for (method_names) |m| {
        common.setMethod(ctx, obj, m.ptr, notImplementedCallback);
    }
}

/// 构建与 Node API 同名的占位 exports；method_names 为需导出的方法/属性名（作为函数占位）
pub fn buildStubExports(
    ctx: jsc.JSContextRef,
    _: std.mem.Allocator,
    module_name: []const u8,
    method_names: []const []const u8,
) jsc.JSValueRef {
    const obj = jsc.JSObjectMake(ctx, null, null);
    setStubMethods(ctx, obj, module_name, method_names);
    return obj;
}
