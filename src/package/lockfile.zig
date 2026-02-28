// 锁文件读写（自定义格式或兼容 bun.lock）
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1

const std = @import("std");

/// 从锁文件路径读取（占位）
pub fn load(allocator: std.mem.Allocator, path: []const u8) !void {
    _ = allocator;
    _ = path;
}

/// 将当前解析结果写入锁文件（占位）
pub fn save(allocator: std.mem.Allocator, path: []const u8) !void {
    _ = allocator;
    _ = path;
}
