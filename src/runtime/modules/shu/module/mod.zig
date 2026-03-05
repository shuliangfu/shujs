// shu:module — 对应 node:module，供 ESM 中 createRequire(import.meta.url) 或 CJS 中 require('shu:module').createRequire(__filename) 使用
// 所有权：createRequire、findPackageJSON、isBuiltin、stripTypeScriptTypes 等返回值为 JSC 持有或栈/调用方缓冲；路径解析内部 [Allocates] 由本模块在回调内 free。
//
// ========== 已实现 / 与 node:module 兼容的 API ==========
//
//   - builtinModules     string[]，当前支持的所有 shu: / node: 内置模块名列表
//   - createRequire(filenameOrUrl)  入参为路径字符串、file:// URL 字符串或 URL 对象（读 .href/.pathname），返回带 .resolve 的 require 函数
//   - isBuiltin(moduleName)  判断 moduleName 是否为已支持的 node:xxx 或 shu:xxx
//   - findPackageJSON(specifier, base?)  按 specifier 相对 base 解析（相对路径或 node_modules 裸说明符）后，从解析结果向上查找 package.json，与 Node 兼容
//   - stripTypeScriptTypes(code[, options])  擦除 TS 类型注解返回纯 JS；options.sourceUrl 可选，追加 //# sourceURL
//
// createRequire 返回的 require 支持：
//   - require(id)  加载模块（相对路径、shu:、node: 内置）
//   - require.resolve(request)  仅解析路径并返回字符串，不加载
//
// ========== 未实现 / 限制 ==========
//
//   - Module 类、Module._load、Module._cache 等内部 API 未提供
//   - register、syncBuiltinESMExports、enableCompileCache 等未实现

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");
const libs_process = @import("libs_process");
const shu_builtin = @import("../builtin.zig");
const node_builtin = @import("../../node/builtin.zig");
const require_mod = @import("../require/mod.zig");
const strip_types = @import("../../../../transpiler/strip_types.zig");
const libs_io = @import("libs_io");
const errors = @import("errors");

/// 从 filename 或 file: URL 字符串中取出文件路径（去掉 file:// 前缀）
fn pathFromFilenameOrUrl(s: []const u8) []const u8 {
    if (std.mem.startsWith(u8, s, "file://")) return s["file://".len..];
    return s;
}

/// 从 JS 值取路径字符串：若为对象则读 .href 或 .pathname，否则 toString
fn getPathStringFromValue(ctx: jsc.JSContextRef, val: jsc.JSValueRef, buf: []u8) ?[]const u8 {
    if (jsc.JSValueToObject(ctx, val, null)) |obj| {
        const k_href = jsc.JSStringCreateWithUTF8CString("href");
        defer jsc.JSStringRelease(k_href);
        var href_val = jsc.JSObjectGetProperty(ctx, obj, k_href, null);
        if (jsc.JSValueIsUndefined(ctx, href_val)) {
            const k_pathname = jsc.JSStringCreateWithUTF8CString("pathname");
            defer jsc.JSStringRelease(k_pathname);
            href_val = jsc.JSObjectGetProperty(ctx, obj, k_pathname, null);
        }
        if (jsc.JSValueIsUndefined(ctx, href_val)) return null;
        const str_ref = jsc.JSValueToStringCopy(ctx, href_val, null);
        defer jsc.JSStringRelease(str_ref);
        const n = jsc.JSStringGetUTF8CString(str_ref, buf.ptr, buf.len);
        if (n == 0) return null;
        return buf[0 .. n - 1];
    }
    const str_ref = jsc.JSValueToStringCopy(ctx, val, null);
    defer jsc.JSStringRelease(str_ref);
    const n = jsc.JSStringGetUTF8CString(str_ref, buf.ptr, buf.len);
    if (n == 0) return null;
    return buf[0 .. n - 1];
}

/// 两切片相等：先比长度，≤8 字节用单次 u64 比较（00 §2.1），否则 std.mem.eql；用于 parent/dir 路径段比较
fn sliceEqlShort(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    if (a.len <= 8) {
        var x: [8]u8 = [_]u8{0} ** 8;
        var y: [8]u8 = [_]u8{0} ** 8;
        @memcpy(x[0..a.len], a);
        @memcpy(y[0..b.len], b);
        return @as(u64, @bitCast(x)) == @as(u64, @bitCast(y));
    }
    return std.mem.eql(u8, a, b);
}

