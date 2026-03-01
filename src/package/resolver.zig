// 裸说明符解析：import map → node_modules → main/exports
// 参考：docs/PACKAGE_DESIGN.md §2、§4
// 与 require/mod.zig、esm_loader 对接，返回绝对路径供加载
// TODO: migrate to io_core (rule §3.0); current dir/file existence checks via std.fs (openDirAbsolute, openFile)

const std = @import("std");
const manifest = @import("manifest.zig");
const export_map = @import("export_map.zig");
const cache = @import("cache.zig");

// 协议前缀常量，便于编译器优化与统一维护（§2.1）
const prefix_https = "https://";
const prefix_http = "http://";
const prefix_jsr = "jsr:";

/// 解析结果：file_path 为可读文件的绝对路径，cache_key 用于模块缓存（可与 file_path 相同或带 query）
pub const ResolveResult = struct {
    file_path: []const u8,
    cache_key: []const u8,
};

/// 解析条件：require 用于 CJS，import 用于 ESM
pub const Condition = export_map.Condition;

/// 从 start_dir 向上查找包含 package.json / package.jsonc 或 deno.json 的目录，返回其绝对路径；未找到返回 null。调用方负责 free。
fn findProjectRoot(allocator: std.mem.Allocator, start_dir: []const u8) ?[]const u8 {
    var dir = allocator.dupe(u8, start_dir) catch return null;
    defer allocator.free(dir);
    while (true) {
        var d = std.fs.openDirAbsolute(dir, .{}) catch break;
        defer d.close();
        if (d.openFile("package.json", .{}) catch null) |file| {
            file.close();
            return allocator.dupe(u8, dir) catch null;
        }
        if (d.openFile("package.jsonc", .{}) catch null) |file| {
            file.close();
            return allocator.dupe(u8, dir) catch null;
        }
        if (d.openFile("deno.json", .{}) catch null) |file| {
            file.close();
            return allocator.dupe(u8, dir) catch null;
        }
        if (d.openFile("deno.jsonc", .{}) catch null) |file| {
            file.close();
            return allocator.dupe(u8, dir) catch null;
        }
        const parent = std.fs.path.dirname(dir) orelse break;
        if (std.mem.eql(u8, parent, dir)) break;
        const new_dir = allocator.dupe(u8, parent) catch break;
        allocator.free(dir);
        dir = new_dir;
    }
    return null;
}

