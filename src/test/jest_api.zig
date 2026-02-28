// describe / it / expect 等类 Jest API
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1

const std = @import("std");

/// 注册 describe / it / expect 到 VM 全局（占位）
pub fn register(allocator: std.mem.Allocator) void {
    _ = allocator;
    // TODO: 向 JSC 注入 describe、it、expect
}
