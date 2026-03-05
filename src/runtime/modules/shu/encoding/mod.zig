// 全局 atob / btoa 注册与 C 回调（Base64 编解码，与 Web 标准一致）
// atob(str)：将 Base64 字符串解码为「二进制字符串」（每字符码点 0–255）
// btoa(str)：将「二进制字符串」编码为 Base64
// 由 engine/encoding.zig 移入，bindings 调用 register
// 所有权：atob/btoa 返回值 JSC 持有；回调内 [Allocates] 在返回前交 JSC 或 free，无向 Zig 调用方返回切片。

const std = @import("std");
const jsc = @import("jsc");
const globals = @import("../../../globals.zig");

/// §1.1 显式 allocator 收敛：register 时注入，atob/btoa 回调优先使用
threadlocal var g_encoding_allocator: ?std.mem.Allocator = null;

/// 向全局对象注册 atob、btoa；allocator 传入时注入 g_encoding_allocator
pub fn register(ctx: jsc.JSGlobalContextRef, allocator: ?std.mem.Allocator) void {
    if (allocator) |a| g_encoding_allocator = a;
    const global = jsc.JSContextGetGlobalObject(ctx);
    setGlobalFn(ctx, global, "atob", atobCallback);
    setGlobalFn(ctx, global, "btoa", btoaCallback);
}

fn setGlobalFn(ctx: jsc.JSGlobalContextRef, global: jsc.JSObjectRef, name: [*]const u8, callback: jsc.JSObjectCallAsFunctionCallback) void {
    const name_ref = jsc.JSStringCreateWithUTF8CString(name);
    defer jsc.JSStringRelease(name_ref);
    const fn_ref = jsc.JSObjectMakeFunctionWithCallback(ctx, name_ref, callback);
    _ = jsc.JSObjectSetProperty(ctx, global, name_ref, fn_ref, jsc.kJSPropertyAttributeNone, null);
}

/// atob(base64String)：解码 Base64 为二进制字符串；非法字符或长度不符时抛错
fn atobCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return throwDOMException(ctx, "atob requires 1 argument");
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const input_js = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(input_js);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(input_js);
    if (max_sz == 0 or max_sz > 256 * 1024) return throwDOMException(ctx, "atob: string too long");
    const buf = allocator.alloc(u8, max_sz) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(buf);
    const n = jsc.JSStringGetUTF8CString(input_js, buf.ptr, max_sz);
    if (n == 0) return jsc.JSValueMakeUndefined(ctx);
    const input = buf[0 .. n - 1];
    const max_decoded = (input.len / 4) * 3 + 2;
    const decoded = allocator.alloc(u8, max_decoded) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(decoded);
    var decoder = std.base64.standard.Decoder;
    decoder.decode(decoded[0..], input) catch return throwDOMException(ctx, "atob: invalid base64");
    const decoded_len = (input.len * 3) / 4;
    const decoded_slice = decoded[0..decoded_len];
    // 将字节转为「二进制字符串」：每字节作为码点 0–255 的字符（用 UTF-16 构造）
    const utf16 = allocator.alloc(u16, decoded_len) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(utf16);
    for (decoded_slice, utf16) |b, *u| u.* = b;
    const result_ref = jsc.JSStringCreateWithCharacters(utf16.ptr, decoded_len);
    defer jsc.JSStringRelease(result_ref);
    return jsc.JSValueMakeString(ctx, result_ref);
}

/// btoa(binaryString)：将二进制字符串（每字符码点 0–255）编码为 Base64；含超 255 字符时抛错
/// 通过 UTF-8 获取内容后按 UTF-8 解码为码点（兼容 macOS 系统 JSC 无 JSStringGetCharacters）
fn btoaCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return throwDOMException(ctx, "btoa requires 1 argument");
    const allocator = g_encoding_allocator orelse globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const input_js = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(input_js);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(input_js);
    if (max_sz == 0 or max_sz > 256 * 1024) return throwDOMException(ctx, "btoa: string too long");
    const buf = allocator.alloc(u8, max_sz) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(buf);
    const n = jsc.JSStringGetUTF8CString(input_js, buf.ptr, max_sz);
    if (n == 0) return jsc.JSValueMakeUndefined(ctx);
    const utf8 = buf[0 .. n - 1];
    var bytes = std.ArrayList(u8).initCapacity(allocator, utf8.len) catch return jsc.JSValueMakeUndefined(ctx);
    defer bytes.deinit(allocator);
    var i: usize = 0;
    while (i < utf8.len) {
        const c = utf8[i];
        if (c < 0x80) {
            bytes.append(allocator, c) catch return jsc.JSValueMakeUndefined(ctx);
            i += 1;
        } else if (c >= 0xC2 and c <= 0xDF and i + 1 < utf8.len) {
            const c2 = utf8[i + 1];
            if (c2 >= 0x80 and c2 <= 0xBF) {
                const code: u16 = (@as(u16, c & 0x1F) << 6) | (c2 & 0x3F);
                if (code > 255) return throwDOMException(ctx, "btoa: character out of range");
                bytes.append(allocator, @intCast(code)) catch return jsc.JSValueMakeUndefined(ctx);
                i += 2;
            } else {
                return throwDOMException(ctx, "btoa: character out of range");
            }
        } else {
            return throwDOMException(ctx, "btoa: character out of range");
        }
    }
    var encoder = std.base64.standard.Encoder;
    const enc_len = encoder.calcSize(bytes.items.len);
    const encoded = allocator.alloc(u8, enc_len + 1) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(encoded);
    const written = encoder.encode(encoded[0..enc_len], bytes.items);
    encoded[written.len] = 0;
    const result_ref = jsc.JSStringCreateWithUTF8CString(encoded.ptr);
    defer jsc.JSStringRelease(result_ref);
    return jsc.JSValueMakeString(ctx, result_ref);
}

/// 将 msg 中的 " 和 \ 转义后拼成 throw new DOMException(...) 并执行
fn throwDOMException(ctx: jsc.JSContextRef, msg: []const u8) jsc.JSValueRef {
    var buf: [512]u8 = undefined;
    var i: usize = 0;
    const prefix = "throw new DOMException(\"";
    @memcpy(buf[0..prefix.len], prefix);
    i = prefix.len;
    for (msg) |c| {
        if (i >= buf.len - 16) break;
        if (c == '"' or c == '\\') {
            buf[i] = '\\';
            i += 1;
        }
        buf[i] = c;
        i += 1;
    }
    const suffix = "\", \"InvalidCharacterError\");";
    @memcpy(buf[i..][0..suffix.len], suffix);
    i += suffix.len;
    buf[i] = 0;
    const script_ref = jsc.JSStringCreateWithUTF8CString(buf[0..].ptr);
    defer jsc.JSStringRelease(script_ref);
    _ = jsc.JSEvaluateScript(ctx, script_ref, null, null, 1, null);
    return jsc.JSValueMakeUndefined(ctx);
}
