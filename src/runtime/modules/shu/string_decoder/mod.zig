// shu:string_decoder 内置：纯 Zig 实现 Node 风格 StringDecoder（write/end）
// 供 require("shu:string_decoder") / node:string_decoder 共用；构造函数与 write 为 Zig，end 合并 buffer 后调用 TextDecoder.decode（依赖引擎已注册 TextDecoder/__shuDecodeUtf8）

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");

var k_encoding: jsc.JSStringRef = undefined;
var k_decoder: jsc.JSStringRef = undefined;
var k__buf: jsc.JSStringRef = undefined;
var k_StringDecoder: jsc.JSStringRef = undefined;
var k_TextDecoder: jsc.JSStringRef = undefined;
var k__sdDecode: jsc.JSStringRef = undefined;
var sd_strings_init: bool = false;

fn ensureSDStrings() void {
    if (sd_strings_init) return;
    k_encoding = jsc.JSStringCreateWithUTF8CString("encoding");
    k_decoder = jsc.JSStringCreateWithUTF8CString("decoder");
    k__buf = jsc.JSStringCreateWithUTF8CString("_buf");
    k_StringDecoder = jsc.JSStringCreateWithUTF8CString("StringDecoder");
    k_TextDecoder = jsc.JSStringCreateWithUTF8CString("TextDecoder");
    k__sdDecode = jsc.JSStringCreateWithUTF8CString("__sdDecode");
    sd_strings_init = true;
}

/// 注入全局 __sdDecode(decoder, bufArray) 供 end() 合并并解码（仅执行一次）
fn ensureSDDecodeHelper(ctx: jsc.JSContextRef) void {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const existing = jsc.JSObjectGetProperty(ctx, global, k__sdDecode, null);
    if (!jsc.JSValueIsUndefined(ctx, existing)) return;
    const script =
        "(function(){ globalThis.__sdDecode=function(dec,arr){ var n=0; for(var i=0;i<arr.length;i++) n+=arr[i].length; var u=new Uint8Array(n),o=0; for(var i=0;i<arr.length;i++){ u.set(arr[i],o); o+=arr[i].length; } return dec.decode(u); }; })();";
    const allocator = globals.current_allocator orelse return;
    const script_z = allocator.dupeZ(u8, script) catch return;
    defer allocator.free(script_z);
    const script_ref = jsc.JSStringCreateWithUTF8CString(script_z.ptr);
    defer jsc.JSStringRelease(script_ref);
    _ = jsc.JSEvaluateScript(ctx, script_ref, global, null, 0, null);
}

/// 构造函数：this.encoding = enc||'utf8'，this.decoder = new TextDecoder(encoding)，this._buf = []
fn stringDecoderConstructor(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    thisObject: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    ensureSDStrings();
    ensureSDDecodeHelper(ctx);
    const enc = if (argumentCount >= 1) arguments[0] else jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString("utf8"));
    const enc_str = jsc.JSValueToStringCopy(ctx, enc, null);
    defer jsc.JSStringRelease(enc_str);
    _ = jsc.JSObjectSetProperty(ctx, thisObject, k_encoding, jsc.JSValueMakeString(ctx, enc_str), jsc.kJSPropertyAttributeNone, null);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const td_val = jsc.JSObjectGetProperty(ctx, global, k_TextDecoder, null);
    const td_ctor = jsc.JSValueToObject(ctx, td_val, null) orelse return thisObject;
    var one: [1]jsc.JSValueRef = .{enc};
    const decoder_instance = jsc.JSObjectCallAsConstructor(ctx, td_ctor, 1, &one, null);
    _ = jsc.JSObjectSetProperty(ctx, thisObject, k_decoder, decoder_instance, jsc.kJSPropertyAttributeNone, null);
    var empty: [0]jsc.JSValueRef = undefined;
    const buf_arr = jsc.JSObjectMakeArray(ctx, 0, &empty, null);
    _ = jsc.JSObjectSetProperty(ctx, thisObject, k__buf, buf_arr, jsc.kJSPropertyAttributeNone, null);
    return jsc.JSValueMakeUndefined(ctx);
}

