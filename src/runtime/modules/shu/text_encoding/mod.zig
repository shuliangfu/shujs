// TextEncoder / TextDecoder：与 fetch、文件等配合
// TextEncoder.encode(str) 返回 Uint8Array（UTF-8 字节）；TextDecoder.decode(buffer) 将 ArrayBuffer/ TypedArray 解码为字符串

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
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

/// __shuDecodeUtf8(buffer) 的 C 回调：从 TypedArray/ArrayBuffer 取字节，以 UTF-8 构造 JS 字符串，纯 Zig
fn shuDecodeUtf8Callback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const buffer_val = arguments[0];
    var byte_len: usize = 0;
    const ptr = blk: {
        const typ = jsc.JSValueGetTypedArrayType(ctx, buffer_val, null);
        if (typ != .None) {
            const obj = jsc.JSValueToObject(ctx, buffer_val, null) orelse break :blk null;
            byte_len = jsc.JSObjectGetTypedArrayByteLength(ctx, obj);
            break :blk jsc.JSObjectGetTypedArrayBytesPtr(ctx, obj, null);
        }
        const obj = jsc.JSValueToObject(ctx, buffer_val, null) orelse break :blk null;
        byte_len = jsc.JSObjectGetArrayBufferByteLength(ctx, obj);
        break :blk jsc.JSObjectGetArrayBufferBytesPtr(ctx, obj, null);
    };
    if (ptr == null or byte_len == 0) return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
    const slice = @as([*]const u8, @ptrCast(ptr))[0..byte_len];
    const z = allocator.dupeZ(u8, slice) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(z);
    const str_ref = jsc.JSStringCreateWithUTF8CString(z.ptr);
    return jsc.JSValueMakeString(ctx, str_ref);
}

/// 注入全局 __shuDecodeUtf8 为 C 回调（仅执行一次），纯 Zig 无内联脚本
fn injectTextDecoderHelper(ctx: jsc.JSContextRef, global: jsc.JSObjectRef) void {
    const k = jsc.JSStringCreateWithUTF8CString("__shuDecodeUtf8");
    defer jsc.JSStringRelease(k);
    if (!jsc.JSValueIsUndefined(ctx, jsc.JSObjectGetProperty(ctx, global, k, null))) return;
    common.setMethod(ctx, global, "__shuDecodeUtf8", shuDecodeUtf8Callback);
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

/// JSC 回收 Uint8Array 时释放 Zig 复制的 UTF-8 缓冲；context 为 *TextEncodingBytesContext
fn textEncodingBytesDeallocator(bytes: *anyopaque, deallocator_context: ?*anyopaque) callconv(.c) void {
    _ = bytes;
    const ctx = @as(*TextEncodingBytesContext, @ptrCast(@alignCast(deallocator_context orelse return)));
    ctx.allocator.free(ctx.slice);
    ctx.allocator.destroy(ctx);
}
const TextEncodingBytesContext = struct {
    allocator: std.mem.Allocator,
    slice: []u8,
};

/// TextEncoder.prototype.encode(str)：将字符串转为 UTF-8 的 Uint8Array，纯 Zig（NoCopy + deallocator）
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
    const copy = allocator.dupe(u8, utf8) catch return jsc.JSValueMakeUndefined(ctx);
    const dc = allocator.create(TextEncodingBytesContext) catch {
        allocator.free(copy);
        return jsc.JSValueMakeUndefined(ctx);
    };
    dc.* = .{ .allocator = allocator, .slice = copy };
    var exception: ?jsc.JSValueRef = null;
    const out = jsc.JSObjectMakeTypedArrayWithBytesNoCopy(ctx, .Uint8Array, copy.ptr, copy.len, textEncodingBytesDeallocator, dc, @ptrCast(&exception));
    if (out == null) {
        allocator.free(copy);
        allocator.destroy(dc);
        return jsc.JSValueMakeUndefined(ctx);
    }
    return out.?;
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
