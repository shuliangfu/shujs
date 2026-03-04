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
const libs_io = @import("libs_io");
const version = @import("version.zig");
const pkg_install = @import("../package/install.zig");
const manifest = @import("../package/manifest.zig");
const registry = @import("../package/registry.zig");
const resolver = @import("../package/resolver.zig");
const cache = @import("../package/cache.zig");

const REGISTRY_BASE = "https://registry.npmjs.org";
const jsr = @import("../package/jsr.zig");

/// 将若干说明符（npm、jsr: 或 https:）写入 manifest 并执行 install；供 shu install <specifier> 与 shu add <specifier> 共用。仅支持 https://，不支持 http://。
/// dev 为 true 时（-D/--dev）将 npm 包写入 devDependencies，否则写入 dependencies。
/// io 为 Zig 0.16 std.Io，用于 stdout 输出。
pub fn addSpecifiersThenInstall(allocator: std.mem.Allocator, cwd_owned: []const u8, positional: []const []const u8, msg_prefix: []const u8, dev: bool, io: std.Io) !void {
    var first_skip_error: ?anyerror = null;
    var added_names = std.ArrayList([]const u8).initCapacity(allocator, positional.len) catch return error.OutOfMemory;
    defer {
        for (added_names.items) |n| allocator.free(n);
        added_names.deinit(allocator);
    }
    const has_deno = manifest.hasDenoJsonInDir(cwd_owned);
    for (positional) |spec| {
        if (std.mem.startsWith(u8, spec, "http://")) {
            try printToStdout(io, "{s}: http:// not supported, only https:// {s}\n", .{ msg_prefix, spec });
            continue;
        }
        if (std.mem.startsWith(u8, spec, "https://")) {
            const cache_root = cache.getCacheRoot(allocator) catch |e| {
                try printToStdout(io, "{s}: cannot get cache directory\n", .{msg_prefix});
                first_skip_error = first_skip_error orelse e;
                continue;
            };
            defer allocator.free(cache_root);
            const cache_path = cache.urlCachePath(allocator, cache_root, spec) catch |e| {
                first_skip_error = first_skip_error orelse e;
                continue;
            };
            defer allocator.free(cache_path);
            libs_io.makePathAbsolute(cache_root) catch {};
            const url_dir = libs_io.pathJoin(allocator, &.{ cache_root, "url" }) catch |e| {
                first_skip_error = first_skip_error orelse e;
                continue;
            };
            defer allocator.free(url_dir);
            libs_io.makePathAbsolute(url_dir) catch {};
            registry.downloadUrlToPath(allocator, spec, cache_path) catch |e| {
                if (e == error.HttpNotSupported) {}
                try printToStdout(io, "{s}: download failed {s}\n", .{ msg_prefix, spec });
                first_skip_error = first_skip_error orelse e;
                continue;
            };
            if (has_deno) manifest.addDenoImport(allocator, cwd_owned, spec, spec) catch {};
            continue;
        }
        if (std.mem.startsWith(u8, spec, "jsr:")) {
            const jsr_alias = resolver.jsrSpecToScopeName(allocator, spec) catch |e| {
                try printToStdout(io, "{s}: invalid jsr specifier {s}\n", .{ msg_prefix, spec });
                first_skip_error = first_skip_error orelse e;
                continue;
            };
            defer allocator.free(jsr_alias);
            const resolved_ver = jsr.resolveVersionFromMeta(allocator, spec) catch |e| {
                try printToStdout(io, "{s}: cannot resolve JSR package version {s}: {s}\n", .{ msg_prefix, spec, @errorName(e) });
                first_skip_error = first_skip_error orelse e;
                continue;
            };
            defer allocator.free(resolved_ver);
            const import_value = try std.fmt.allocPrint(allocator, "jsr:{s}@^{s}", .{ jsr_alias, resolved_ver });
            defer allocator.free(import_value);
            // JSR 与 npm 一致：写入 ^ 版本范围，格式 "@scope/name" -> "jsr:@scope/name@^1.1.2"
            if (has_deno) {
                manifest.addDenoImport(allocator, cwd_owned, jsr_alias, import_value) catch |e| {
                    first_skip_error = first_skip_error orelse e;
                    continue;
                };
            } else {
                manifest.addPackageImport(allocator, cwd_owned, jsr_alias, import_value) catch |e| {
                    if (e == error.ManifestNotFound) {
                        try printToStdout(io, "{s}: no manifest (package.json or deno.json); use shu add in a project with manifest\n", .{msg_prefix});
                    }
                    first_skip_error = first_skip_error orelse e;
                    continue;
                };
                try printToStdout(io, "{s}: added {s} to imports in package.json\n", .{ msg_prefix, jsr_alias });
            }
            added_names.append(allocator, try allocator.dupe(u8, jsr_alias)) catch {};
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
                const res = registry.resolveVersionAndTarball(allocator, REGISTRY_BASE, name, "latest", null) catch |e| {
                    try printToStdout(io, "{s}: cannot resolve latest version for {s}: {s}\n", .{ msg_prefix, name, @errorName(e) });
                    if (e == error.AllRegistriesUnreachable) {
                        try printToStdout(io, "{s}: all registries unreachable; configure a registry in .npmrc\n", .{msg_prefix});
                    } else if (e == error.EmptyRegistryResponse) {
                        try printToStdout(io, "{s}: registry returned empty response; check network or set registry in .npmrc\n", .{msg_prefix});
                    } else if (e == error.UnknownHostName) {
                        try printToStdout(io, "{s}: cannot resolve registry hostname (DNS failed); check network/DNS or set registry in .npmrc\n", .{msg_prefix});
                    } else {
                        try printToStdout(io, "{s}: if network or TLS issue, check network/proxy/certs or set registry in .npmrc\n", .{msg_prefix});
                    }
                    first_skip_error = first_skip_error orelse e;
                    continue;
                };
                defer allocator.free(res.version);
                defer allocator.free(res.tarball_url);
                version_owned = std.fmt.allocPrint(allocator, "^{s}", .{res.version}) catch |e| {
                    try printToStdout(io, "{s}: out of memory\n", .{msg_prefix});
                    first_skip_error = first_skip_error orelse e;
                    continue;
                };
                version_to_write = version_owned.?;
            }
            if (has_deno) {
                const npm_import_value = try std.fmt.allocPrint(allocator, "npm:{s}@{s}", .{ name, version_to_write });
                defer allocator.free(npm_import_value);
                manifest.addDenoImport(allocator, cwd_owned, name, npm_import_value) catch |e| {
                    first_skip_error = first_skip_error orelse e;
                    continue;
                };
            } else {
                manifest.addPackageDependency(allocator, cwd_owned, name, version_to_write, dev) catch |e| {
                    if (e == error.ManifestNotFound) {
                        try printToStdout(io, "{s}: no manifest (package.json or deno.json); use shu add in a project with manifest\n", .{msg_prefix});
                    }
                    first_skip_error = first_skip_error orelse e;
                    continue;
                };
            }
            added_names.append(allocator, try allocator.dupe(u8, name)) catch {};
        }
    }
    if (first_skip_error) |e| return e;
    const use_color = std.c.isatty(1) != 0;
    // add 已在 add.zig 打印 "shu add v..."，此处仅 install 带 specifier 时打印
    if (std.mem.eql(u8, msg_prefix, "shu install")) try version.printCommandHeader(io, "install");
    var progress_state = ProgressState{ .total = 0, .use_color = use_color, .start_time = std.Io.Clock.now(.awake, io).toMilliseconds(), .io = io };
    const reporter = pkg_install.InstallReporter{
        .ctx = &progress_state,
        .onResolving = onResolving,
        .onResolvingComplete = onResolvingComplete,
        .onResolveFailure = onResolveFailure,
        .onStart = onInstallStart,
        .onProgress = onInstallProgress,
        .onPackage = onInstallPackage,
        .onDone = onInstallDone,
        .resolving_elapsed_ms = &progress_state.resolving_elapsed_ms,
        .installing_elapsed_ms = &progress_state.installing_elapsed_ms,
        .onPackageAdded = onPackageAddedPrint,
    };
    pkg_install.install(allocator, cwd_owned, &reporter, added_names.items, null) catch |e| {
        if (e == error.NoManifest) {}
        try printToStdout(io, "{s}: dependencies written to manifest but install failed (run shu install to retry): {s}\n", .{ msg_prefix, @errorName(e) });
        if (e == error.AllRegistriesUnreachable) {
            try printToStdout(io, "Hint: all registries unreachable; configure a registry in .npmrc\n", .{});
        } else if (e == error.InvalidRegistryResponse or e == error.EmptyRegistryResponse or e == error.RegistryReturnedNonJson) {
            try printToStdout(io, "Hint: check network or set registry in .npmrc\n", .{});
        } else {
            try printToStdout(io, "Hint: if network or TLS issue, check network/proxy/certs or set registry in .npmrc\n", .{});
        }
        return e;
    };
}

