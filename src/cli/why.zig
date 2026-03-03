// shu why 子命令：解释某包为何被安装（依赖谁、被谁依赖）
// 参考：README.md 建议新增 why（P3）

const std = @import("std");
const args = @import("args.zig");
const errors = @import("errors");
const libs_process = @import("libs_process");

/// 执行 shu why <包名>，显示依赖关系；当前为占位
pub fn why(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu why: not implemented (Phase 0 placeholder)\n", .{});
}

/// 向 stdout 打印；0.16 使用 getProcessIo + std.Io.File.Writer。
fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    const io_out = libs_process.getProcessIo() orelse return error.NoProcessIo;
    var buf: [128]u8 = undefined;
    var w = std.Io.File.Writer.init(std.Io.File.stdout(), io_out, &buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
