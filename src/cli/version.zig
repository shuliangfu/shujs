//! 版本号与打印（cli/version.zig）
//!
//! 职责
//!   - 定义当前 shu 版本号常量 VERSION（占位 "0.1.0"，后续可由 build.zig 注入）。
//!   - 提供 printVersion()：将 "shu <version>\n" 打印到 stdout，供子命令 version 或全局 -v/--version 使用。
//!
//! 主要 API
//!   - VERSION：版本字符串，供 help.zig 等引用。
//!   - printVersion()：打印版本到 stdout。
//!
//! 参考：README.md ⌨️ CLI 实用命令分析 P0

const std = @import("std");

/// 当前 shu 版本号（占位，后续可由 build.zig 注入）；供 help.zig 等引用
pub const VERSION = "0.1.0";

/// 打印版本号到 stdout，供子命令 version 或全局 -v/--version 使用
pub fn printVersion() !void {
    var buf: [64]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print("shu {s}\n", .{VERSION});
    try w.interface.flush();
}
