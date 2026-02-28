// 词法/语法解析（可与 runtime 或 src/parser 共用）
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1

const std = @import("std");

/// 解析源码为 AST（占位，后续可委托给 src/parser）
pub fn parse(allocator: std.mem.Allocator, source: []const u8) !void {
    _ = allocator;
    _ = source;
}
