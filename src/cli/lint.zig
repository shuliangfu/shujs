//! shu lint 子命令（cli/lint.zig）
//!
//! 职责
//!   - 有 scripts.lint 时：用 shell 执行该脚本。
//!   - 无 script 时：收集 lint_extensions（不含 .md/.mdc）；
//!     传 --md/--markdown 时额外收集 .md/.mdc 并用 markdownlint-cli 检查。
//!   - JS/TS：优先用项目本地 node_modules/.bin/eslint，否则 npx --yes eslint。
//!     有 eslint.config.js/.mjs/.cjs 则直接用；
//!     无则若 package.json 有 "eslintConfig" 则设 ESLINT_USE_FLAT_CONFIG=false；
//!     ESLint 不可用时对 .ts/.tsx 做 strip_types 语法检查。
//!     package.json/deno.json 的 "lint"（include/exclude）用于过滤文件。
//!
//! 主要 API
//!   - lint(allocator, parsed, positional)：入口；
//!     有语法错误时打印到 stderr 并返回 LintFailed。
//!
//! 约定
//!   - 目录与文件列表经 scan 与 io_core；面向用户输出为英文；
//!     与 PACKAGE_DESIGN.md lint 配置对齐。

const std = @import("std");
const builtin = @import("builtin");
const args = @import("args.zig");
const version = @import("version.zig");
const libs_io = @import("libs_io");
const errors = @import("errors");
const libs_process = @import("libs_process");
const manifest = @import("../package/manifest.zig");
const scan = @import("scan.zig");
const strip_types = @import("../transpiler/strip_types.zig");

/// 占位开关：为 true 时 shu lint 仅打印提示并成功返回，不执行下方完整实现；改为 false 可恢复完整 lint。
const LINT_PLACEHOLDER = true;

/// 从 positional 中解析 --md / --markdown，返回是否启用 markdown 检查。
fn parseLintMarkdownFlag(positional: []const []const u8) bool {
    for (positional) |arg| {
        if (std.mem.eql(u8, arg, "--md") or std.mem.eql(u8, arg, "--markdown")) return true;
    }
    return false;
}

/// 执行 shu lint：有 scripts.lint 则用 shell 执行；否则收集 lint_extensions
/// （传 --md/--markdown 时额外检查 .md/.mdc），仅用 ESLint，
/// 不可用时对 .ts/.tsx 做 strip_types。
pub fn lint(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    const io = libs_process.getProcessIo() orelse return error.NoProcessIo;
    try version.printCommandHeader(io, "lint");
    if (LINT_PLACEHOLDER) {
        try printStderr("shu lint: placeholder, full implementation coming soon.\n", .{});
        return;
    }
    _ = parsed;
    const markdown = parseLintMarkdownFlag(positional);
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = libs_io.realpath(".", &cwd_buf) catch {
        try printStderr("shu lint: cannot get current directory\n", .{});
        return error.CwdFailed;
    };
    const cwd_owned = allocator.dupe(u8, cwd) catch return;
    defer allocator.free(cwd_owned);

    var loaded = manifest.Manifest.load(allocator, cwd_owned) catch |e| {
        if (e == error.ManifestNotFound) return runDefaultLint(allocator, cwd_owned, markdown, null);
        return e;
    };
    defer loaded.arena.deinit();
    const m = &loaded.manifest;

    if (m.scripts.get("lint")) |cmd| {
        runScriptInCwd(allocator, cwd_owned, cmd) catch |e| {
            try printStderr("shu lint: script failed\n", .{});
            return e;
        };
        try printToStdout("\n", .{});
        return;
    }

    return runDefaultLint(allocator, cwd_owned, markdown, m.lint_value);
}

