// shu cache 子命令：预拉取并缓存依赖（类 deno cache）
// 参考：README.md 建议新增 cache（P2）
// 0.16：stdout 经 libs_process.getProcessIo() + std.Io.File.stdout().Writer

const std = @import("std");
const args = @import("args.zig");
const errors = @import("errors");
const libs_process = @import("libs_process");

/// 执行 shu cache [选项]，根据 lockfile 或 manifest 预拉取依赖到缓存；当前为占位
pub fn cache(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu cache: not implemented (Phase 0 placeholder)\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    const io = libs_process.getProcessIo() orelse return error.NoProcessIo;
    var buf: [128]u8 = undefined;
    var w = std.Io.File.Writer.init(std.Io.File.stdout(), io, &buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