/// 执行 shu install [specifier...]
/// - 无参数：按当前目录 package.json（及 shu.lock）安装依赖到 node_modules，未命中缓存则从 registry 下载并写回 lock
/// - 有参数：将每个说明符（npm 包名或 jsr:@scope/name）写入 manifest 后执行一次 install
pub fn install(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8, io: std.Io) !void {
    _ = parsed;
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = libs_io.realpath(".", &cwd_buf) catch {
        try printToStdout(io, "shu install: cannot get current directory\n", .{});
        return;
    };
    const cwd_owned = allocator.dupe(u8, cwd) catch return;
    defer allocator.free(cwd_owned);
    if (positional.len == 0) {
        const use_color = std.c.isatty(1) != 0;
        try version.printCommandHeader(io, "install");
        var progress_state = ProgressState{ .total = 0, .use_color = use_color, .start_time = std.Io.Clock.now(.awake, io).toMilliseconds(), .io = io };
        const reporter = pkg_install.InstallReporter{
            .ctx = &progress_state,
            .onResolving = onResolving,
            .onResolvingComplete = onResolvingComplete,
            .onResolveFailure = onResolveFailure,
            .onStart = onInstallStart,
            .onProgress = onInstallProgress,
            .onPackage = onInstallPackage,
            .onDone = onInstallDone,
            .resolving_elapsed_ms = &progress_state.resolving_elapsed_ms,
            .installing_elapsed_ms = &progress_state.installing_elapsed_ms,
        };
        var error_detail: pkg_install.InstallErrorDetail = .{};
        pkg_install.install(allocator, cwd_owned, &reporter, null, &error_detail) catch |e| {
            if (e == error.NoManifest) {
                try printToStdout(io, "\nshu install: no manifest (package.json or deno.json) in current directory\n", .{});
                return;
            }
            if (e == error.VersionNotFound and error_detail.name != null and error_detail.version != null) {
                try printToStdout(io, "\nshu install: VersionNotFound ({s}@{s})\n", .{ error_detail.name.?, error_detail.version.? });
            } else {
                try printToStdout(io, "\nshu install: {s}\n", .{@errorName(e)});
            }
            defer {
                if (error_detail.name) |n| allocator.free(n);
                if (error_detail.version) |v| allocator.free(v);
            }
            if (e == error.AllRegistriesUnreachable) {
                try printToStdout(io, "Hint: all registries unreachable; configure a registry in .npmrc\n", .{});
                try printToStdout(io, "Create .npmrc in project root or home with: registry=<url>\n", .{});
            } else if (e == error.UnknownHostName) {
                try printToStdout(io, "Hint: cannot resolve registry hostname (DNS failed). If Bun works, run shu in the same terminal as Bun\n", .{});
                try printToStdout(io, "Create .npmrc in project root or home with: registry=<url>\n", .{});
            } else if (e == error.InvalidRegistryResponse or e == error.EmptyRegistryResponse or e == error.RegistryReturnedNonJson) {
                try printToStdout(io, "Hint: registry returned error or empty; check network access to current registry\n", .{});
                try printToStdout(io, "Configure registry in .npmrc in project root or home\n", .{});
            } else if (e == error.JsrMetaNoJsonObject or e == error.JsrMetaEmptyResponse) {
                try printToStdout(io, "Hint: JSR meta response was not JSON or empty. Set SHU_DEBUG_HTTP=1 to log failing URL and body\n", .{});
            } else if (e == error.ResponseTooLarge) {
                try printToStdout(io, "Hint: response exceeded size limit. Run './zig-out/bin/shu install' to use the binary you just built (registry/JSR/default limit is 2GB).\n", .{});
            } else if (e == error.ConnectionResetByPeer or e == error.BrokenPipe or e == error.ConnectionRefused) {
                try printToStdout(io, "Hint: connection lost or refused (network/server). Retry or check proxy; set SHU_DEBUG_HTTP=1 to see failing URL.\n", .{});
            } else if (e == error.ReadFailed) {
                try printToStdout(io, "Hint: HTTP read failed (e.g. connection closed during body). Last URL is logged above as [shu http] read failed url=... Set SHU_DEBUG_HTTP=1 if not visible. Retry 'shu install' (transient JSR/npm issues often succeed on retry).\n", .{});
            } else if (e == error.TarballExtractFailed) {
                try printToStdout(io, "Hint: tgz extract failed. Set SHU_DEBUG_TGZ=1 to see failing step (open_dest_dir/create_file) and path. If many (extract): ReadFailed, clear cache: rm -rf \"$SHU_CACHE/content\" or ~/.shu/cache/content\n", .{});
            } else if (e == error.AccessDenied and @import("builtin").os.tag == .windows) {
                try printToStdout(io, "Hint: symlink creation failed on Windows. Enable Developer Mode (Settings > Privacy & security > For developers) or run as Administrator.\n", .{});
            } else if (e == error.VersionNotFound) {
                try printToStdout(io, "Hint: the requested version is not in registry (exact match). Check lockfile/manifest or try another registry in .npmrc.\n", .{});
                try printToStdout(io, "Create .npmrc in project root or home with: registry=<url>\n", .{});
            } else {
                try printToStdout(io, "Hint: if network or TLS issue, check network/proxy/certs or set registry in .npmrc. Set SHU_DEBUG_HTTP=1 to see request URLs.\n", .{});
                try printToStdout(io, "Create .npmrc in project root or home with: registry=<url>\n", .{});
            }
            return e;
        };
        return;
    }
    // 仅 add/install 识别 --dev/-D，从 positionals 中剥离后得到说明符列表
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
        try printToStdout(io, "shu install: no specifiers given (use -D/--dev before package names to add as devDependencies)\n", .{});
        return;
    }
    try addSpecifiersThenInstall(allocator, cwd_owned, specifiers.items, "shu install", dev, io);
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

