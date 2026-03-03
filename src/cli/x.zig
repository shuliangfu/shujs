// shu x 子命令：执行 npm 包提供的二进制（类 npx / bun x）
// 参考：README.md 建议新增 x / exec（P1）
// 0.16：stdout 经 libs_process.getProcessIo() + std.Io.File.stdout().Writer

const std = @import("std");
const args = @import("args.zig");
const errors = @import("errors");
const libs_process = @import("libs_process");

/// 执行 shu x <pkg> [args...]，临时运行包提供的可执行命令；当前为占位
pub fn x(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu x: not implemented (Phase 0 placeholder)\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    const io = libs_process.getProcessIo() orelse return error.NoProcessIo;
    var buf: [128]u8 = undefined;
    var w = std.Io.File.Writer.init(std.Io.File.stdout(), io, &buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
