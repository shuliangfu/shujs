// package.json 解析（依赖、scripts、exports 等）
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1

const std = @import("std");

/// 解析后的 package.json 表示（占位）
pub const Manifest = struct {
    name: []const u8 = "",
    version: []const u8 = "",
    main: ?[]const u8 = null,
    scripts: std.StringArrayHashMap([]const u8) = undefined,

    /// 释放 scripts 等占用的内存
    pub fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        self.scripts.deinit();
        _ = allocator;
    }

    /// 从路径读取并解析 package.json
    pub fn load(allocator: std.mem.Allocator, dir: []const u8) !Manifest {
        _ = dir;
        var m: Manifest = .{};
        m.scripts = std.StringArrayHashMap([]const u8).init(allocator);
        return m;
    }
};
