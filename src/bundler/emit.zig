// 代码生成（输出 ESM/CJS 单文件或分块）
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1

const std = @import("std");
const ast = @import("ast.zig");

/// 从 AST 生成代码并写入 out_path（占位）
pub fn emit(allocator: std.mem.Allocator, root: *const ast.Node, out_path: []const u8) !void {
    _ = allocator;
    _ = root;
    _ = out_path;
}
