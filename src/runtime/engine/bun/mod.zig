// Bun.file / Bun.write / Bun.serve：用 Shu.fs、Shu.server 实现，替换 stubs 中的占位
// 需在 Shu 注册后调用；Bun.serve 仅在 --allow-net 时覆盖占位，内部调用 Shu.server

const std = @import("std");
const jsc = @import("jsc");
const run_options = @import("../../run_options.zig");

/// 在已有 global.Bun 上覆盖 file、write 为真实实现；若 options != null 且 allow_net 则覆盖 serve（内部调 Shu.server）；allocator 统一传入（§1.1），本模块暂不使用
pub fn register(ctx: jsc.JSGlobalContextRef, allocator: ?std.mem.Allocator, options: ?*const run_options.RunOptions) void {
    _ = allocator;
    const global = jsc.JSContextGetGlobalObject(ctx);
    const name_bun = jsc.JSStringCreateWithUTF8CString("Bun");
    defer jsc.JSStringRelease(name_bun);
    const bun_val = jsc.JSObjectGetProperty(ctx, global, name_bun, null);
    const bun_obj = jsc.JSValueToObject(ctx, bun_val, null) orelse return;
    setMethod(ctx, bun_obj, "file", bunFileCallback);
    setMethod(ctx, bun_obj, "write", bunWriteCallback);
    if (options) |opts| {
        if (opts.permissions.allow_net) setMethod(ctx, bun_obj, "serve", bunServeCallback);
    }
}

fn setMethod(ctx: jsc.JSGlobalContextRef, obj: jsc.JSObjectRef, name: [*]const u8, callback: jsc.JSObjectCallAsFunctionCallback) void {
    const name_ref = jsc.JSStringCreateWithUTF8CString(name);
    defer jsc.JSStringRelease(name_ref);
    const fn_ref = jsc.JSObjectMakeFunctionWithCallback(ctx, name_ref, callback);
    _ = jsc.JSObjectSetProperty(ctx, obj, name_ref, fn_ref, jsc.kJSPropertyAttributeNone, null);
}

/// Bun.file(path)：返回带 .text() 的对象，.text() 同步返回文件内容（内部调用 Shu.fs.readSync）
fn bunFileCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const file_obj = jsc.JSObjectMake(ctx, null, null);
    const name_path = jsc.JSStringCreateWithUTF8CString("__path");
    defer jsc.JSStringRelease(name_path);
    _ = jsc.JSObjectSetProperty(ctx, file_obj, name_path, arguments[0], jsc.kJSPropertyAttributeNone, null);
    setMethod(ctx, file_obj, "text", bunFileTextCallback);
    return file_obj;
}

