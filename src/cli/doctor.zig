// shu doctor 子命令：诊断环境（版本、权限、磁盘、网络等）
// 参考：README.md 还可实现的命令 - 开发体验

const std = @import("std");
const args = @import("args.zig");

/// 执行 shu doctor，诊断运行环境；当前为占位
pub fn doctor(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu doctor: 尚未实现（Phase 0 占位）\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
