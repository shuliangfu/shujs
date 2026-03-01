//! 项目内递归收集文件路径（cli/scan.zig）
//!
//! 职责
//!   - 从给定根目录递归遍历，收集扩展名匹配的文件相对路径，跳过 default_exclude_dirs（node_modules、.git、dist、build 等，与 deno/npm 惯例一致）。
//!   - 供 test、fmt、lint 的默认行为使用：test 扫描 tests/ 下 test/spec 文件，fmt/lint 扫描全项目对应扩展名。
//!
//! 主要 API
//!   - default_exclude_dirs：默认排除的目录名列表；isExcludedDir(name) 判断是否排除。
//!   - collectFilesRecursive(allocator, root_abs, extensions)：返回 ArrayList([]const u8)，每项为相对 root_abs 的路径，调用方负责 deinit 与 free 各 item。
//!   - test_extensions / fmt_extensions / lint_extensions：各子命令默认使用的扩展名列表。
//!
//! 约定
//!   - 目录遍历经 io_core（openDirAbsolute 等）；不分配多余内存，路径在递归中按需拼接。

const std = @import("std");
const io_core = @import("io_core");

/// 默认排除的目录名（lint/fmt 全项目扫描、test 在 tests/ 下扫描时均跳过这些目录）。
/// 与 deno/npm 惯例一致：依赖、构建产物、缓存、版本控制、覆盖率等。
pub const default_exclude_dirs = [_][]const u8{
    "node_modules",
    ".git",
    "dist",
    "build",
    "out",
    ".next",
    ".nuxt",
    "coverage",
    ".shu",
    ".cache",
    "vendor",
    ".turbo",
    ".vercel",
    ".netlify",
    ".deno",
};

/// 判断 name 是否为默认排除的目录名（大小写敏感，与 default_exclude_dirs 一致）。
pub fn isExcludedDir(name: []const u8) bool {
    for (default_exclude_dirs) |ex| {
        if (std.mem.eql(u8, name, ex)) return true;
    }
    return false;
}

/// 判断文件路径是否以任一给定后缀结尾（用于扩展名匹配）。
fn hasExtension(path: []const u8, extensions: []const []const u8) bool {
    for (extensions) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return true;
    }
    return false;
}

/// 递归收集 root_abs 目录下所有相对路径文件，扩展名在 extensions 中且不进入排除目录。
/// 返回的 ArrayList 中每项为相对 root_abs 的路径，由调用方 deinit(allocator) 并 free 各 item。
/// 使用 io_core 做目录打开与遍历（§3.0）。
fn collectFilesRecursiveImpl(
    allocator: std.mem.Allocator,
    root_abs: []const u8,
    dir_abs: []const u8,
    prefix: []const u8,
    extensions: []const []const u8,
    list: *std.ArrayList([]const u8),
) !void {
    var dir = io_core.openDirAbsolute(dir_abs, .{ .iterate = true }) catch return;
    defer dir.close();
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const name = entry.name;
        if (name.len == 0 or name[0] == '.') {
            // 跳过 "." ".." 及以 . 开头的隐藏目录（如 .git 已由 isExcludedDir 覆盖，此处可跳过 . 与 ..）
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        }
        const rel: []const u8 = if (prefix.len == 0)
            name
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name });
        defer if (prefix.len > 0) allocator.free(rel);

        switch (entry.kind) {
            .directory => {
                if (isExcludedDir(name)) continue;
                const sub_abs = try io_core.pathJoin(allocator, &.{ dir_abs, name });
                defer allocator.free(sub_abs);
                try collectFilesRecursiveImpl(allocator, root_abs, sub_abs, rel, extensions, list);
            },
            .file => {
                if (hasExtension(name, extensions)) {
                    const path_to_store = if (prefix.len == 0) try allocator.dupe(u8, name) else try allocator.dupe(u8, rel);
                    try list.append(allocator, path_to_store);
                }
            },
            else => {},
        }
    }
}

/// 从根目录 root_abs 递归收集所有扩展名在 extensions 中的文件相对路径。
/// 返回的 ArrayList 由调用方 deinit(allocator) 并 free 各 item。
pub fn collectFilesRecursive(
    allocator: std.mem.Allocator,
    root_abs: []const u8,
    extensions: []const []const u8,
) !std.ArrayList([]const u8) {
    var list = try std.ArrayList([]const u8).initCapacity(allocator, 64);
    try collectFilesRecursiveImpl(allocator, root_abs, root_abs, "", extensions, &list);
    return list;
}

/// 默认 test 使用的扩展名：*.test.ts, *.test.js, *.spec.ts, *.spec.js
pub const test_extensions = [_][]const u8{ ".test.ts", ".test.js", ".spec.ts", ".spec.js" };

/// 默认 fmt 使用的扩展名：.ts, .tsx, .js, .jsx, .mjs, .cjs
pub const fmt_extensions = [_][]const u8{ ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs" };

/// 默认 lint 使用的扩展名：与 fmt 一致
pub const lint_extensions = [_][]const u8{ ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs" };
