// shu cache 子命令：预拉取并缓存依赖（类 deno cache）
// 参考：README.md 建议新增 cache（P2）

const std = @import("std");
const args = @import("args.zig");

/// 执行 shu cache [选项]，根据 lockfile 或 manifest 预拉取依赖到缓存；当前为占位
pub fn cache(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu cache: not implemented (Phase 0 placeholder)\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
