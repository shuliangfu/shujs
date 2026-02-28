// Bun.* API 实现（Bun.serve、Bun.file 等，与 compat/bun 配合）
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1

const std = @import("std");

/// Bun 模块命名空间（导出 Bun.serve、Bun.file 等，占位）
pub const bun = struct {
    /// 注册 Bun 模块（占位）
    pub fn init() void {
        _ = std;
    }
};
