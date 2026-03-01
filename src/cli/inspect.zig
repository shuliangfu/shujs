// shu inspect 子命令：以调试模式启动，暴露 DevTools/Inspector 端口
// 参考：README.md 还可实现的命令 - 调试与诊断

const std = @import("std");
const args = @import("args.zig");

/// 执行 shu inspect [entry]，以调试模式运行；当前为占位
pub fn inspect(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu inspect: not implemented (Phase 0 placeholder)\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