/// write(buf)：将 buf 推入 _buf，返回 ''（Node 行为是缓冲不立即输出）
fn writeCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
    const buf_val = jsc.JSObjectGetProperty(ctx, thisObject, k__buf, null);
    const buf_arr = jsc.JSValueToObject(ctx, buf_val, null) orelse return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
    const global = jsc.JSContextGetGlobalObject(ctx);
    const arr_val = jsc.JSObjectGetProperty(ctx, global, jsc.JSStringCreateWithUTF8CString("Array"), null);
    const arr_obj = jsc.JSValueToObject(ctx, arr_val, null) orelse return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
    const proto_val = jsc.JSObjectGetProperty(ctx, arr_obj, jsc.JSStringCreateWithUTF8CString("prototype"), null);
    const proto_obj = jsc.JSValueToObject(ctx, proto_val, null) orelse return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
    const push_val = jsc.JSObjectGetProperty(ctx, proto_obj, jsc.JSStringCreateWithUTF8CString("push"), null);
    const push_fn = jsc.JSValueToObject(ctx, push_val, null) orelse return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
    var one: [1]jsc.JSValueRef = .{arguments[0]};
    _ = jsc.JSObjectCallAsFunction(ctx, push_fn, buf_arr, 1, &one, null);
    return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
}

/// end(buf?)：若有 buf 则 push，再合并 _buf 并 decoder.decode，清空 _buf 后返回字符串
fn endCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount >= 1 and !jsc.JSValueIsUndefined(ctx, arguments[0])) {
        const buf_val = jsc.JSObjectGetProperty(ctx, thisObject, k__buf, null);
        const buf_arr = jsc.JSValueToObject(ctx, buf_val, null) orelse return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
        const global = jsc.JSContextGetGlobalObject(ctx);
        const arr_val = jsc.JSObjectGetProperty(ctx, global, jsc.JSStringCreateWithUTF8CString("Array"), null);
        const arr_obj = jsc.JSValueToObject(ctx, arr_val, null) orelse return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
        const proto_val = jsc.JSObjectGetProperty(ctx, arr_obj, jsc.JSStringCreateWithUTF8CString("prototype"), null);
        const proto_obj = jsc.JSValueToObject(ctx, proto_val, null) orelse return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
        const push_val = jsc.JSObjectGetProperty(ctx, proto_obj, jsc.JSStringCreateWithUTF8CString("push"), null);
        const push_fn = jsc.JSValueToObject(ctx, push_val, null) orelse return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
        var one: [1]jsc.JSValueRef = .{arguments[0]};
        _ = jsc.JSObjectCallAsFunction(ctx, push_fn, buf_arr, 1, &one, null);
    }
    const decoder_val = jsc.JSObjectGetProperty(ctx, thisObject, k_decoder, null);
    const buf_val = jsc.JSObjectGetProperty(ctx, thisObject, k__buf, null);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const helper_val = jsc.JSObjectGetProperty(ctx, global, k__sdDecode, null);
    const helper_fn = jsc.JSValueToObject(ctx, helper_val, null) orelse return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
    var two: [2]jsc.JSValueRef = .{ decoder_val, buf_val };
    const result = jsc.JSObjectCallAsFunction(ctx, helper_fn, null, 2, &two, null);
    var empty: [0]jsc.JSValueRef = undefined;
    const empty_arr = jsc.JSObjectMakeArray(ctx, 0, &empty, null);
    _ = jsc.JSObjectSetProperty(ctx, thisObject, k__buf, empty_arr, jsc.kJSPropertyAttributeNone, null);
    if (jsc.JSValueIsUndefined(ctx, result)) return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
    return result;
}

pub fn getExports(ctx: jsc.JSContextRef, _: std.mem.Allocator) jsc.JSValueRef {
    ensureSDStrings();
    ensureSDDecodeHelper(ctx);
    const proto = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, proto, "write", writeCallback);
    common.setMethod(ctx, proto, "end", endCallback);
    const ctor_name = jsc.JSStringCreateWithUTF8CString("StringDecoder");
    defer jsc.JSStringRelease(ctor_name);
    const ctor = jsc.JSObjectMakeFunctionWithCallback(ctx, ctor_name, stringDecoderConstructor);
    _ = jsc.JSObjectSetProperty(ctx, ctor, jsc.JSStringCreateWithUTF8CString("prototype"), proto, jsc.kJSPropertyAttributeNone, null);
    const exports = jsc.JSObjectMake(ctx, null, null);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_StringDecoder, ctor, jsc.kJSPropertyAttributeNone, null);
    return exports;
}
