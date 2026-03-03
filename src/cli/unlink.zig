// shu unlink 子命令：移除 link
// 参考：README.md 还可实现的命令 - 包管理扩展

const std = @import("std");
const args = @import("args.zig");
const errors = @import("errors");
const libs_process = @import("libs_process");

/// 执行 shu unlink [包名]，移除 link；当前为占位
pub fn unlink(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu unlink: not implemented (Phase 0 placeholder)\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    const io_out = libs_process.getProcessIo() orelse return error.NoProcessIo;
    var buf: [128]u8 = undefined;
    var w = std.Io.File.Writer.init(std.Io.File.stdout(), io_out, &buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
