// shu run 子命令：执行单文件或 package.json scripts
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1
// Zig 0.15.2：std.fs 与 I/O 使用当前稳定 API

const std = @import("std");
const args_mod = @import("args.zig");
const errors = @import("../errors.zig");
const strip_types = @import("../transpiler/strip_types.zig");
const run_options = @import("../runtime/run_options.zig");
const vm = @import("../runtime/vm.zig");

/// 执行 shu run [entry] 或 shu run <script>
/// entry 可为单文件路径；.ts/.tsx 会先做类型擦除再执行。
/// argv 为完整命令行参数（含程序名与子命令），用于 process.argv。
pub fn run(allocator: std.mem.Allocator, parsed: args_mod.ParsedArgs, positional: []const []const u8, argv: []const []const u8) !void {
    if (parsed.help or positional.len == 0) {
        try printRunUsage();
        if (positional.len == 0) return error.MissingEntry;
        return;
    }

    const entry = positional[0];
    const cwd_dir = std.fs.cwd();
    const file = cwd_dir.openFile(entry, .{}) catch |e| {
        if (e == std.fs.File.OpenError.FileNotFound) {
            const msg = std.fmt.allocPrint(allocator, "File not found: {s}", .{entry}) catch "File not found";
            defer allocator.free(msg);
            try errors.reportToStderr(.{ .code = .file_not_found, .message = msg });
            return e;
        }
        return e;
    };
    defer file.close();

    const raw = file.readToEndAlloc(allocator, std.math.maxInt(usize)) catch return;
    defer allocator.free(raw);

    var stripped_to_free: ?[]const u8 = null;
    const source: []const u8 = blk: {
        if (hasExtension(entry, ".ts") or hasExtension(entry, ".tsx") or hasExtension(entry, ".mts")) {
            const stripped = strip_types.strip(allocator, raw) catch return;
            stripped_to_free = stripped;
            break :blk stripped;
        }
        break :blk raw;
    };
    defer if (stripped_to_free) |s| allocator.free(s);

    // 构建 RunOptions：cwd、入口绝对路径、argv、权限（供 process / __dirname / __filename）
    const cwd_str = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd_str);
    const entry_path_abs = try std.fs.path.join(allocator, &.{ cwd_str, entry });
    defer allocator.free(entry_path_abs);
    const is_forked = std.posix.getenv("SHU_FORKED") != null;
    const options = run_options.RunOptions{
        .entry_path = entry_path_abs,
        .cwd = cwd_str,
        .argv = argv,
        .permissions = .{
            .allow_net = parsed.allow_net,
            .allow_read = parsed.allow_read,
            .allow_env = parsed.allow_env,
            .allow_write = parsed.allow_write,
            .allow_exec = parsed.allow_exec,
        },
        .locale = parsed.lang orelse run_options.default_locale,
        .is_forked = is_forked,
    };

    var runtime = vm.VM.init(allocator, &options) catch return;
    defer runtime.deinit();
    try runtime.run(source, entry_path_abs);
}

fn hasExtension(path: []const u8, ext: []const u8) bool {
    if (path.len < ext.len) return false;
    return std.mem.eql(u8, path[path.len - ext.len ..], ext);
}

/// 打印 run 子命令用法（硬编码英文）
fn printRunUsage() !void {
    try printToStdout(
        \\shu run <entry> [options...]
        \\Run a single .js/.ts/.tsx file (types stripped for .ts); or package.json script (later).
        \\Options: --allow-net, --allow-read, --allow-env, --allow-write, --allow-exec
        \\
    , .{});
}

fn printToStdout(comptime fmt: []const u8, fargs: anytype) !void {
    var buf: [256]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const out = &w.interface;
    try out.print(fmt, fargs);
    try out.flush();
}
