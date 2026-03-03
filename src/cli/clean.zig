// shu clean 子命令：清除本地缓存、构建产物
// 参考：README.md 建议新增 clean（P3）

const std = @import("std");
const args = @import("args.zig");
const version = @import("version.zig");
const errors = @import("errors");
const libs_io = @import("libs_io");
const libs_process = @import("libs_process");
const cache = @import("../package/cache.zig");

/// 执行 shu clean [选项]，清除 SHU_CACHE（默认 ~/.shu/cache）及当前目录 dist；目录不存在则跳过。
pub fn clean(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = parsed;
    _ = positional;
    const io = libs_process.getProcessIo() orelse return error.NoProcessIo;
    try version.printCommandHeader(io, "clean");
    // 1. 清除依赖缓存（tarball、metadata、url 等）
    const cache_root = cache.getCacheRoot(allocator) catch return error.OutOfMemory;
    defer allocator.free(cache_root);
    libs_io.deleteTreeAbsolute(allocator, cache_root) catch |e| {
        if (e != error.FileNotFound) return e;
    };
    try printToStdout("Cleaned cache at {s}\n", .{cache_root});

    // 2. 清除当前目录 dist（构建产物）；仅当 dist 存在时才删除并提示
    var cwd_buf: [libs_io.max_path_bytes]u8 = undefined;
    const cwd = libs_io.realpath(".", &cwd_buf) catch return error.CwdFailed;
    const dist_path = try libs_io.pathJoin(allocator, &.{ cwd, "dist" });
    defer allocator.free(dist_path);
    var dist_dir = libs_io.openDirAbsolute(dist_path, .{}) catch |e| {
        if (e == error.FileNotFound) {
            try printToStdout("\n", .{});
            return; // dist 不存在，不清理也不提示
        }
        return e;
    };
    dist_dir.close(io);
    libs_io.deleteTreeAbsolute(allocator, dist_path) catch |err| return err;
    try printToStdout("Removed dist\n", .{});
    try printToStdout("\n", .{});
}

/// 向 stdout 打印格式化字符串；0.16 使用 getProcessIo + std.Io.File.Writer。
fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    const io_out = libs_process.getProcessIo() orelse return error.NoProcessIo;
    var buf: [256]u8 = undefined;
    var w = std.Io.File.Writer.init(std.Io.File.stdout(), io_out, &buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