/// 进度回调共享状态：总数、是否启用颜色、开始时间（毫秒）、解析/安装阶段是否首次、第二遍是否已打过换行；io 用于 Zig 0.16 stdout。
const ProgressState = struct {
    total: usize,
    use_color: bool,
    start_time: i64,
    io: std.Io,
    resolving_first: bool = true,
    installing_first: bool = true,
    install_done_newline: bool = false,
    /// 解析阶段耗时（ms），由 install 写入；-1 表示未设置
    resolving_elapsed_ms: i64 = -1,
    /// 安装阶段耗时（ms），由 install 写入；-1 表示未设置
    installing_elapsed_ms: i64 = -1,
};

/// ANSI 清除从光标到行末，避免上次内容残留
const c_erase_to_eol = "\x1b[K";
/// 光标上移 1 行，Resolving 两行刷新时用
const c_cursor_up_1 = "\x1b[1A";
/// 光标上移 2 行，Installing 两行刷新时用（当前在第二行末尾，需回到第一行重写两行）
const c_cursor_up_2 = "\x1b[2A";

/// 环境变量 SHU_NO_PROGRESS 非空时关闭进度条，便于调试时看清 [shu install] failed 等 stderr 诊断。
fn progressDisabled() bool {
    return std.c.getenv("SHU_NO_PROGRESS") != null;
}

