// shu clean 子命令：清除本地缓存、构建产物
// 参考：README.md 建议新增 clean（P3）

const std = @import("std");
const args = @import("args.zig");
const version = @import("version.zig");
const io_core = @import("io_core");
const cache = @import("../package/cache.zig");

/// 执行 shu clean [选项]，清除 SHU_CACHE（默认 ~/.shu/cache）及当前目录 dist；目录不存在则跳过。
pub fn clean(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = parsed;
    _ = positional;
    try version.printCommandHeader("clean");
    // 1. 清除依赖缓存（tarball、metadata、url 等）
    const cache_root = cache.getCacheRoot(allocator) catch return error.OutOfMemory;
    defer allocator.free(cache_root);
    io_core.deleteTreeAbsolute(cache_root) catch |e| {
        if (e != error.FileNotFound) return e;
    };
    try printToStdout("Cleaned cache at {s}\n", .{cache_root});

    // 2. 清除当前目录 dist（构建产物）；仅当 dist 存在时才删除并提示
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch return error.CwdFailed;
    const dist_path = try io_core.pathJoin(allocator, &.{ cwd, "dist" });
    defer allocator.free(dist_path);
    var dist_dir = io_core.openDirAbsolute(dist_path, .{}) catch |e| {
        if (e == error.FileNotFound) {
            try printToStdout("\n", .{});
            return; // dist 不存在，不清理也不提示
        }
        return e;
    };
    dist_dir.close();
    io_core.deleteTreeAbsolute(dist_path) catch |err| return err;
    try printToStdout("Removed dist\n", .{});
    try printToStdout("\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [256]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
