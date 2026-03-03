//! shu pack 子命令（cli/pack.zig）
//!
//! 职责
//!   - 根据当前目录 package.json 的 name/version，将除 node_modules、.git、.shu、*.tgz 外的文件打入 <name>-<version>.tgz（npm pack 风格，tar 内路径含 package/ 前缀）。
//!   - 使用 gzip 压缩生成 .tgz；目录遍历与路径经 io_core。
//!
//! 主要 API
//!   - pack(allocator, parsed, positional)：入口；无 manifest 时提示并返回 ManifestNotFound；成功后输出 tgz 路径。
//!
//! 约定
//!   - 面向用户输出为英文；参考 PACKAGE_DESIGN.md、01-代码规则。

const std = @import("std");
const args = @import("args.zig");
const cli_version = @import("version.zig");
const manifest = @import("../package/manifest.zig");
const io_core = @import("io_core");
const shu_zlib = @import("../runtime/modules/shu/zlib/gzip.zig");

/// 执行 shu pack：根据当前目录 package.json 的 name/version，将除 node_modules、.git、.shu、*.tgz 外的文件打入 <name>-<version>.tgz。
pub fn pack(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = parsed;
    _ = positional;
    try cli_version.printCommandHeader("pack");
    var cwd_buf: [1024]u8 = undefined;
    const cwd = std.posix.getcwd(&cwd_buf) catch return error.CwdFailed;
    const cwd_owned = allocator.dupe(u8, cwd) catch return error.OutOfMemory;
    defer allocator.free(cwd_owned);

    var loaded = manifest.Manifest.load(allocator, cwd_owned) catch |e| {
        if (e == error.ManifestNotFound) {
            try printToStdout("shu pack: no manifest (package.json or deno.json) in current directory\n", .{});
            return e;
        }
        return e;
    };
    defer loaded.arena.deinit();
    const m = &loaded.manifest;
    const name = if (m.name.len > 0) m.name else "package";
    const version = if (m.version.len > 0) m.version else "1.0.0";

    var tar_list = std.ArrayList(u8).initCapacity(allocator, 512 * 1024) catch return error.OutOfMemory;
    defer tar_list.deinit(allocator);

    var dir = try io_core.openDirCwd(".", .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        const path = entry.name;
        if (std.mem.eql(u8, path, "node_modules") or std.mem.eql(u8, path, ".git") or std.mem.eql(u8, path, ".shu")) continue;
        if (std.mem.endsWith(u8, path, ".tgz")) continue;
        const full = try io_core.pathJoin(allocator, &.{ cwd_owned, path });
        defer allocator.free(full);
        const tar_name = try std.fmt.allocPrint(allocator, "package/{s}", .{path});
        defer allocator.free(tar_name);
        const content = dir.openFile(path, .{}) catch continue;
        defer content.close();
        const size = content.getEndPos() catch continue;
        try writeTarEntry(allocator, &tar_list, tar_name, content, size);
    }
    // Tar end-of-archive: two 512-byte zero blocks
    var zeros: [512]u8 = undefined;
    @memset(&zeros, 0);
    try tar_list.appendSlice(allocator, &zeros);
    try tar_list.appendSlice(allocator, &zeros);

    const tgz_name = try std.fmt.allocPrint(allocator, "{s}-{s}.tgz", .{ name, version });
    defer allocator.free(tgz_name);
    const gz = shu_zlib.compressGzip(allocator, tar_list.items) catch return error.CompressFailed;
    defer allocator.free(gz);
    var out = io_core.createFileAbsolute(tgz_name, .{}) catch {
        try printToStdout("shu pack: cannot create {s}\n", .{tgz_name});
        return error.CannotCreateFile;
    };
    defer out.close();
    try out.writeAll(gz);
    try printToStdout("shu pack: wrote {s}\n", .{tgz_name});
    try printToStdout("\n", .{});
}

/// 向 tar 缓冲追加一个文件条目：512 字节头 + 内容 + 块对齐 padding；name 以 package/ 前缀写入。
fn writeTarEntry(allocator: std.mem.Allocator, tar: *std.ArrayList(u8), name: []const u8, file: std.fs.File, size: u64) !void {
    var header: [512]u8 = undefined;
    @memset(&header, 0);
    const name_len = @min(name.len, 100);
    @memcpy(header[0..name_len], name[0..name_len]);
    var size_oct: [12]u8 = undefined;
    @memset(&size_oct, ' ');
    _ = std.fmt.bufPrint(size_oct[0..11], "{o}", .{size}) catch {};
    @memcpy(header[124..136], &size_oct);
    header[156] = '0';
    try tar.appendSlice(allocator, &header);
    var buf: [8192]u8 = undefined;
    var remain = size;
    while (remain > 0) {
        const to_read = @min(buf.len, remain);
        const n = file.read(buf[0..to_read]) catch break;
        if (n == 0) break;
        try tar.appendSlice(allocator, buf[0..n]);
        remain -= n;
    }
    const pad = (512 - (size % 512)) % 512;
    var i: usize = 0;
    while (i < pad) : (i += 1) try tar.append(allocator, 0);
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [256]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
