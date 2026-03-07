//! shu run 子命令（cli/run.zig）
//!
//! 职责
//!   - 执行单入口文件（.js / .ts / .tsx）或 package.json scripts；.ts/.tsx 先做类型擦除，.tsx 再经 JSX 转译。
//!   - 若当前目录存在 package.json、package.jsonc、deno.json 或 deno.jsonc 任一，会先自动执行依赖安装（与 Deno 一致）；皆无则跳过。
//!   - 构建 RunOptions（cwd、entry_path、argv、permissions 等）并调用 VM 执行源码。
//!
//! 主要 API
//!   - run(allocator, parsed, positional, argv)：入口；positional[0] 为 entry 或 script 名；argv 为完整命令行用于 process.argv。
//!
//! 约定
//!   - 无 entry 且非 help 时返回 error.MissingEntry 并打印用法；面向用户输出为英文。
//!   - 文件与路径 I/O 使用当前稳定 API；install 等经 package 与 io_core。
//!
//! 参考：SHU_RUNTIME_ANALYSIS.md 6.1

const std = @import("std");
const args_mod = @import("args.zig");
const errors = @import("errors");
const libs_io = @import("libs_io");
const libs_process = @import("libs_process");
const strip_types = @import("../transpiler/strip_types.zig");
const jsx = @import("../transpiler/jsx.zig");
const run_options = @import("../runtime/run_options.zig");
const vm = @import("../runtime/vm.zig");
const engine_globals = @import("../runtime/globals.zig");
const pkg_install = @import("../package/install.zig");

/// 执行 shu run [entry] 或 shu run <script>
/// entry 可为单文件路径；.ts/.tsx 会先做类型擦除；.tsx 再经 JSX 转译（默认 @dreamer/view 格式）。
/// 若当前目录存在 package.json 或 package.jsonc、deno.json 或 deno.jsonc 任一，会先自动执行依赖安装（与 Deno 一致）；皆无则跳过。
/// argv 为完整命令行参数（含程序名与子命令），用于 process.argv。io 为 Zig 0.16 std.Io，用于 stdout/stderr。
pub fn run(allocator: std.mem.Allocator, parsed: args_mod.ParsedArgs, positional: []const []const u8, argv: []const []const u8, io: std.Io) !void {
    if (parsed.help or positional.len == 0) {
        try printRunUsage(io);
        if (positional.len == 0) return error.MissingEntry;
        return;
    }

    const entry = positional[0];
    // Zig 0.16：process.getCwdAlloc 已移除，用 libs_io.realpath 取当前目录；路径长度用 Io.Dir.max_path_bytes
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_str = allocator.dupe(u8, try libs_io.realpath(".", &cwd_buf)) catch return;
    defer allocator.free(cwd_str);
    // 存在 package.json/jsonc 或 deno.json/jsonc 时自动安装依赖（Deno 风格）；皆无则跳过（install 需 package 才真正安装，仅 deno 时会 NoManifest）
    if (hasAnyManifest(cwd_str)) {
        pkg_install.install(allocator, cwd_str, null, null, null) catch |e| {
            if (e != error.NoManifest) return e;
        };
    }

    const cwd_dir = std.Io.Dir.cwd();
    const file = cwd_dir.openFile(io, entry, .{}) catch |e| {
        if (e == std.Io.File.OpenError.FileNotFound) {
            const msg = std.fmt.allocPrint(allocator, "File not found: {s}", .{entry}) catch "File not found";
            defer allocator.free(msg);
            try errors.reportToStderr(.{ .code = .file_not_found, .message = msg });
            return e;
        }
        return e;
    };
    defer file.close(io);

    var file_reader = file.reader(io, &.{});
    const raw = file_reader.interface.allocRemaining(allocator, std.Io.Limit.unlimited) catch return;
    defer allocator.free(raw);

    var stripped_to_free: ?[]const u8 = null;
    var jsx_to_free: ?[]const u8 = null;
    const source: []const u8 = blk: {
        if (hasExtension(entry, ".ts") or hasExtension(entry, ".tsx") or hasExtension(entry, ".mts")) {
            const stripped = strip_types.strip(allocator, raw) catch return;
            stripped_to_free = stripped;
            if (hasExtension(entry, ".tsx")) {
                const jsx_src = jsx.transformDefault(allocator, stripped) catch return;
                jsx_to_free = jsx_src;
                break :blk jsx_src;
            }
            break :blk stripped;
        }
        break :blk raw;
    };
    defer if (stripped_to_free) |s| allocator.free(s);
    defer if (jsx_to_free) |j| allocator.free(j);

    // 构建 RunOptions：cwd、入口绝对路径、argv、权限（供 process / __dirname / __filename）
    const entry_path_abs = try std.fs.path.join(allocator, &.{ cwd_str, entry });
    defer allocator.free(entry_path_abs);
    const is_forked = std.c.getenv("SHU_FORKED") != null;
    const options = run_options.RunOptions{
        .entry_path = entry_path_abs,
        .cwd = cwd_str,
        .argv = argv,
        .permissions = .{
            .allow_net = parsed.allow_net,
            .allow_read = parsed.allow_read,
            .allow_env = parsed.allow_env,
            .allow_write = parsed.allow_write,
            .allow_run = parsed.allow_run,
            .allow_hrtime = parsed.allow_hrtime,
            .allow_ffi = parsed.allow_ffi,
        },
        .locale = run_options.default_locale,
        .is_forked = is_forked,
    };

    var runtime = vm.VM.init(allocator, &options) catch return;
    defer runtime.deinit();
    try runtime.run(source, entry_path_abs);
    if (engine_globals.pending_process_exit) |code| {
        std.process.exit(code);
    }
}

/// 当前目录是否存在任意 manifest：package.json 或 package.jsonc、deno.json 或 deno.jsonc 任一存在即返回 true。Zig 0.16：用 libs_io.openDirAbsolute，Dir/File 操作需 io。
fn hasAnyManifest(dir: []const u8) bool {
    const io = libs_process.getProcessIo() orelse return false;
    const names = [_][]const u8{ "package.json", "package.jsonc", "deno.json", "deno.jsonc" };
    var d = libs_io.openDirAbsolute(dir, .{}) catch return false;
    defer d.close(io);
    for (names) |name| {
        const f = d.openFile(io, name, .{}) catch continue;
        defer f.close(io);
        return true;
    }
    return false;
}

fn hasExtension(path: []const u8, ext: []const u8) bool {
    if (path.len < ext.len) return false;
    return std.mem.eql(u8, path[path.len - ext.len ..], ext);
}

/// 打印 run 子命令用法（硬编码英文）。Zig 0.16：使用 io 写 stdout。
fn printRunUsage(io: std.Io) !void {
    try printToStdout(io,
        \\shu run <entry> [options...]
        \\Run a single .js / .ts / .tsx file (types stripped; .tsx also JSX-transformed); or package.json script (later).
        \\Options: --allow-all / -A, --allow-net, --allow-read, --allow-env, --allow-write, --allow-run, --allow-hrtime, --allow-ffi
        \\
    , .{});
}

fn printToStdout(io: std.Io, comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.Writer.init(std.Io.File.stdout(), io, &buf);
    try w.interface.print(fmt, fargs);
    w.flush() catch {};
}
