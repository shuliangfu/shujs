//! shu lint 子命令（cli/lint.zig）
//!
//! 职责
//!   - 有 scripts.lint 时：用 shell 执行该脚本。
//!   - 无 script 时：默认递归收集项目内与 fmt 相同的扩展名文件（排除 default_exclude_dirs），先尝试 deno lint；不可用时对 .ts/.tsx 做内置语法检查（strip_types），.js/.jsx/.mjs/.cjs 在无 deno 时不检查。
//!
//! 主要 API
//!   - lint(allocator, parsed, positional)：入口；有语法错误时打印到 stderr 并返回 LintFailed。
//!
//! 约定
//!   - 目录与文件列表经 scan 与 io_core；面向用户输出为英文；与 PACKAGE_DESIGN.md lint 配置对齐。

const std = @import("std");
const builtin = @import("builtin");
const args = @import("args.zig");
const io_core = @import("io_core");
const manifest = @import("../package/manifest.zig");
const scan = @import("scan.zig");
const strip_types = @import("../transpiler/strip_types.zig");

/// 执行 shu lint：有 scripts.lint 则用 shell 执行；否则默认收集项目下所有 lint_extensions 文件（排除 default_exclude_dirs），先尝试 deno lint，不可用时对 .ts/.tsx 做内置语法检查并跳过 .js/.jsx/.mjs/.cjs。
pub fn lint(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = positional;
    _ = parsed;
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = io_core.realpath(".", &cwd_buf) catch {
        try printStderr("shu lint: cannot get current directory\n", .{});
        return error.CwdFailed;
    };
    const cwd_owned = allocator.dupe(u8, cwd) catch return;
    defer allocator.free(cwd_owned);

    var loaded = manifest.Manifest.load(allocator, cwd_owned) catch |e| {
        if (e == error.ManifestNotFound) return runDefaultLint(allocator, cwd_owned);
        return e;
    };
    defer loaded.arena.deinit();
    const m = &loaded.manifest;

    if (m.scripts.get("lint")) |cmd| {
        runScriptInCwd(allocator, cwd_owned, cmd) catch |e| {
            try printStderr("shu lint: script failed\n", .{});
            return e;
        };
        return;
    }

    return runDefaultLint(allocator, cwd_owned);
}

/// 默认行为：先尝试 deno lint；失败则对 .ts/.tsx 做 strip 语法检查，.js/.jsx/.mjs/.cjs 仅提示跳过
fn runDefaultLint(allocator: std.mem.Allocator, cwd_owned: []const u8) !void {
    var list = try scan.collectFilesRecursive(allocator, cwd_owned, &scan.lint_extensions);
    defer {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    }
    if (list.items.len == 0) return;

    if (runDenoLint(allocator, cwd_owned, list.items)) return;

    // 回退：仅对 .ts/.tsx 做 strip 语法检查
    var has_error = false;
    for (list.items) |rel| {
        if (std.mem.endsWith(u8, rel, ".ts") or std.mem.endsWith(u8, rel, ".tsx")) {
            const abs = try io_core.pathJoin(allocator, &.{ cwd_owned, rel });
            defer allocator.free(abs);
            var f = io_core.openFileAbsolute(abs, .{}) catch {
                try printStderr("shu lint: {s}: open failed\n", .{rel});
                has_error = true;
                continue;
            };
            defer f.close();
            const raw = f.readToEndAlloc(allocator, std.math.maxInt(usize)) catch {
                try printStderr("shu lint: {s}: read failed\n", .{rel});
                has_error = true;
                continue;
            };
            defer allocator.free(raw);
            const stripped = strip_types.strip(allocator, raw) catch |e| {
                try printStderr("shu lint: {s}: syntax error ({})\n", .{ rel, e });
                has_error = true;
                continue;
            };
            allocator.free(stripped);
        }
    }
    if (has_error) return error.LintFailed;
}

/// 执行 deno lint <files...>；成功返回 true，未找到 deno 或失败返回 false
fn runDenoLint(allocator: std.mem.Allocator, cwd: []const u8, files: []const []const u8) bool {
    var argv = std.ArrayList([]const u8).initCapacity(allocator, files.len + 3) catch return false;
    defer argv.deinit(allocator);
    argv.append(allocator, "deno") catch return false;
    argv.append(allocator, "lint") catch return false;
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
