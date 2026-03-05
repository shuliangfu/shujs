// shu:zlib 压缩模块：gzip / deflate / brotli
// 供 Shu.zlib、require("shu:zlib") / node:zlib 与 Shu.server 响应压缩共用
// 所有权：gzipSync/deflateSync 等返回值 JSC 持有；getBytesFromArg [Allocates] 调用方 free；内部压缩缓冲在回调内分配并 free。
// 异步与 bytesToUint8Array 已改为纯 Zig（微任务 + JSC TypedArray API），无内联 JS。

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");
const promise = @import("../promise.zig");
const timer_state = @import("../timers/state.zig");
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

/// 向 shu_obj 上注册 Shu.zlib 子对象（委托 getExports）；并注册全局 __zlibAsyncMicrotask 供异步微任务使用
pub fn register(ctx: jsc.JSGlobalContextRef, shu_obj: jsc.JSObjectRef) void {
    const allocator = globals.current_allocator orelse return;
    const name_zlib = jsc.JSStringCreateWithUTF8CString("zlib");
    defer jsc.JSStringRelease(name_zlib);
    _ = jsc.JSObjectSetProperty(ctx, shu_obj, name_zlib, getExports(ctx, allocator), jsc.kJSPropertyAttributeNone, null);
    const global = jsc.JSContextGetGlobalObject(ctx);
    common.setMethod(ctx, @ptrCast(global), "__zlibAsyncMicrotask", zlibAsyncMicrotaskCallback);
}

// ---------- 内部辅助与回调 ----------

/// [Allocates] 从 JS 第一个参数取字节：支持 string（按 UTF-8）；调用方负责 free 返回的 slice。
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

/// JSC 回收 Uint8Array 时调用的释放回调；context 为 *ZlibBytesContext
fn zlibBytesDeallocator(bytes: *anyopaque, deallocator_context: ?*anyopaque) callconv(.c) void {
    _ = bytes;
    const ctx = @as(*ZlibBytesContext, @ptrCast(@alignCast(deallocator_context orelse return)));
    ctx.allocator.free(ctx.slice);
    ctx.allocator.destroy(ctx);
}
const ZlibBytesContext = struct {
    allocator: std.mem.Allocator,
    slice: []u8,
};

/// 将 Zig 字节复制后交给 JSC 的 Uint8Array（NoCopy，GC 时 deallocator 释放）；[Allocates] 调用方不 free，由 JSC 回收时释放
fn bytesToUint8Array(ctx: jsc.JSContextRef, allocator: std.mem.Allocator, data: []const u8) jsc.JSValueRef {
    const copy = allocator.dupe(u8, data) catch return jsc.JSValueMakeUndefined(ctx);
    const dc = allocator.create(ZlibBytesContext) catch {
        allocator.free(copy);
        return jsc.JSValueMakeUndefined(ctx);
    };
    dc.* = .{ .allocator = allocator, .slice = copy };
    var exception: ?jsc.JSValueRef = null;
    const out = jsc.JSObjectMakeTypedArrayWithBytesNoCopy(
        ctx,
        .Uint8Array,
        copy.ptr,
        copy.len,
        zlibBytesDeallocator,
        dc,
        @ptrCast(&exception),
    );
    if (out == null) {
        allocator.free(copy);
        allocator.destroy(dc);
        return jsc.JSValueMakeUndefined(ctx);
    }
    return out.?;
}

// ---------- 异步压缩：微任务 + Shu.zlib.xxxSync，纯 Zig ----------

const ZlibAsyncPayload = struct {
    allocator: std.mem.Allocator,
    method_name: []const u8,
    data: []const u8,
    input_uint8array_js: jsc.JSValueRef,
    resolve: jsc.JSValueRef,
    reject: jsc.JSValueRef,
};
var pending_zlib_async_list: ?std.ArrayListUnmanaged(*ZlibAsyncPayload) = null;

fn ensureZlibAsyncList(allocator: std.mem.Allocator) void {
    if (pending_zlib_async_list == null) {
        pending_zlib_async_list = std.ArrayListUnmanaged(*ZlibAsyncPayload).initCapacity(allocator, 8) catch return;
    }
}

fn zlibAsyncMicrotaskCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    var list_opt = pending_zlib_async_list orelse return jsc.JSValueMakeUndefined(ctx);
    if (list_opt.items.len == 0) return jsc.JSValueMakeUndefined(ctx);
    const payload = list_opt.orderedRemove(0);
    pending_zlib_async_list = list_opt;
    defer {
        jsc.JSValueUnprotect(ctx, payload.resolve);
        jsc.JSValueUnprotect(ctx, payload.reject);
        jsc.JSValueUnprotect(ctx, payload.input_uint8array_js);
        allocator.free(payload.data);
        allocator.destroy(payload);
    }
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_Shu = jsc.JSStringCreateWithUTF8CString("Shu");
    defer jsc.JSStringRelease(k_Shu);
    const k_zlib = jsc.JSStringCreateWithUTF8CString("zlib");
    defer jsc.JSStringRelease(k_zlib);
    const Shu = jsc.JSObjectGetProperty(ctx, global, k_Shu, null);
    const zlib_obj = jsc.JSObjectGetProperty(ctx, @ptrCast(Shu), k_zlib, null);
    const method_str = jsc.JSStringCreateWithUTF8CString(payload.method_name.ptr);
    defer jsc.JSStringRelease(method_str);
    const method_val = jsc.JSObjectGetProperty(ctx, @ptrCast(zlib_obj), method_str, null);
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(method_val))) {
        const rej_fn = jsc.JSValueToObject(ctx, payload.reject, null);
        var rej_args: [1]jsc.JSValueRef = .{jsc.JSValueMakeUndefined(ctx)};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(rej_fn), null, 1, &rej_args, null);
        return jsc.JSValueMakeUndefined(ctx);
    }
    var one: [1]jsc.JSValueRef = .{payload.input_uint8array_js};
    var exception: ?jsc.JSValueRef = null;
    const result = jsc.JSObjectCallAsFunction(ctx, @ptrCast(method_val), @ptrCast(zlib_obj), 1, &one, @ptrCast(&exception));
    if (exception != null) {
        const rej_fn = jsc.JSValueToObject(ctx, payload.reject, null);
        var rej_args: [1]jsc.JSValueRef = .{exception.?};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(rej_fn), null, 1, &rej_args, null);
        return jsc.JSValueMakeUndefined(ctx);
    }
    const resolve_fn = jsc.JSValueToObject(ctx, payload.resolve, null);
    var res_args: [1]jsc.JSValueRef = .{result};
    _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(resolve_fn), null, 1, &res_args, null);
    return jsc.JSValueMakeUndefined(ctx);
}

fn zlibAsyncOnExecutor(ctx: jsc.JSContextRef, resolve_val: jsc.JSValueRef, reject_val: jsc.JSValueRef, user_data: ?*anyopaque) void {
    const payload = @as(*ZlibAsyncPayload, @ptrCast(@alignCast(user_data orelse return)));
    payload.resolve = resolve_val;
    payload.reject = reject_val;
    const input_js = bytesToUint8Array(ctx, payload.allocator, payload.data);
    if (jsc.JSValueIsUndefined(ctx, input_js)) {
        payload.allocator.free(payload.data);
        payload.allocator.destroy(payload);
        return;
    }
    payload.input_uint8array_js = input_js;
    jsc.JSValueProtect(ctx, resolve_val);
    jsc.JSValueProtect(ctx, reject_val);
    jsc.JSValueProtect(ctx, input_js);
    const allocator = globals.current_allocator orelse return;
    ensureZlibAsyncList(allocator);
    var list = &pending_zlib_async_list.?;
    list.append(allocator, payload) catch return;
    const state = globals.current_timer_state orelse return;
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k = jsc.JSStringCreateWithUTF8CString("__zlibAsyncMicrotask");
    defer jsc.JSStringRelease(k);
    const fn_val = jsc.JSObjectGetProperty(ctx, global, k, null);
    if (jsc.JSValueIsUndefined(ctx, fn_val) or jsc.JSValueIsNull(ctx, fn_val)) return;
    const fn_obj = jsc.JSValueToObject(ctx, fn_val, null) orelse return;
    if (!jsc.JSObjectIsFunction(ctx, fn_obj)) return;
    jsc.JSValueProtect(ctx, fn_val);
    state.enqueueMicrotask(@ptrCast(ctx), fn_val);
}

/// 异步压缩：Promise(executor) + 微任务中调用 Shu.zlib.xxxSync，纯 Zig
fn compressAsync(ctx: jsc.JSContextRef, allocator: std.mem.Allocator, data: []const u8, syncMethodName: []const u8) jsc.JSValueRef {
    const data_dup = allocator.dupe(u8, data) catch return jsc.JSValueMakeUndefined(ctx);
    const payload = allocator.create(ZlibAsyncPayload) catch {
        allocator.free(data_dup);
        return jsc.JSValueMakeUndefined(ctx);
    };
    payload.* = .{
        .allocator = allocator,
        .method_name = syncMethodName,
        .data = data_dup,
        .input_uint8array_js = undefined,
        .resolve = undefined,
        .reject = undefined,
    };
    return promise.createWithExecutor(ctx, zlibAsyncOnExecutor, payload);
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
    return bytesToUint8Array(ctx, allocator, compressed);
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
    return bytesToUint8Array(ctx, allocator, compressed);
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
    return bytesToUint8Array(ctx, allocator, compressed);
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
    return compressAsync(ctx, allocator, input, "gzipSync");
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
    return compressAsync(ctx, allocator, input, "deflateSync");
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
    return compressAsync(ctx, allocator, input, "brotliSync");
}

// ---------- 供 Shu.server、package 等直接调用的压缩/解压 API（与 gzip.zig / brotli.zig 一致） ----------

/// Gzip：压缩 / 解压。解压供 package 下载 Content-Encoding: gzip 时使用；返回的 slice 调用方 free。
pub const compressGzip = gzip.compressGzip;
pub const decompressGzip = gzip.decompressGzip;

/// Deflate（zlib）：压缩为 raw deflate / 解压为 zlib 格式。解压供 Content-Encoding: deflate 时使用；返回的 slice 调用方 free。
pub const compressDeflate = gzip.compressDeflate;
pub const decompressDeflate = gzip.decompressDeflate;

/// Brotli：压缩 / 解压。解压供 package 下载 Content-Encoding: br 时使用；返回的 slice 调用方 free。
pub const compressBrotli = brotli_mod.compressBrotli;
pub const decompressBrotli = brotli_mod.decompressBrotli;
