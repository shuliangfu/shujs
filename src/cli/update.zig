// shu update 子命令：在版本范围内升级依赖
// 参考：README.md 还可实现的命令 - 包管理扩展

const std = @import("std");
const args = @import("args.zig");

/// 执行 shu update [包名...]，按版本范围升级依赖；当前为占位
pub fn update(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu update: 尚未实现（Phase 0 占位）\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
