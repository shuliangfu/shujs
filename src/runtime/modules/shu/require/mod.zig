// CJS 模块：require(id) / module / exports（与 ESM import/export 分开实现，各写各的）
// 入口与 require 进来的文件均以 (function(module, exports, require, __filename, __dirname) { ... }) 包装执行；
// 模块缓存：按「解析后的绝对路径 + 可选 ?query」为 key；带 ?query 的 id（如 "xxx.ts?v=time"）用路径读文件、用 path+query 做缓存键，实现按 query 不缓存/缓存隔离
// 仅支持相对路径（./ ../），node: 等后续扩展

const std = @import("std");
const jsc = @import("jsc");
const globals = @import("../../../globals.zig");
const errors = @import("../../../../errors.zig");
const node_builtin = @import("../../node/builtin.zig");
const shu_builtin = @import("../builtin.zig");
const pkg_resolver = @import("../../../../package/resolver.zig");

/// 单次 run 的模块缓存：resolved_path -> 已保护的 exports 值（避免 GC）；allocator 由 initCache(allocator) 调用方传入，put/clear 等由各回调的 globals.current_allocator 或参数提供（§1.1 不持全局 allocator）
var g_cache: ?*std.StringHashMap(CacheEntry) = null;

const CacheEntry = struct {
    exports: jsc.JSValueRef,
};

const k_parent_path = "__parentPath";

/// 以 CJS 模块方式执行入口源码：包装 (module, exports, require, __filename, __dirname)，注入 require 后执行
/// 执行前会初始化并清空模块缓存，执行后保留缓存供同次 run 内 require 复用
pub fn runAsModule(
    ctx: jsc.JSContextRef,
    allocator: std.mem.Allocator,
    entry_path: []const u8,
    source: []const u8,
) void {
    initCache(allocator);
    defer clearCache(allocator, ctx);
    const parent_dir = std.fs.path.dirname(entry_path) orelse ".";
    _ = runModuleWithSource(ctx, allocator, entry_path, parent_dir, source) catch {
        errors.reportToStderr(.{ .code = .unknown, .message = "runAsModule failed" }) catch {};
        return;
    };
}

fn initCache(allocator: std.mem.Allocator) void {
    if (g_cache == null) {
        const p = allocator.create(std.StringHashMap(CacheEntry)) catch return;
        p.* = std.StringHashMap(CacheEntry).init(allocator);
        g_cache = p;
    } else {
        clearCache(allocator, null);
    }
}

/// 清空模块缓存：对已保护的 exports 做 Unprotect，释放 key 字符串，再清空 map
fn clearCache(allocator: std.mem.Allocator, ctx: ?jsc.JSContextRef) void {
    const cache = g_cache orelse return;
    var keys = std.ArrayList([]const u8).initCapacity(allocator, 32) catch return;
    defer keys.deinit(allocator);
    var it = cache.iterator();
    while (it.next()) |entry| {
        keys.append(allocator, entry.key_ptr.*) catch {};
        if (ctx) |c| jsc.JSValueUnprotect(c, entry.value_ptr.exports);
    }
    for (keys.items) |k| {
        _ = cache.remove(k);
        allocator.free(k);
    }
}

/// 从 require 函数对象上读取 __parentPath 字符串，写入 buf，返回有效切片
fn getParentPathFromRequire(ctx: jsc.JSContextRef, require_fn: jsc.JSObjectRef, buf: []u8) ?[]const u8 {
    const k = jsc.JSStringCreateWithUTF8CString(k_parent_path);
    defer jsc.JSStringRelease(k);
    const val = jsc.JSObjectGetProperty(ctx, require_fn, k, null);
    if (jsc.JSValueIsUndefined(ctx, val)) return null;
    const str_ref = jsc.JSValueToStringCopy(ctx, val, null);
    const n = jsc.JSStringGetUTF8CString(str_ref, buf.ptr, buf.len);
    jsc.JSStringRelease(str_ref);
    if (n == 0) return null;
    return buf[0 .. n - 1];
}

