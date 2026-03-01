// shu clean 子命令：清除本地缓存、构建产物
// 参考：README.md 建议新增 clean（P3）

const std = @import("std");
const args = @import("args.zig");

/// 执行 shu clean [选项]，清除 .shu/cache、dist 等；当前为占位
pub fn clean(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu clean: 尚未实现（Phase 0 占位）\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
