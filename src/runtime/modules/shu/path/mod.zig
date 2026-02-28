// Shu.path 路径相关 API：join、resolve、dirname、basename、extname、normalize、isAbsolute、relative、filePathToUrl、urlToFilePath、sep、delimiter
// §2.2 性能规则：os 相关用 comptime 常量，避免热路径重复分支

const std = @import("std");
const builtin = @import("builtin");
const jsc = @import("jsc");
const globals = @import("../../../globals.zig");
const common = @import("../../../common.zig");

/// 是否 Windows（comptime 分派，供路径逻辑分支）
const is_windows = builtin.os.tag == .windows;
/// 路径分隔符（comptime 分派，编译期唯一）
const path_sep = if (is_windows) "\\" else "/";
/// 环境变量分隔符（comptime 分派）
const path_delimiter = if (is_windows) ";" else ":";

/// 返回 Shu.path 的 exports 对象（供 shu:path 内置与引擎挂载）；allocator 预留
pub fn getExports(ctx: jsc.JSContextRef, _: std.mem.Allocator) jsc.JSValueRef {
    const path_obj = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, path_obj, "join", pathJoinCallback);
    common.setMethod(ctx, path_obj, "resolve", pathResolveCallback);
    common.setMethod(ctx, path_obj, "dirname", pathDirnameCallback);
    common.setMethod(ctx, path_obj, "basename", pathBasenameCallback);
    common.setMethod(ctx, path_obj, "extname", pathExtnameCallback);
    common.setMethod(ctx, path_obj, "normalize", pathNormalizeCallback);
    common.setMethod(ctx, path_obj, "isAbsolute", pathIsAbsoluteCallback);
    common.setMethod(ctx, path_obj, "relative", pathRelativeCallback);
    common.setMethod(ctx, path_obj, "filePathToUrl", pathFilePathToUrlCallback);
    common.setMethod(ctx, path_obj, "urlToFilePath", pathUrlToFilePathCallback);
    setStringProperty(ctx, path_obj, "sep", path_sep);
    setStringProperty(ctx, path_obj, "delimiter", path_delimiter);
    return path_obj;
}

/// 向 shu_obj 上注册 Shu.path 子对象（委托 getExports）
pub fn register(ctx: jsc.JSGlobalContextRef, shu_obj: jsc.JSObjectRef) void {
    const allocator = globals.current_allocator orelse return;
    const name_path = jsc.JSStringCreateWithUTF8CString("path");
    defer jsc.JSStringRelease(name_path);
    _ = jsc.JSObjectSetProperty(ctx, shu_obj, name_path, getExports(ctx, allocator), jsc.kJSPropertyAttributeNone, null);
}

/// 在 obj 上设置只读字符串属性（getExports 内部使用）
fn setStringProperty(ctx: jsc.JSContextRef, obj: jsc.JSObjectRef, name: [*:0]const u8, value: [*:0]const u8) void {
    const name_ref = jsc.JSStringCreateWithUTF8CString(name);
    defer jsc.JSStringRelease(name_ref);
    const value_ref = jsc.JSStringCreateWithUTF8CString(value);
    defer jsc.JSStringRelease(value_ref);
    _ = jsc.JSObjectSetProperty(ctx, obj, name_ref, jsc.JSValueMakeString(ctx, value_ref), jsc.kJSPropertyAttributeNone, null);
}

// ---------- 内部辅助 ----------

/// 从 JS 参数取第 idx 个参数的 UTF-8 字符串，返回的切片需由调用方 free
fn getPathArg(allocator: std.mem.Allocator, ctx: jsc.JSContextRef, arguments: [*]const jsc.JSValueRef, argumentCount: usize, idx: usize) ?[]const u8 {
    if (argumentCount <= idx) return null;
    const path_js = jsc.JSValueToStringCopy(ctx, arguments[idx], null);
    defer jsc.JSStringRelease(path_js);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(path_js);
    if (max_sz == 0 or max_sz > 65536) return null;
    const path_buf = allocator.alloc(u8, max_sz) catch return null;
    defer allocator.free(path_buf);
    const n = jsc.JSStringGetUTF8CString(path_js, path_buf.ptr, max_sz);
    if (n == 0) return null;
    return allocator.dupe(u8, path_buf[0 .. n - 1]) catch null;
}

/// 将 Zig 切片转为 JS 字符串并返回（调用方已持有 allocator 管理的切片，可在此后 free）
fn stringToJS(ctx: jsc.JSContextRef, allocator: std.mem.Allocator, s: []const u8) jsc.JSValueRef {
    const z = allocator.dupeZ(u8, s) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(z);
    const ref = jsc.JSStringCreateWithUTF8CString(z.ptr);
    defer jsc.JSStringRelease(ref);
    return jsc.JSValueMakeString(ctx, ref);
}

