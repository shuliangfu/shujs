// shu list / ls 子命令：列出已安装包（可带依赖树）
// 参考：README.md 还可实现的命令 - 包管理扩展

const std = @import("std");
const args = @import("args.zig");

/// 执行 shu list [选项]，列出已安装包；当前为占位
pub fn list(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu list: 尚未实现（Phase 0 占位）\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
