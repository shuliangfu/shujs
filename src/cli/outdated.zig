// shu outdated 子命令：列出已过期的依赖及可升级版本
// 参考：README.md 还可实现的命令 - 包管理扩展

const std = @import("std");
const args = @import("args.zig");

/// 执行 shu outdated，列出可升级的依赖；当前为占位
pub fn outdated(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu outdated: 尚未实现（Phase 0 占位）\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
