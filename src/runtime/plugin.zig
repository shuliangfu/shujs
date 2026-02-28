// 插件/扩展 ABI（加载 Zig/C 扩展，注入原生模块或钩子）
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1

const std = @import("std");

/// 插件描述（占位，后续定义 ABI）
pub const Plugin = struct {
    name: []const u8,
    path: []const u8,

    /// 从路径加载插件（占位）
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Plugin {
        _ = allocator;
        return .{ .name = "plugin", .path = path };
    }
};
