// shu why 子命令：解释某包为何被安装（依赖谁、被谁依赖）
// 参考：README.md 建议新增 why（P3）

const std = @import("std");
const args = @import("args.zig");

/// 执行 shu why <包名>，显示依赖关系；当前为占位
pub fn why(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu why: not implemented (Phase 0 placeholder)\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