/// 解析阶段两行进度绘制（进度条 + Resolving (N) name）；first 首次为 true 时输出换行+两行，否则 \x1b[1A 上移一行再重写，调用后 *first 置 false。
fn drawResolvingTwoLines(io: std.Io, current: usize, total: usize, name: []const u8, use_color: bool, first: *bool) void {
    const filled: usize = if (total > 0) (current * progress_bar_width) / total else 0;
    var line1_buf: [80]u8 = undefined;
    var w1 = std.Io.Writer.fixed(&line1_buf);
    if (use_color) w1.print("{s}", .{c_cyan}) catch return;
    w1.print("[", .{}) catch return;
    var i: usize = 0;
    while (i < progress_bar_width) : (i += 1) {
        const ch: u8 = if (i < filled) '#' else ' ';
        w1.print("{c}", .{ch}) catch return;
    }
    w1.print("] {d}/{d} {s}", .{ current, total, c_erase_to_eol }) catch return;
    if (use_color) w1.print("{s}", .{c_reset}) catch return;
    var line2_buf: [160]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&line2_buf);
    if (use_color) w2.print("{s}", .{c_dim}) catch return;
    w2.print("Resolving ({d}) {s}...{s}", .{ total, name, c_erase_to_eol }) catch return;
    if (use_color) w2.print("{s}", .{c_reset}) catch return;
    var out_buf: [280]u8 = undefined;
    var stdout_w = std.Io.File.Writer.init(std.Io.File.stdout(), io, &out_buf);
    if (first.*) {
        first.* = false;
        stdout_w.interface.print("\n{s}\n{s}", .{ std.Io.Writer.buffered(&w1), std.Io.Writer.buffered(&w2) }) catch return;
    } else {
        stdout_w.interface.print("{s}\r{s}\n{s}", .{ c_cursor_up_1, std.Io.Writer.buffered(&w1), std.Io.Writer.buffered(&w2) }) catch return;
    }
    stdout_w.flush() catch return;
}

