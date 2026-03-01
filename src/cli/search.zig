// shu search 子命令：在 registry 中搜索包
// 参考：README.md 还可实现的命令 - 发布与协作

const std = @import("std");
const args = @import("args.zig");

/// 执行 shu search <关键词>，在 registry 搜索包；当前为占位
pub fn search(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu search: 尚未实现（Phase 0 占位）\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
