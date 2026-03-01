// shu install 子命令：安装依赖到 node_modules
// 参考：docs/PACKAGE_DESIGN.md
// 约定：shu install（无参数）按 package.json 安装；shu install <specifier> 写回 manifest 并安装

const std = @import("std");
const args = @import("args.zig");
const pkg_install = @import("../package/install.zig");
const manifest = @import("../package/manifest.zig");
const registry = @import("../package/registry.zig");
const resolver = @import("../package/resolver.zig");
const cache = @import("../package/cache.zig");

const REGISTRY_BASE = "https://registry.npmjs.org";

/// 将若干说明符（npm、jsr: 或 https:）写入 manifest 并执行 install；供 shu install <specifier> 与 shu add <specifier> 共用。仅支持 https://，不支持 http://。
pub fn addSpecifiersThenInstall(allocator: std.mem.Allocator, cwd_owned: []const u8, positional: []const []const u8, msg_prefix: []const u8) !void {
    for (positional) |spec| {
        if (std.mem.startsWith(u8, spec, "http://")) {
            try printToStdout("{s}: 不支持 http://，仅支持 https:// {s}\n", .{ msg_prefix, spec });
            continue;
        }
        if (std.mem.startsWith(u8, spec, "https://")) {
            const cache_root = cache.getCacheRoot(allocator) catch {
                try printToStdout("{s}: 无法获取缓存目录\n", .{msg_prefix});
                continue;
            };
            defer allocator.free(cache_root);
            const cache_path = cache.urlCachePath(allocator, cache_root, spec) catch continue;
            defer allocator.free(cache_path);
            var cache_dir = std.fs.openDirAbsolute(cache_root, .{}) catch blk: {
                std.fs.cwd().makePath(cache_root) catch {};
                break :blk std.fs.openDirAbsolute(cache_root, .{}) catch continue;
            };
            defer cache_dir.close();
            cache_dir.makePath("url") catch {};
            registry.downloadUrlToPath(allocator, spec, cache_path) catch |e| {
                if (e == error.HttpNotSupported) {}
                try printToStdout("{s}: 下载失败 {s}\n", .{ msg_prefix, spec });
                continue;
            };
            manifest.addDenoImport(allocator, cwd_owned, spec, spec) catch {};
            continue;
        }
        if (std.mem.startsWith(u8, spec, "jsr:")) {
            const npm_name = resolver.jsrToNpmSpecifier(allocator, spec) catch {
                try printToStdout("{s}: 无效的 jsr 说明符 {s}\n", .{ msg_prefix, spec });
                continue;
            };
            defer allocator.free(npm_name);
            const res = registry.resolveVersionAndTarball(allocator, REGISTRY_BASE, npm_name, "latest") catch {
                try printToStdout("{s}: 无法解析 JSR 包版本 {s}\n", .{ msg_prefix, spec });
                continue;
            };
            defer allocator.free(res.version);
            defer allocator.free(res.tarball_url);
            const version_range = try std.fmt.allocPrint(allocator, "^{s}", .{res.version});
            defer allocator.free(version_range);
            manifest.addPackageDependency(allocator, cwd_owned, npm_name, version_range) catch |e| {
                if (e == error.ManifestNotFound) {
                    try printToStdout("{s}: 未找到 package.json，无法添加依赖\n", .{msg_prefix});
                }
                continue;
            };
            const jsr_alias = spec["jsr:".len..];
            const import_value = try std.fmt.allocPrint(allocator, "jsr:{s}@{s}", .{ jsr_alias, res.version });
            defer allocator.free(import_value);
            manifest.addDenoImport(allocator, cwd_owned, jsr_alias, import_value) catch {};
        } else {
            var name = spec;
            var version_spec: []const u8 = "latest";
            var last_at: ?usize = null;
            for (spec, 0..) |c, i| {
                if (c == '@') last_at = i;
            }
            if (last_at) |at| {
                if (at > 0) {
                    name = spec[0..at];
                    version_spec = spec[at + 1 ..];
                }
            }
            manifest.addPackageDependency(allocator, cwd_owned, name, version_spec) catch |e| {
                if (e == error.ManifestNotFound) {
                    try printToStdout("{s}: 未找到 package.json，无法添加依赖\n", .{msg_prefix});
                }
                continue;
            };
        }
    }
    pkg_install.install(allocator, cwd_owned) catch |e| {
        if (e == error.NoManifest) {}
        return e;
    };
}

/// 执行 shu install [specifier...]
/// - 无参数：按当前目录 package.json（及 shu.lock）安装依赖到 node_modules，未命中缓存则从 registry 下载并写回 lock
/// - 有参数：将每个说明符（npm 包名或 jsr:@scope/name）写入 manifest 后执行一次 install
pub fn install(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = parsed;
    var cwd_buf: [1024]u8 = undefined;
    const cwd = std.fs.realpath(".", &cwd_buf) catch {
        try printToStdout("shu install: 无法获取当前目录\n", .{});
        return;
    };
    const cwd_owned = allocator.dupe(u8, cwd) catch return;
    defer allocator.free(cwd_owned);
    if (positional.len == 0) {
        pkg_install.install(allocator, cwd_owned) catch |e| {
            if (e == error.NoManifest) {
                try printToStdout("shu install: 未找到 package.json 或 package.jsonc\n", .{});
                return;
            }
            return e;
        };
        try printToStdout("shu install: 完成\n", .{});
        return;
    }
    try addSpecifiersThenInstall(allocator, cwd_owned, positional, "shu install");
    try printToStdout("shu install: 完成\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