/// 解析阶段某个包失败时在写 stderr 前调用：换行并刷新 stdout，使进度行「定稿」，后续 stderr 错误信息不会被进度条覆盖。SHU_NO_PROGRESS 时也换行，避免错误信息跟在 \r 行后挤在一起。
fn onResolveFailure(ctx: ?*anyopaque) void {
    _ = ctx;
    _ = std.c.write(1, "\n".ptr, 1);
}

/// InstallReporter.onResolvingComplete：仅当本轮曾输出过 onResolving 时调用；在「Resolving (N) name」下输出 Resolving X ms（带颜色时标签 cyan、耗时 dim），再空一行后进入 Installing。
fn onResolvingComplete(ctx: ?*anyopaque, resolving_elapsed_ms: i64) void {
    const state = if (ctx) |c| @as(*ProgressState, @ptrCast(@alignCast(c))) else return;
    if (resolving_elapsed_ms >= 0) {
        if (state.use_color) {
            printToStdout(state.io, "\n{s}Resolving{s} {d} ms{s}\n", .{ c_cyan, c_dim, resolving_elapsed_ms, c_reset }) catch return;
        } else {
            printToStdout(state.io, "\nResolving {d} ms\n", .{resolving_elapsed_ms}) catch return;
        }
    } else {
        printToStdout(state.io, "\n", .{}) catch return;
    }
}

/// InstallReporter.onResolving：有进度条时两行原地更新，进度条在上、Resolving (N) name 在下；SHU_NO_PROGRESS 时每包一行「Resolving (N) name...」。
fn onResolving(ctx: ?*anyopaque, name: []const u8, current_in_run: usize, total_to_resolve: usize) void {
    if (progressDisabled()) {
        var buf: [256]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.print("Resolving ({d}) {s}...\n", .{ total_to_resolve, name }) catch return;
        const s = std.Io.Writer.buffered(&w);
        _ = std.c.write(1, s.ptr, s.len);
        return;
    }
    const state = if (ctx) |c| @as(*ProgressState, @ptrCast(@alignCast(c))) else return;
    drawResolvingTwoLines(state.io, current_in_run, total_to_resolve, name, state.use_color, &state.resolving_first);
}

