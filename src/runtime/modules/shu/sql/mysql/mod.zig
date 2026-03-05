// MySQL / MariaDB 后端占位；与 sql/mod.zig 统一入口按 mysql://、mariadb:// 分派，实现时对接 libmysqlclient 或兼容驱动。
//
// 本文件为占位，实现时提供连接池、tagged template 执行、事务等，与 postgresql、sqlite 并列。

const std = @import("std");
const jsc = @import("jsc");

/// 返回 MySQL/MariaDB 后端占位 exports；当前未对外单独暴露，由 sql/mod.zig 按 connectionString 分派时使用。
pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    comptime _ = allocator;
    return jsc.JSValueMakeUndefined(ctx);
}
