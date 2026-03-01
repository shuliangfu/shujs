// shu serve 子命令：面向「生产式」静态服务（与 preview 区分）
// 参考：README.md 还可实现的命令 - 其他

const std = @import("std");
const args = @import("args.zig");

/// 执行 shu serve [目录] [选项]，启动静态服务（gzip、缓存头等）；当前为占位
pub fn serve(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu serve: not implemented (Phase 0 placeholder)\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