/// 安装阶段第二行包名最大显示长度，避免终端折行
const install_line_name_max = 48;

/// InstallReporter.onProgress：两行（进度条上、Installing 下）。onInstallStart 已输出两行，这里始终用 \x1b[1A 上移一行再重写两行，不再额外换行，避免出现四行。
fn onInstallProgress(ctx: ?*anyopaque, current: usize, total: usize, last_completed_name: ?[]const u8) void {
    if (progressDisabled() or total == 0) return;
    const use_color = if (ctx) |c| @as(*ProgressState, @ptrCast(@alignCast(c))).use_color else false;

    // 第一行：进度条 [###...] current/total（与 onResolving 一致）
    const filled: usize = if (total > 0) (current * progress_bar_width) / total else 0;
    var line1_buf: [80]u8 = undefined;
    var w1 = std.Io.Writer.fixed(&line1_buf);
    if (use_color) w1.print("{s}", .{c_cyan}) catch return;
    w1.print("[", .{}) catch return;
    var i: usize = 0;
    while (i < progress_bar_width) : (i += 1) {
        const ch: u8 = if (i < filled) '#' else ' ';
        w1.print("{c}", .{ch}) catch return;
    }
    w1.print("] {d}/{d} {s}", .{ current, total, c_erase_to_eol }) catch return;
    if (use_color) w1.print("{s}", .{c_reset}) catch return;
    const line1 = std.Io.Writer.buffered(&w1);

    // 第二行：Installing (current/total) name... 或 packages...（与 onResolving 第二行一致）
    var line2_buf: [120]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&line2_buf);
    if (use_color) w2.print("{s}", .{c_dim}) catch return;
    if (last_completed_name) |name| {
        const n = @min(name.len, install_line_name_max);
        if (n > 0) {
            w2.print("Installing ({d}/{d}) {s}...{s}", .{ current, total, name[0..n], c_erase_to_eol }) catch return;
        } else {
            w2.print("Installing ({d}/{d}) packages...{s}", .{ current, total, c_erase_to_eol }) catch return;
        }
    } else {
        w2.print("Installing ({d}/{d}) packages...{s}", .{ current, total, c_erase_to_eol }) catch return;
    }
    if (use_color) w2.print("{s}", .{c_reset}) catch return;
    const line2 = std.Io.Writer.buffered(&w2);

    var out_buf: [220]u8 = undefined;
    const io = if (ctx) |c| @as(*ProgressState, @ptrCast(@alignCast(c))).io else return;
    var stdout_w = std.Io.File.Writer.init(std.Io.File.stdout(), io, &out_buf);
    // onInstallStart 已画好两行，这里只上移一行再重写两行，不再额外 \n，避免变成四行
    stdout_w.interface.print("{s}\r{s}\n{s}", .{ c_cursor_up_1, line1, line2 }) catch return;
    stdout_w.flush() catch return;
}