/// require(id) 的 C 回调：从 callee 的 __parentPath 取父目录，解析 id，走缓存或 loadModule
fn requireCallback(
    ctx: jsc.JSContextRef,
    require_fn: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    var id_buf: [2048]u8 = undefined;
    const str_ref = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(str_ref);
    const id_n = jsc.JSStringGetUTF8CString(str_ref, &id_buf, id_buf.len);
    if (id_n == 0) return jsc.JSValueMakeUndefined(ctx);
    const id = id_buf[0 .. id_n - 1];
    // 使用运行时即需权限：require（含 node:/bun/deno 内置）统一要求 --allow-read
    if (!opts.permissions.allow_read) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "require() needs --allow-read" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    var parent_buf: [4096]u8 = undefined;
    const parent_dir = getParentPathFromRequire(ctx, require_fn, &parent_buf) orelse return jsc.JSValueMakeUndefined(ctx);
    // node:path / node:fs 等内置：直接返回内置 exports 并缓存，不读文件
    if (node_builtin.isSupportedNodeBuiltin(id)) {
        const cache_ptr = g_cache orelse return jsc.JSValueMakeUndefined(ctx);
        if (cache_ptr.get(id)) |entry| return entry.exports;
        const exports_val = node_builtin.getNodeBuiltin(ctx, allocator, id);
        if (jsc.JSValueIsUndefined(ctx, exports_val)) return exports_val;
        jsc.JSValueProtect(ctx, exports_val);
        cache_ptr.put(allocator.dupe(u8, id) catch return exports_val, .{ .exports = exports_val }) catch return exports_val;
        return exports_val;
    }
    // shu:fs / shu:path / shu:zlib 等内置：从 globalThis.Shu 取子对象并缓存
    if (shu_builtin.isSupportedShuBuiltin(id)) {
        const cache_ptr = g_cache orelse return jsc.JSValueMakeUndefined(ctx);
        if (cache_ptr.get(id)) |entry| return entry.exports;
        const exports_val = shu_builtin.getShuBuiltin(ctx, allocator, id);
        if (jsc.JSValueIsUndefined(ctx, exports_val)) return exports_val;
        jsc.JSValueProtect(ctx, exports_val);
        cache_ptr.put(allocator.dupe(u8, id) catch return exports_val, .{ .exports = exports_val }) catch return exports_val;
        return exports_val;
    }
    const result = resolveId(allocator, parent_dir, id) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(result.file_path);
    defer if (result.cache_key.ptr != result.file_path.ptr) allocator.free(result.cache_key);
    const cache_ptr = g_cache orelse return jsc.JSValueMakeUndefined(ctx);
    if (cache_ptr.get(result.cache_key)) |entry| return entry.exports;
    const child_dir = std.fs.path.dirname(result.file_path) orelse parent_dir;
    const content = readFileContent(allocator, result.file_path) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(content);
    const exports_val = runModuleWithSource(ctx, allocator, result.file_path, child_dir, content) catch return jsc.JSValueMakeUndefined(ctx);
    jsc.JSValueProtect(ctx, exports_val);
    cache_ptr.put(allocator.dupe(u8, result.cache_key) catch return exports_val, .{ .exports = exports_val }) catch return exports_val;
    return exports_val;
}

/// 将 id 拆成路径部分与 query（? 及之后）；读文件只用 path_part，缓存键用 path+query 以支持 ?v=time 不缓存
fn splitIdQuery(id: []const u8) struct { path_part: []const u8, query: []const u8 } {
    if (std.mem.indexOfScalar(u8, id, '?')) |q_pos| {
        return .{ .path_part = id[0..q_pos], .query = id[q_pos..] };
    }
    return .{ .path_part = id, .query = "" };
}

