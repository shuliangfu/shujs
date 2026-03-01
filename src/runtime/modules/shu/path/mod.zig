//! Shu.path：路径字符串解析与组装，纯逻辑无 I/O，不访问文件系统。
//!
//! ## 提供 API（同步，无权限要求）
//! - **join(...parts)**：多段路径用平台分隔符拼接并规范化
//! - **resolve(...parts)**：相对当前工作目录解析为绝对路径（从右到左）
//! - **dirname(path)**：目录部分（不含最后一段）
//! - **basename(path [, ext])**：最后一段；可选第二参去掉后缀
//! - **extname(path)**：扩展名（含点，如 ".zig"）
//! - **normalize(path)**：规范化（解析 .、.. 与多余分隔符）
//! - **isAbsolute(path)**：是否绝对路径
//! - **relative(from, to)**：从 from 到 to 的相对路径
//! - **parse(path)**：返回 `{ root, dir, base, name, ext }`，与 Node path.parse 一致
//! - **format(pathObject)**：从 `{ root, dir, base, name, ext }` 组装路径，与 Node path.format 一致
//! - **root(path)**：仅返回根部分（如 "/"、"C:\\"），等价 parse(path).root（Shu 特色）
//! - **name(path)**：仅返回文件名无扩展名，等价 parse(path).name（Shu 特色）
//! - **toNamespacedPath(path)**：Windows 下转为 `\\?\` 长路径命名空间，非 Windows 返回规范化绝对路径
//! - **filePathToUrl(path)**：路径 → file: URL 字符串（等价 Node url.pathToFileURL）
//! - **urlToFilePath(url)**：file: URL → 路径（等价 Node url.fileURLToPath）
//! - **sep**：路径分隔符（"/" 或 "\\"）
//! - **delimiter**：环境变量分隔符（":" 或 ";"）
//! - **posix** / **win32**：子对象，同名方法 + 固定 sep/delimiter（posix: "/"、":"，win32: "\\"、";"），便于跨平台脚本
//!
//! ## 与 Node.js (node:path) 兼容情况
//! | Node API | Shu.path | 说明 |
//! |----------|---------|------|
//! | path.join, resolve, dirname, basename, extname, normalize, isAbsolute, relative | 同名 | 行为与 Node 一致，按当前 OS 分隔符 |
//! | path.parse, path.format | 同名 | 返回/接收 { root, dir, base, name, ext } |
//! | path.sep, path.delimiter | 同名 | 只读属性 |
//! | path.posix, path.win32 | 同名 | 子对象，相同方法 + 固定 sep/delimiter |
//! | path.toNamespacedPath | 同名 | Windows 长路径 `\\?\`；非 Windows 返回规范化路径 |
//! | url.pathToFileURL / url.fileURLToPath | filePathToUrl / urlToFilePath | 功能等价，命名不同 |
//! | path.root / path.name | 有 | Node 无此二者，为 Shu 特色便捷方法 |
//!
//! ## 与 Deno 兼容情况
//! - Deno 使用 `@std/path` 或 `Deno` 命名空间：basename、dirname、extname、join、normalize、resolve、relative、isAbsolute、fromFileUrl、toFileUrl、parse、format 等。
//! - Shu.path 的 join/resolve/dirname/basename/extname/normalize/isAbsolute/relative/parse/format 与 @std/path 对应方法语义一致。
//! - filePathToUrl ≈ toFileUrl，urlToFilePath ≈ fromFileUrl；sep、delimiter 与 std path 一致。
//! - root、name、toNamespacedPath 为 Shu 扩展；posix/win32 与 Node 对齐，Deno std 有 posix/win32 子模块可类比。
//!
//! ## 与 Bun 兼容情况
//! - Bun 兼容 Node path 模块：`import path from "node:path"` 或 `import * as path from "path"`。
//! - Shu.path 提供的 join、resolve、dirname、basename、extname、normalize、isAbsolute、relative、parse、format、sep、delimiter、posix、win32、toNamespacedPath 与 Node/Bun 一致或等价。
//! - filePathToUrl/urlToFilePath 对应 Node 的 url.pathToFileURL/url.fileURLToPath；root、name 为 Shu 额外便捷 API。
//!
//! ## 性能与约定
//! - §2.2 性能规则：os 相关用 comptime 常量（is_windows、path_sep、path_delimiter），避免热路径运行时分支。
//! - 所有方法均为纯字符串解析，不触发 I/O，无需 --allow-read/--allow-write。

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
    common.setMethod(ctx, path_obj, "parse", pathParseCallback);
    common.setMethod(ctx, path_obj, "format", pathFormatCallback);
    common.setMethod(ctx, path_obj, "root", pathRootCallback);
    common.setMethod(ctx, path_obj, "name", pathNameCallback);
    common.setMethod(ctx, path_obj, "toNamespacedPath", pathToNamespacedPathCallback);
    common.setMethod(ctx, path_obj, "filePathToUrl", pathFilePathToUrlCallback);
    common.setMethod(ctx, path_obj, "urlToFilePath", pathUrlToFilePathCallback);
    setStringProperty(ctx, path_obj, "sep", path_sep);
    setStringProperty(ctx, path_obj, "delimiter", path_delimiter);
    // Node 兼容：path.posix / path.win32 固定平台规则，sep 与 delimiter 固定
    const posix_obj = jsc.JSObjectMake(ctx, null, null);
    setPathPlatformProperty(ctx, posix_obj, "posix");
    attachPathMethodsToObject(ctx, posix_obj, "/", ":");
    const win32_obj = jsc.JSObjectMake(ctx, null, null);
    setPathPlatformProperty(ctx, win32_obj, "win32");
    attachPathMethodsToObject(ctx, win32_obj, "\\", ";");
    const k_posix = jsc.JSStringCreateWithUTF8CString("posix");
    defer jsc.JSStringRelease(k_posix);
    const k_win32 = jsc.JSStringCreateWithUTF8CString("win32");
    defer jsc.JSStringRelease(k_win32);
    _ = jsc.JSObjectSetProperty(ctx, path_obj, k_posix, posix_obj, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, path_obj, k_win32, win32_obj, jsc.kJSPropertyAttributeNone, null);
    return path_obj;
}

