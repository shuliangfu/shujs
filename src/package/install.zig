// 安装与缓存（下载 tarball、解压到 node_modules）
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1

const std = @import("std");

/// 根据已解析的依赖执行安装到 node_modules（占位）
pub fn install(allocator: std.mem.Allocator, cwd: []const u8) !void {
    _ = allocator;
    _ = cwd;
    // TODO: 下载 tarball、解压、写 node_modules
}
