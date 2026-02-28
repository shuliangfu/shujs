// shu lint 子命令：代码检查（对齐 deno lint）
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1
// Zig 0.15.2：I/O 使用 std.fs.File.stdout().writer(...)

const std = @import("std");
const args = @import("args.zig");

/// 执行 shu lint [路径...]，对代码做静态检查
pub fn lint(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu lint: 尚未实现（Phase 0 占位）\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
