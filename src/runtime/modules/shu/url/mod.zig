// shu:url 内置：Node 风格 parse/format + 全局 URL/URLSearchParams（当 JSC 未提供时）
// 基于 std.Uri；register 由 bindings 调用，getExports 供 require("shu:url")/node:url

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");

// ---------- 全局 URL / URLSearchParams 注册（来自原 engine/url.zig）---------

/// §1.1 显式 allocator 收敛：register 时注入，URL/URLSearchParams 回调优先使用
threadlocal var g_url_allocator: ?std.mem.Allocator = null;

/// 仅当全局尚无 URL 时注册 globalThis.URL 与 globalThis.URLSearchParams；由 bindings 调用；allocator 传入时注入
pub fn register(ctx: jsc.JSGlobalContextRef, allocator: ?std.mem.Allocator) void {
    if (allocator) |a| g_url_allocator = a;
    const global = jsc.JSContextGetGlobalObject(ctx);
    const name_url = jsc.JSStringCreateWithUTF8CString("URL");
    defer jsc.JSStringRelease(name_url);
    const existing = jsc.JSObjectGetProperty(ctx, global, name_url, null);
    if (!jsc.JSValueIsUndefined(ctx, existing)) return;
    setGlobalConstructor(ctx, global, "URLSearchParams", urlSearchParamsConstructorCallback);
    setGlobalConstructor(ctx, global, "URL", urlConstructorCallback);
}

fn setGlobalConstructor(ctx: jsc.JSGlobalContextRef, global: jsc.JSObjectRef, name: [*]const u8, callback: jsc.JSObjectCallAsFunctionCallback) void {
    const name_ref = jsc.JSStringCreateWithUTF8CString(name);
    defer jsc.JSStringRelease(name_ref);
    const fn_ref = jsc.JSObjectMakeFunctionWithCallback(ctx, name_ref, callback);
    _ = jsc.JSObjectSetProperty(ctx, global, name_ref, fn_ref, jsc.kJSPropertyAttributeNone, null);
}

fn setMethod(ctx: jsc.JSGlobalContextRef, obj: jsc.JSObjectRef, method_name: [*]const u8, callback: jsc.JSObjectCallAsFunctionCallback) void {
    const name_ref = jsc.JSStringCreateWithUTF8CString(method_name);
    defer jsc.JSStringRelease(name_ref);
    const fn_ref = jsc.JSObjectMakeFunctionWithCallback(ctx, name_ref, callback);
    _ = jsc.JSObjectSetProperty(ctx, obj, name_ref, fn_ref, jsc.kJSPropertyAttributeNone, null);
}

/// 给 URL 对象设置字符串属性（name 为字面量 [*]const u8，value 会 dupeZ 后设到 JSC）
fn setStringPropertyUrl(ctx: jsc.JSContextRef, obj: jsc.JSObjectRef, name: [*]const u8, value: []const u8) void {
    const allocator = g_url_allocator orelse globals.current_allocator orelse return;
    const name_ref = jsc.JSStringCreateWithUTF8CString(name);
    defer jsc.JSStringRelease(name_ref);
    const value_z = allocator.dupeZ(u8, value) catch return;
    defer allocator.free(value_z);
    const value_ref = jsc.JSStringCreateWithUTF8CString(value_z.ptr);
    defer jsc.JSStringRelease(value_ref);
    _ = jsc.JSObjectSetProperty(ctx, obj, name_ref, jsc.JSValueMakeString(ctx, value_ref), jsc.kJSPropertyAttributeNone, null);
}

// ---------- 共用与 URLSearchParams ----------

fn setStringProperty(ctx: jsc.JSContextRef, obj: jsc.JSObjectRef, name: []const u8, value: []const u8) void {
    const allocator = g_url_allocator orelse globals.current_allocator orelse return;
    const name_z = allocator.dupeZ(u8, name) catch return;
    defer allocator.free(name_z);
    const name_ref = jsc.JSStringCreateWithUTF8CString(name_z.ptr);
    defer jsc.JSStringRelease(name_ref);
    const value_z = allocator.dupeZ(u8, value) catch return;
    defer allocator.free(value_z);
    const value_ref = jsc.JSStringCreateWithUTF8CString(value_z.ptr);
    defer jsc.JSStringRelease(value_ref);
    _ = jsc.JSObjectSetProperty(ctx, obj, name_ref, jsc.JSValueMakeString(ctx, value_ref), jsc.kJSPropertyAttributeNone, null);
}

