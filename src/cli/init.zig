// shu init 子命令：在当前目录初始化项目（package.json 等）
// 参考：README.md 建议新增 init（P1）

const std = @import("std");
const args = @import("args.zig");

/// 执行 shu init，生成 package.json（可选 tsconfig、.gitignore）；当前为占位
pub fn init(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu init: 尚未实现（Phase 0 占位）\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
