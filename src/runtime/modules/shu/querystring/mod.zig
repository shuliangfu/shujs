// shu:querystring 内置：纯 Zig 实现 Node 风格 parse/stringify
// 供 require("shu:querystring") / node:querystring 共用，无内嵌 JS 脚本；parse 用 Zig 解析，stringify 用 Object.keys + 遍历

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");

const QueryPair = struct { k: []const u8, v: []const u8 };

/// [Allocates] 解析 "a=1&b=2" 为键值对列表；strip 前导 '?'；返回的 ArrayList 由调用方 deinit(allocator)。
fn parseQuery(allocator: std.mem.Allocator, search: []const u8) !std.ArrayList(QueryPair) {
    var list = try std.ArrayList(QueryPair).initCapacity(allocator, 0);
    var rest = search;
    if (rest.len > 0 and rest[0] == '?') rest = rest[1..];
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

/// parse(str)：Zig 解析查询串为 JS 对象，同键多值为数组
fn parseCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSObjectMake(ctx, null, null);
    const allocator = globals.current_allocator orelse return jsc.JSObjectMake(ctx, null, null);
    const str_js = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(str_js);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(str_js);
    if (max_sz == 0 or max_sz > 65536) return jsc.JSObjectMake(ctx, null, null);
    const buf = allocator.alloc(u8, max_sz) catch return jsc.JSObjectMake(ctx, null, null);
    defer allocator.free(buf);
    const n = jsc.JSStringGetUTF8CString(str_js, buf.ptr, max_sz);
    if (n == 0) return jsc.JSObjectMake(ctx, null, null);
    const search = buf[0 .. n - 1];
    var list = parseQuery(allocator, search) catch return jsc.JSObjectMake(ctx, null, null);
    defer list.deinit(allocator);
    const result = jsc.JSObjectMake(ctx, null, null);
    var key_values = std.StringArrayHashMap(std.ArrayList([]const u8)).init(allocator);
    defer {
        for (key_values.values()) |*arr| arr.deinit(allocator);
        key_values.deinit();
    }
    for (list.items) |pair| {
        const gop = key_values.getOrPut(pair.k) catch continue;
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList([]const u8).initCapacity(allocator, 1) catch continue;
        }
        const v_dup = allocator.dupe(u8, pair.v) catch continue;
        gop.value_ptr.append(allocator, v_dup) catch continue;
    }
    for (key_values.keys(), key_values.values()) |k, arr| {
        const k_z = allocator.dupeZ(u8, k) catch continue;
        defer allocator.free(k_z);
        const k_ref = jsc.JSStringCreateWithUTF8CString(k_z.ptr);
        defer jsc.JSStringRelease(k_ref);
        if (arr.items.len == 1) {
            const v_z = allocator.dupeZ(u8, arr.items[0]) catch continue;
            defer allocator.free(v_z);
            const v_ref = jsc.JSStringCreateWithUTF8CString(v_z.ptr);
            defer jsc.JSStringRelease(v_ref);
            _ = jsc.JSObjectSetProperty(ctx, result, k_ref, jsc.JSValueMakeString(ctx, v_ref), jsc.kJSPropertyAttributeNone, null);
        } else {
            var vals: [32]jsc.JSValueRef = undefined;
            const count = @min(arr.items.len, 32);
            for (arr.items[0..count], 0..) |v, i| {
                const v_z = allocator.dupeZ(u8, v) catch continue;
                const v_ref = jsc.JSStringCreateWithUTF8CString(v_z.ptr);
                vals[i] = jsc.JSValueMakeString(ctx, v_ref);
                allocator.free(v_z);
            }
            const arr_js = jsc.JSObjectMakeArray(ctx, count, &vals, null);
            _ = jsc.JSObjectSetProperty(ctx, result, k_ref, arr_js, jsc.kJSPropertyAttributeNone, null);
        }
    }
    return result;
}

/// stringify(obj)：用 Object.keys 取键，逐项拼 "k=v&..."
fn stringifyCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
    const obj_val = arguments[0];
    const obj = jsc.JSValueToObject(ctx, obj_val, null) orelse return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
    const global = jsc.JSContextGetGlobalObject(ctx);
    const obj_ctor = jsc.JSObjectGetProperty(ctx, global, jsc.JSStringCreateWithUTF8CString("Object"), null);
    const obj_obj = jsc.JSValueToObject(ctx, obj_ctor, null) orelse return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
    const keys_val = jsc.JSObjectGetProperty(ctx, obj_obj, jsc.JSStringCreateWithUTF8CString("keys"), null);
    const keys_fn = jsc.JSValueToObject(ctx, keys_val, null) orelse return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
    var one: [1]jsc.JSValueRef = .{obj_val};
    const keys_arr = jsc.JSObjectCallAsFunction(ctx, keys_fn, null, 1, &one, null);
    const keys_obj = jsc.JSValueToObject(ctx, keys_arr, null) orelse return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
    const len_val = jsc.JSObjectGetProperty(ctx, keys_obj, jsc.JSStringCreateWithUTF8CString("length"), null);
    const len: usize = @intFromFloat(jsc.JSValueToNumber(ctx, len_val, null));
    var out = std.ArrayList(u8).initCapacity(allocator, 256) catch return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
    defer out.deinit(allocator);
    var first = true;
    for (0..len) |i| {
        const key_val = jsc.JSObjectGetPropertyAtIndex(ctx, keys_obj, @intCast(i), null);
        const key_str = jsc.JSValueToStringCopy(ctx, key_val, null);
        defer jsc.JSStringRelease(key_str);
        const val_val = jsc.JSObjectGetProperty(ctx, obj, key_str, null);
        const val_str = jsc.JSValueToStringCopy(ctx, val_val, null);
        defer jsc.JSStringRelease(val_str);
        const k_max = jsc.JSStringGetMaximumUTF8CStringSize(key_str);
        const v_max = jsc.JSStringGetMaximumUTF8CStringSize(val_str);
        if (k_max == 0 or k_max > 4096 or v_max == 0 or v_max > 4096) continue;
        var k_buf: [4096]u8 = undefined;
        var v_buf: [4096]u8 = undefined;
        const kn = jsc.JSStringGetUTF8CString(key_str, &k_buf, k_buf.len);
        const vn = jsc.JSStringGetUTF8CString(val_str, &v_buf, v_buf.len);
        const k_slice = k_buf[0..if (kn > 0) kn - 1 else 0];
        const v_slice = v_buf[0..if (vn > 0) vn - 1 else 0];
        if (!first) out.append(allocator, '&') catch continue;
        first = false;
        out.appendSlice(allocator, k_slice) catch continue;
        out.append(allocator, '=') catch continue;
        out.appendSlice(allocator, v_slice) catch continue;
    }
    const z = allocator.dupeZ(u8, out.items) catch return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
    defer allocator.free(z);
    const ref = jsc.JSStringCreateWithUTF8CString(z.ptr);
    return jsc.JSValueMakeString(ctx, ref);
}

pub fn getExports(ctx: jsc.JSContextRef, _: std.mem.Allocator) jsc.JSValueRef {
    const exports = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, exports, "parse", parseCallback);
    common.setMethod(ctx, exports, "stringify", stringifyCallback);
    return exports;
}
