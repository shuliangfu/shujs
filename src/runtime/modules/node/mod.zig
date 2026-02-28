// node:* 内置模块（node:fs、node:path、node:http 等）
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1

const std = @import("std");

/// Node 模块命名空间（node:fs、node:path、node:http 等，占位）
pub const node = struct {
    /// 注册 Node 模块（占位）
    pub fn init() void {
        _ = std;
    }
};
