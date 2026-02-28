// 构造传给 handler 的 Request 对象与调用 handler：makeRequestObject、invokeHandlerWithOnError、appendJsonEscaped
// 供 mod / conn / h2 等调用；头部遍历复用 parse.iterHeaderLines，与 parse 解析策略统一（§2.1）

const std = @import("std");
const jsc = @import("jsc");
const types = @import("types.zig");
const parse = @import("parse.zig");

/// 将字符串转成 JSON 双引号内的内容（转义 \ 与 "），追加到 list，用于拼 headers JSON
pub fn appendJsonEscaped(list: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '"' => try list.appendSlice(allocator, "\\\""),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => try list.append(allocator, c),
        }
    }
}

/// 构造传给 handler 的 JS Request 对象：{ url, method, headers }
/// 精简 JSC 调用：url/method 各 1 次 CreateString+SetProperty；headers 用 JSON.parse 一次生成
pub fn makeRequestObject(ctx: jsc.JSContextRef, allocator: std.mem.Allocator, parsed: *const types.ParsedRequest) ?jsc.JSObjectRef {
    const req = jsc.JSObjectMake(ctx, null, null);
    const k_url = jsc.JSStringCreateWithUTF8CString("url");
    defer jsc.JSStringRelease(k_url);
    const k_method = jsc.JSStringCreateWithUTF8CString("method");
    defer jsc.JSStringRelease(k_method);
    const k_headers = jsc.JSStringCreateWithUTF8CString("headers");
    defer jsc.JSStringRelease(k_headers);

    const path_z = allocator.dupeZ(u8, parsed.path) catch return null;
    defer allocator.free(path_z);
    const url_js = jsc.JSStringCreateWithUTF8CString(path_z.ptr);
    defer jsc.JSStringRelease(url_js);
    _ = jsc.JSObjectSetProperty(ctx, req, k_url, jsc.JSValueMakeString(ctx, url_js), jsc.kJSPropertyAttributeNone, null);

    const method_z = allocator.dupeZ(u8, parsed.method) catch return null;
    defer allocator.free(method_z);
    const method_js = jsc.JSStringCreateWithUTF8CString(method_z.ptr);
    defer jsc.JSStringRelease(method_js);
    _ = jsc.JSObjectSetProperty(ctx, req, k_method, jsc.JSValueMakeString(ctx, method_js), jsc.kJSPropertyAttributeNone, null);

    var headers_json = std.ArrayList(u8).initCapacity(allocator, 0) catch return null;
    defer headers_json.deinit(allocator);
    headers_json.append(allocator, '{') catch return null;
    var iter = parse.iterHeaderLines(parsed.headers_head);
    var first = true;
    while (iter.next()) |kv| {
        if (!first) headers_json.append(allocator, ',') catch return null;
        first = false;
        headers_json.append(allocator, '"') catch return null;
        for (kv.name) |c| {
            if (c == '"' or c == '\\') {
                headers_json.append(allocator, '\\') catch return null;
                headers_json.append(allocator, c) catch return null;
            } else if (c >= 'A' and c <= 'Z') {
                headers_json.append(allocator, c + 32) catch return null;
            } else {
                headers_json.append(allocator, c) catch return null;
            }
        }
        headers_json.appendSlice(allocator, "\":\"") catch return null;
        appendJsonEscaped(&headers_json, allocator, kv.value) catch return null;
        headers_json.append(allocator, '"') catch return null;
    }
    headers_json.append(allocator, '}') catch return null;
    const json_slice = headers_json.items;
    const json_z = allocator.dupeZ(u8, json_slice) catch return null;
    defer allocator.free(json_z);
    const json_js = jsc.JSStringCreateWithUTF8CString(json_z.ptr);
    defer jsc.JSStringRelease(json_js);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_JSON = jsc.JSStringCreateWithUTF8CString("JSON");
    defer jsc.JSStringRelease(k_JSON);
    const json_obj_val = jsc.JSObjectGetProperty(ctx, global, k_JSON, null);
    const json_obj = jsc.JSValueToObject(ctx, json_obj_val, null) orelse return null;
    const k_parse = jsc.JSStringCreateWithUTF8CString("parse");
    defer jsc.JSStringRelease(k_parse);
    const parse_fn_val = jsc.JSObjectGetProperty(ctx, json_obj, k_parse, null);
    const parse_fn = jsc.JSValueToObject(ctx, parse_fn_val, null) orelse return null;
    var parse_args = [_]jsc.JSValueRef{jsc.JSValueMakeString(ctx, json_js)};
    const headers_obj_val = jsc.JSObjectCallAsFunction(ctx, parse_fn, json_obj, 1, &parse_args, null);
    const headers_obj = jsc.JSValueToObject(ctx, headers_obj_val, null);
    if (headers_obj != null) {
        _ = jsc.JSObjectSetProperty(ctx, req, k_headers, headers_obj_val, jsc.kJSPropertyAttributeNone, null);
    } else {
        _ = jsc.JSObjectSetProperty(ctx, req, k_headers, jsc.JSObjectMake(ctx, null, null), jsc.kJSPropertyAttributeNone, null);
    }
    return req;
}

/// 调用 handler(req)，若抛错或返回非对象则视情况调用 onError(err)；返回最终可用的 response 或标记为无效
pub fn invokeHandlerWithOnError(
    ctx: jsc.JSContextRef,
    handler_fn: jsc.JSValueRef,
    req_obj: jsc.JSValueRef,
    error_callback: ?jsc.JSValueRef,
) struct { value: jsc.JSValueRef, is_valid: bool } {
    var exception: ?jsc.JSValueRef = null;
    const args = [_]jsc.JSValueRef{req_obj};
    const response_val = jsc.JSObjectCallAsFunction(ctx, @ptrCast(handler_fn), null, 1, &args, @ptrCast(&exception));
    const had_exception = exception != null;
    const invalid_return = jsc.JSValueToObject(ctx, response_val, null) == null;
    if (!had_exception and !invalid_return) return .{ .value = response_val, .is_valid = true };

    if (error_callback) |on_err| {
        const err_arg = if (had_exception) exception.? else response_val;
        const err_args = [_]jsc.JSValueRef{err_arg};
        var err_exc: ?jsc.JSValueRef = null;
        const on_err_ret = jsc.JSObjectCallAsFunction(ctx, @ptrCast(on_err), null, 1, &err_args, @ptrCast(&err_exc));
        if (jsc.JSValueToObject(ctx, on_err_ret, null) != null) return .{ .value = on_err_ret, .is_valid = true };
    }
    return .{ .value = undefined, .is_valid = false };
}
