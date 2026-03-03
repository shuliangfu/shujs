//! shu fmt 子命令（cli/fmt.zig）
//!
//! 职责
//!   - 有 scripts.fmt 时：用 shell 执行该脚本。
//!   - 无 script 时：若传入 positional 则只扫描这些路径，否则递归收集
//!     （含 .zig，暂不含 .c/.h）；若存在 fmt 配置则按 include/exclude 过滤。
//!     JS/TS/JSON/MD 仅用 npx prettier；.zig 用 zig fmt。
//!
//! 主要 API
//!   - fmt(allocator, parsed, positional)：入口；
//!     无可用 formatter 时给出英文提示并返回错误。
//!
//! 约定
//!   - 目录与文件列表经 scan 与 io_core；面向用户输出为英文；
//!     与 PACKAGE_DESIGN.md fmt 配置对齐。

const std = @import("std");
const builtin = @import("builtin");
const args = @import("args.zig");
const version = @import("version.zig");
const io_core = @import("io_core");
const manifest = @import("../package/manifest.zig");
const scan = @import("scan.zig");

/// 执行 shu fmt：有 scripts.fmt 则用 shell 执行；否则若有 positional 则只扫描指定文件/目录，
/// 无则全局扫描 fmt_extensions。
pub fn fmt(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = parsed;
    try version.printCommandHeader("fmt");
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = io_core.realpath(".", &cwd_buf) catch {
        try printStderr("shu fmt: cannot get current directory\n", .{});
        return error.CwdFailed;
    };
    const cwd_owned = allocator.dupe(u8, cwd) catch return;
    defer allocator.free(cwd_owned);

    var loaded = manifest.Manifest.load(allocator, cwd_owned) catch |e| {
        if (e == error.ManifestNotFound) return runDefaultFmt(allocator, cwd_owned, positional, null);
        return e;
    };
    defer loaded.arena.deinit();
    const m = &loaded.manifest;

    if (m.scripts.get("fmt")) |cmd| {
        runScriptInCwd(allocator, cwd_owned, cmd) catch |e| {
            try printStderr("shu fmt: script failed\n", .{});
            return e;
        };
        try printToStdout("\n", .{});
        return;
    }

    return runDefaultFmt(allocator, cwd_owned, positional, m.fmt_value);
}

/// Prettier 处理的扩展名（JS/TS/JSON/MD）
const prettier_extensions = [_][]const u8{ ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".json", ".jsonc", ".md", ".mdc" };
/// zig fmt 处理的扩展名
const zig_fmt_extensions = [_][]const u8{".zig"};

