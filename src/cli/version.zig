//! 版本号与打印（cli/version.zig）
//!
//! 职责
//!   - 从 build_options 暴露当前 shu 版本号 VERSION（由 build.zig 注入，发布时只改 build.zig 一处）。
//!   - 提供 printVersion()：将 "shu <version>\n" 打印到 stdout，供子命令 version 或全局 -v/--version 使用。
//!
//! 主要 API
//!   - VERSION：版本字符串，供 help.zig 等引用。
//!   - printVersion()：打印版本到 stdout。
//!
//! 参考：README.md ⌨️ CLI 实用命令分析 P0

const std = @import("std");
const build_options = @import("build_options");

/// 当前 shu 版本号（由 build.zig 注入）；供 help.zig 等引用。发布时只改 build.zig 内 shu_version。
pub const VERSION: []const u8 = build_options.version;

/// 打印版本号到 stdout，供子命令 version 或全局 -v/--version 使用。Zig 0.16：使用 std.Io。
pub fn printVersion(io: std.Io) !void {
    var buf: [64]u8 = undefined;
    var w = std.Io.File.Writer.init(std.Io.File.stdout(), io, &buf);
    try w.interface.print("shu {s}\n", .{VERSION});
    w.flush() catch {};
}

// ANSI SGR：仅 TTY 时使用，与 install/help 等一致
const c_cyan = "\x1b[36m";
const c_reset = "\x1b[0m";

/// 打印统一命令头 "shu <cmd> v<VERSION>" 到 stdout；stdout 为 TTY 时使用青色美化，否则无颜色。供各子命令入口调用。Zig 0.16：需传入 io。
pub fn printCommandHeader(io: std.Io, cmd: []const u8) !void {
    var buf: [128]u8 = undefined;
    var w = std.Io.File.Writer.init(std.Io.File.stdout(), io, &buf);
    const use_color = std.c.isatty(1) != 0;
    if (use_color) {
        try w.interface.print("{s}shu {s} v{s}{s}\n", .{ c_cyan, cmd, VERSION, c_reset });
    } else {
        try w.interface.print("shu {s} v{s}\n", .{ cmd, VERSION });
    }
    w.flush() catch {};
}
