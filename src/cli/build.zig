// shu build 子命令：打包入口为单文件或分块
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1
// Zig 0.15.2：I/O 使用 std.fs.File.stdout().writer(...)

const std = @import("std");
const args = @import("args.zig");

/// 执行 shu build [入口] [选项]，输出 ESM/CJS 单文件或分块
pub fn build(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu build: 尚未实现（Phase 0 占位）\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
