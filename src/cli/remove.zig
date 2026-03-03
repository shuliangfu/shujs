// shu remove 子命令：从 dependencies/devDependencies 与 imports 移除指定包并写回 package.json，再执行 install
// 参考：PACKAGE_DESIGN.md、01-代码规则（面向用户输出为英文）
// JSR 包（jsr:@scope/name 或 @scope/name）可能写在 imports 中，需同时尝试 removePackageDependency 与 removePackageImport。

const std = @import("std");
const args = @import("args.zig");
const version = @import("version.zig");
const manifest = @import("../package/manifest.zig");
const pkg_install = @import("../package/install.zig");
const resolver = @import("../package/resolver.zig");

/// 执行 shu remove <包名>...：从 package.json(c) 的 dependencies、devDependencies 与 imports 中移除指定包并写回，然后执行 install 以同步 node_modules。
/// 包名可为 npm 名或 JSR 说明符（jsr:@scope/name 或 @scope/name）；JSR 会规范化为 @scope/name 后同时从 dependencies 与 imports 尝试移除。
pub fn remove(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = parsed;
    if (positional.len == 0) {
        try printToStdout("shu remove: no package name given. Usage: shu remove <name> [name...]  e.g. shu remove <name>  shu remove jsr:@scope/name\n", .{});
        return;
    }
    try version.printCommandHeader("remove");
    var cwd_buf: [1024]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch return error.CwdFailed;
    const cwd_owned = allocator.dupe(u8, cwd) catch return error.OutOfMemory;
    defer allocator.free(cwd_owned);

    for (positional) |name| {
        // JSR 说明符（jsr:@scope/name 或带版本）规范化为 @scope/name，与 add 时写入的 key 一致；npm 包名原样使用
        const key_to_remove = if (std.mem.startsWith(u8, name, "jsr:"))
            resolver.jsrSpecToScopeName(allocator, name) catch name
        else
            name;
        defer if (key_to_remove.ptr != name.ptr) allocator.free(key_to_remove);
        const removed_dep = manifest.removePackageDependency(allocator, cwd_owned, key_to_remove) catch |e| {
            if (e == error.ManifestNotFound) {
                try printToStdout("shu remove: no manifest (package.json or deno.json) in current directory\n", .{});
                return e;
            }
            if (e == error.InvalidPackageJson) {
                try printToStdout("shu remove: invalid package.json\n", .{});
                return e;
            }
            return e;
        };
        const removed_import = manifest.removePackageImport(allocator, cwd_owned, key_to_remove) catch |e| blk: {
            if (e == error.InvalidPackageJson) {
                try printToStdout("shu remove: invalid package.json\n", .{});
                return e;
            }
            break :blk false; // ManifestNotFound 等：静默，未从 imports 移除
        };
        if (removed_dep or removed_import) {
            try printToStdout("Removed {s}\n", .{name});
        }
    }

    pkg_install.install(allocator, cwd_owned, null, null, null) catch |e| {
        if (e == error.NoManifest) {}
        return e;
    };
    try printToStdout("\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [256]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
