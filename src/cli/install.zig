//! shu install 子命令（cli/install.zig）
//!
//! 职责
//!   - shu install（无参数）：按当前目录 package.json / package.jsonc 与 shu.lock 安装依赖到 node_modules；支持 .npmrc registry。
//!   - shu install <specifier>...：将每个说明符写入 manifest 并执行安装；addSpecifiersThenInstall 供 shu add 共用。
//!
//! 主要 API
//!   - install(allocator, parsed, positional)：入口；addSpecifiersThenInstall(allocator, cwd_owned, positional, msg_prefix)：写 manifest 并 install。
//!
//! 参考：docs/PACKAGE_DESIGN.md

const std = @import("std");
const args = @import("args.zig");
const io_core = @import("io_core");
const version = @import("version.zig");
const pkg_install = @import("../package/install.zig");
const manifest = @import("../package/manifest.zig");
const registry = @import("../package/registry.zig");
const resolver = @import("../package/resolver.zig");
const cache = @import("../package/cache.zig");

const REGISTRY_BASE = "https://registry.npmjs.org";

/// 将若干说明符（npm、jsr: 或 https:）写入 manifest 并执行 install；供 shu install <specifier> 与 shu add <specifier> 共用。仅支持 https://，不支持 http://。
/// 若有任一说明符因解析/添加失败被跳过，则不再执行 install，直接返回该错误，避免出现「报错却仍打印 done」的情况。
pub fn addSpecifiersThenInstall(allocator: std.mem.Allocator, cwd_owned: []const u8, positional: []const []const u8, msg_prefix: []const u8) !void {
    var first_skip_error: ?anyerror = null;
    var added_names = std.ArrayList([]const u8).initCapacity(allocator, positional.len) catch return error.OutOfMemory;
    defer {
        for (added_names.items) |n| allocator.free(n);
        added_names.deinit(allocator);
    }
    for (positional) |spec| {
        if (std.mem.startsWith(u8, spec, "http://")) {
            try printToStdout("{s}: http:// not supported, only https:// {s}\n", .{ msg_prefix, spec });
            continue;
        }
        if (std.mem.startsWith(u8, spec, "https://")) {
            const cache_root = cache.getCacheRoot(allocator) catch |e| {
                try printToStdout("{s}: cannot get cache directory\n", .{msg_prefix});
                first_skip_error = first_skip_error orelse e;
                continue;
            };
            defer allocator.free(cache_root);
            const cache_path = cache.urlCachePath(allocator, cache_root, spec) catch |e| {
                first_skip_error = first_skip_error orelse e;
                continue;
            };
            defer allocator.free(cache_path);
            io_core.makePathAbsolute(cache_root) catch {};
            const url_dir = io_core.pathJoin(allocator, &.{ cache_root, "url" }) catch |e| {
                first_skip_error = first_skip_error orelse e;
                continue;
            };
            defer allocator.free(url_dir);
            io_core.makePathAbsolute(url_dir) catch {};
            registry.downloadUrlToPath(allocator, spec, cache_path) catch |e| {
                if (e == error.HttpNotSupported) {}
                try printToStdout("{s}: download failed {s}\n", .{ msg_prefix, spec });
                first_skip_error = first_skip_error orelse e;
                continue;
            };
            manifest.addDenoImport(allocator, cwd_owned, spec, spec) catch {};
            continue;
        }
        if (std.mem.startsWith(u8, spec, "jsr:")) {
            const npm_name = resolver.jsrToNpmSpecifier(allocator, spec) catch |e| {
                try printToStdout("{s}: invalid jsr specifier {s}\n", .{ msg_prefix, spec });
                first_skip_error = first_skip_error orelse e;
                continue;
            };
            defer allocator.free(npm_name);
            const res = registry.resolveVersionAndTarball(allocator, REGISTRY_BASE, npm_name, "latest") catch |e| {
                try printToStdout("{s}: cannot resolve JSR package version {s}\n", .{ msg_prefix, spec });
                first_skip_error = first_skip_error orelse e;
                continue;
            };
            defer allocator.free(res.version);
            defer allocator.free(res.tarball_url);
            const version_range = try std.fmt.allocPrint(allocator, "^{s}", .{res.version});
            defer allocator.free(version_range);
            manifest.addPackageDependency(allocator, cwd_owned, npm_name, version_range) catch |e| {
                if (e == error.ManifestNotFound) {
                    try printToStdout("{s}: package.json not found, cannot add dependency\n", .{msg_prefix});
                }
                first_skip_error = first_skip_error orelse e;
                continue;
            };
            added_names.append(allocator, try allocator.dupe(u8, npm_name)) catch {};
            const jsr_alias = spec["jsr:".len..];
            const import_value = try std.fmt.allocPrint(allocator, "jsr:{s}@{s}", .{ jsr_alias, res.version });
            defer allocator.free(import_value);
            manifest.addDenoImport(allocator, cwd_owned, jsr_alias, import_value) catch {};
        } else {
            var name = spec;
            var version_spec: []const u8 = "latest";
            var last_at: ?usize = null;
            for (spec, 0..) |c, i| {
                if (c == '@') last_at = i;
            }
            if (last_at) |at| {
                if (at > 0) {
                    name = spec[0..at];
                    version_spec = spec[at + 1 ..];
                }
            }
            // 与 Bun 一致：不写 "latest"，先解析出实际最新稳定版再写入 ^版本
            var version_to_write: []const u8 = version_spec;
            var version_owned: ?[]const u8 = null;
            defer if (version_owned) |v| allocator.free(v);
            if (std.mem.eql(u8, version_spec, "latest")) {
                const res = registry.resolveVersionAndTarball(allocator, REGISTRY_BASE, name, "latest") catch |e| {
                    try printToStdout("{s}: cannot resolve latest version for {s}: {s}\n", .{ msg_prefix, name, @errorName(e) });
                    if (e == error.AllRegistriesUnreachable) {
                        try printToStdout("{s}: all registries unreachable; configure a registry in .npmrc\n", .{msg_prefix});
                    } else if (e == error.EmptyRegistryResponse) {
                        try printToStdout("{s}: registry returned empty response; check network or set registry in .npmrc\n", .{msg_prefix});
                    } else if (e == error.UnknownHostName) {
                        try printToStdout("{s}: cannot resolve registry hostname (DNS failed); check network/DNS or set registry in .npmrc\n", .{msg_prefix});
                    } else {
                        try printToStdout("{s}: if network or TLS issue, check network/proxy/certs or set registry in .npmrc\n", .{msg_prefix});
                    }
                    first_skip_error = first_skip_error orelse e;
                    continue;
                };
                defer allocator.free(res.version);
                defer allocator.free(res.tarball_url);
                version_owned = std.fmt.allocPrint(allocator, "^{s}", .{res.version}) catch |e| {
                    try printToStdout("{s}: out of memory\n", .{msg_prefix});
                    first_skip_error = first_skip_error orelse e;
                    continue;
                };
                version_to_write = version_owned.?;
            }
            manifest.addPackageDependency(allocator, cwd_owned, name, version_to_write) catch |e| {
                if (e == error.ManifestNotFound) {
                    try printToStdout("{s}: package.json not found, cannot add dependency\n", .{msg_prefix});
                }
                first_skip_error = first_skip_error orelse e;
                continue;
            };
            added_names.append(allocator, try allocator.dupe(u8, name)) catch {};
        }
    }
    if (first_skip_error) |e| return e;
    const use_color = std.posix.isatty(1);
    if (use_color) {
        try printToStdout("{s}shu install v{s}{s}\n\n", .{ c_cyan, version.VERSION, c_reset });
    } else {
        try printToStdout("shu install v{s}\n\n", .{version.VERSION});
    }
    var progress_state = ProgressState{ .total = 0, .use_color = use_color, .start_time = std.time.milliTimestamp() };
    const reporter = pkg_install.InstallReporter{
        .ctx = &progress_state,
        .onResolving = onResolving,
        .onStart = onInstallStart,
        .onPackage = onInstallPackage,
        .onDone = onInstallDone,
        .onPackageAdded = onPackageAddedPrint,
    };
    pkg_install.install(allocator, cwd_owned, &reporter, added_names.items) catch |e| {
        if (e == error.NoManifest) {}
        try printToStdout("{s}: dependencies written to package.json but install failed (run shu install to retry): {s}\n", .{ msg_prefix, @errorName(e) });
        if (e == error.AllRegistriesUnreachable) {
            try printToStdout("Hint: all registries unreachable; configure a registry in .npmrc\n", .{});
        } else if (e == error.InvalidRegistryResponse or e == error.EmptyRegistryResponse or e == error.RegistryReturnedNonJson) {
            try printToStdout("Hint: check network or set registry in .npmrc\n", .{});
        } else {
            try printToStdout("Hint: if network or TLS issue, check network/proxy/certs or set registry in .npmrc\n", .{});
        }
        return e;
    };
}

