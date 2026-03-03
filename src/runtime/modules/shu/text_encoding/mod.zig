// TextEncoder / TextDecoder：与 fetch、文件等配合
// TextEncoder.encode(str) 返回 Uint8Array（UTF-8 字节）；TextDecoder.decode(buffer) 将 ArrayBuffer/ TypedArray 解码为字符串

const std = @import("std");
const jsc = @import("jsc");
const globals = @import("../../../globals.zig");

/// §1.1 显式 allocator 收敛：register(ctx, allocator) 时注入，TextEncoder.encode 等回调优先使用
threadlocal var g_text_encoding_allocator: ?std.mem.Allocator = null;

/// 向全局注册 TextEncoder、TextDecoder（若引擎未提供则宿主提供）
/// 若传入 allocator 则注入 g_text_encoding_allocator，供 encode 等回调使用
pub fn register(ctx: jsc.JSGlobalContextRef, allocator: ?std.mem.Allocator) void {
    if (allocator) |a| g_text_encoding_allocator = a;
    const global = jsc.JSContextGetGlobalObject(ctx);
    injectTextDecoderHelper(ctx, global);
    setGlobalConstructor(ctx, global, "TextEncoder", textEncoderConstructorCallback);
    setGlobalConstructor(ctx, global, "TextDecoder", textDecoderConstructorCallback);
}

/// 注入全局 __shuDecodeUtf8(buffer)，供 TextDecoder.decode 回调调用以在 JS 侧解码 UTF-8
fn injectTextDecoderHelper(ctx: jsc.JSContextRef, global: jsc.JSObjectRef) void {
    const script =
        "(function(){ function utf8Decode(bytes){ var s='',i=0; while(i<bytes.length){ var c=bytes[i++]; if(c<0x80)s+=String.fromCharCode(c); else if(c>=0xC2&&c<=0xDF&&i<bytes.length){ s+=String.fromCharCode(((c&0x1F)<<6)|(bytes[i++]&0x3F)); } else if(c>=0xE0&&c<=0xEF&&i+1<bytes.length){ s+=String.fromCharCode(((c&0x0F)<<12)|((bytes[i++]&0x3F)<<6)|(bytes[i++]&0x3F)); } else if(c>=0xF0&&c<=0xF4&&i+2<bytes.length){ var n=((c&7)<<18)|((bytes[i++]&0x3F)<<12)|((bytes[i++]&0x3F)<<6)|(bytes[i++]&0x3F); s+=n<=0xFFFF?String.fromCharCode(n):String.fromCharCode(0xD800+((n-0x10000)>>10),0xDC00+((n-0x10000)&0x3FF)); } else s+='\\uFFFD'; } return s; } globalThis.__shuDecodeUtf8=function(buffer){ var bytes=new Uint8Array(buffer); return utf8Decode(bytes); }; })();";
    const ref = jsc.JSStringCreateWithUTF8CString(script.ptr);
    defer jsc.JSStringRelease(ref);
    _ = jsc.JSEvaluateScript(ctx, ref, global, null, 0, null);
}

fn setGlobalConstructor(ctx: jsc.JSGlobalContextRef, global: jsc.JSObjectRef, name: [*]const u8, callback: jsc.JSObjectCallAsFunctionCallback) void {
    const name_ref = jsc.JSStringCreateWithUTF8CString(name);
    defer jsc.JSStringRelease(name_ref);
    const fn_ref = jsc.JSObjectMakeFunctionWithCallback(ctx, name_ref, callback);
    _ = jsc.JSObjectSetProperty(ctx, global, name_ref, fn_ref, jsc.kJSPropertyAttributeNone, null);
}

/// new TextEncoder()：返回带 encode 方法的对象
fn textEncoderConstructorCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    _ = argumentCount;
    _ = arguments;
    const encoder_obj = jsc.JSObjectMake(ctx, null, null);
    setMethod(ctx, encoder_obj, "encode", textEncoderEncodeCallback);
    return encoder_obj;
}

