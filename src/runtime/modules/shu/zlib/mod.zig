// shu:zlib 压缩模块：gzip / deflate / brotli
// 供 Shu.zlib、require("shu:zlib") / node:zlib 与 Shu.server 响应压缩共用

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");
const gzip = @import("gzip.zig");
const brotli_mod = @import("brotli.zig");

/// 返回 Shu.zlib 的 exports 对象（供 shu:zlib 内置与引擎挂载）；allocator 预留
pub fn getExports(ctx: jsc.JSContextRef, _: std.mem.Allocator) jsc.JSValueRef {
    const zlib_obj = jsc.JSObjectMake(ctx, null, null);
    // 同步方法
    common.setMethod(ctx, zlib_obj, "gzipSync", gzipSyncCallback);
    common.setMethod(ctx, zlib_obj, "deflateSync", deflateSyncCallback);
    common.setMethod(ctx, zlib_obj, "brotliSync", brotliSyncCallback);
    // 异步方法（返回 Promise，用 setImmediate 延后执行同步压缩，避免阻塞当前 tick）
    common.setMethod(ctx, zlib_obj, "gzip", gzipAsyncCallback);
    common.setMethod(ctx, zlib_obj, "deflate", deflateAsyncCallback);
    common.setMethod(ctx, zlib_obj, "brotli", brotliAsyncCallback);
    return zlib_obj;
}

/// 向 shu_obj 上注册 Shu.zlib 子对象（委托 getExports）
pub fn register(ctx: jsc.JSGlobalContextRef, shu_obj: jsc.JSObjectRef) void {
    const allocator = globals.current_allocator orelse return;
    const name_zlib = jsc.JSStringCreateWithUTF8CString("zlib");
    defer jsc.JSStringRelease(name_zlib);
    _ = jsc.JSObjectSetProperty(ctx, shu_obj, name_zlib, getExports(ctx, allocator), jsc.kJSPropertyAttributeNone, null);
}

// ---------- 内部辅助与回调 ----------

/// 从 JS 第一个参数取字节：支持 string（按 UTF-8）；调用方 free 返回的 slice
fn getBytesFromArg(ctx: jsc.JSContextRef, arguments: [*]const jsc.JSValueRef, allocator: std.mem.Allocator) ?[]const u8 {
    const val = arguments[0];
    const js_str = jsc.JSValueToStringCopy(ctx, val, null);
    defer jsc.JSStringRelease(js_str);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(js_str);
    if (max_sz == 0 or max_sz > 64 * 1024 * 1024) return null;
    const buf = allocator.alloc(u8, max_sz) catch return null;
    defer allocator.free(buf);
    const n = jsc.JSStringGetUTF8CString(js_str, buf.ptr, max_sz);
    if (n == 0) return null;
    return allocator.dupe(u8, buf[0 .. n - 1]) catch null;
}

/// 异步压缩通用逻辑：将 data 以 base64 注入脚本，在 setImmediate 中调用 syncMethodName(data)，返回 Promise
fn compressAsyncScript(ctx: jsc.JSContextRef, allocator: std.mem.Allocator, data: []const u8, syncMethodName: []const u8) jsc.JSValueRef {
    const enc_len = std.base64.standard.Encoder.calcSize(data.len);
    const b64_buf = allocator.alloc(u8, enc_len) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(b64_buf);
    const b64_slice = std.base64.standard.Encoder.encode(b64_buf, data);
    const script_slice = std.fmt.allocPrint(
        allocator,
        "(function(b64){{ var s=atob(b64); var a=new Uint8Array(s.length); for(var i=0;i<s.length;i++) a[i]=s.charCodeAt(i); return new Promise(function(resolve,reject){{ setImmediate(function(){{ try {{ resolve(Shu.zlib.{s}(a)); }} catch(e) {{ reject(e); }} }}); }}); }})(\"{s}\")",
        .{ syncMethodName, b64_slice },
    ) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(script_slice);
    const script = allocator.dupeZ(u8, script_slice) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(script);
    const script_ref = jsc.JSStringCreateWithUTF8CString(script.ptr);
    defer jsc.JSStringRelease(script_ref);
    return jsc.JSEvaluateScript(ctx, script_ref, null, null, 1, null);
}

/// 将 Zig 压缩结果通过 base64 注入脚本，返回 JS 的 Uint8Array（避免依赖 JSC ArrayBuffer API）
fn bytesToUint8ArrayScript(ctx: jsc.JSContextRef, allocator: std.mem.Allocator, data: []const u8) jsc.JSValueRef {
    const enc_len = std.base64.standard.Encoder.calcSize(data.len);
    const b64_buf = allocator.alloc(u8, enc_len) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(b64_buf);
    const b64_slice = std.base64.standard.Encoder.encode(b64_buf, data);
    const script_slice = std.fmt.allocPrint(allocator, "(function(b64){{ var s=atob(b64); var a=new Uint8Array(s.length); for(var i=0;i<s.length;i++) a[i]=s.charCodeAt(i); return a; }})(\"{s}\")", .{b64_slice}) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(script_slice);
    const script = allocator.dupeZ(u8, script_slice) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(script);
    const script_ref = jsc.JSStringCreateWithUTF8CString(script.ptr);
    defer jsc.JSStringRelease(script_ref);
    return jsc.JSEvaluateScript(ctx, script_ref, null, null, 1, null);
}

fn gzipSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const input = getBytesFromArg(ctx, arguments, allocator) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(input);
    const compressed = gzip.compressGzip(allocator, input) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(compressed);
    return bytesToUint8ArrayScript(ctx, allocator, compressed);
}

fn deflateSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const input = getBytesFromArg(ctx, arguments, allocator) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(input);
    const compressed = gzip.compressDeflate(allocator, input) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(compressed);
    return bytesToUint8ArrayScript(ctx, allocator, compressed);
}

fn brotliSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const input = getBytesFromArg(ctx, arguments, allocator) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(input);
    const compressed = brotli_mod.compressBrotli(allocator, input) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(compressed);
    return bytesToUint8ArrayScript(ctx, allocator, compressed);
}

fn gzipAsyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const input = getBytesFromArg(ctx, arguments, allocator) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(input);
    return compressAsyncScript(ctx, allocator, input, "gzipSync");
}

fn deflateAsyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const input = getBytesFromArg(ctx, arguments, allocator) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(input);
    return compressAsyncScript(ctx, allocator, input, "deflateSync");
}

fn brotliAsyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const input = getBytesFromArg(ctx, arguments, allocator) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(input);
    return compressAsyncScript(ctx, allocator, input, "brotliSync");
}

// ---------- 供 Shu.server 等直接调用的压缩 API（与 gzip.zig / brotli.zig 一致） ----------

pub const compressGzip = gzip.compressGzip;
pub const compressDeflate = gzip.compressDeflate;
pub const compressBrotli = brotli_mod.compressBrotli;
