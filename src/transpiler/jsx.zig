// JSX 转译（pragma 与运行时对齐 Bun）
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1

const std = @import("std");

/// 将 JSX 转译为 JS（占位）
pub fn transform(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    _ = allocator;
    _ = source;
    return source;
}
