// shu repl 子命令：启动交互式 REPL
// 参考：README.md 建议新增 repl（P2）

const std = @import("std");
const args = @import("args.zig");
const errors = @import("errors");
const libs_process = @import("libs_process");

/// 执行 shu repl，启动交互式 REPL；当前为占位
pub fn repl(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu repl: not implemented (Phase 0 placeholder)\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    const io = libs_process.getProcessIo() orelse return error.NoProcessIo;
    var buf: [128]u8 = undefined;
    var w = std.Io.File.Writer.init(std.Io.File.stdout(), io, &buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
