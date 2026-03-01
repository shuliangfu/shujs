// shu doc 子命令：从 JSDoc/TS 注释生成 API 文档
// 参考：README.md 建议新增 doc（P3）

const std = @import("std");
const args = @import("args.zig");

/// 执行 shu doc [入口] [选项]，生成 API 文档；当前为占位
pub fn doc(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = allocator;
    _ = parsed;
    _ = positional;
    try printToStdout("shu doc: 尚未实现（Phase 0 占位）\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
