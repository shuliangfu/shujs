// shu x 子命令：执行 npm 包提供的二进制（类 npx / bun x）
// 参考：README.md 建议新增 x / exec（P1）

const std = @import("std");
const args = @import("args.zig");

/// 执行 shu x <pkg> [args...]，临时运行包提供的可执行命令；当前为占位
pub fn x(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu x: not implemented (Phase 0 placeholder)\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