fn setMethod(ctx: jsc.JSGlobalContextRef, obj: jsc.JSObjectRef, name: [*]const u8, callback: jsc.JSObjectCallAsFunctionCallback) void {
    const name_ref = jsc.JSStringCreateWithUTF8CString(name);
    defer jsc.JSStringRelease(name_ref);
    const fn_ref = jsc.JSObjectMakeFunctionWithCallback(ctx, name_ref, callback);
    _ = jsc.JSObjectSetProperty(ctx, obj, name_ref, fn_ref, jsc.kJSPropertyAttributeNone, null);
}

/// TextEncoder.prototype.encode(str)：将字符串转为 UTF-8 的 Uint8Array（通过 JS 侧 atob + Uint8Array 构造）
fn textEncoderEncodeCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const allocator = g_text_encoding_allocator orelse globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const input_js = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(input_js);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(input_js);
    if (max_sz == 0 or max_sz > 4 * 1024 * 1024) return jsc.JSValueMakeUndefined(ctx);
    const buf = allocator.alloc(u8, max_sz) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(buf);
    const n = jsc.JSStringGetUTF8CString(input_js, buf.ptr, max_sz);
    if (n == 0) return jsc.JSValueMakeUndefined(ctx);
    const utf8 = buf[0 .. n - 1];
    var encoder = std.base64.standard.Encoder;
    const enc_len = encoder.calcSize(utf8.len);
    const b64_buf = allocator.alloc(u8, enc_len + 1) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(b64_buf);
    const written = encoder.encode(b64_buf[0..enc_len], utf8);
    b64_buf[written.len] = 0;
    var escaped = std.ArrayList(u8).initCapacity(allocator, written.len * 2 + 4) catch return jsc.JSValueMakeUndefined(ctx);
    defer escaped.deinit(allocator);
    escaped.appendSlice(allocator, "(function(b64){var s=atob(b64);var a=new Uint8Array(s.length);for(var i=0;i<s.length;i++)a[i]=s.charCodeAt(i);return a;})('") catch return jsc.JSValueMakeUndefined(ctx);
    for (b64_buf[0..written.len]) |c| {
        if (c == '\\') escaped.appendSlice(allocator, "\\\\") catch return jsc.JSValueMakeUndefined(ctx) else if (c == '\'') escaped.appendSlice(allocator, "\\'") catch return jsc.JSValueMakeUndefined(ctx) else escaped.append(allocator, c) catch return jsc.JSValueMakeUndefined(ctx);
    }
    escaped.appendSlice(allocator, "')") catch return jsc.JSValueMakeUndefined(ctx);
    const script_z = allocator.dupeZ(u8, escaped.items) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(script_z);
    const script_ref = jsc.JSStringCreateWithUTF8CString(script_z.ptr);
    defer jsc.JSStringRelease(script_ref);
    return jsc.JSEvaluateScript(ctx, script_ref, null, null, 1, null);
}

/// new TextDecoder(label?)：返回带 decode 方法的对象；当前仅支持 utf-8
fn textDecoderConstructorCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    _ = argumentCount;
    _ = arguments;
    const decoder_obj = jsc.JSObjectMake(ctx, null, null);
    setMethod(ctx, decoder_obj, "decode", textDecoderDecodeCallback);
    return decoder_obj;
}

/// TextDecoder.prototype.decode(buffer)：调用全局 __shuDecodeUtf8(buffer) 在 JS 侧解码
fn textDecoderDecodeCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const name_ref = jsc.JSStringCreateWithUTF8CString("__shuDecodeUtf8");
    defer jsc.JSStringRelease(name_ref);
    const fn_val = jsc.JSObjectGetProperty(ctx, global, name_ref, null);
    if (jsc.JSValueIsUndefined(ctx, fn_val)) return jsc.JSValueMakeUndefined(ctx);
    const fn_obj = jsc.JSValueToObject(ctx, fn_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const args = [_]jsc.JSValueRef{arguments[0]};
    return jsc.JSObjectCallAsFunction(ctx, fn_obj, null, 1, &args, null);
}