/// 从 JS 值取 UTF-8 字符串，调用方 free
fn jsValueToUtf8(ctx: jsc.JSContextRef, value: jsc.JSValueRef, allocator: std.mem.Allocator) ?[]const u8 {
    const js_str = jsc.JSValueToStringCopy(ctx, value, null);
    defer jsc.JSStringRelease(js_str);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(js_str);
    if (max_sz == 0 or max_sz > 65536) return null;
    const buf = allocator.alloc(u8, max_sz) catch return null;
    defer allocator.free(buf);
    const n = jsc.JSStringGetUTF8CString(js_str, buf.ptr, max_sz);
    if (n == 0) return null;
    return allocator.dupe(u8, buf[0 .. n - 1]) catch null;
}

const search_key = "__search";

fn getSearchFromThis(ctx: jsc.JSContextRef, this: jsc.JSObjectRef, allocator: std.mem.Allocator) ?[]const u8 {
    const name_ref = jsc.JSStringCreateWithUTF8CString(search_key);
    defer jsc.JSStringRelease(name_ref);
    const val = jsc.JSObjectGetProperty(ctx, this, name_ref, null);
    const js_str = jsc.JSValueToStringCopy(ctx, val, null);
    defer jsc.JSStringRelease(js_str);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(js_str);
    if (max_sz == 0) return null;
    const buf = allocator.alloc(u8, max_sz) catch return null;
    defer allocator.free(buf);
    const n = jsc.JSStringGetUTF8CString(js_str, buf.ptr, max_sz);
    if (n == 0) return null;
    return allocator.dupe(u8, buf[0 .. n - 1]) catch null;
}

const QueryPair = struct { k: []const u8, v: []const u8 };

fn parseQuery(allocator: std.mem.Allocator, search: []const u8) !std.ArrayList(QueryPair) {
    var list = try std.ArrayList(QueryPair).initCapacity(allocator, 0);
    var rest = search;
    while (rest.len > 0) {
        const amp = std.mem.indexOfScalar(u8, rest, '&') orelse rest.len;
        const part = rest[0..amp];
        rest = if (amp < rest.len) rest[amp + 1 ..] else rest[rest.len..];
        const eq = std.mem.indexOfScalar(u8, part, '=');
        const k = if (eq) |e| part[0..e] else part;
        const v = if (eq) |e| part[e + 1 ..] else "";
        try list.append(allocator, .{ .k = k, .v = v });
    }
    return list;
}

fn urlSearchParamsConstructorCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = g_url_allocator orelse globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    var init_str: []const u8 = "";
    if (argumentCount >= 1) {
        const s = jsValueToUtf8(ctx, arguments[0], allocator) orelse "";
        defer if (s.len > 0) allocator.free(s);
        init_str = s;
        if (init_str.len > 0 and init_str[0] == '?') init_str = init_str[1..];
    }
    const obj = jsc.JSObjectMake(ctx, null, null);
    const name_ref = jsc.JSStringCreateWithUTF8CString(search_key);
    defer jsc.JSStringRelease(name_ref);
    const init_dup = allocator.dupeZ(u8, init_str) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(init_dup);
    const val_ref = jsc.JSStringCreateWithUTF8CString(init_dup.ptr);
    defer jsc.JSStringRelease(val_ref);
    _ = jsc.JSObjectSetProperty(ctx, obj, name_ref, jsc.JSValueMakeString(ctx, val_ref), jsc.kJSPropertyAttributeNone, null);
    setMethod(ctx, obj, "get", searchParamsGetCallback);
    setMethod(ctx, obj, "getAll", searchParamsGetAllCallback);
    setMethod(ctx, obj, "toString", searchParamsToStringCallback);
    return obj;
}

fn searchParamsGetCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const allocator = g_url_allocator orelse globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const search = getSearchFromThis(ctx, this, allocator) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(search);
    const name = jsValueToUtf8(ctx, arguments[0], allocator) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(name);
    var list = parseQuery(allocator, search) catch return jsc.JSValueMakeUndefined(ctx);
    defer list.deinit(allocator);
    for (list.items) |pair| {
        if (std.mem.eql(u8, pair.k, name)) {
            const v_z = allocator.dupeZ(u8, pair.v) catch return jsc.JSValueMakeUndefined(ctx);
            defer allocator.free(v_z);
            const ref = jsc.JSStringCreateWithUTF8CString(v_z.ptr);
            defer jsc.JSStringRelease(ref);
            return jsc.JSValueMakeString(ctx, ref);
        }
    }
    return jsc.JSValueMakeUndefined(ctx);
}

