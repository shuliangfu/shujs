// shu remove 子命令：移除依赖并更新 package.json
// 参考：README.md 还可实现的命令 - 包管理扩展

const std = @import("std");
const args = @import("args.zig");

/// 执行 shu remove <包名>...，从 dependencies 移除并更新 package.json；当前为占位
pub fn remove(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu remove: 尚未实现（Phase 0 占位）\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