/// Shu.path.join(...parts)：将多个路径段用平台分隔符拼接
fn pathJoinCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    var parts = std.ArrayList([]const u8).initCapacity(allocator, 0) catch return jsc.JSValueMakeUndefined(ctx);
    defer parts.deinit(allocator);
    var i: usize = 0;
    while (i < argumentCount) : (i += 1) {
        const part_js = jsc.JSValueToStringCopy(ctx, arguments[i], null);
        defer jsc.JSStringRelease(part_js);
        const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(part_js);
        if (max_sz == 0 or max_sz > 4096) continue;
        const buf = allocator.alloc(u8, max_sz) catch continue;
        const n = jsc.JSStringGetUTF8CString(part_js, buf.ptr, max_sz);
        if (n > 0) {
            const slice = allocator.dupe(u8, buf[0 .. n - 1]) catch {
                allocator.free(buf);
                continue;
            };
            parts.append(allocator, slice) catch {
                allocator.free(slice);
                allocator.free(buf);
                continue;
            };
        }
        allocator.free(buf);
    }
    const joined = std.fs.path.join(allocator, parts.items) catch {
        for (parts.items) |p| allocator.free(p);
        return jsc.JSValueMakeUndefined(ctx);
    };
    for (parts.items) |p| allocator.free(p);
    defer allocator.free(joined);
    const joined_z = allocator.dupeZ(u8, joined) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(joined_z);
    const ref = jsc.JSStringCreateWithUTF8CString(joined_z.ptr);
    defer jsc.JSStringRelease(ref);
    return jsc.JSValueMakeString(ctx, ref);
}

/// Shu.path.resolve(...parts)：从右到左解析为绝对路径（相对 cwd）
fn pathResolveCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    var parts = std.ArrayList([]const u8).initCapacity(allocator, 0) catch return jsc.JSValueMakeUndefined(ctx);
    defer parts.deinit(allocator);
    const cwd_dup = allocator.dupe(u8, opts.cwd) catch return jsc.JSValueMakeUndefined(ctx);
    parts.append(allocator, cwd_dup) catch {
        allocator.free(cwd_dup);
        return jsc.JSValueMakeUndefined(ctx);
    };
    var i: usize = 0;
    while (i < argumentCount) : (i += 1) {
        const part_js = jsc.JSValueToStringCopy(ctx, arguments[i], null);
        defer jsc.JSStringRelease(part_js);
        const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(part_js);
        if (max_sz == 0 or max_sz > 4096) continue;
        const buf = allocator.alloc(u8, max_sz) catch continue;
        const n = jsc.JSStringGetUTF8CString(part_js, buf.ptr, max_sz);
        if (n > 0) {
            const slice = allocator.dupe(u8, buf[0 .. n - 1]) catch {
                allocator.free(buf);
                continue;
            };
            parts.append(allocator, slice) catch {
                allocator.free(slice);
                allocator.free(buf);
                continue;
            };
        }
        allocator.free(buf);
    }
    const resolved = std.fs.path.resolve(allocator, parts.items) catch {
        for (parts.items) |p| allocator.free(p);
        return jsc.JSValueMakeUndefined(ctx);
    };
    for (parts.items) |p| allocator.free(p);
    defer allocator.free(resolved);
    const resolved_z = allocator.dupeZ(u8, resolved) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved_z);
    const ref = jsc.JSStringCreateWithUTF8CString(resolved_z.ptr);
    defer jsc.JSStringRelease(ref);
    return jsc.JSValueMakeString(ctx, ref);
}

/// Shu.path.dirname(path)：返回路径的目录部分（不含最后一段）
fn pathDirnameCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const path = getPathArg(allocator, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(path);
    const dir = std.fs.path.dirname(path) orelse ".";
    return stringToJS(ctx, allocator, dir);
}

/// Shu.path.basename(path [, ext])：返回路径最后一段；若传 ext 则去掉该后缀
fn pathBasenameCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const path = getPathArg(allocator, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(path);
    var base = std.fs.path.basename(path);
    if (argumentCount >= 2) {
        const ext = getPathArg(allocator, ctx, arguments, argumentCount, 1) orelse return stringToJS(ctx, allocator, base);
        defer allocator.free(ext);
        if (ext.len > 0 and base.len >= ext.len and std.mem.endsWith(u8, base, ext)) {
            base = base[0 .. base.len - ext.len];
        }
    }
    return stringToJS(ctx, allocator, base);
}

/// Shu.path.extname(path)：返回扩展名（含点，如 ".zig"）
fn pathExtnameCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const path = getPathArg(allocator, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(path);
    const ext = std.fs.path.extension(path);
    return stringToJS(ctx, allocator, ext);
}

/// Shu.path.normalize(path)：规范化路径（解析 .、.. 与多余分隔符）
fn pathNormalizeCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const path = getPathArg(allocator, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(path);
    const normalized = std.fs.path.resolve(allocator, &.{path}) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(normalized);
    return stringToJS(ctx, allocator, normalized);
}

/// Shu.path.isAbsolute(path)：判断是否为绝对路径
fn pathIsAbsoluteCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const path = getPathArg(allocator, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeBoolean(ctx, false);
    defer allocator.free(path);
    return jsc.JSValueMakeBoolean(ctx, std.fs.path.isAbsolute(path));
}

