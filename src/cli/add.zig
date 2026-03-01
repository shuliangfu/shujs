// shu add 子命令：添加并安装 npm / JSR 包到当前项目
// 参考：docs/PACKAGE_DESIGN.md §3
// 约定：至少一个说明符（lodash、jsr:@scope/name 等），写回 package.json(c) 与 deno.json(c) 后执行 install

const std = @import("std");
const args = @import("args.zig");
const cli_install = @import("install.zig");

/// 执行 shu add <specifier>...
/// 将每个说明符（npm 包名或 jsr:@scope/name）写入 manifest 并安装到 node_modules；无参数时提示用法。
pub fn add(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = parsed;
    if (positional.len == 0) {
        try printToStdout("shu add: 请至少指定一个包（npm 或 jsr:）\n", .{});
        try printToStdout("用法: shu add <specifier>...  例如: shu add lodash  shu add jsr:@luca/flag\n", .{});
        return;
    }
    var cwd_buf: [1024]u8 = undefined;
    const cwd = std.fs.realpath(".", &cwd_buf) catch {
        try printToStdout("shu add: 无法获取当前目录\n", .{});
        return;
    };
    const cwd_owned = allocator.dupe(u8, cwd) catch return;
    defer allocator.free(cwd_owned);
    try cli_install.addSpecifiersThenInstall(allocator, cwd_owned, positional, "shu add");
    try printToStdout("shu add: 完成\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
