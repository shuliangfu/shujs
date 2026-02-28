// Deno 兼容层：与 Deno 风格相关的运行时行为（非 deno:xxx 模块列表）
//
// 职责见本目录 README.md。可在此实现：
// - deno: 协议解析策略（与 modules/deno/builtin.zig 配合）
// - Import Map 解析与说明符重写
// - 权限风格 API（Deno.permissions 等）与 --allow-* 对齐
// - Deno 全局命名空间（Deno.args、Deno.build、Deno.serve 等）
// deno: 说明符规划在 modules/deno/builtin.zig。参考：SHU_RUNTIME_ANALYSIS.md 6.1、engine/BUILTINS.md

const std = @import("std");

/// Deno 兼容层占位；实现后由 bindings 或 loader 在适当时机调用 init()
pub const deno_compat = struct {
    /// 初始化 Deno 兼容相关行为（占位）
    pub fn init() void {
        _ = std;
    }
};
