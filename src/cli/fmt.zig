//! shu fmt 子命令（cli/fmt.zig）
//!
//! 职责
//!   - 有 scripts.fmt 时：用 shell 执行该脚本。
//!   - 无 script 时：默认递归收集项目内 .ts、.tsx、.js、.jsx、.mjs、.cjs（排除 scan.default_exclude_dirs），先尝试 deno fmt，不可用时尝试 npx prettier --write；无 package.json 时仍可走默认格式化。
//!
//! 主要 API
//!   - fmt(allocator, parsed, positional)：入口；无可用 formatter 时给出英文提示并返回错误。
//!
//! 约定
//!   - 目录与文件列表经 scan 与 io_core；面向用户输出为英文；与 PACKAGE_DESIGN.md fmt 配置对齐。

const std = @import("std");
const builtin = @import("builtin");
const args = @import("args.zig");
const io_core = @import("io_core");
const manifest = @import("../package/manifest.zig");
const scan = @import("scan.zig");

/// 执行 shu fmt：有 scripts.fmt 则用 shell 执行；否则默认收集项目下所有 fmt_extensions 文件（排除 default_exclude_dirs），先尝试 deno fmt，不可用时用 npx prettier --write。
pub fn fmt(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = positional;
    _ = parsed;
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = io_core.realpath(".", &cwd_buf) catch {
        try printStderr("shu fmt: cannot get current directory\n", .{});
        return error.CwdFailed;
    };
    const cwd_owned = allocator.dupe(u8, cwd) catch return;
    defer allocator.free(cwd_owned);

    var loaded = manifest.Manifest.load(allocator, cwd_owned) catch |e| {
        if (e == error.ManifestNotFound) return runDefaultFmt(allocator, cwd_owned);
        return e;
    };
    defer loaded.arena.deinit();
    const m = &loaded.manifest;

    if (m.scripts.get("fmt")) |cmd| {
        runScriptInCwd(allocator, cwd_owned, cmd) catch |e| {
            try printStderr("shu fmt: script failed\n", .{});
            return e;
        };
        return;
    }

    return runDefaultFmt(allocator, cwd_owned);
}

/// 默认行为：递归收集 cwd 下 .ts/.tsx/.js/.jsx/.mjs/.cjs（排除 default_exclude_dirs），先 deno fmt，失败则 npx prettier --write
fn runDefaultFmt(allocator: std.mem.Allocator, cwd_owned: []const u8) !void {
    var list = try scan.collectFilesRecursive(allocator, cwd_owned, &scan.fmt_extensions);
    defer {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    }
    if (list.items.len == 0) return;

    // 先尝试 deno fmt file1 file2 ...
    const deno_ok = runDenoFmt(allocator, cwd_owned, list.items);
    if (deno_ok) return;

    // 再尝试 npx prettier --write file1 file2 ...
    const prettier_ok = runPrettierFmt(allocator, cwd_owned, list.items);
    if (prettier_ok) return;

    try printStderr("shu fmt: no \"fmt\" script and neither deno nor npx prettier available. Install deno or add \"fmt\" to package.json scripts.\n", .{});
    return error.NoFmtScript;
}

/// 执行 deno fmt <files...>；成功返回 true，未找到 deno 或失败返回 false
fn runDenoFmt(allocator: std.mem.Allocator, cwd: []const u8, files: []const []const u8) bool {
    var argv = std.ArrayList([]const u8).initCapacity(allocator, files.len + 3) catch return false;
    defer argv.deinit(allocator);
    argv.append(allocator, "deno") catch return false;
    argv.append(allocator, "fmt") catch return false;
    for (files) |f| {
        argv.append(allocator, f) catch return false;
    }
    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.spawn() catch return false;
    const term = child.wait() catch return false;
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

/// 执行 npx prettier --write <files...>；成功返回 true，未找到或失败返回 false
fn runPrettierFmt(allocator: std.mem.Allocator, cwd: []const u8, files: []const []const u8) bool {
    var argv = std.ArrayList([]const u8).initCapacity(allocator, files.len + 4) catch return false;
    defer argv.deinit(allocator);
    argv.append(allocator, "npx") catch return false;
    argv.append(allocator, "prettier") catch return false;
    argv.append(allocator, "--write") catch return false;
    for (files) |f| {
        argv.append(allocator, f) catch return false;
    }
    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.spawn() catch return false;
    const term = child.wait() catch return false;
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn runScriptInCwd(allocator: std.mem.Allocator, cwd: []const u8, cmd: []const u8) !void {
    var argv_buf: [3][]const u8 = undefined;
    if (builtin.os.tag == .windows) {
        argv_buf[0] = "cmd.exe";
        argv_buf[1] = "/c";
        argv_buf[2] = cmd;
    } else {
        argv_buf[0] = "/bin/sh";
        argv_buf[1] = "-c";
        argv_buf[2] = cmd;
    }
    var child = std.process.Child.init(&argv_buf, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return error.ScriptExitedNonZero,
        .Signal, .Stopped => return error.ScriptSignalled,
        .Unknown => return error.ScriptExitedNonZero,
    }
}

fn printStderr(comptime fmt_str: []const u8, fargs: anytype) !void {
    var buf: [256]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    try w.interface.print(fmt_str, fargs);
    try w.interface.flush();
}
