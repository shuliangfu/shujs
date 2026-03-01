// shu trace 子命令：打印模块加载/require 调用链
// 参考：README.md 还可实现的命令 - 调试与诊断

const std = @import("std");
const args = @import("args.zig");

/// 执行 shu trace [entry]，输出模块解析与加载链；当前为占位
pub fn trace(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu trace: 尚未实现（Phase 0 占位）\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
