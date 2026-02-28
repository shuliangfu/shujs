// shu install 子命令：安装依赖到 node_modules
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1
// Zig 0.15.2：I/O 使用 std.fs.File.stdout().writer(...)

const std = @import("std");
const args = @import("args.zig");

/// 执行 shu install，在当前目录解析 package.json 并安装依赖
pub fn install(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu install: 尚未实现（Phase 0 占位）\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
