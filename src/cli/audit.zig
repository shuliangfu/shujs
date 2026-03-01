// shu audit 子命令：依赖安全审计，报告已知漏洞
// 参考：README.md 还可实现的命令 - 调试与诊断

const std = @import("std");
const args = @import("args.zig");

/// 执行 shu audit [选项]，检查依赖安全；当前为占位
pub fn audit(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu audit: not implemented (Phase 0 placeholder)\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