/// 解析结果：file_path 用于读文件与 __filename；cache_key 用于模块缓存（无 query 时与 file_path 相同，有 ?query 时为 path+query 实现缓存隔离）
const ResolveResult = struct { file_path: []const u8, cache_key: []const u8 };

/// require.resolve(request) 的回调：从 this（require 函数）取 __parentPath，解析 request，返回解析后的路径字符串；失败返回 undefined
fn requireResolveCallback(
    ctx: jsc.JSContextRef,
    require_fn: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    var parent_buf: [4096]u8 = undefined;
    const parent_dir = getParentPathFromRequire(ctx, require_fn, &parent_buf) orelse return jsc.JSValueMakeUndefined(ctx);
    var id_buf: [2048]u8 = undefined;
    const str_ref = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(str_ref);
    const id_n = jsc.JSStringGetUTF8CString(str_ref, &id_buf, id_buf.len);
    if (id_n == 0) return jsc.JSValueMakeUndefined(ctx);
    const id = id_buf[0 .. id_n - 1];
    const path_result = resolveRequest(allocator, parent_dir, id) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(path_result);
    const path_z = allocator.dupeZ(u8, path_result) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(path_z);
    const path_js = jsc.JSStringCreateWithUTF8CString(path_z.ptr);
    defer jsc.JSStringRelease(path_js);
    return jsc.JSValueMakeString(ctx, path_js);
}

/// 解析 request 得到绝对路径；node:/shu: 返回原 id；相对路径返回解析后的 file_path。调用方负责 free 返回值。
pub fn resolveRequest(allocator: std.mem.Allocator, parent_dir: []const u8, id: []const u8) ![]const u8 {
    if (node_builtin.isSupportedNodeBuiltin(id)) return allocator.dupe(u8, id);
    if (shu_builtin.isSupportedShuBuiltin(id)) return allocator.dupe(u8, id);
    const result = try resolveId(allocator, parent_dir, id);
    defer allocator.free(result.file_path);
    defer if (result.cache_key.ptr != result.file_path.ptr) allocator.free(result.cache_key);
    return allocator.dupe(u8, result.file_path);
}

/// 为 findPackageJSON 解析 specifier：相对 base_path 得到「起始路径」（文件或目录）。
/// 相对路径（./ ../）用 path.resolve；裸说明符（无 /、非 . 开头）按 Node 规则从 dirname(base_path) 向上查 node_modules/<specifier>。
/// 返回解析后的绝对路径（可能是文件或目录），调用方负责 free。内置协议（node:/shu:/deno:/bun:）及空串返回 null，不当作路径或 node_modules 解析。
pub fn resolveSpecifierForPackageJson(allocator: std.mem.Allocator, base_path: []const u8, specifier: []const u8) ?[]const u8 {
    if (specifier.len == 0) return null;
    if (std.mem.startsWith(u8, specifier, "node:")) return null;
    if (std.mem.startsWith(u8, specifier, "shu:")) return null;
    if (std.mem.startsWith(u8, specifier, "deno:")) return null;
    if (std.mem.startsWith(u8, specifier, "bun:")) return null;
    const parent_dir = std.fs.path.dirname(base_path) orelse ".";
    // 相对路径或绝对路径：path.resolve(parent_dir, specifier)
    if (specifier[0] == '.' or std.fs.path.isAbsolute(specifier)) {
        return std.fs.path.resolve(allocator, &.{ parent_dir, specifier }) catch return null;
    }
    // 裸说明符：从 parent_dir 向上查找 node_modules/<specifier> 目录
    var dir = allocator.dupe(u8, parent_dir) catch return null;
    defer allocator.free(dir);
    while (true) {
        const nm_path = std.fs.path.join(allocator, &.{ dir, "node_modules", specifier }) catch return null;
        defer allocator.free(nm_path);
        var dir_handle = std.fs.openDirAbsolute(dir, .{}) catch break;
        defer dir_handle.close();
        var nm_handle = dir_handle.openDir("node_modules", .{}) catch {
            const parent = std.fs.path.dirname(dir) orelse break;
            if (std.mem.eql(u8, parent, dir)) break;
            const new_dir = allocator.dupe(u8, parent) catch break;
            allocator.free(dir);
            dir = new_dir;
            continue;
        };
        defer nm_handle.close();
        var sub = nm_handle.openDir(specifier, .{}) catch {
            const parent = std.fs.path.dirname(dir) orelse break;
            if (std.mem.eql(u8, parent, dir)) break;
            const new_dir = allocator.dupe(u8, parent) catch break;
            allocator.free(dir);
            dir = new_dir;
            continue;
        };
        sub.close();
        return std.fs.path.resolve(allocator, &.{ nm_path }) catch return null;
    }
    return null;
}