/// Shu.path.relative(from, to)：计算从 from 到 to 的相对路径
fn pathRelativeCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const from = getPathArg(allocator, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(from);
    const to = getPathArg(allocator, ctx, arguments, argumentCount, 1) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(to);
    const rel = std.fs.path.relative(allocator, from, to) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(rel);
    return stringToJS(ctx, allocator, rel);
}

// ---------- filePathToUrl / urlToFilePath（模仿 Node.js url.pathToFileURL / fileURLToPath）----------

/// 将路径中需编码的字符转为 %XX，用于 file URL 的 path 部分（保留 / 不编码）
fn percentEncodePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var list = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer list.deinit(allocator);
    for (path) |c| {
        switch (c) {
            '/', 'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try list.append(allocator, c),
            '%' => try list.appendSlice(allocator, "%25"),
            '#' => try list.appendSlice(allocator, "%23"),
            '?' => try list.appendSlice(allocator, "%3F"),
            '[' => try list.appendSlice(allocator, "%5B"),
            ']' => try list.appendSlice(allocator, "%5D"),
            ' ' => try list.appendSlice(allocator, "%20"),
            '!' => try list.appendSlice(allocator, "%21"),
            '$' => try list.appendSlice(allocator, "%24"),
            '&' => try list.appendSlice(allocator, "%26"),
            '\'' => try list.appendSlice(allocator, "%27"),
            '(' => try list.appendSlice(allocator, "%28"),
            ')' => try list.appendSlice(allocator, "%29"),
            '*' => try list.appendSlice(allocator, "%2A"),
            '+' => try list.appendSlice(allocator, "%2B"),
            ',' => try list.appendSlice(allocator, "%2C"),
            ';' => try list.appendSlice(allocator, "%3B"),
            '=' => try list.appendSlice(allocator, "%3D"),
            ':' => try list.appendSlice(allocator, "%3A"),
            '@' => try list.appendSlice(allocator, "%40"),
            '\\' => try list.append(allocator, '/'), // 在 URL 中统一用 /
            else => {
                try list.append(allocator, '%');
                try std.fmt.format(list.writer(allocator), "{X:0>2}", .{c});
            },
        }
    }
    return list.toOwnedSlice(allocator);
}

/// 将 %XX 解码为字节
fn percentDecodePath(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var list = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer list.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hex = s[i + 1 .. i + 3];
            const byte = std.fmt.parseUnsigned(u8, hex, 16) catch {
                try list.append(allocator, s[i]);
                i += 1;
                continue;
            };
            try list.append(allocator, byte);
            i += 3;
        } else {
            try list.append(allocator, s[i]);
            i += 1;
        }
    }
    return list.toOwnedSlice(allocator);
}

/// Shu.path.filePathToUrl(path)：将文件路径转为 file: URL 字符串（模仿 Node url.pathToFileURL）
fn pathFilePathToUrlCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const path = getPathArg(allocator, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(path);
    const resolved = std.fs.path.resolve(allocator, &.{opts.cwd, path}) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    var path_for_url = resolved;
    if (is_windows) {
        path_for_url = std.mem.replaceOwned(u8, allocator, resolved, "\\", "/") catch {
            allocator.free(resolved);
            return jsc.JSValueMakeUndefined(ctx);
        };
        defer allocator.free(path_for_url);
    }
    const encoded = percentEncodePath(allocator, path_for_url) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(encoded);
    const prefix = "file://";
    const need_leading_slash = encoded.len == 0 or encoded[0] != '/';
    const extra: usize = if (need_leading_slash) @as(usize, 1) else @as(usize, 0);
    const result_len = prefix.len + extra + encoded.len;
    const result = allocator.alloc(u8, result_len) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(result);
    @memcpy(result[0..prefix.len], prefix);
    if (need_leading_slash) {
        result[prefix.len] = '/';
        @memcpy(result[prefix.len + 1 ..], encoded);
    } else {
        @memcpy(result[prefix.len..], encoded);
    }
    return stringToJS(ctx, allocator, result);
}

/// Shu.path.urlToFilePath(url)：将 file: URL 转为文件路径（模仿 Node url.fileURLToPath）
fn pathUrlToFilePathCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const url_str = getPathArg(allocator, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(url_str);
    if (!std.mem.startsWith(u8, url_str, "file://")) {
        return jsc.JSValueMakeUndefined(ctx);
    }
    const path_part = url_str["file://".len..];
    const decoded = percentDecodePath(allocator, path_part) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(decoded);
    var path = decoded;
    if (decoded.len > 0 and decoded[0] == '/') {
        path = decoded[1..];
    }
    if (is_windows and path.len >= 2 and path[1] == ':') {
        const with_backslash = std.mem.replaceOwned(u8, allocator, path, "/", "\\") catch return jsc.JSValueMakeUndefined(ctx);
        defer allocator.free(with_backslash);
        return stringToJS(ctx, allocator, with_backslash);
    }
    if (is_windows) {
        return stringToJS(ctx, allocator, path);
    }
    const absolute = allocator.alloc(u8, 1 + path.len) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(absolute);
    absolute[0] = '/';
    @memcpy(absolute[1..], path);
    return stringToJS(ctx, allocator, absolute);
}
