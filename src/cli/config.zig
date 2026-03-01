// shu config 子命令：读写全局或项目级配置
// 参考：README.md 还可实现的命令 - 其他

const std = @import("std");
const args = @import("args.zig");

/// 执行 shu config [key] [value]，读写配置；当前为占位
pub fn config(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu config: not implemented (Phase 0 placeholder)\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