/// 解析 require(id)：相对路径 ./ ../、裸说明符（node_modules + main/exports）、jsr:；id 可带 ?query；node:/shu: 在 requireCallback 中直接走内置，不进入 resolveId
fn resolveId(allocator: std.mem.Allocator, parent_dir: []const u8, id: []const u8) !ResolveResult {
    if (std.mem.startsWith(u8, id, "node:")) {
        errors.reportToStderr(.{ .code = .type_error, .message = "require(node:...) only supports registered node: builtins" }) catch {};
        return error.NotImplemented;
    }
    if (std.mem.startsWith(u8, id, "shu:")) {
        errors.reportToStderr(.{ .code = .type_error, .message = "require(shu:...) only supports registered shu: builtins (fs, path, zlib, crypto, assert, events, util, querystring, url, string_decoder)" }) catch {};
        return error.NotImplemented;
    }
    if (std.mem.startsWith(u8, id, ".")) {
        const split = splitIdQuery(id);
        const file_path = try std.fs.path.resolve(allocator, &.{ parent_dir, split.path_part });
        errdefer allocator.free(file_path);
        if (split.query.len == 0) {
            return .{ .file_path = file_path, .cache_key = file_path };
        }
        const cache_key = try std.mem.concat(allocator, u8, &.{ file_path, split.query });
        return .{ .file_path = file_path, .cache_key = cache_key };
    }
    const pkg_result = pkg_resolver.resolve(allocator, parent_dir, id, .require) catch |e| {
        if (e == error.ModuleNotFound) {
            var msg_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&msg_buf, "Cannot find module: {s}", .{id}) catch "Cannot find module";
            errors.reportToStderr(.{ .code = .file_not_found, .message = msg }) catch {};
        }
        return e;
    };
    return .{ .file_path = pkg_result.file_path, .cache_key = pkg_result.cache_key };
}

fn readFileContent(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch |e| {
        var msg_buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&msg_buf, "Cannot find module: {s}", .{path}) catch "Cannot find module";
        errors.reportToStderr(.{ .code = .file_not_found, .message = msg }) catch {};
        return e;
    };
    defer file.close();
    return file.readToEndAlloc(allocator, std.math.maxInt(usize));
}

/// 创建供模块使用的 require 函数，并设置 __parentPath = parent_dir；同时挂载 .resolve(request) 方法，与 node:module 兼容
pub fn makeRequire(ctx: jsc.JSContextRef, allocator: std.mem.Allocator, parent_dir: []const u8) jsc.JSObjectRef {
    const common_mod = @import("../../../common.zig");
    const name = jsc.JSStringCreateWithUTF8CString("require");
    defer jsc.JSStringRelease(name);
    const fn_ref = jsc.JSObjectMakeFunctionWithCallback(ctx, name, requireCallback);
    const path_z = allocator.dupeZ(u8, parent_dir) catch return fn_ref;
    defer allocator.free(path_z);
    const path_js = jsc.JSStringCreateWithUTF8CString(path_z.ptr);
    defer jsc.JSStringRelease(path_js);
    const k = jsc.JSStringCreateWithUTF8CString(k_parent_path);
    defer jsc.JSStringRelease(k);
    _ = jsc.JSObjectSetProperty(ctx, fn_ref, k, jsc.JSValueMakeString(ctx, path_js), jsc.kJSPropertyAttributeNone, null);
    common_mod.setMethod(ctx, fn_ref, "resolve", requireResolveCallback);
    return fn_ref;
}

