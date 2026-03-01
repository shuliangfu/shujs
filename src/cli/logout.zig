// shu logout 子命令：登出 npm 或私有 registry
// 参考：README.md 还可实现的命令 - 发布与协作

const std = @import("std");
const args = @import("args.zig");

/// 执行 shu logout，登出当前 registry；当前为占位
pub fn logout(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu logout: not implemented (Phase 0 placeholder)\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
