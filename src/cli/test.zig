//! shu test 子命令（cli/test.zig）
//!
//! 职责
//!   - 有 scripts.test 时：用 shell 执行该脚本（runScriptInCwd）。
//!   - 无 script 时：默认扫描 tests/ 下 *.test.ts、*.test.js、*.spec.ts、*.spec.js（排除 scan.default_exclude_dirs），对每个文件执行 shu run；无 package.json 时仍可走默认扫描。
//!
//! 主要 API
//!   - runTest(allocator, parsed, positional)：入口；无 tests/ 或无可匹配文件时给出英文提示。
//!
//! 约定
//!   - 目录遍历与路径经 io_core；面向用户输出为英文；与 PACKAGE_DESIGN.md test 配置、deno test 对齐。

const std = @import("std");
const builtin = @import("builtin");
const args = @import("args.zig");
const io_core = @import("io_core");
const manifest = @import("../package/manifest.zig");
const scan = @import("scan.zig");

/// 执行 shu test：有 scripts.test 则用 shell 执行；否则默认扫描 tests/ 下 *.test.ts、*.test.js、*.spec.ts、*.spec.js（排除 default_exclude_dirs），对每个文件执行 shu run。
pub fn runTest(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = positional;
    _ = parsed;
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = io_core.realpath(".", &cwd_buf) catch {
        try printStderr("shu test: cannot get current directory\n", .{});
        return error.CwdFailed;
    };
    const cwd_owned = allocator.dupe(u8, cwd) catch return;
    defer allocator.free(cwd_owned);

    var loaded = manifest.Manifest.load(allocator, cwd_owned) catch |e| {
        if (e == error.ManifestNotFound) {
            // 无 package.json 时仍使用默认扫描 tests/
            return runDefaultTests(allocator, cwd_owned);
        }
        return e;
    };
    defer loaded.arena.deinit();
    const m = &loaded.manifest;

    if (m.scripts.get("test")) |cmd| {
        runScriptInCwd(allocator, cwd_owned, cmd) catch |e| {
            try printStderr("shu test: script failed\n", .{});
            return e;
        };
        return;
    }

    return runDefaultTests(allocator, cwd_owned);
}

/// 默认行为：扫描 tests/ 下 test/spec 文件并逐个 shu run；排除 scan.default_exclude_dirs
fn runDefaultTests(allocator: std.mem.Allocator, cwd_owned: []const u8) !void {
    const tests_dir_abs = try io_core.pathJoin(allocator, &.{ cwd_owned, "tests" });
    defer allocator.free(tests_dir_abs);

    var tests_dir = io_core.openDirAbsolute(tests_dir_abs, .{}) catch {
        try printStderr("shu test: no tests/ directory. Create tests/ with *.test.ts, *.test.js, *.spec.ts, or *.spec.js files.\n", .{});
        return error.NoTestsDir;
    };
    tests_dir.close();

    var list = try scan.collectFilesRecursive(allocator, tests_dir_abs, &scan.test_extensions);
    defer {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    }
    if (list.items.len == 0) {
        try printStderr("shu test: no test files found under tests/\n", .{});
        return;
    }

    const self_exe = std.fs.selfExePathAlloc(allocator) catch {
        try printStderr("shu test: cannot get executable path\n", .{});
        return error.SelfExeFailed;
    };
    defer allocator.free(self_exe);

    var failed: bool = false;
    for (list.items) |item| {
        const run_path = try io_core.pathJoin(allocator, &.{ "tests", item });
        defer allocator.free(run_path);
        var argv_buf: [4][]const u8 = undefined;
        argv_buf[0] = self_exe;
        argv_buf[1] = "run";
        argv_buf[2] = run_path;
        const argv = argv_buf[0..3];
        var child = std.process.Child.init(argv, allocator);
        child.cwd = cwd_owned;
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        try child.spawn();
        const term = try child.wait();
        switch (term) {
            .Exited => |code| {
                if (code != 0) failed = true;
            },
            .Signal, .Stopped, .Unknown => failed = true,
        }
    }
    if (failed) return error.ScriptExitedNonZero;
}

/// 在 cwd 下用 shell 执行 cmd（/bin/sh -c cmd 或 cmd.exe /c cmd）；stdio 继承
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