/// 执行 shu install [specifier...]
/// - 无参数：按当前目录 package.json（及 shu.lock）安装依赖到 node_modules，未命中缓存则从 registry 下载并写回 lock
/// - 有参数：将每个说明符（npm 包名或 jsr:@scope/name）写入 manifest 后执行一次 install
pub fn install(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8) !void {
    _ = parsed;
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = io_core.realpath(".", &cwd_buf) catch {
        try printToStdout("shu install: cannot get current directory\n", .{});
        return;
    };
    const cwd_owned = allocator.dupe(u8, cwd) catch return;
    defer allocator.free(cwd_owned);
    if (positional.len == 0) {
        const use_color = std.posix.isatty(1);
        if (use_color) {
            try printToStdout("{s}shu install v{s}{s}\n\n", .{ c_cyan, version.VERSION, c_reset });
        } else {
            try printToStdout("shu install v{s}\n\n", .{version.VERSION});
        }
        var progress_state = ProgressState{ .total = 0, .use_color = use_color, .start_time = std.time.milliTimestamp() };
        const reporter = pkg_install.InstallReporter{
            .ctx = &progress_state,
            .onResolving = onResolving,
            .onStart = onInstallStart,
            .onPackage = onInstallPackage,
            .onDone = onInstallDone,
        };
        pkg_install.install(allocator, cwd_owned, &reporter, null) catch |e| {
            if (e == error.NoManifest) {
                try printToStdout("shu install: package.json or package.jsonc not found\n", .{});
                return;
            }
            try printToStdout("shu install: {s}\n", .{@errorName(e)});
            if (e == error.AllRegistriesUnreachable) {
                try printToStdout("Hint: all registries unreachable; configure a registry in .npmrc\n", .{});
                try printToStdout("Create .npmrc in project root or home with: registry=<url>\n", .{});
            } else if (e == error.UnknownHostName) {
                try printToStdout("Hint: cannot resolve registry hostname (DNS failed). If Bun works, run shu in the same terminal as Bun\n", .{});
                try printToStdout("Create .npmrc in project root or home with: registry=<url>\n", .{});
            } else if (e == error.InvalidRegistryResponse or e == error.EmptyRegistryResponse or e == error.RegistryReturnedNonJson) {
                try printToStdout("Hint: registry returned error or empty; check network access to current registry\n", .{});
                try printToStdout("Configure registry in .npmrc in project root or home\n", .{});
            } else {
                try printToStdout("Hint: if network or TLS issue, check network/proxy/certs or set registry in .npmrc\n", .{});
                try printToStdout("Create .npmrc in project root or home with: registry=<url>\n", .{});
            }
            return e;
        };
        return;
    }
    try addSpecifiersThenInstall(allocator, cwd_owned, positional, "shu install");
}

