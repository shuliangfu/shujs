// Node 兼容层：与 Node 风格相关的运行时行为（非 node:xxx 模块解析）
//
// 职责见本目录 README.md。可在此实现：
// - Node 风格启动（process.argv/execPath 语义、nextTick）
// - CJS/ESM 互操作钩子（require.extensions、Module._load）
// - Buffer/process 与 Node 的细微差异
// node:xxx 的解析与 exports 在 modules/node/builtin.zig，不在此。
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1、engine/BUILTINS.md

const std = @import("std");

/// Node 兼容层占位；实现后由 bindings 或 loader 在适当时机调用 init()
pub const node_compat = struct {
    /// 初始化 Node 兼容相关行为（占位）
    pub fn init() void {
        _ = std;
    }
};
