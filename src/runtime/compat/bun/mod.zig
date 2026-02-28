// Bun 兼容层：与 Bun 风格相关的运行时行为（非 Bun.* API 与 bun:xxx 列表）
//
// 职责见本目录 README.md。可在此实现：
// - Bun 风格启动（Bun.main、Bun.env 与 process 的差异、热重载入口）
// - Bun 与 Node 的行为差异（如 Bun.sleep、Bun.file 与 fs 的桥接策略）
// - bun:xxx 的解析策略（与 modules/bun/builtin.zig 配合）
// Bun.serve、Bun.file、Bun.write 等在 engine/bun；bun: 说明符在 modules/bun/builtin.zig。参考：SHU_RUNTIME_ANALYSIS.md 6.1、engine/BUILTINS.md

const std = @import("std");

/// Bun 兼容层占位；实现后由 bindings 或 loader 在适当时机调用 init()
pub const bun_compat = struct {
    /// 初始化 Bun 兼容相关行为（占位）
    pub fn init() void {
        _ = std;
    }
};