/// InstallReporter.onStart：新起一行后输出两行（进度条 0/total、Installing (0/total) packages...），后续 onInstallProgress 用 \x1b[1A 上移一行再重写，只占两行。
fn onInstallStart(ctx: ?*anyopaque, total: usize) void {
    if (progressDisabled()) {
        if (total > 0) _ = std.c.write(1, "\nInstalling packages...\n".ptr, 22);
        return;
    }
    if (ctx) |c| {
        const state = @as(*ProgressState, @ptrCast(@alignCast(c)));
        state.total = total;
    }
    if (total == 0) return;
    const use_color = if (ctx) |c| @as(*ProgressState, @ptrCast(@alignCast(c))).use_color else false;
    var line1_buf: [80]u8 = undefined;
    var w1 = std.Io.Writer.fixed(&line1_buf);
    if (use_color) w1.print("{s}", .{c_cyan}) catch return;
    w1.print("[", .{}) catch return;
    var i: usize = 0;
    while (i < progress_bar_width) : (i += 1) w1.print(" ", .{}) catch return;
    w1.print("] 0/{d} {s}", .{ total, c_erase_to_eol }) catch return;
    if (use_color) w1.print("{s}", .{c_reset}) catch return;
    const line1 = std.Io.Writer.buffered(&w1);
    var line2_buf: [80]u8 = undefined;
    var w2 = std.Io.Writer.fixed(&line2_buf);
    if (use_color) w2.print("{s}", .{c_dim}) catch return;
    w2.print("Installing (0/{d}) packages...{s}", .{ total, c_erase_to_eol }) catch return;
    if (use_color) w2.print("{s}", .{c_reset}) catch return;
    const line2 = std.Io.Writer.buffered(&w2);
    var out_buf: [200]u8 = undefined;
    const io = if (ctx) |c| @as(*ProgressState, @ptrCast(@alignCast(c))).io else return;
    var stdout_w = std.Io.File.Writer.init(std.Io.File.stdout(), io, &out_buf);
    stdout_w.interface.print("\n{s}\n{s}", .{ line1, line2 }) catch return;
    stdout_w.flush() catch return;
}

/// 仅写进度条行「[###...] current/total」到 stdout，不换行，供底部单行进度条原地更新
fn writeProgressBarOnly(use_color: bool, current: usize, total: usize) void {
    if (progressDisabled()) return;
    const filled: usize = if (total > 0) (current * progress_bar_width) / total else 0;
    var line_buf: [80]u8 = undefined;
    var w = std.Io.Writer.fixed(&line_buf);
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
    const line = std.Io.Writer.buffered(&w);
    // writeProgressBarOnly 无 ctx，用 std.c.write 写 stdout fd，避免传 io
    _ = std.c.write(1, "\r".ptr, 1);
    _ = std.c.write(1, line.ptr, line.len);
}

/// InstallReporter.onPackage：下载完成后第二遍按 install_order 回调；仅在新安装时打印 +name，不再刷新进度条（394 满即止，避免下面再出一行进度条）。首次打印前先换行，避免与两行进度块挤在同一行。
fn onInstallPackage(ctx: ?*anyopaque, index: usize, total: usize, name: []const u8, ver: []const u8, newly_installed: bool) void {
    if (progressDisabled()) {
        if (total == 0) return;
        const current = index + 1;
        var buf: [256]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.print("Installing {d}/{d} {s}\n", .{ current, total, name }) catch return;
        const s = std.Io.Writer.buffered(&w);
        _ = std.c.write(1, s.ptr, s.len);
        return;
    }
    if (total == 0) return;
    const state = if (ctx) |c| @as(*ProgressState, @ptrCast(@alignCast(c))) else return;
    const use_color = state.use_color;
    var out_buf: [256]u8 = undefined;
    var stdout_w = std.Io.File.Writer.init(std.Io.File.stdout(), state.io, &out_buf);
    {
        if (!state.install_done_newline) {
            state.install_done_newline = true;
            // 第二遍首次：先强制把进度条刷成 total/total（修复单包时一直是 0/1），再换行打 +name
            if (total > 0) {
                var line1_buf: [80]u8 = undefined;
                var w1 = std.Io.Writer.fixed(&line1_buf);
                if (use_color) w1.print("{s}", .{c_cyan}) catch return;
                w1.print("[", .{}) catch return;
                var i: usize = 0;
                while (i < progress_bar_width) : (i += 1) w1.print("#", .{}) catch return;
                w1.print("] {d}/{d} {s}", .{ total, total, c_erase_to_eol }) catch return;
                if (use_color) w1.print("{s}", .{c_reset}) catch return;
                const line1 = std.Io.Writer.buffered(&w1);
                var line2_buf: [120]u8 = undefined;
                var w2 = std.Io.Writer.fixed(&line2_buf);
                if (use_color) w2.print("{s}", .{c_dim}) catch return;
                const n = @min(name.len, install_line_name_max);
                if (n > 0) {
                    w2.print("Installing ({d}/{d}) {s}...{s}", .{ total, total, name[0..n], c_erase_to_eol }) catch return;
                } else {
                    w2.print("Installing ({d}/{d}) packages...{s}", .{ total, total, c_erase_to_eol }) catch return;
                }
                if (use_color) w2.print("{s}", .{c_reset}) catch return;
                const line2 = std.Io.Writer.buffered(&w2);
                stdout_w.interface.print("{s}\r{s}\n{s}", .{ c_cursor_up_1, line1, line2 }) catch return;
                stdout_w.flush() catch return;
            }
            stdout_w.interface.print("\n", .{}) catch return;
        }
    }
    if (newly_installed) {
        if (use_color) {
            stdout_w.interface.print("+ {s}{s}@{s}{s}\n", .{ c_green, name, ver, c_reset }) catch return;
        } else {
            stdout_w.interface.print("+ {s}@{s}\n", .{ name, ver }) catch return;
        }
    }
    stdout_w.flush() catch return;
}