/// JS/TS 扩展名（供 ESLint / strip_types 使用；.json/.jsonc 也可由 ESLint 检查）
const js_ts_extensions = [_][]const u8{ ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs" };

/// 判断路径是否被 lint 配置的 exclude 排除（pattern 为子串匹配或含 * 的简单 glob）。
fn pathMatchesExclude(path: []const u8, pattern: []const u8) bool {
    if (std.mem.indexOf(u8, pattern, "*")) |_| {
        if (pattern.len >= 2 and pattern[0] == '*' and pattern[pattern.len - 1] != '*') {
            const suffix = pattern[1..];
            return std.mem.endsWith(u8, path, suffix);
        }
        if (pattern.len >= 2 and pattern[pattern.len - 1] == '*' and pattern[0] != '*') {
            const prefix = pattern[0 .. pattern.len - 1];
            return std.mem.startsWith(u8, path, prefix);
        }
        return std.mem.indexOf(u8, path, pattern) != null;
    }
    return std.mem.indexOf(u8, path, pattern) != null;
}

/// 判断路径是否匹配 lint 配置的 include 某一项（子串或简单 glob）。
fn pathMatchesInclude(path: []const u8, pattern: []const u8) bool {
    if (std.mem.indexOf(u8, pattern, "*")) |_| {
        if (pattern.len >= 2 and pattern[0] == '*' and pattern[pattern.len - 1] != '*') {
            return std.mem.endsWith(u8, path, pattern[1..]);
        }
        if (pattern.len >= 2 and pattern[pattern.len - 1] == '*' and pattern[0] != '*') {
            return std.mem.startsWith(u8, path, pattern[0 .. pattern.len - 1]);
        }
        return std.mem.indexOf(u8, path, pattern) != null;
    }
    return std.mem.indexOf(u8, path, pattern) != null;
}

/// 根据 package.json/deno.json 的 lint 配置（include、exclude）过滤路径列表。
/// lint_value 为 null 或非 object 则返回原 list 的副本（由调用方 free 各 item 并 deinit）。
fn filterPathsByLintConfig(
    allocator: std.mem.Allocator,
    list: std.ArrayList([]const u8),
    lint_value: ?std.json.Value,
) !std.ArrayList([]const u8) {
    var out = std.ArrayList([]const u8).initCapacity(allocator, list.items.len) catch return error.OutOfMemory;
    const lv = lint_value orelse {
        for (list.items) |p| try out.append(allocator, try allocator.dupe(u8, p));
        return out;
    };
    if (lv != .object) {
        for (list.items) |p| try out.append(allocator, try allocator.dupe(u8, p));
        return out;
    }
    const obj = lv.object;
    const exclude_arr = obj.get("exclude");
    const include_arr = obj.get("include");
    for (list.items) |path| {
        if (exclude_arr) |ex| {
            if (ex == .array) {
                var excluded = false;
                for (ex.array.items) |item| {
                    if (item == .string and pathMatchesExclude(path, item.string)) {
                        excluded = true;
                        break;
                    }
                }
                if (excluded) continue;
            }
        }
        if (include_arr) |inc| {
            if (inc == .array and inc.array.items.len > 0) {
                var included = false;
                for (inc.array.items) |item| {
                    if (item == .string and pathMatchesInclude(path, item.string)) {
                        included = true;
                        break;
                    }
                }
                if (!included) continue;
            }
        }
        try out.append(allocator, try allocator.dupe(u8, path));
    }
    return out;
}

/// 默认行为：收集 lint_extensions（暂不含 .zig/.c/.h）；--md 时再收集 .md/.mdc。
/// 若 manifest 存在则用其 lint 配置过滤。JS/TS 仅用 ESLint，
/// 不可用时对 .ts/.tsx 做 strip_types；.md/.mdc 用 markdownlint。
fn runDefaultLint(allocator: std.mem.Allocator, cwd_owned: []const u8, markdown: bool, lint_value: ?std.json.Value) !void {
    const io = libs_process.getProcessIo() orelse return error.NoProcessIo;
    var list = try scan.collectFilesRecursive(allocator, cwd_owned, &scan.lint_extensions, io);
    if (lint_value) |lv| {
        const filtered = try filterPathsByLintConfig(allocator, list, lv);
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
        list = filtered;
    }
    defer {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    }

    var js_ts = std.ArrayList([]const u8).initCapacity(allocator, list.items.len) catch return;
    defer js_ts.deinit(allocator);
    for (list.items) |rel| {
        if (scan.hasExtension(rel, &js_ts_extensions)) {
            js_ts.append(allocator, rel) catch return;
        }
    }

    var md_list = std.ArrayList([]const u8).initCapacity(allocator, 0) catch return;
    defer {
        for (md_list.items) |p| allocator.free(p);
        md_list.deinit(allocator);
    }
    if (markdown) {
        var collected = try scan.collectFilesRecursive(allocator, cwd_owned, &scan.lint_md_extensions, io);
        defer {
            for (collected.items) |p| allocator.free(p);
            collected.deinit(allocator);
        }
        for (collected.items) |p| {
            try md_list.append(allocator, try allocator.dupe(u8, p));
        }
        if (lint_value) |lv| {
            const filtered_md = try filterPathsByLintConfig(allocator, md_list, lv);
            for (md_list.items) |p| allocator.free(p);
            md_list.deinit(allocator);
            md_list = filtered_md;
        }
    }

    if (js_ts.items.len == 0 and md_list.items.len == 0) {
        try printToStdout("\n", .{});
        return;
    }

    var lint_failed = false;
    if (js_ts.items.len > 0) {
        const use_legacy = !hasEslintFlatConfig(cwd_owned) and hasPackageJsonEslintConfig(allocator, cwd_owned);
        const eslint_ok = runEslint(allocator, cwd_owned, js_ts.items, use_legacy);
        if (!eslint_ok) {
            var has_error = false;
            for (js_ts.items) |rel| {
                if (std.mem.endsWith(u8, rel, ".ts") or std.mem.endsWith(u8, rel, ".tsx")) {
                    const abs = try libs_io.pathJoin(allocator, &.{ cwd_owned, rel });
                    defer allocator.free(abs);
                    var f = libs_io.openFileAbsolute(abs, .{}) catch {
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
            if (has_error) lint_failed = true else {
                try printStderr("shu lint: eslint not found or failed. Install eslint (e.g. shu add -D eslint) or add \"lint\" to scripts.\n", .{});
                lint_failed = true;
            }
        }
    }
    if (md_list.items.len > 0 and !runMarkdownLint(allocator, cwd_owned, md_list.items)) {
        lint_failed = true;
    }
    if (lint_failed) return error.LintFailed;
    try printToStdout("\n", .{});
}

/// 检测项目根是否存在 ESLint 9+ 扁平配置文件（eslint.config.js / .mjs / .cjs）。
/// 有则 ESLint 会直接使用，无需环境变量。
fn hasEslintFlatConfig(cwd: []const u8) bool {
    var dir = std.fs.openDirAbsolute(cwd, .{}) catch return false;
    defer dir.close();
    const names = [_][]const u8{ "eslint.config.js", "eslint.config.mjs", "eslint.config.cjs" };
    for (names) |name| {
        var file = dir.openFile(name, .{}) catch continue;
        file.close();
        return true;
    }
    return false;
}

/// 检测 package.json 是否包含 "eslintConfig"（ESLint 旧版配置）。
/// 若有且无扁平配置，需设 ESLINT_USE_FLAT_CONFIG=false 让 ESLint 读取。
fn hasPackageJsonEslintConfig(allocator: std.mem.Allocator, cwd: []const u8) bool {
    const path = libs_io.pathJoin(allocator, &.{ cwd, "package.json" }) catch return false;
    defer allocator.free(path);
    var f = libs_io.openFileAbsolute(path, .{}) catch return false;
    defer f.close();
    const raw = f.readToEndAlloc(allocator, std.math.maxInt(usize)) catch return false;
    defer allocator.free(raw);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{ .allocate = .alloc_always }) catch return false;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return false;
    return root.object.get("eslintConfig") != null;
}

/// 将路径用单引号包起来供 shell 使用，路径内单引号改为 '\''。
fn shellQuotePath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var list = std.ArrayList(u8).initCapacity(allocator, path.len + 4) catch return error.OutOfMemory;
    list.append(allocator, '\'') catch return error.OutOfMemory;
    for (path) |c| {
        if (c == '\'') {
            list.appendSlice(allocator, "'\\''") catch return error.OutOfMemory;
        } else {
            list.append(allocator, c) catch return error.OutOfMemory;
        }
    }
    list.append(allocator, '\'') catch return error.OutOfMemory;
    return list.toOwnedSlice(allocator);
}

/// 返回项目本地 node_modules/.bin/eslint 的绝对路径，若不存在则返回 null。
/// 调用方负责 free 返回的切片。
fn resolveLocalEslintBin(allocator: std.mem.Allocator, cwd: []const u8) ?[]const u8 {
    const bin_name = if (builtin.os.tag == .windows) "eslint.cmd" else "eslint";
    const path = libs_io.pathJoin(allocator, &.{ cwd, "node_modules", ".bin", bin_name }) catch return null;
    var f = libs_io.openFileAbsolute(path, .{}) catch {
        allocator.free(path);
        return null;
    };
    f.close();
    return path;
}

/// 执行 ESLint 做 JS/TS 检查：优先用项目本地 node_modules/.bin/eslint，不存在再用 npx --yes eslint。
/// use_legacy_config 为 true 时通过 shell 设置 ESLINT_USE_FLAT_CONFIG=false，
/// 使 ESLint 9+ 读取 package.json 的 eslintConfig。
/// 成功返回 true，未找到或失败返回 false。
fn runEslint(allocator: std.mem.Allocator, cwd: []const u8, files: []const []const u8, use_legacy_config: bool) bool {
    if (use_legacy_config) {
        // 用 shell 前置环境变量，避免 child.env_map 触发的 incorrect alignment panic
        const local_bin = resolveLocalEslintBin(allocator, cwd);
        if (local_bin) |bin_path| {
            defer allocator.free(bin_path);
            var argv = std.ArrayList([]const u8).initCapacity(allocator, files.len + 1) catch return false;
            defer argv.deinit(allocator);
            argv.append(allocator, bin_path) catch return false;
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
                .exited => |code| code == 0,
                else => false,
            };
        }
        var cmd = std.ArrayList(u8).initCapacity(allocator, 256) catch return false;
        defer cmd.deinit(allocator);
        const prefix = if (builtin.os.tag == .windows)
            "set ESLINT_USE_FLAT_CONFIG=false && npx --yes eslint"
        else
            "ESLINT_USE_FLAT_CONFIG=false npx --yes eslint";
        cmd.appendSlice(allocator, prefix) catch return false;
        for (files) |f| {
            cmd.append(allocator, ' ') catch return false;
            const quoted = shellQuotePath(allocator, f) catch return false;
            defer allocator.free(quoted);
            cmd.appendSlice(allocator, quoted) catch return false;
        }
        const argv_buf: [3][]const u8 = if (builtin.os.tag == .windows)
            .{ "cmd.exe", "/c", cmd.items }
        else
            .{ "/bin/sh", "-c", cmd.items };
        var child = std.process.Child.init(&argv_buf, allocator);
        child.cwd = cwd;
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        child.spawn() catch return false;
        const term = child.wait() catch return false;
        return switch (term) {
            .exited => |code| code == 0,
            else => false,
        };
    }
    const local_bin = resolveLocalEslintBin(allocator, cwd);
    if (local_bin) |bin_path| {
        defer allocator.free(bin_path);
        var argv = std.ArrayList([]const u8).initCapacity(allocator, files.len + 1) catch return false;
        defer argv.deinit(allocator);
        argv.append(allocator, bin_path) catch return false;
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
            .exited => |code| code == 0,
            else => false,
        };
    }
    var argv = std.ArrayList([]const u8).initCapacity(allocator, files.len + 4) catch return false;
    defer argv.deinit(allocator);
    argv.append(allocator, "npx") catch return false;
    argv.append(allocator, "--yes") catch return false;
    argv.append(allocator, "eslint") catch return false;
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
        .exited => |code| code == 0,
        else => false,
    };
}