/// 包装源码并执行，返回 module.exports（仅 CJS；ESM import/export 由单独模块实现）
fn runModuleWithSource(
    ctx: jsc.JSContextRef,
    allocator: std.mem.Allocator,
    module_id: []const u8,
    parent_dir: []const u8,
    source: []const u8,
) !jsc.JSValueRef {
    const module_obj = jsc.JSObjectMake(ctx, null, null);
    const exports_obj = jsc.JSObjectMake(ctx, null, null);
    const k_exports = jsc.JSStringCreateWithUTF8CString("exports");
    defer jsc.JSStringRelease(k_exports);
    const k_id = jsc.JSStringCreateWithUTF8CString("id");
    defer jsc.JSStringRelease(k_id);
    _ = jsc.JSObjectSetProperty(ctx, module_obj, k_exports, exports_obj, jsc.kJSPropertyAttributeNone, null);
    const id_z = allocator.dupeZ(u8, module_id) catch return error.OutOfMemory;
    defer allocator.free(id_z);
    const id_js = jsc.JSStringCreateWithUTF8CString(id_z.ptr);
    defer jsc.JSStringRelease(id_js);
    _ = jsc.JSObjectSetProperty(ctx, module_obj, k_id, jsc.JSValueMakeString(ctx, id_js), jsc.kJSPropertyAttributeNone, null);
    const req_fn = makeRequire(ctx, allocator, parent_dir);
    const dirname = std.fs.path.dirname(module_id) orelse ".";
    const dirname_z = allocator.dupeZ(u8, dirname) catch return error.OutOfMemory;
    defer allocator.free(dirname_z);
    const filename_z = allocator.dupeZ(u8, module_id) catch return error.OutOfMemory;
    defer allocator.free(filename_z);
    const filename_js = jsc.JSStringCreateWithUTF8CString(filename_z.ptr);
    defer jsc.JSStringRelease(filename_js);
    const dirname_js = jsc.JSStringCreateWithUTF8CString(dirname_z.ptr);
    defer jsc.JSStringRelease(dirname_js);
    var wrapper = std.ArrayList(u8).initCapacity(allocator, source.len + 256) catch return error.OutOfMemory;
    defer wrapper.deinit(allocator);
    wrapper.appendSlice(allocator, "(function(module, exports, require, __filename, __dirname) {\n") catch return error.OutOfMemory;
    wrapper.appendSlice(allocator, source) catch return error.OutOfMemory;
    wrapper.appendSlice(allocator, "\n})") catch return error.OutOfMemory;
    const script_z = allocator.dupeZ(u8, wrapper.items) catch return error.OutOfMemory;
    defer allocator.free(script_z);
    const script_ref = jsc.JSStringCreateWithUTF8CString(script_z.ptr);
    defer jsc.JSStringRelease(script_ref);
    const fn_val = jsc.JSEvaluateScript(ctx, script_ref, null, null, 1, null);
    const fn_obj = jsc.JSValueToObject(ctx, fn_val, null) orelse return error.ScriptError;
    var args = [_]jsc.JSValueRef{
        module_obj,
        exports_obj,
        req_fn,
        jsc.JSValueMakeString(ctx, filename_js),
        jsc.JSValueMakeString(ctx, dirname_js),
    };
    _ = jsc.JSObjectCallAsFunction(ctx, fn_obj, null, 5, &args, null);
    const exports_val = jsc.JSObjectGetProperty(ctx, module_obj, k_exports, null);
    return exports_val;
}
