// shu remove 子命令：从 dependencies/devDependencies 移除指定包并写回 package.json，再执行 install
// 参考：PACKAGE_DESIGN.md、01-代码规则（面向用户输出为英文）

const std = @import("std");
const args = @import("args.zig");
const manifest = @import("../package/manifest.zig");
const pkg_install = @import("../package/install.zig");

/// 执行 shu remove <包名>...：从 package.json(c) 的 dependencies 与 devDependencies 中移除指定包并写回，然后执行 install 以同步 node_modules。
pub fn remove(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = parsed;
    if (positional.len == 0) {
        try printToStdout("shu remove: no package name given. Usage: shu remove <name> [name...]\n", .{});
        return;
    }
    var cwd_buf: [1024]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch return error.CwdFailed;
    const cwd_owned = allocator.dupe(u8, cwd) catch return error.OutOfMemory;
    defer allocator.free(cwd_owned);

    for (positional) |name| {
        manifest.removePackageDependency(allocator, cwd_owned, name) catch |e| {
            if (e == error.ManifestNotFound) {
                try printToStdout("shu remove: no package.json or package.jsonc in current directory\n", .{});
                return e;
            }
            if (e == error.InvalidPackageJson) {
                try printToStdout("shu remove: invalid package.json\n", .{});
                return e;
            }
            return e;
        };
    }

    pkg_install.install(allocator, cwd_owned, null, null) catch |e| {
        if (e == error.NoManifest) {}
        return e;
    };
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [256]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