fn searchParamsGetAllCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const allocator = g_url_allocator orelse globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const search = getSearchFromThis(ctx, this, allocator) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(search);
    const name = jsValueToUtf8(ctx, arguments[0], allocator) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(name);
    var list = parseQuery(allocator, search) catch return jsc.JSValueMakeUndefined(ctx);
    defer list.deinit(allocator);
    var values = std.ArrayList(jsc.JSValueRef).initCapacity(allocator, 0) catch return jsc.JSValueMakeUndefined(ctx);
    defer values.deinit(allocator);
    for (list.items) |pair| {
        if (std.mem.eql(u8, pair.k, name)) {
            const v_z = allocator.dupeZ(u8, pair.v) catch continue;
            defer allocator.free(v_z);
            const ref = jsc.JSStringCreateWithUTF8CString(v_z.ptr);
            defer jsc.JSStringRelease(ref);
            values.append(allocator, jsc.JSValueMakeString(ctx, ref)) catch continue;
        }
    }
    const arr = jsc.JSObjectMakeArray(ctx, values.items.len, values.items.ptr, null);
    return arr;
}

fn searchParamsToStringCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = g_url_allocator orelse globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const search = getSearchFromThis(ctx, this, allocator) orelse return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
    defer allocator.free(search);
    const search_z = allocator.dupeZ(u8, search) catch return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
    defer allocator.free(search_z);
    const ref = jsc.JSStringCreateWithUTF8CString(search_z.ptr);
    defer jsc.JSStringRelease(ref);
    return jsc.JSValueMakeString(ctx, ref);
}

fn throwURLException(ctx: jsc.JSContextRef, msg: []const u8) jsc.JSValueRef {
    var buf: [384]u8 = undefined;
    const prefix = "throw new TypeError(\"";
    @memcpy(buf[0..prefix.len], prefix);
    var i: usize = prefix.len;
    for (msg) |c| {
        if (i >= buf.len - 4) break;
        if (c == '"' or c == '\\') {
            buf[i] = '\\';
            i += 1;
        }
        buf[i] = c;
        i += 1;
    }
    const suffix = "\");";
    @memcpy(buf[i..][0..suffix.len], suffix);
    i += suffix.len;
    buf[i] = 0;
    const script_ref = jsc.JSStringCreateWithUTF8CString(buf[0..].ptr);
    defer jsc.JSStringRelease(script_ref);
    _ = jsc.JSEvaluateScript(ctx, script_ref, null, null, 1, null);
    return jsc.JSValueMakeUndefined(ctx);
}