/// 执行 npx --yes markdownlint-cli <files...> 检查 Markdown；成功返回 true。
/// 未安装时跳过并提示，不判失败。
fn runMarkdownLint(allocator: std.mem.Allocator, cwd: []const u8, files: []const []const u8) bool {
    var argv = std.ArrayList([]const u8).initCapacity(allocator, files.len + 5) catch return true;
    defer argv.deinit(allocator);
    argv.append(allocator, "npx") catch return true;
    argv.append(allocator, "--yes") catch return true;
    argv.append(allocator, "markdownlint-cli") catch return true;
    for (files) |f| {
        argv.append(allocator, f) catch return true;
    }
    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.spawn() catch {
        printStderr("shu lint: markdownlint not found, skipping .md/.mdc (install: npx -y markdownlint-cli)\n", .{}) catch {};
        return true;
    };
    const term = child.wait() catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn runScriptInCwd(allocator: std.mem.Allocator, cwd: []const u8, cmd: []const u8) !void {
    const io = libs_process.getProcessIo() orelse return error.NoProcessIo;
    _ = allocator;
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
    const argv = argv_buf[0..3];
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.ScriptExitedNonZero,
        .signal, .stopped => return error.ScriptSignalled,
        .unknown => return error.ScriptExitedNonZero,
    }
}

fn printToStdout(comptime fmt_str: []const u8, fargs: anytype) !void {
    const io_out = libs_process.getProcessIo() orelse return error.NoProcessIo;
    var buf: [64]u8 = undefined;
    var w = std.Io.File.Writer.init(std.Io.File.stdout(), io_out, &buf);
    try w.interface.print(fmt_str, fargs);
    try w.interface.flush();
}

fn printStderr(comptime fmt_str: []const u8, fargs: anytype) !void {
    const io = libs_process.getProcessIo() orelse return error.NoProcessIo;
    var buf: [256]u8 = undefined;
    var w = std.Io.File.Writer.init(std.Io.File.stderr(), io, &buf);
    try w.interface.print(fmt_str, fargs);
    try w.interface.flush();
}