/// 判断路径是否被 fmt 配置的 exclude 排除（pattern 为子串或含 * 的简单 glob）。
fn pathMatchesFmtExclude(path: []const u8, pattern: []const u8) bool {
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

/// 判断路径是否匹配 fmt 配置的 include 某一项（子串或简单 glob）。
fn pathMatchesFmtInclude(path: []const u8, pattern: []const u8) bool {
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

/// 根据 package.json/deno.json 的 fmt 配置（include、exclude）过滤路径列表。
/// fmt_value 为 null 或非 object 则不过滤，返回原 list 的副本（由调用方 free 并 deinit）。
fn filterPathsByFmtConfig(
    allocator: std.mem.Allocator,
    list: std.ArrayList([]const u8),
    fmt_value: ?std.json.Value,
) !std.ArrayList([]const u8) {
    var out = std.ArrayList([]const u8).initCapacity(allocator, list.items.len) catch return error.OutOfMemory;
    const fv = fmt_value orelse {
        for (list.items) |p| try out.append(allocator, try allocator.dupe(u8, p));
        return out;
    };
    if (fv != .object) {
        for (list.items) |p| try out.append(allocator, try allocator.dupe(u8, p));
        return out;
    }
    const obj = fv.object;
    const exclude_arr = obj.get("exclude");
    const include_arr = obj.get("include");
    for (list.items) |path| {
        if (exclude_arr) |ex| {
            if (ex == .array) {
                var excluded = false;
                for (ex.array.items) |item| {
                    if (item == .string and pathMatchesFmtExclude(path, item.string)) {
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
                    if (item == .string and pathMatchesFmtInclude(path, item.string)) {
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

/// 默认行为：若有 positional 则只扫描指定文件/目录，无则递归收集（不含 .c/.h）。
/// 若 manifest 存在则用其 fmt 配置过滤。JS/TS/JSON/MD 仅用 Prettier；.zig 用 zig fmt。
fn runDefaultFmt(allocator: std.mem.Allocator, cwd_owned: []const u8, positional: []const []const u8, fmt_value: ?std.json.Value) !void {
    var list = if (positional.len > 0)
        try collectFilesFromPositional(allocator, cwd_owned, positional)
    else
        try scan.collectFilesRecursive(allocator, cwd_owned, &scan.fmt_extensions);
    if (fmt_value) |fv| {
        const filtered = try filterPathsByFmtConfig(allocator, list, fv);
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
        list = filtered;
    }
    defer {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    }
    if (list.items.len == 0) {
        try printToStdout("\n", .{});
        return;
    }

    var prettier_list = std.ArrayList([]const u8).initCapacity(allocator, list.items.len) catch return;
    defer prettier_list.deinit(allocator);
    var zig_files = std.ArrayList([]const u8).initCapacity(allocator, list.items.len) catch return;
    defer zig_files.deinit(allocator);
    for (list.items) |path| {
        if (scan.hasExtension(path, &prettier_extensions)) {
            prettier_list.append(allocator, path) catch return;
        } else if (scan.hasExtension(path, &zig_fmt_extensions)) {
            zig_files.append(allocator, path) catch return;
        }
    }

    var any_failed = false;
    if (prettier_list.items.len > 0) {
        const prettier_ok = runPrettierFmt(allocator, cwd_owned, prettier_list.items);
        if (!prettier_ok) {
            try printStderr("shu fmt: JS/TS/JSON/MD formatting failed (npx prettier not found or failed). Install Prettier or add \"fmt\" to scripts.\n", .{});
            any_failed = true;
        }
    }
    if (zig_files.items.len > 0 and !runZigFmt(allocator, cwd_owned, zig_files.items)) {
        printStderr("shu fmt: zig not found or zig fmt failed, skipping .zig files\n", .{}) catch {};
    }
    if (any_failed) return error.NoFmtScript;
    try printToStdout("\n", .{});
}

/// 根据 positional 收集要格式化的文件：目录则递归收集 fmt_extensions，
/// 文件则仅当扩展名匹配时加入；路径相对 cwd 解析为绝对。
fn collectFilesFromPositional(allocator: std.mem.Allocator, cwd_owned: []const u8, positional: []const []const u8) !std.ArrayList([]const u8) {
    var list = try std.ArrayList([]const u8).initCapacity(allocator, 32);
    for (positional) |path| {
        const path_abs = if (io_core.pathIsAbsolute(path))
            try allocator.dupe(u8, path)
        else
            try io_core.pathJoin(allocator, &.{ cwd_owned, path });
        defer allocator.free(path_abs);

        var dir = io_core.openDirAbsolute(path_abs, .{ .iterate = true }) catch {
            if (scan.hasExtension(path_abs, &scan.fmt_extensions)) {
                try list.append(allocator, try allocator.dupe(u8, path_abs));
            }
            continue;
        };
        defer dir.close();
        var sub = try scan.collectFilesRecursive(allocator, path_abs, &scan.fmt_extensions);
        defer {
            for (sub.items) |p| allocator.free(p);
            sub.deinit(allocator);
        }
        for (sub.items) |rel| {
            try list.append(allocator, try io_core.pathJoin(allocator, &.{ path_abs, rel }));
        }
    }
    return list;
}

/// 执行 npx --yes prettier --write <files...>；成功返回 true，未找到或失败返回 false。
/// 仅将「有变更」的文件行打印到 stdout（过滤掉 Prettier 输出的 "(unchanged)" 行）。
/// （--yes 避免交互安装，fmt 不需额外权限。）退出码 0 与 1 均视为成功。
fn runPrettierFmt(allocator: std.mem.Allocator, cwd: []const u8, files: []const []const u8) bool {
    var argv = std.ArrayList([]const u8).initCapacity(allocator, files.len + 5) catch return false;
    defer argv.deinit(allocator);
    argv.append(allocator, "npx") catch return false;
    argv.append(allocator, "--yes") catch return false;
    argv.append(allocator, "prettier") catch return false;
    argv.append(allocator, "--write") catch return false;
    for (files) |f| {
        argv.append(allocator, f) catch return false;
    }
    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    child.spawn() catch return false;
    const stdout = child.stdout orelse {
        _ = child.wait() catch {};
        return false;
    };
    var buf: [4096]u8 = undefined;
    var out = std.ArrayList(u8).initCapacity(allocator, 4096) catch {
        _ = child.wait() catch {};
        return false;
    };
    defer out.deinit(allocator);
    while (stdout.read(buf[0..])) |n| {
        if (n == 0) break;
        out.appendSlice(allocator, buf[0..n]) catch break;
    } else |_| {}
    // 不在此 close stdout，由 child.wait() 内部 cleanupStreams() 统一关闭，否则会 BADF
    const term = child.wait() catch return false;
    const ok = switch (term) {
        .Exited => |code| code == 0 or code == 1,
        else => false,
    };
    // 只输出「有变更」的行（Prettier 对未修改文件会输出 "(unchanged)"），路径与时间分色
    const use_color = std.posix.isatty(1);
    var it = std.mem.splitScalar(u8, out.items, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (trimmed.len > 0 and std.mem.indexOf(u8, trimmed, "(unchanged)") == null) {
            printFmtChangedLine(trimmed, use_color) catch {};
        }
    }
    return ok;
}

/// 执行 zig fmt <files...>；成功返回 true，未找到 zig 或失败返回 false。退出码 0/1 均视为成功。
fn runZigFmt(allocator: std.mem.Allocator, cwd: []const u8, files: []const []const u8) bool {
    var argv = std.ArrayList([]const u8).initCapacity(allocator, files.len + 2) catch return false;
    defer argv.deinit(allocator);
    argv.append(allocator, "zig") catch return false;
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
        .Exited => |code| code == 0 or code == 1,
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

/// Prettier 单行格式为 "path time"（如 examples/fetch-test.js 2ms），路径与时间分色输出；非 TTY 则原样输出。
fn printFmtChangedLine(line: []const u8, use_color: bool) !void {
    const path_color = "\x1b[36m"; // cyan
    const time_color = "\x1b[2m"; // dim
    const reset = "\x1b[0m";
    var buf: [512]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const last_space = std.mem.lastIndexOfScalar(u8, line, ' ');
    if (use_color and last_space != null) {
        const path = line[0..last_space.?];
        const time = line[last_space.? + 1 ..];
        try w.interface.print("{s}{s}{s} {s}{s}{s}\n", .{ path_color, path, reset, time_color, time, reset });
    } else {
        try w.interface.print("{s}\n", .{line});
    }
    try w.interface.flush();
}

fn printToStdout(comptime fmt_str: []const u8, fargs: anytype) !void {
    var buf: [64]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt_str, fargs);
    try w.interface.flush();
}

fn printStderr(comptime fmt_str: []const u8, fargs: anytype) !void {
    var buf: [256]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    try w.interface.print(fmt_str, fargs);
    try w.interface.flush();
}
