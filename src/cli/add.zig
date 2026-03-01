//! shu add 子命令（cli/add.zig）
//!
//! 职责
//!   - 将每个位置参数作为说明符（npm 包名如 lodash、JSR 如 jsr:@scope/name、或 https://...），写入当前项目 manifest（package.json(c) / deno.json(c)）并执行安装。
//!   - 至少需要一个说明符；无参数时打印用法并返回；实际写回与安装委托 install.addSpecifiersThenInstall。
//!
//! 主要 API
//!   - add(allocator, parsed, positional)：入口；cwd 解析与 addSpecifiersThenInstall 调用，msg_prefix 为 "shu add"。
//!
//! 约定
//!   - 参考 docs/PACKAGE_DESIGN.md §3；与 shu install <specifier> 共用 install 层逻辑。

const std = @import("std");
const args = @import("args.zig");
const io_core = @import("io_core");
const cli_install = @import("install.zig");

/// 执行 shu add <specifier>...
/// 将每个说明符（npm 包名或 jsr:@scope/name）写入 manifest 并安装到 node_modules；无参数时提示用法。
pub fn add(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = parsed;
    if (positional.len == 0) {
        try printToStdout("shu add: please specify at least one package (npm or jsr:)\n", .{});
        try printToStdout("Usage: shu add <specifier>...  e.g. shu add lodash  shu add jsr:@luca/flag\n", .{});
        return;
    }
    var cwd_buf: [io_core.max_path_bytes]u8 = undefined;
    const cwd = io_core.realpath(".", &cwd_buf) catch {
        try printToStdout("shu add: cannot get current directory\n", .{});
        return;
    };
    const cwd_owned = allocator.dupe(u8, cwd) catch return;
    defer allocator.free(cwd_owned);
    try cli_install.addSpecifiersThenInstall(allocator, cwd_owned, positional, "shu add");
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