/// 上述 file 对象的 .text()：从 this.__path 取路径，调用 Shu.fs.readSync(path) 并返回
fn bunFileTextCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const name_path = jsc.JSStringCreateWithUTF8CString("__path");
    defer jsc.JSStringRelease(name_path);
    const path_val = jsc.JSObjectGetProperty(ctx, this, name_path, null);
    const name_shu = jsc.JSStringCreateWithUTF8CString("Shu");
    defer jsc.JSStringRelease(name_shu);
    const shu_val = jsc.JSObjectGetProperty(ctx, global, name_shu, null);
    const shu_obj = jsc.JSValueToObject(ctx, shu_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const name_fs = jsc.JSStringCreateWithUTF8CString("fs");
    defer jsc.JSStringRelease(name_fs);
    const fs_val = jsc.JSObjectGetProperty(ctx, shu_obj, name_fs, null);
    const fs_obj = jsc.JSValueToObject(ctx, fs_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const name_read = jsc.JSStringCreateWithUTF8CString("readSync");
    defer jsc.JSStringRelease(name_read);
    const read_val = jsc.JSObjectGetProperty(ctx, fs_obj, name_read, null);
    const read_fn = jsc.JSValueToObject(ctx, read_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const args = [_]jsc.JSValueRef{path_val};
    return jsc.JSObjectCallAsFunction(ctx, read_fn, fs_obj, 1, &args, null);
}

/// Bun.write(dest, content)：同步写入，内部调用 Shu.fs.writeSync(dest, content)
fn bunWriteCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const name_shu = jsc.JSStringCreateWithUTF8CString("Shu");
    defer jsc.JSStringRelease(name_shu);
    const shu_val = jsc.JSObjectGetProperty(ctx, global, name_shu, null);
    const shu_obj = jsc.JSValueToObject(ctx, shu_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const name_fs = jsc.JSStringCreateWithUTF8CString("fs");
    defer jsc.JSStringRelease(name_fs);
    const fs_val = jsc.JSObjectGetProperty(ctx, shu_obj, name_fs, null);
    const fs_obj = jsc.JSValueToObject(ctx, fs_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const name_write = jsc.JSStringCreateWithUTF8CString("writeSync");
    defer jsc.JSStringRelease(name_write);
    const write_val = jsc.JSObjectGetProperty(ctx, fs_obj, name_write, null);
    const write_fn = jsc.JSValueToObject(ctx, write_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const args = [_]jsc.JSValueRef{ arguments[0], arguments[1] };
    return jsc.JSObjectCallAsFunction(ctx, write_fn, fs_obj, 2, &args, null);
}

/// 从 JS 对象 obj 读取字符串属性 key，写入 buf，返回有效切片；若不存在或非字符串则返回 null
fn getOptionalStringFromObj(ctx: jsc.JSContextRef, obj: jsc.JSObjectRef, key: [*]const u8, buf: []u8) ?[]const u8 {
    const k = jsc.JSStringCreateWithUTF8CString(key);
    defer jsc.JSStringRelease(k);
    const val = jsc.JSObjectGetProperty(ctx, obj, k, null);
    if (jsc.JSValueIsUndefined(ctx, val)) return null;
    const str_ref = jsc.JSValueToStringCopy(ctx, val, null);
    const n = jsc.JSStringGetUTF8CString(str_ref, buf.ptr, buf.len);
    jsc.JSStringRelease(str_ref);
    if (n == 0) return null;
    return buf[0 .. n - 1];
}

/// Bun.serve(options)：将 Bun 的 port/hostname|host/fetch 转为 Shu.server 选项并调用，返回 Shu.server 的返回值（含 stop/reload/restart）
fn bunServeCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const options_obj = jsc.JSValueToObject(ctx, arguments[0], null) orelse return jsc.JSValueMakeUndefined(ctx);
    const shu_opts = jsc.JSObjectMake(ctx, null, null);
    const k_port = jsc.JSStringCreateWithUTF8CString("port");
    defer jsc.JSStringRelease(k_port);
    const k_host = jsc.JSStringCreateWithUTF8CString("host");
    defer jsc.JSStringRelease(k_host);
    const k_fetch = jsc.JSStringCreateWithUTF8CString("fetch");
    defer jsc.JSStringRelease(k_fetch);
    const port_val = jsc.JSObjectGetProperty(ctx, options_obj, k_port, null);
    _ = jsc.JSObjectSetProperty(ctx, shu_opts, k_port, port_val, jsc.kJSPropertyAttributeNone, null);
    var host_buf: [256]u8 = undefined;
    const host_slice = getOptionalStringFromObj(ctx, options_obj, "hostname", &host_buf) orelse
        getOptionalStringFromObj(ctx, options_obj, "host", &host_buf) orelse "0.0.0.0";
    // host_slice 可能即 host_buf 内的一段（getOptionalStringFromObj 写入后返回），此时不可 @memcpy 自拷贝，仅补 \0
    const host_for_js: [*]const u8 = if (host_slice.len < host_buf.len) blk: {
        const dst = host_buf[0..host_slice.len];
        if (host_slice.ptr != host_buf[0..].ptr) @memcpy(dst, host_slice);
        host_buf[host_slice.len] = 0;
        break :blk host_buf[0..].ptr;
    } else "0.0.0.0";
    const host_js = jsc.JSStringCreateWithUTF8CString(host_for_js);
    defer jsc.JSStringRelease(host_js);
    _ = jsc.JSObjectSetProperty(ctx, shu_opts, k_host, jsc.JSValueMakeString(ctx, host_js), jsc.kJSPropertyAttributeNone, null);
    const fetch_val = jsc.JSObjectGetProperty(ctx, options_obj, k_fetch, null);
    if (jsc.JSValueIsUndefined(ctx, fetch_val)) return jsc.JSValueMakeUndefined(ctx);
    _ = jsc.JSObjectSetProperty(ctx, shu_opts, k_fetch, fetch_val, jsc.kJSPropertyAttributeNone, null);
    const on_error_k = jsc.JSStringCreateWithUTF8CString("onError");
    defer jsc.JSStringRelease(on_error_k);
    const on_error_val = jsc.JSObjectGetProperty(ctx, options_obj, on_error_k, null);
    if (!jsc.JSValueIsUndefined(ctx, on_error_val))
        _ = jsc.JSObjectSetProperty(ctx, shu_opts, on_error_k, on_error_val, jsc.kJSPropertyAttributeNone, null);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const name_shu = jsc.JSStringCreateWithUTF8CString("Shu");
    defer jsc.JSStringRelease(name_shu);
    const shu_val = jsc.JSObjectGetProperty(ctx, global, name_shu, null);
    const shu_obj = jsc.JSValueToObject(ctx, shu_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const name_server = jsc.JSStringCreateWithUTF8CString("server");
    defer jsc.JSStringRelease(name_server);
    const server_val = jsc.JSObjectGetProperty(ctx, shu_obj, name_server, null);
    const server_fn = jsc.JSValueToObject(ctx, server_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    var args = [_]jsc.JSValueRef{shu_opts};
    return jsc.JSObjectCallAsFunction(ctx, server_fn, shu_obj, 1, &args, null);
}
