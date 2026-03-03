// 全局 fetch(url) 注册与 C 回调；需 --allow-net，同步 GET 返回 { ok, status, statusText, body }
// 由 bindings 在具备 RunOptions 时调用注册到 globalThis；本模块不依赖 engine。
// HTTP 请求统一经 libs_io.http（Content-Length 固定长度 / chunked 流式解压），与 registry、JSR 一致。

const std = @import("std");
const jsc = @import("jsc");
const libs_io = @import("libs_io");
const errors = @import("errors");
const globals = @import("../../../globals.zig");

/// §1.1 显式 allocator 收敛：register 时注入，fetch 回调优先使用
threadlocal var g_fetch_allocator: ?std.mem.Allocator = null;

/// 向全局对象注册 fetch；由 bindings.registerGlobals 在 options 非 null 时调用；allocator 传入时注入
pub fn register(ctx: jsc.JSGlobalContextRef, allocator: ?std.mem.Allocator) void {
    if (allocator) |a| g_fetch_allocator = a;
    const global = jsc.JSContextGetGlobalObject(ctx);
    const name_fetch = jsc.JSStringCreateWithUTF8CString("fetch");
    defer jsc.JSStringRelease(name_fetch);
    const fetch_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, name_fetch, callback);
    _ = jsc.JSObjectSetProperty(ctx, global, name_fetch, fetch_fn, jsc.kJSPropertyAttributeNone, null);
}

/// fetch 的 C 回调：取 URL、校验 allow_net、同步 GET、解压 body，返回 { ok, status, statusText, body }；无 allocator/opts 时返回 undefined。
fn callback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = g_fetch_allocator orelse globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    if (argumentCount == 0) return jsc.JSValueMakeUndefined(ctx);
    const url_val = arguments[0];
    const url_js = jsc.JSValueToStringCopy(ctx, url_val, null);
    defer jsc.JSStringRelease(url_js);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(url_js);
    if (max_sz == 0 or max_sz > 8192) return jsc.JSValueMakeUndefined(ctx);
    const url_buf = allocator.alloc(u8, max_sz) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(url_buf);
    const n = jsc.JSStringGetUTF8CString(url_js, url_buf.ptr, max_sz);
    if (n == 0) return jsc.JSValueMakeUndefined(ctx);
    const url = url_buf[0 .. n - 1];
    if (!opts.permissions.allow_net) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "fetch requires --allow-net" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    // 统一经 libs_io.http 发 GET：有 Content-Length 读固定长度，chunked 时流式解压，与 registry/JSR 一致；用 freeResponse 统一释放 body 与可分配的 status_text
    const resp = libs_io.http.request(allocator, url, .{
        .method = .GET,
        .max_response_bytes = 2 * 1024 * 1024,
    }) catch |e| {
        if (e == error.ResponseTooLarge) {
            errors.reportToStderr(.{ .code = .unknown, .message = "fetch response body too large" }) catch {};
        } else {
            errors.reportToStderr(.{ .code = .unknown, .message = "fetch request failed" }) catch {};
        }
        return jsc.JSValueMakeUndefined(ctx);
    };
    defer libs_io.http.freeResponse(allocator, &resp);
    const status: u16 = resp.status;
    const ok = status >= 200 and status < 300;
    const body_slice = resp.body;
    const resp_obj = jsc.JSObjectMake(ctx, null, null);
    const name_ok = jsc.JSStringCreateWithUTF8CString("ok");
    defer jsc.JSStringRelease(name_ok);
    const name_status = jsc.JSStringCreateWithUTF8CString("status");
    defer jsc.JSStringRelease(name_status);
    const name_statusText = jsc.JSStringCreateWithUTF8CString("statusText");
    defer jsc.JSStringRelease(name_statusText);
    const name_body = jsc.JSStringCreateWithUTF8CString("body");
    defer jsc.JSStringRelease(name_body);
    _ = jsc.JSObjectSetProperty(ctx, resp_obj, name_ok, jsc.JSValueMakeBoolean(ctx, ok), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, resp_obj, name_status, jsc.JSValueMakeNumber(ctx, @floatFromInt(status)), jsc.kJSPropertyAttributeNone, null);
    const statusText_z = allocator.dupeZ(u8, resp.status_text) catch "";
    defer if (statusText_z.len > 0) allocator.free(statusText_z);
    const statusText_js = if (statusText_z.len > 0) jsc.JSStringCreateWithUTF8CString(statusText_z.ptr) else jsc.JSStringCreateWithUTF8CString("");
    defer jsc.JSStringRelease(statusText_js);
    _ = jsc.JSObjectSetProperty(ctx, resp_obj, name_statusText, jsc.JSValueMakeString(ctx, statusText_js), jsc.kJSPropertyAttributeNone, null);
    // JSC 需要以 null 结尾的 C 串；body 切片未必带尾 0，用 dupeZ 保证安全
    const body_z = if (body_slice.len > 0) allocator.dupeZ(u8, body_slice) catch "" else "";
    defer if (body_z.len > 0) allocator.free(body_z);
    const body_js = jsc.JSStringCreateWithUTF8CString(if (body_z.len > 0) body_z.ptr else "");
    defer jsc.JSStringRelease(body_js);
    _ = jsc.JSObjectSetProperty(ctx, resp_obj, name_body, jsc.JSValueMakeString(ctx, body_js), jsc.kJSPropertyAttributeNone, null);
    return resp_obj;
}