/// 沿 parent_dir 向上查找 node_modules/<specifier> 目录，返回包目录绝对路径；未找到返回 null。调用方负责 free。
fn findNodeModulesPackage(allocator: std.mem.Allocator, parent_dir: []const u8, specifier: []const u8) ?[]const u8 {
    if (specifier.len == 0) return null;
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

/// jsr:@scope/name 转为 npm 兼容名 @jsr/scope__name；供 install 与 resolver 使用，返回的切片由调用方 free。
pub fn jsrToNpmSpecifier(allocator: std.mem.Allocator, jsr_spec: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, jsr_spec, prefix_jsr)) return error.InvalidJsrSpecifier;
    const rest = jsr_spec[prefix_jsr.len..];
    if (rest.len == 0) return error.InvalidJsrSpecifier;
    if (rest[0] != '@') return error.InvalidJsrSpecifier;
    var out = std.ArrayList(u8).initCapacity(allocator, rest.len + 8) catch return error.OutOfMemory;
    try out.appendSlice(allocator, "@jsr/");
    for (rest["@".len..]) |c| {
        if (c == '/') try out.appendSlice(allocator, "__") else try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

/// 在包目录 pkg_dir 内根据 main/exports 与 subpath 解析出入口文件绝对路径。allocator 用于路径拼接与可能的 export 模式展开；返回路径调用方负责 free（或来自 arena）。
fn resolvePackageEntry(
    allocator: std.mem.Allocator,
    pkg_dir: []const u8,
    subpath: []const u8,
    condition: Condition,
) ![]const u8 {
    var loaded = manifest.Manifest.loadPackageOnly(allocator, pkg_dir) catch return error.ManifestNotFound;
    defer loaded.arena.deinit();
    const m = &loaded.manifest;

    if (m.exports_value) |exp| {
        const entry_rel = try export_map.resolve(allocator, exp, subpath, condition);
        if (entry_rel) |res| {
            defer if (res.caller_owns) allocator.free(res.path);
            return std.fs.path.join(allocator, &.{ pkg_dir, res.path });
        }
    }
    if (subpath.len > 0) return error.PackagePathNotExported;
    if (m.main) |main_val| return std.fs.path.join(allocator, &.{ pkg_dir, main_val });
    return std.fs.path.join(allocator, &.{ pkg_dir, "index.js" });
}

/// 解析说明符为绝对文件路径。顺序：协议/内置不处理；import map；相对/绝对路径；https:（仅支持，从缓存解析）；jsr:；裸说明符 node_modules + main/exports。http:// 不支持。
/// project_root 可选，为 null 时从 parent_dir 向上查找。返回的 ResolveResult 中 file_path、cache_key 由 allocator 分配，调用方负责 free。
pub fn resolve(
    allocator: std.mem.Allocator,
    parent_dir: []const u8,
    specifier: []const u8,
    condition: Condition,
) !ResolveResult {
    const path_part = if (std.mem.indexOfScalar(u8, specifier, '?')) |q_pos| specifier[0..q_pos] else specifier;
    const query = if (std.mem.indexOfScalar(u8, specifier, '?')) |q_pos| specifier[q_pos..] else "";

    const project_root = findProjectRoot(allocator, parent_dir);
    defer if (project_root) |r| allocator.free(r);

    if (project_root) |root| {
        const proj = manifest.Manifest.load(allocator, root) catch null;
        if (proj) |p| {
            defer p.arena.deinit();
            if (p.manifest.imports.get(path_part)) |mapped| {
                const sub = try resolve(allocator, parent_dir, mapped, condition);
                errdefer allocator.free(sub.file_path);
                errdefer if (sub.cache_key.ptr != sub.file_path.ptr) allocator.free(sub.cache_key);
                return sub;
            }
        }
    }

    if (path_part.len >= 1 and (path_part[0] == '.' or std.fs.path.isAbsolute(path_part))) {
        const file_path = try std.fs.path.resolve(allocator, &.{ parent_dir, path_part });
        errdefer allocator.free(file_path);
        const cache_key = if (query.len == 0) file_path else try std.mem.concat(allocator, u8, &.{ file_path, query });
        return .{ .file_path = file_path, .cache_key = cache_key };
    }

    if (std.mem.startsWith(u8, path_part, prefix_https)) {
        const cache_root = cache.getCacheRoot(allocator) catch return error.ModuleNotFound;
        defer allocator.free(cache_root);
        const file_path = cache.getCachedUrlPath(allocator, cache_root, path_part) orelse return error.HttpsUrlNotCached;
        errdefer allocator.free(file_path);
        const cache_key = if (query.len == 0) file_path else try std.mem.concat(allocator, u8, &.{ file_path, query });
        return .{ .file_path = file_path, .cache_key = cache_key };
    }
    if (std.mem.startsWith(u8, path_part, prefix_http)) return error.HttpNotSupported;

    if (std.mem.startsWith(u8, path_part, prefix_jsr)) {
        const npm_spec = jsrToNpmSpecifier(allocator, path_part) catch return error.InvalidJsrSpecifier;
        defer allocator.free(npm_spec);
        const pkg_dir = findNodeModulesPackage(allocator, parent_dir, npm_spec) orelse return error.ModuleNotFound;
        defer allocator.free(pkg_dir);
        const file_path = try resolvePackageEntry(allocator, pkg_dir, "", condition);
        errdefer allocator.free(file_path);
        const cache_key = if (query.len == 0) file_path else try std.mem.concat(allocator, u8, &.{ file_path, query });
        return .{ .file_path = file_path, .cache_key = cache_key };
    }

    const pkg_name: []const u8 = blk: {
        if (path_part.len > 0 and path_part[0] == '@') {
            if (std.mem.indexOfScalar(u8, path_part[1..], '/')) |i| {
                break :blk path_part[0 .. 1 + i];
            }
            break :blk path_part;
        }
        if (std.mem.indexOfScalar(u8, path_part, '/')) |i| {
            break :blk path_part[0..i];
        }
        break :blk path_part;
    };
    const subpath: []const u8 = if (path_part.len > pkg_name.len and path_part[pkg_name.len] == '/')
        path_part[pkg_name.len + 1 ..]
    else
        "";
    const pkg_dir = findNodeModulesPackage(allocator, parent_dir, pkg_name) orelse return error.ModuleNotFound;
    defer allocator.free(pkg_dir);
    const file_path = try resolvePackageEntry(allocator, pkg_dir, subpath, condition);
    errdefer allocator.free(file_path);
    const cache_key = if (query.len == 0) file_path else try std.mem.concat(allocator, u8, &.{ file_path, query });
    return .{ .file_path = file_path, .cache_key = cache_key };
}