/// new URL(input [, base])：解析 URL，返回带 href、origin、pathname、search、hash、searchParams 的对象
fn urlConstructorCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return throwURLException(ctx, "URL requires 1 argument");
    const allocator = g_url_allocator orelse globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const input = jsValueToUtf8(ctx, arguments[0], allocator) orelse return throwURLException(ctx, "URL: invalid input");
    defer allocator.free(input);
    const uri = std.Uri.parse(input) catch return throwURLException(ctx, "URL: failed to parse");
    if (argumentCount >= 2) {
        const base_opt = jsValueToUtf8(ctx, arguments[1], allocator);
        defer if (base_opt) |s| allocator.free(s);
        const base_str = base_opt orelse "";
        if (base_str.len > 0) {
            _ = std.Uri.parse(base_str) catch return throwURLException(ctx, "URL: failed to parse base");
        }
    }
    const scheme = uri.scheme;
    var host_buf: [256]u8 = undefined;
    const host = if (uri.host) |h| (h.toRaw(&host_buf) catch host_buf[0..0]) else host_buf[0..0];
    const port = uri.port orelse 0;
    var path_buf: [1024]u8 = undefined;
    const pathname = uri.path.toRaw(&path_buf) catch path_buf[0..0];
    const pathname_s = if (pathname.len > 0) pathname else "/";
    var query_buf: [512]u8 = undefined;
    const query = if (uri.query) |q| (q.toRaw(&query_buf) catch query_buf[0..0]) else query_buf[0..0];
    var frag_buf: [256]u8 = undefined;
    const fragment = if (uri.fragment) |f| (f.toRaw(&frag_buf) catch frag_buf[0..0]) else frag_buf[0..0];
    var href_buf: [2048]u8 = undefined;
    var href_len: usize = 0;
    const p1 = std.fmt.bufPrint(href_buf[href_len..], "{s}://{s}", .{ scheme, host }) catch href_buf[href_len..][0..0];
    href_len += p1.len;
    if (port != 0) {
        const p2 = std.fmt.bufPrint(href_buf[href_len..], ":{d}", .{port}) catch href_buf[href_len..][0..0];
        href_len += p2.len;
    }
    const p3 = std.fmt.bufPrint(href_buf[href_len..], "{s}", .{pathname_s}) catch href_buf[href_len..][0..0];
    href_len += p3.len;
    if (query.len > 0) {
        const p4 = std.fmt.bufPrint(href_buf[href_len..], "?{s}", .{query}) catch href_buf[href_len..][0..0];
        href_len += p4.len;
    }
    if (fragment.len > 0) {
        const p5 = std.fmt.bufPrint(href_buf[href_len..], "#{s}", .{fragment}) catch href_buf[href_len..][0..0];
        href_len += p5.len;
    }
    const href = allocator.dupe(u8, href_buf[0..href_len]) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(href);
    var origin_buf: [256]u8 = undefined;
    const origin = if (port == 0)
        std.fmt.bufPrintZ(&origin_buf, "{s}://{s}", .{ scheme, host }) catch scheme
    else
        std.fmt.bufPrintZ(&origin_buf, "{s}://{s}:{d}", .{ scheme, host, port }) catch scheme;
    const obj = jsc.JSObjectMake(ctx, null, null);
    var search_buf: [512]u8 = undefined;
    var hash_buf: [512]u8 = undefined;
    const search_str = if (query.len > 0) std.fmt.bufPrint(&search_buf, "?{s}", .{query}) catch "" else "";
    const hash_str = if (fragment.len > 0) std.fmt.bufPrint(&hash_buf, "#{s}", .{fragment}) catch "" else "";
    setStringPropertyUrl(ctx, obj, "href", href);
    setStringPropertyUrl(ctx, obj, "origin", origin);
    setStringPropertyUrl(ctx, obj, "pathname", pathname_s);
    setStringPropertyUrl(ctx, obj, "search", search_str);
    setStringPropertyUrl(ctx, obj, "hash", hash_str);
    const name_sp = jsc.JSStringCreateWithUTF8CString("searchParams");
    defer jsc.JSStringRelease(name_sp);
    const sp_obj = jsc.JSObjectMake(ctx, null, null);
    const name_search = jsc.JSStringCreateWithUTF8CString(search_key);
    defer jsc.JSStringRelease(name_search);
    const q_z = allocator.dupeZ(u8, query) catch "";
    defer if (q_z.len > 0) allocator.free(q_z);
    const q_ref = jsc.JSStringCreateWithUTF8CString(if (q_z.len > 0) q_z.ptr else "");
    defer jsc.JSStringRelease(q_ref);
    _ = jsc.JSObjectSetProperty(ctx, sp_obj, name_search, jsc.JSValueMakeString(ctx, q_ref), jsc.kJSPropertyAttributeNone, null);
    setMethod(ctx, sp_obj, "get", searchParamsGetCallback);
    setMethod(ctx, sp_obj, "getAll", searchParamsGetAllCallback);
    setMethod(ctx, sp_obj, "toString", searchParamsToStringCallback);
    _ = jsc.JSObjectSetProperty(ctx, obj, name_sp, sp_obj, jsc.kJSPropertyAttributeNone, null);
    return obj;
}

// ---------- shu:url / node:url 模块：parse、format ----------