/// add 流程下 install 结束后对本次添加的包打印「+ name@version」，即使已是 Already up to date
fn onPackageAddedPrint(ctx: ?*anyopaque, name: []const u8, ver: []const u8) void {
    const state = if (ctx) |c| @as(*ProgressState, @ptrCast(@alignCast(c))) else return;
    const use_color = state.use_color;
    if (use_color) {
        printToStdout(state.io, "+ {s}{s}@{s}{s}\n", .{ c_green, name, ver, c_reset }) catch {};
    } else {
        printToStdout(state.io, "+ {s}@{s}\n", .{ name, ver }) catch {};
    }
}

/// InstallReporter.onDone：换行结束进度条；若有安装则先打 Installing Xms（在包列表下），再打安装数量与总耗时。
/// elapsed_ms 由 package/install 从 install() 入口计时到 onDone 调用前，含 Resolving + Installing。
fn onInstallDone(ctx: ?*anyopaque, total_count: usize, new_count: usize, elapsed_ms: i64) void {
    const state = if (ctx) |c| @as(*ProgressState, @ptrCast(@alignCast(c))) else return;
    const use_color = state.use_color;
    if (new_count == 0) {
        if (use_color) {
            printToStdout(state.io, "\n{s}Already up to date ({d} packages){s}\n\n", .{ c_green, total_count, c_reset }) catch {};
        } else {
            printToStdout(state.io, "\nAlready up to date ({d} packages)\n\n", .{total_count}) catch {};
        }
    } else {
        // 先输出 Installing X ms（在包列表下方），空一行，再输出安装数量与总耗时；ms 前加空格，带颜色时标签 cyan、耗时 dim，总结行 green。
        if (state.installing_elapsed_ms >= 0) {
            if (use_color) {
                printToStdout(state.io, "{s}Installing{s} {d} ms{s}\n\n", .{ c_cyan, c_dim, state.installing_elapsed_ms, c_reset }) catch {};
            } else {
                printToStdout(state.io, "Installing {d} ms\n\n", .{state.installing_elapsed_ms}) catch {};
            }
        }
        if (new_count == total_count) {
            if (use_color) {
                printToStdout(state.io, "{s}{d} packages installed{s} [{d} ms]{s}\n\n", .{ c_green, total_count, c_dim, elapsed_ms, c_reset }) catch {};
            } else {
                printToStdout(state.io, "{d} packages installed [{d} ms]\n\n", .{ total_count, elapsed_ms }) catch {};
            }
        } else {
            if (use_color) {
                printToStdout(state.io, "{s}{d} new, {d} total packages{s} [{d} ms]{s}\n\n", .{ c_green, new_count, total_count, c_dim, elapsed_ms, c_reset }) catch {};
            } else {
                printToStdout(state.io, "{d} new, {d} total packages [{d} ms]\n\n", .{ new_count, total_count, elapsed_ms }) catch {};
            }
        }
    }
}

fn printToStdout(io: std.Io, comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [128]u8 = undefined;
    var w = std.Io.File.Writer.init(std.Io.File.stdout(), io, &buf);
    try w.interface.print(fmt, fargs);
    w.flush() catch {};
}
