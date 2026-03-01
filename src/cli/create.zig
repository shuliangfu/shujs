// shu create 子命令：从模板脚手架新项目
// 参考：README.md 还可实现的命令 - 开发体验

const std = @import("std");
const args = @import("args.zig");

/// 执行 shu create <名> [目录]，从模板创建新项目；当前为占位
pub fn create(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu create: not implemented (Phase 0 placeholder)\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