/// parse(u [, parseQuery])：Zig 用 std.Uri 解析，返回 { href, protocol, host, hostname, port, pathname, search, hash, query }
fn parseCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const allocator = g_url_allocator orelse globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const input = jsValueToUtf8(ctx, arguments[0], allocator) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(input);
    const parse_query = if (argumentCount >= 2) jsc.JSValueToBoolean(ctx, arguments[1]) else true;
    const uri = std.Uri.parse(input) catch return jsc.JSValueMakeUndefined(ctx);
    var host_buf: [256]u8 = undefined;
    const host = if (uri.host) |h| (h.toRaw(&host_buf) catch host_buf[0..0]) else host_buf[0..0];
    const port = uri.port orelse 0;
    var path_buf: [1024]u8 = undefined;
    const pathname = uri.path.toRaw(&path_buf) catch path_buf[0..0];
    const pathname_s = if (pathname.len > 0) pathname else "/";
    var query_buf: [512]u8 = undefined;
    const query = if (uri.query) |q| (q.toRaw(&query_buf) catch query_buf[0..0]) else query_buf[0..0];
    var frag_buf: [256]u8 = undefined;
    const fragment = if (uri.fragment) |f| (f.toRaw(&frag_buf) catch frag_buf[0..0]) else frag_buf[0..0];
    var href_buf: [2048]u8 = undefined;
    var href_len: usize = 0;
    const p1 = std.fmt.bufPrint(href_buf[href_len..], "{s}://{s}", .{ uri.scheme, host }) catch href_buf[href_len..][0..0];
    href_len += p1.len;
    if (port != 0) {
        const p2 = std.fmt.bufPrint(href_buf[href_len..], ":{d}", .{port}) catch href_buf[href_len..][0..0];
        href_len += p2.len;
    }
    const p3 = std.fmt.bufPrint(href_buf[href_len..], "{s}", .{pathname_s}) catch href_buf[href_len..][0..0];
    href_len += p3.len;
    if (query.len > 0) {
        const p4 = std.fmt.bufPrint(href_buf[href_len..], "?{s}", .{query}) catch href_buf[href_len..][0..0];
        href_len += p4.len;
    }
    if (fragment.len > 0) {
        const p5 = std.fmt.bufPrint(href_buf[href_len..], "#{s}", .{fragment}) catch href_buf[href_len..][0..0];
        href_len += p5.len;
    }
    const href = href_buf[0..href_len];
    var search_buf: [512]u8 = undefined;
    var hash_buf: [512]u8 = undefined;
    const search_str = if (query.len > 0) std.fmt.bufPrint(&search_buf, "?{s}", .{query}) catch "" else "";
    const hash_str = if (fragment.len > 0) std.fmt.bufPrint(&hash_buf, "#{s}", .{fragment}) catch "" else "";
    const obj = jsc.JSObjectMake(ctx, null, null);
    setStringProperty(ctx, obj, "href", href);
    setStringProperty(ctx, obj, "protocol", uri.scheme);
    setStringProperty(ctx, obj, "host", host);
    setStringProperty(ctx, obj, "hostname", host);
    if (port != 0) {
        var port_buf: [16]u8 = undefined;
        const port_s = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch "";
        setStringProperty(ctx, obj, "port", port_s);
    } else {
        setStringProperty(ctx, obj, "port", "");
    }
    setStringProperty(ctx, obj, "pathname", pathname_s);
    setStringProperty(ctx, obj, "search", search_str);
    setStringProperty(ctx, obj, "hash", hash_str);
    if (parse_query and query.len > 0) {
        const query_obj = parseQueryToObject(ctx, allocator, query) orelse obj;
        _ = jsc.JSObjectSetProperty(ctx, obj, jsc.JSStringCreateWithUTF8CString("query"), query_obj, jsc.kJSPropertyAttributeNone, null);
    } else {
        setStringProperty(ctx, obj, "query", search_str);
    }
    return obj;
}

fn parseQueryToObject(ctx: jsc.JSContextRef, allocator: std.mem.Allocator, search: []const u8) ?jsc.JSObjectRef {
    const result = jsc.JSObjectMake(ctx, null, null);
    var rest = search;
    while (rest.len > 0) {
        const amp = std.mem.indexOfScalar(u8, rest, '&') orelse rest.len;
        const part = rest[0..amp];
        rest = if (amp < rest.len) rest[amp + 1 ..] else rest[rest.len..];
        const eq = std.mem.indexOfScalar(u8, part, '=');
        const k = if (eq) |e| part[0..e] else part;
        const v = if (eq) |e| part[e + 1 ..] else "";
        const k_z = allocator.dupeZ(u8, k) catch continue;
        defer allocator.free(k_z);
        const v_z = allocator.dupeZ(u8, v) catch continue;
        defer allocator.free(v_z);
        const k_ref = jsc.JSStringCreateWithUTF8CString(k_z.ptr);
        defer jsc.JSStringRelease(k_ref);
        const v_ref = jsc.JSStringCreateWithUTF8CString(v_z.ptr);
        defer jsc.JSStringRelease(v_ref);
        _ = jsc.JSObjectSetProperty(ctx, result, k_ref, jsc.JSValueMakeString(ctx, v_ref), jsc.kJSPropertyAttributeNone, null);
    }
    return result;
}

