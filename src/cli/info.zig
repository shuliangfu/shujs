// shu info 子命令：显示依赖树、模块解析结果或环境信息
// 参考：README.md 建议新增 info（P2）

const std = @import("std");
const args = @import("args.zig");

/// 执行 shu info [选项]，显示依赖树、解析路径或环境信息；当前为占位
pub fn info(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu info: not implemented (Phase 0 placeholder)\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