/// 进度条宽度（等分数）
const progress_bar_width = 24;
/// 单行最大宽度，用于用空格覆盖上一次更长输出
const progress_line_width = 80;

// ANSI SGR：仅 TTY 时使用，避免管道/重定向时输出乱码
const c_reset = "\x1b[0m";
const c_dim = "\x1b[2m";
const c_green = "\x1b[32m";
const c_cyan = "\x1b[36m";

/// 进度回调共享状态：总数、是否启用颜色、开始时间（毫秒）、解析阶段是否首次（用于两行刷新）
const ProgressState = struct { total: usize, use_color: bool, start_time: i64, resolving_first: bool = true };

/// ANSI 光标上移 N 行，用于解析阶段两行+一空行的原地更新
const c_cursor_up_3 = "\x1b[3A";
/// ANSI 清除从光标到行末，避免用空格填满整行导致光标跑远
const c_erase_to_eol = "\x1b[K";

/// InstallReporter.onResolving：两行原地更新，上一行「Resolving (本次要解析数) 当前包名...」，下一行进度条用 current/total；TTY 时加颜色
fn onResolving(ctx: ?*anyopaque, name: []const u8, current_in_run: usize, total_to_resolve: usize) void {
    const use_color = if (ctx) |c| @as(*ProgressState, @ptrCast(@alignCast(c))).use_color else false;
    const filled: usize = if (total_to_resolve > 0) (current_in_run * progress_bar_width) / total_to_resolve else 0;

    var line1_buf: [160]u8 = undefined;
    var fbs1 = std.io.fixedBufferStream(&line1_buf);
    const w1 = fbs1.writer();
    if (use_color) w1.print("{s}", .{c_dim}) catch return;
    w1.print("Resolving ({d}) {s}...", .{ total_to_resolve, name }) catch return;
    if (use_color) w1.print("{s}", .{c_reset}) catch return;
    w1.print("{s}", .{c_erase_to_eol}) catch return;
    const line1 = fbs1.getWritten();

    var line2_buf: [80]u8 = undefined;
    var fbs2 = std.io.fixedBufferStream(&line2_buf);
    const w2 = fbs2.writer();
    if (use_color) w2.print("{s}", .{c_cyan}) catch return;
    w2.print("[", .{}) catch return;
    var i: usize = 0;
    while (i < progress_bar_width) : (i += 1) {
        const ch: u8 = if (i < filled) '#' else ' ';
        w2.print("{c}", .{ch}) catch return;
    }
    w2.print("]", .{}) catch return;
    if (use_color) w2.print("{s}", .{c_reset}) catch return;
    w2.print("{s}", .{c_erase_to_eol}) catch return;
    const line2 = fbs2.getWritten();

    var out_buf: [320]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writer(&out_buf);
    const first = if (ctx) |c| blk: {
        const state = @as(*ProgressState, @ptrCast(@alignCast(c)));
        const f = state.resolving_first;
        if (f) state.resolving_first = false;
        break :blk f;
    } else true;
    if (first) {
        stdout_w.interface.print("{s}\n{s}\n\n", .{ line1, line2 }) catch return;
    } else {
        stdout_w.interface.print("\r{s}\r{s}\n{s}\n\n", .{ c_cursor_up_3, line1, line2 }) catch return;
    }
    stdout_w.interface.flush() catch return;
}

