// shu preview 子命令：启动静态文件服务器预览（如 SSG/静态站点）
// 参考：README.md 建议新增 preview（P1）

const std = @import("std");
const args = @import("args.zig");
const errors = @import("errors");
const libs_process = @import("libs_process");

/// 执行 shu preview [目录] [选项]，启动静态服务预览；当前为占位
pub fn preview(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu preview: not implemented (Phase 0 placeholder)\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    const io_out = libs_process.getProcessIo() orelse return error.NoProcessIo;
    var buf: [128]u8 = undefined;
    var w = std.Io.File.Writer.init(std.Io.File.stdout(), io_out, &buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