/// format(o)：从对象取 href 或拼 protocol+host+pathname+search+hash，返回规范 URL 字符串
fn formatCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
    const allocator = g_url_allocator orelse globals.current_allocator orelse return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
    const obj = jsc.JSValueToObject(ctx, arguments[0], null) orelse return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
    const href_val = jsc.JSObjectGetProperty(ctx, obj, jsc.JSStringCreateWithUTF8CString("href"), null);
    if (!jsc.JSValueIsUndefined(ctx, href_val)) {
        const href = jsValueToUtf8(ctx, href_val, allocator) orelse return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
        defer allocator.free(href);
        if (href.len > 0) {
            const full = allocator.dupeZ(u8, href) catch return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
            defer allocator.free(full);
            const ref = jsc.JSStringCreateWithUTF8CString(full.ptr);
            return jsc.JSValueMakeString(ctx, ref);
        }
    }
    const protocol_s = jsValueToUtf8(ctx, jsc.JSObjectGetProperty(ctx, obj, jsc.JSStringCreateWithUTF8CString("protocol"), null), allocator);
    const protocol = protocol_s orelse "";
    defer if (protocol_s) |s| allocator.free(s);
    const host_s = jsValueToUtf8(ctx, jsc.JSObjectGetProperty(ctx, obj, jsc.JSStringCreateWithUTF8CString("host"), null), allocator);
    const host = host_s orelse "";
    defer if (host_s) |s| allocator.free(s);
    const pathname_s2 = jsValueToUtf8(ctx, jsc.JSObjectGetProperty(ctx, obj, jsc.JSStringCreateWithUTF8CString("pathname"), null), allocator);
    const pathname = pathname_s2 orelse "";
    defer if (pathname_s2) |s| allocator.free(s);
    const search_s = jsValueToUtf8(ctx, jsc.JSObjectGetProperty(ctx, obj, jsc.JSStringCreateWithUTF8CString("search"), null), allocator);
    const search = search_s orelse "";
    defer if (search_s) |s| allocator.free(s);
    const hash_s = jsValueToUtf8(ctx, jsc.JSObjectGetProperty(ctx, obj, jsc.JSStringCreateWithUTF8CString("hash"), null), allocator);
    const hash = hash_s orelse "";
    defer if (hash_s) |s| allocator.free(s);
    var built_buf: [2048]u8 = undefined;
    const built_slice = std.fmt.bufPrint(&built_buf, "{s}{s}{s}{s}{s}", .{ protocol, host, pathname, search, hash }) catch return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
    const built = allocator.dupeZ(u8, built_slice) catch return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
    defer allocator.free(built);
    const uri = std.Uri.parse(built_slice) catch return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
    var href_out: [2048]u8 = undefined;
    var len: usize = 0;
    const empty: []u8 = href_out[len..][0..0];
    len += (std.fmt.bufPrint(href_out[len..], "{s}://", .{uri.scheme}) catch empty).len;
    if (uri.host) |h| {
        var host_buf: [256]u8 = undefined;
        len += (std.fmt.bufPrint(href_out[len..], "{s}", .{(h.toRaw(&host_buf) catch host_buf[0..0])}) catch empty).len;
    }
    if (uri.port) |p| len += (std.fmt.bufPrint(href_out[len..], ":{d}", .{p}) catch empty).len;
    var path_buf: [1024]u8 = undefined;
    const path_slice = uri.path.toRaw(&path_buf) catch path_buf[0..0];
    if (path_slice.len > 0) {
        len += (std.fmt.bufPrint(href_out[len..], "{s}", .{path_slice}) catch empty).len;
    }
    if (uri.query) |q| {
        var q_buf: [512]u8 = undefined;
        len += (std.fmt.bufPrint(href_out[len..], "?{s}", .{(q.toRaw(&q_buf) catch q_buf[0..0])}) catch empty).len;
    }
    if (uri.fragment) |f| {
        var f_buf: [256]u8 = undefined;
        len += (std.fmt.bufPrint(href_out[len..], "#{s}", .{(f.toRaw(&f_buf) catch f_buf[0..0])}) catch empty).len;
    }
    const z = allocator.dupeZ(u8, href_out[0..len]) catch return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
    defer allocator.free(z);
    const ref = jsc.JSStringCreateWithUTF8CString(z.ptr);
    return jsc.JSValueMakeString(ctx, ref);
}

/// 返回 shu:url / node:url 的 exports（parse、format）
pub fn getExports(ctx: jsc.JSContextRef, _: std.mem.Allocator) jsc.JSValueRef {
    const exports = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, exports, "parse", parseCallback);
    common.setMethod(ctx, exports, "format", formatCallback);
    return exports;
}