/// InstallReporter.onStart：total 为本轮新安装数量；为 0 时不画进度条（already up to date），否则画 0/total
fn onInstallStart(ctx: ?*anyopaque, total: usize) void {
    if (ctx) |c| {
        const state = @as(*ProgressState, @ptrCast(@alignCast(c)));
        state.total = total;
    }
    if (total == 0) return;
    const use_color = if (ctx) |c| @as(*ProgressState, @ptrCast(@alignCast(c))).use_color else false;
    writeProgressBarOnly(use_color, 0, total);
}

/// 仅写进度条行「[###...] current/total」到 stdout，不换行，供底部单行进度条原地更新
fn writeProgressBarOnly(use_color: bool, current: usize, total: usize) void {
    const filled: usize = if (total > 0) (current * progress_bar_width) / total else 0;
    var line_buf: [80]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&line_buf);
    const w = fbs.writer();
    if (use_color) w.print("{s}", .{c_cyan}) catch return;
    w.print("[", .{}) catch return;
    var i: usize = 0;
    while (i < progress_bar_width) : (i += 1) {
        const ch: u8 = if (i < filled) '#' else ' ';
        w.print("{c}", .{ch}) catch return;
    }
    w.print("]", .{}) catch return;
    if (use_color) w.print("{s}", .{c_reset}) catch return;
    if (use_color) {
        w.print("  {s}{d}/{d}{s}{s}", .{ c_dim, current, total, c_reset, c_erase_to_eol }) catch return;
    } else {
        w.print("  {d}/{d}  {s}", .{ current, total, c_erase_to_eol }) catch return;
    }
    const line = fbs.getWritten();
    var out_buf: [96]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writer(&out_buf);
    stdout_w.interface.print("{s}", .{line}) catch return;
    stdout_w.interface.flush() catch return;
}

