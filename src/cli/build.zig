// shu build 子命令：打包入口为单文件或分块
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1
// Zig 0.16.0-dev：I/O 使用 std.Io

const std = @import("std");
const args = @import("args.zig");

/// 执行 shu build [入口] [选项]，输出 ESM/CJS 单文件或分块
pub fn build(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8, io: std.Io) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout(io, "shu build: not implemented (Phase 0 placeholder)\n", .{});
}

fn printToStdout(io: std.Io, comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.Io.File.Writer.init(std.Io.File.stdout(), io, &buf);
    try w.interface.print(fmt, fargs);
    w.flush() catch {};
}