/// 在 obj 上设置 __pathPlatform 为 "posix" 或 "win32"，供回调通过 this 判断平台
fn setPathPlatformProperty(ctx: jsc.JSContextRef, obj: jsc.JSObjectRef, platform: [*:0]const u8) void {
    const k = jsc.JSStringCreateWithUTF8CString("__pathPlatform");
    defer jsc.JSStringRelease(k);
    const v = jsc.JSStringCreateWithUTF8CString(platform);
    defer jsc.JSStringRelease(v);
    _ = jsc.JSObjectSetProperty(ctx, obj, k, jsc.JSValueMakeString(ctx, v), jsc.kJSPropertyAttributeNone, null);
}

/// 向 target 挂载与 path_obj 相同的方法及 sep/delimiter，用于 posix/win32 子对象
fn attachPathMethodsToObject(ctx: jsc.JSContextRef, target: jsc.JSObjectRef, sep: [*:0]const u8, delimiter: [*:0]const u8) void {
    setStringProperty(ctx, target, "sep", sep);
    setStringProperty(ctx, target, "delimiter", delimiter);
    common.setMethod(ctx, target, "join", pathJoinCallback);
    common.setMethod(ctx, target, "resolve", pathResolveCallback);
    common.setMethod(ctx, target, "dirname", pathDirnameCallback);
    common.setMethod(ctx, target, "basename", pathBasenameCallback);
    common.setMethod(ctx, target, "extname", pathExtnameCallback);
    common.setMethod(ctx, target, "normalize", pathNormalizeCallback);
    common.setMethod(ctx, target, "isAbsolute", pathIsAbsoluteCallback);
    common.setMethod(ctx, target, "relative", pathRelativeCallback);
    common.setMethod(ctx, target, "parse", pathParseCallback);
    common.setMethod(ctx, target, "format", pathFormatCallback);
    common.setMethod(ctx, target, "root", pathRootCallback);
    common.setMethod(ctx, target, "name", pathNameCallback);
    common.setMethod(ctx, target, "toNamespacedPath", pathToNamespacedPathCallback);
    common.setMethod(ctx, target, "filePathToUrl", pathFilePathToUrlCallback);
    common.setMethod(ctx, target, "urlToFilePath", pathUrlToFilePathCallback);
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

// ---------- parse / format（Node path.parse / path.format 兼容）----------

/// 从绝对路径中解析出 root 部分（POSIX 为 "/"，Windows 为 "C:\\" 或 "\\\\server\\share"）；非绝对路径返回空切片；path 为传入路径，返回值为 path 的切片，不分配
fn pathRootSlice(path: []const u8) []const u8 {
    if (path.len == 0) return path;
    if (is_windows) {
        // Windows: "C:\" 或 "C:" 或 "\\server\share"
        if (path.len >= 2 and path[1] == ':') {
            if (path.len >= 3 and (path[2] == '/' or path[2] == '\\'))
                return path[0..3];
            return path[0..2];
        }
        if (path.len >= 2 and (path[0] == '/' or path[0] == '\\') and (path[1] == '/' or path[1] == '\\')) {
            var i: usize = 2;
            var count: u32 = 0;
            while (i < path.len) : (i += 1) {
                if (path[i] == '/' or path[i] == '\\') {
                    count += 1;
                    if (count == 2) return path[0..i];
                }
            }
            return path;
        }
        return path[0..0];
    }
    // POSIX
    if (path[0] == '/') return path[0..1];
    return path[0..0];
}

/// Shu.path.parse(path)：返回 { root, dir, base, name, ext }，与 Node path.parse 一致；需 -- 无，纯字符串解析
fn pathParseCallback(
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
    const root = pathRootSlice(path);
    const dir = std.fs.path.dirname(path) orelse ".";
    const base = std.fs.path.basename(path);
    const ext = std.fs.path.extension(path);
    const name = if (ext.len > 0 and base.len >= ext.len and std.mem.endsWith(u8, base, ext))
        base[0 .. base.len - ext.len]
    else
        base;
    const obj = jsc.JSObjectMake(ctx, null, null);
    const k_root = jsc.JSStringCreateWithUTF8CString("root");
    defer jsc.JSStringRelease(k_root);
    const k_dir = jsc.JSStringCreateWithUTF8CString("dir");
    defer jsc.JSStringRelease(k_dir);
    const k_base = jsc.JSStringCreateWithUTF8CString("base");
    defer jsc.JSStringRelease(k_base);
    const k_name = jsc.JSStringCreateWithUTF8CString("name");
    defer jsc.JSStringRelease(k_name);
    const k_ext = jsc.JSStringCreateWithUTF8CString("ext");
    defer jsc.JSStringRelease(k_ext);
    const root_z = allocator.dupeZ(u8, root) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(root_z);
    const dir_z = allocator.dupeZ(u8, dir) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(dir_z);
    const base_z = allocator.dupeZ(u8, base) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(base_z);
    const name_z = allocator.dupeZ(u8, name) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(name_z);
    const ext_z = allocator.dupeZ(u8, ext) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(ext_z);
    {
        const root_str = jsc.JSStringCreateWithUTF8CString(root_z.ptr);
        defer jsc.JSStringRelease(root_str);
        _ = jsc.JSObjectSetProperty(ctx, obj, k_root, jsc.JSValueMakeString(ctx, root_str), jsc.kJSPropertyAttributeNone, null);
    }
    {
        const dir_str = jsc.JSStringCreateWithUTF8CString(dir_z.ptr);
        defer jsc.JSStringRelease(dir_str);
        _ = jsc.JSObjectSetProperty(ctx, obj, k_dir, jsc.JSValueMakeString(ctx, dir_str), jsc.kJSPropertyAttributeNone, null);
    }
    {
        const base_str = jsc.JSStringCreateWithUTF8CString(base_z.ptr);
        defer jsc.JSStringRelease(base_str);
        _ = jsc.JSObjectSetProperty(ctx, obj, k_base, jsc.JSValueMakeString(ctx, base_str), jsc.kJSPropertyAttributeNone, null);
    }
    {
        const name_str = jsc.JSStringCreateWithUTF8CString(name_z.ptr);
        defer jsc.JSStringRelease(name_str);
        _ = jsc.JSObjectSetProperty(ctx, obj, k_name, jsc.JSValueMakeString(ctx, name_str), jsc.kJSPropertyAttributeNone, null);
    }
    {
        const ext_str = jsc.JSStringCreateWithUTF8CString(ext_z.ptr);
        defer jsc.JSStringRelease(ext_str);
        _ = jsc.JSObjectSetProperty(ctx, obj, k_ext, jsc.JSValueMakeString(ctx, ext_str), jsc.kJSPropertyAttributeNone, null);
    }
    return obj;
}

/// 从 JS 对象读取字符串属性；若不存在或非字符串则返回 null，否则返回 dupe 的切片（调用方 free）
fn getObjectStringProperty(allocator: std.mem.Allocator, ctx: jsc.JSContextRef, obj: jsc.JSObjectRef, key_name: [*:0]const u8) ?[]const u8 {
    const k = jsc.JSStringCreateWithUTF8CString(key_name);
    defer jsc.JSStringRelease(k);
    const val = jsc.JSObjectGetProperty(ctx, obj, k, null);
    if (jsc.JSValueIsUndefined(ctx, val) or jsc.JSValueIsNull(ctx, val)) return null;
    const str = jsc.JSValueToStringCopy(ctx, val, null);
    defer jsc.JSStringRelease(str);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(str);
    if (max_sz == 0 or max_sz > 65536) return null;
    const buf = allocator.alloc(u8, max_sz) catch return null;
    defer allocator.free(buf);
    const n = jsc.JSStringGetUTF8CString(str, buf.ptr, max_sz);
    if (n == 0) return null;
    return allocator.dupe(u8, buf[0 .. n - 1]) catch null;
}

/// Shu.path.format(pathObject)：从 { root, dir, base, name, ext } 组装路径，与 Node path.format 一致；若提供 dir+base 则 dir+sep+base，否则 root+name+ext（ext 无点时自动加点）
fn pathFormatCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const arg0 = arguments[0];
    const obj = jsc.JSValueToObject(ctx, arg0, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const dir = getObjectStringProperty(allocator, ctx, obj, "dir");
    defer if (dir) |d| allocator.free(d);
    const root = getObjectStringProperty(allocator, ctx, obj, "root");
    defer if (root) |r| allocator.free(r);
    const base = getObjectStringProperty(allocator, ctx, obj, "base");
    defer if (base) |b| allocator.free(b);
    const name = getObjectStringProperty(allocator, ctx, obj, "name");
    defer if (name) |n| allocator.free(n);
    const ext = getObjectStringProperty(allocator, ctx, obj, "ext");
    defer if (ext) |e| allocator.free(e);
    // Node 规则：若有 dir 且（有 base 或 有 name/ext），则优先 dir + sep + (base 或 name+ext)
    if (dir != null and (base != null or name != null or ext != null)) {
        const segment = if (base) |b| b else blk: {
            var list = std.ArrayList(u8).initCapacity(allocator, 0) catch return jsc.JSValueMakeUndefined(ctx);
            defer list.deinit(allocator);
            if (name) |n| list.appendSlice(allocator, n) catch return jsc.JSValueMakeUndefined(ctx);
            if (ext) |e| {
                if (e.len > 0 and e[0] == '.')
                    list.appendSlice(allocator, e) catch return jsc.JSValueMakeUndefined(ctx)
                else {
                    list.append(allocator, '.') catch return jsc.JSValueMakeUndefined(ctx);
                    list.appendSlice(allocator, e) catch return jsc.JSValueMakeUndefined(ctx);
                }
            }
            break :blk list.toOwnedSlice(allocator) catch return jsc.JSValueMakeUndefined(ctx);
        };
        defer if (base == null) allocator.free(segment);
        const d = dir.?;
        const out = std.fs.path.join(allocator, &.{ d, segment }) catch return jsc.JSValueMakeUndefined(ctx);
        defer allocator.free(out);
        return stringToJS(ctx, allocator, out);
    }
    // 否则用 root + base 或 root + name + ext
    const r = root orelse "";
    const segment = if (base) |b| b else blk: {
        var list = std.ArrayList(u8).initCapacity(allocator, 0) catch return jsc.JSValueMakeUndefined(ctx);
        defer list.deinit(allocator);
        if (name) |n| list.appendSlice(allocator, n) catch return jsc.JSValueMakeUndefined(ctx);
        if (ext) |e| {
            if (e.len > 0 and e[0] == '.')
                list.appendSlice(allocator, e) catch return jsc.JSValueMakeUndefined(ctx)
            else {
                list.append(allocator, '.') catch return jsc.JSValueMakeUndefined(ctx);
                list.appendSlice(allocator, e) catch return jsc.JSValueMakeUndefined(ctx);
            }
        }
        break :blk list.toOwnedSlice(allocator) catch return jsc.JSValueMakeUndefined(ctx);
    };
    defer if (base == null) allocator.free(segment);
    if (r.len == 0) return stringToJS(ctx, allocator, segment);
    const out = std.fs.path.join(allocator, &.{ r, segment }) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(out);
    return stringToJS(ctx, allocator, out);
}

// ---------- root / name / toNamespacedPath（Shu 特色与 Node 兼容）----------

/// Shu.path.root(path)：仅返回路径的根部分（如 "/"、"C:\\"），与 parse(path).root 一致；纯字符串解析
fn pathRootCallback(
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
    const root = pathRootSlice(path);
    return stringToJS(ctx, allocator, root);
}

/// Shu.path.name(path)：仅返回文件名无扩展名（即 parse(path).name）；纯字符串解析
fn pathNameCallback(
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
    const base = std.fs.path.basename(path);
    const ext = std.fs.path.extension(path);
    const name = if (ext.len > 0 and base.len >= ext.len and std.mem.endsWith(u8, base, ext))
        base[0 .. base.len - ext.len]
    else
        base;
    return stringToJS(ctx, allocator, name);
}

/// Shu.path.toNamespacedPath(path)：Windows 下转为长路径命名空间 "\\?\\..."，非 Windows 返回规范化路径；需先 resolve 为绝对路径
fn pathToNamespacedPathCallback(
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
    const resolved = std.fs.path.resolve(allocator, &.{ opts.cwd, path }) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    if (!is_windows) {
        return stringToJS(ctx, allocator, resolved);
    }
    // Windows：转为 \\?\ 前缀的长路径形式（UNC 为 \\?\UNC\server\share）
    if (resolved.len >= 2 and (resolved[0] == '/' or resolved[0] == '\\') and (resolved[1] == '/' or resolved[1] == '\\')) {
        const unc = std.mem.replaceOwned(u8, allocator, resolved, "/", "\\") catch return jsc.JSValueMakeUndefined(ctx);
        defer allocator.free(unc);
        const prefix = "\\\\?\\UNC";
        const result = allocator.alloc(u8, prefix.len + unc.len - 2) catch return jsc.JSValueMakeUndefined(ctx);
        defer allocator.free(result);
        @memcpy(result[0..prefix.len], prefix);
        @memcpy(result[prefix.len..], unc[2..]);
        return stringToJS(ctx, allocator, result);
    }
    const prefix = "\\\\?\\";
    const result = allocator.alloc(u8, prefix.len + resolved.len) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(result);
    @memcpy(result[0..prefix.len], prefix);
    const normalized = std.mem.replaceOwned(u8, allocator, resolved, "/", "\\") catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(normalized);
    @memcpy(result[prefix.len..], normalized);
    return stringToJS(ctx, allocator, result);
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