/// InstallReporter.onPackage：仅在新安装时调用；更新进度条 current/total（total 为本轮新安装数）并可选打印 +name
fn onInstallPackage(ctx: ?*anyopaque, index: usize, total: usize, name: []const u8, ver: []const u8, newly_installed: bool) void {
    const current = index + 1;
    if (total == 0) return;
    const use_color = if (ctx) |c| @as(*ProgressState, @ptrCast(@alignCast(c))).use_color else false;
    var out_buf: [256]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writer(&out_buf);
    stdout_w.interface.print("\r{s}", .{c_erase_to_eol}) catch return;
    if (newly_installed) {
        if (use_color) {
            stdout_w.interface.print("+ {s}{s}@{s}{s}\n", .{ c_green, name, ver, c_reset }) catch return;
        } else {
            stdout_w.interface.print("+ {s}@{s}\n", .{ name, ver }) catch return;
        }
    }
    stdout_w.interface.flush() catch return;
    writeProgressBarOnly(use_color, current, total);
}

/// add 流程下 install 结束后对本次添加的包打印「+ name@version」，即使已是 Already up to date
fn onPackageAddedPrint(ctx: ?*anyopaque, name: []const u8, ver: []const u8) void {
    const use_color = if (ctx) |c| @as(*ProgressState, @ptrCast(@alignCast(c))).use_color else false;
    if (use_color) {
        printToStdout("+ {s}{s}@{s}{s}\n", .{ c_green, name, ver, c_reset }) catch {};
    } else {
        printToStdout("+ {s}@{s}\n", .{ name, ver }) catch {};
    }
}

/// InstallReporter.onDone：换行结束进度条，打 "N new, M total packages" 或 "M packages installed"（无新装时）
fn onInstallDone(ctx: ?*anyopaque, total_count: usize, new_count: usize) void {
    const use_color = if (ctx) |c| @as(*ProgressState, @ptrCast(@alignCast(c))).use_color else false;
    const start_time = if (ctx) |c| @as(*ProgressState, @ptrCast(@alignCast(c))).start_time else std.time.milliTimestamp();
    const elapsed_ms: i64 = std.time.milliTimestamp() - start_time;
    printToStdout("\n\n", .{}) catch {};
    if (new_count == 0) {
        if (use_color) {
            printToStdout("{s}Already up to date ({d} packages){s}\n\n", .{ c_green, total_count, c_reset }) catch {};
        } else {
            printToStdout("Already up to date ({d} packages)\n\n", .{total_count}) catch {};
        }
    } else if (new_count == total_count) {
        if (use_color) {
            printToStdout("{s}{d} packages installed [{d}.00ms]{s}\n\n", .{ c_green, total_count, elapsed_ms, c_reset }) catch {};
        } else {
            printToStdout("{d} packages installed [{d}.00ms]\n\n", .{ total_count, elapsed_ms }) catch {};
        }
    } else {
        if (use_color) {
            printToStdout("{s}{d} new, {d} total packages [{d}.00ms]{s}\n\n", .{ c_green, new_count, total_count, elapsed_ms, c_reset }) catch {};
        } else {
            printToStdout("{d} new, {d} total packages [{d}.00ms]\n\n", .{ new_count, total_count, elapsed_ms }) catch {};
        }
    }
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print(fmt, fargs);
    try w.interface.flush();
}
