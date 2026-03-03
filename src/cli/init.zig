//! shu init 子命令（cli/init.zig）
//!
//! 职责
//!   - 若当前目录尚无 package.json 或 package.jsonc，则生成最小 package.json：name 取自目录名或 "my-app"，version "1.0.0"。
//!   - 可选生成 .gitignore（常见 Node 忽略项）；若已存在 package.json(c) 则提示并跳过。
//!
//! 主要 API
//!   - init(allocator, parsed, positional)：入口；使用 io_core 检查与写文件，面向用户输出为英文。
//!
//! 约定
//!   - 参考 PACKAGE_DESIGN.md、01-代码规则（面向用户输出为英文）。

const std = @import("std");
const args = @import("args.zig");
const errors = @import("errors");
const libs_process = @import("libs_process");
const version = @import("version.zig");
const libs_io = @import("libs_io");

/// 执行 shu init：若当前目录尚无 package.json/package.jsonc，则生成最小 package.json（name 取自目录名或 "my-app"，version "1.0.0"）；可选生成 .gitignore。
pub fn init(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = parsed;
    _ = positional;
    const io = libs_process.getProcessIo() orelse return error.NoProcessIo;
    try version.printCommandHeader(io, "init");
    var cwd_buf: [1024]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_buf) catch return error.CwdFailed;
    const cwd = cwd_buf[0..cwd_len];
    const cwd_owned = allocator.dupe(u8, cwd) catch return error.OutOfMemory;
    defer allocator.free(cwd_owned);

    var dir = libs_io.openDirCwd(".", .{}) catch return error.CwdOpenFailed;
    defer dir.close(io);
    if (dir.openFile(io, "package.json", .{})) |f| {
        f.close(io);
        try printToStdout("shu init: package.json already exists, skipping.\n", .{});
        try printToStdout("\n", .{});
        return;
    } else |_| {}
    if (dir.openFile(io, "package.jsonc", .{})) |f| {
        f.close(io);
        try printToStdout("shu init: package.jsonc already exists, skipping.\n", .{});
        try printToStdout("\n", .{});
        return;
    } else |_| {}

    const name = libs_io.pathBasename(cwd_owned);
    const content = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "name": "{s}",
        \\  "version": "1.0.0",
        \\  "type": "module",
        \\  "dependencies": {{}}
        \\}}
        \\
    , .{if (name.len > 0) name else "my-app"});
    defer allocator.free(content);

    var pkg_file = try dir.createFile(io, "package.json", .{});
    defer pkg_file.close(io);
    var wbuf: [4096]u8 = undefined;
    var w = pkg_file.writer(io, &wbuf);
    _ = std.Io.Writer.writeVec(&w.interface, &.{content}) catch return;
    try w.interface.flush();

    if (dir.openFile(io, ".gitignore", .{}) catch null) |f| {
        f.close(io);
    } else {
        var ig = dir.createFile(io, ".gitignore", .{}) catch return;
        defer ig.close(io);
        const ig_content = "node_modules/\n.shu/\n*.tgz\n";
        var ig_buf: [256]u8 = undefined;
        var iw = ig.writer(io, &ig_buf);
        _ = std.Io.Writer.writeVec(&iw.interface, &.{ig_content}) catch return;
        try iw.interface.flush();
    }

    try printToStdout("shu init: created package.json and .gitignore (if missing).\n", .{});
    try printToStdout("\n", .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    const io = libs_process.getProcessIo() orelse return error.NoProcessIo;
    var buf: [256]u8 = undefined;
    var w = std.Io.File.Writer.init(std.Io.File.stdout(), io, &buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