/// createRequire(filenameOrUrl)：入参可为路径字符串、file:// 字符串或 URL 对象（.href/.pathname），返回 require 函数
fn createRequireCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const allocator = g_module_allocator orelse globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    var path_buf: [4096]u8 = undefined;
    const path_slice = getPathStringFromValue(ctx, arguments[0], &path_buf) orelse return jsc.JSValueMakeUndefined(ctx);
    const path = pathFromFilenameOrUrl(path_slice);
    const parent_dir = std.fs.path.dirname(path) orelse ".";
    return require_mod.makeRequire(ctx, allocator, parent_dir);
}

/// findPackageJSON(specifier, base?)：与 Node 兼容。先按 specifier 相对 base 解析（相对路径或 node_modules 裸说明符），再从解析结果所在目录向上查找 package.json，返回其绝对路径；未找到返回 undefined。base 可为路径或 file:// 或 URL 对象。
fn findPackageJSONCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const allocator = g_module_allocator orelse globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    var path_buf: [4096]u8 = undefined;
    var spec_buf: [2048]u8 = undefined;
    const spec_ref = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(spec_ref);
    const spec_n = jsc.JSStringGetUTF8CString(spec_ref, &spec_buf, spec_buf.len);
    if (spec_n == 0) return jsc.JSValueMakeUndefined(ctx);
    const specifier = spec_buf[0 .. spec_n - 1];
    const base_val = if (argumentCount >= 2) arguments[1] else arguments[0];
    const path_slice = getPathStringFromValue(ctx, base_val, &path_buf) orelse return jsc.JSValueMakeUndefined(ctx);
    const base_path = pathFromFilenameOrUrl(path_slice);
    // 用 specifier 解析得到起始路径（相对路径或 node_modules 裸说明符）；未解析到时从 base 所在目录开始
    const io = libs_process.getProcessIo() orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = require_mod.resolveSpecifierForPackageJson(allocator, base_path, specifier);
    const start_dir = if (resolved) |path| blk: {
        defer allocator.free(path);
        var d = libs_io.openDirAbsolute(path, .{}) catch {
            const f = libs_io.openFileAbsolute(path, .{}) catch break :blk allocator.dupe(u8, std.fs.path.dirname(base_path) orelse ".") catch return jsc.JSValueMakeUndefined(ctx);
            f.close(io);
            break :blk allocator.dupe(u8, std.fs.path.dirname(path) orelse ".") catch return jsc.JSValueMakeUndefined(ctx);
        };
        d.close(io);
        break :blk allocator.dupe(u8, path) catch return jsc.JSValueMakeUndefined(ctx);
    } else allocator.dupe(u8, std.fs.path.dirname(base_path) orelse ".") catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(start_dir);
    var dir = start_dir;
    while (true) {
        const pkg_path = std.fs.path.join(allocator, &.{ dir, "package.json" }) catch return jsc.JSValueMakeUndefined(ctx);
        defer allocator.free(pkg_path);
        const file = libs_io.openFileAbsolute(pkg_path, .{}) catch {
            const parent = std.fs.path.dirname(dir) orelse break;
            if (sliceEqlShort(parent, dir)) break;
            const new_dir = allocator.dupe(u8, parent) catch break;
            if (dir.ptr != start_dir.ptr) allocator.free(dir);
            dir = new_dir;
            continue;
        };
        file.close(io);
        const pkg_z = allocator.dupeZ(u8, pkg_path) catch return jsc.JSValueMakeUndefined(ctx);
        defer allocator.free(pkg_z);
        const js_str = jsc.JSStringCreateWithUTF8CString(pkg_z.ptr);
        defer jsc.JSStringRelease(js_str);
        return jsc.JSValueMakeString(ctx, js_str);
    }
    if (dir.ptr != start_dir.ptr) allocator.free(dir);
    return jsc.JSValueMakeUndefined(ctx);
}

/// 单次 stripTypeScriptTypes 允许的最大代码长度（避免栈上 256KB）；改为堆分配
const MODULE_CODE_BUF_MAX = 256 * 1024;

