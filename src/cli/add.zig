//! shu add 子命令（cli/add.zig）
//!
//! 职责
//!   - 将每个位置参数作为说明符（npm 包名、JSR jsr:@scope/name、或 https://...），写入当前项目 manifest（package.json(c) / deno.json(c)）并执行安装。
//!   - 至少需要一个说明符；无参数时打印用法并返回；实际写回与安装委托 install.addSpecifiersThenInstall。
//!
//! 主要 API
//!   - add(allocator, parsed, positional)：入口；cwd 解析与 addSpecifiersThenInstall 调用，msg_prefix 为 "shu add"。
//!
//! 约定
//!   - 参考 docs/PACKAGE_DESIGN.md §3；与 shu install <specifier> 共用 install 层逻辑。

const std = @import("std");
const args = @import("args.zig");
const version = @import("version.zig");
const libs_io = @import("libs_io");
const cli_install = @import("install.zig");

/// 执行 shu add <specifier>...；支持 --dev/-D 将包写入 devDependencies（仅本命令识别，非全局选项）。
/// 将每个说明符（npm 包名或 jsr:@scope/name）写入 manifest 并安装到 node_modules；无参数时提示用法。Zig 0.16：io 用于 stdout。
pub fn add(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8, io: std.Io) !void {
    _ = parsed;
    var dev: bool = false;
    var specifiers = std.ArrayList([]const u8).initCapacity(allocator, positional.len) catch return;
    defer specifiers.deinit(allocator);
    for (positional) |arg| {
        if (std.mem.eql(u8, arg, "-D") or std.mem.eql(u8, arg, "--dev")) {
            dev = true;
        } else {
            specifiers.append(allocator, arg) catch return;
        }
    }
    if (specifiers.items.len == 0) {
        try printToStdout(io, "shu add: please specify at least one package (package name or jsr:)\n", .{});
        try printToStdout(io, "Usage: shu add [--dev|-D] <specifier>...  e.g. shu add <pkg>  shu add -D <pkg>  shu add <pkg>@<version>\n", .{});
        return;
    }
    try version.printCommandHeader(io, "add");
    var cwd_buf: [libs_io.max_path_bytes]u8 = undefined;
    const cwd = libs_io.realpath(".", &cwd_buf) catch {
        try printToStdout(io, "shu add: cannot get current directory\n", .{});
        return;
    };
    const cwd_owned = allocator.dupe(u8, cwd) catch return;
    defer allocator.free(cwd_owned);
    try cli_install.addSpecifiersThenInstall(allocator, cwd_owned, specifiers.items, "shu add", dev, io);
    try printToStdout(io, "\n", .{});
}

fn printToStdout(io: std.Io, comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.Io.File.Writer.init(std.Io.File.stdout(), io, &buf);
    try w.interface.print(fmt, fargs);
    w.flush() catch {};
}
