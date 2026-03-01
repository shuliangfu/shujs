// shu task / tasks 子命令：列出或执行 package.json 中可运行的 scripts
// 参考：README.md 还可实现的命令 - 开发体验

const std = @import("std");
const args = @import("args.zig");

/// 执行 shu task [任务名] 或 shu task（列出），对齐 deno task；当前为占位
pub fn task(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu task: not implemented (Phase 0 placeholder)\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