/// stripTypeScriptTypes(code[, options])：擦除 TS 类型注解返回纯 JS；options.sourceUrl 可选，会追加 //# sourceURL=...
fn stripTypeScriptTypesCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const allocator = g_module_allocator orelse globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    // 大 buffer 堆分配，避免栈上 256KB 爆栈（规范 §1.2）
    const code_buf = allocator.alloc(u8, MODULE_CODE_BUF_MAX) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(code_buf);
    const str_ref = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(str_ref);
    const n = jsc.JSStringGetUTF8CString(str_ref, code_buf.ptr, code_buf.len);
    if (n == 0) return jsc.JSValueMakeUndefined(ctx);
    const code = code_buf[0 .. n - 1];
    const stripped = strip_types.strip(allocator, code) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(stripped);
    if (argumentCount >= 2) {
        const opts = jsc.JSValueToObject(ctx, arguments[1], null);
        if (opts) |o| {
            const k = jsc.JSStringCreateWithUTF8CString("sourceUrl");
            defer jsc.JSStringRelease(k);
            const url_val = jsc.JSObjectGetProperty(ctx, o, k, null);
            if (!jsc.JSValueIsUndefined(ctx, url_val)) {
                var url_buf: [512]u8 = undefined;
                const url_ref = jsc.JSValueToStringCopy(ctx, url_val, null);
                defer jsc.JSStringRelease(url_ref);
                const url_n = jsc.JSStringGetUTF8CString(url_ref, &url_buf, url_buf.len);
                if (url_n > 0) {
                    const suffix = std.fmt.allocPrint(allocator, "\n//# sourceURL={s}", .{url_buf[0 .. url_n - 1]}) catch return jsc.JSValueMakeUndefined(ctx);
                    defer allocator.free(suffix);
                    const with_url = std.mem.concat(allocator, u8, &.{ stripped, suffix }) catch return jsc.JSValueMakeUndefined(ctx);
                    defer allocator.free(with_url);
                    const z = allocator.dupeZ(u8, with_url) catch return jsc.JSValueMakeUndefined(ctx);
                    defer allocator.free(z);
                    const js_str = jsc.JSStringCreateWithUTF8CString(z.ptr);
                    defer jsc.JSStringRelease(js_str);
                    return jsc.JSValueMakeString(ctx, js_str);
                }
            }
        }
    }
    const z = allocator.dupeZ(u8, stripped) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(z);
    const js_str = jsc.JSStringCreateWithUTF8CString(z.ptr);
    defer jsc.JSStringRelease(js_str);
    return jsc.JSValueMakeString(ctx, js_str);
}

/// isBuiltin(moduleName)：判断是否为内置模块（node:xxx 或 shu:xxx）
fn isBuiltinCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeBoolean(ctx, false);
    var name_buf: [256]u8 = undefined;
    const str_ref = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(str_ref);
    const n = jsc.JSStringGetUTF8CString(str_ref, &name_buf, name_buf.len);
    if (n == 0) return jsc.JSValueMakeBoolean(ctx, false);
    const name = name_buf[0 .. n - 1];
    const ok = node_builtin.isSupportedNodeBuiltin(name) or shu_builtin.isSupportedShuBuiltin(name);
    return jsc.JSValueMakeBoolean(ctx, ok);
}

/// §1.1 显式 allocator 收敛：getExports 时注入，回调内优先使用
threadlocal var g_module_allocator: ?std.mem.Allocator = null;

/// 返回 require('shu:module') 的 exports：builtinModules、createRequire、isBuiltin、findPackageJSON、stripTypeScriptTypes
pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    g_module_allocator = allocator;
    const exports = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, exports, "createRequire", createRequireCallback);
    common.setMethod(ctx, exports, "isBuiltin", isBuiltinCallback);
    common.setMethod(ctx, exports, "findPackageJSON", findPackageJSONCallback);
    common.setMethod(ctx, exports, "stripTypeScriptTypes", stripTypeScriptTypesCallback);

    const total = shu_builtin.SUPPORTED.len + node_builtin.NODE_BUILTIN_NAMES.len;
    var arr = allocator.alloc(jsc.JSValueRef, total) catch return exports;
    defer allocator.free(arr);
    var i: usize = 0;
    for (shu_builtin.SUPPORTED) |s| {
        const z = allocator.dupeZ(u8, s) catch continue;
        const js_str = jsc.JSStringCreateWithUTF8CString(z.ptr);
        arr[i] = jsc.JSValueMakeString(ctx, js_str);
        jsc.JSStringRelease(js_str);
        allocator.free(z);
        i += 1;
    }
    for (node_builtin.NODE_BUILTIN_NAMES) |s| {
        const z = allocator.dupeZ(u8, s) catch continue;
        const js_str = jsc.JSStringCreateWithUTF8CString(z.ptr);
        arr[i] = jsc.JSValueMakeString(ctx, js_str);
        jsc.JSStringRelease(js_str);
        allocator.free(z);
        i += 1;
    }
    const k_builtinModules = jsc.JSStringCreateWithUTF8CString("builtinModules");
    defer jsc.JSStringRelease(k_builtinModules);
    const arr_val = jsc.JSObjectMakeArray(ctx, i, arr.ptr, null);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_builtinModules, arr_val, jsc.kJSPropertyAttributeNone, null);
    return exports;
}
