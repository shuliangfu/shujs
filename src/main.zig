// CLI 入口，解析子命令并分发到 run/install/add/build/test/check/lint/fmt 及建议新增子命令（占位）
// 参考：README.md ⌨️ CLI 实用命令分析、SHU_RUNTIME_ANALYSIS.md 6.1
// Zig 0.15.2：stdout/stderr 使用 std.fs.File.stdout().writer(...)，无旧版 API

const std = @import("std");
const cli_args = @import("cli/args.zig");
const cli_run = @import("cli/run.zig");
const cli_install = @import("cli/install.zig");
const cli_add = @import("cli/add.zig");
const cli_build = @import("cli/build.zig");
const cli_test = @import("cli/test.zig");
const cli_check = @import("cli/check.zig");
const cli_lint = @import("cli/lint.zig");
const cli_fmt = @import("cli/fmt.zig");
const cli_version = @import("cli/version.zig");
const cli_init = @import("cli/init.zig");
const cli_x = @import("cli/x.zig");
const cli_cache = @import("cli/cache.zig");
const cli_info = @import("cli/info.zig");
const cli_repl = @import("cli/repl.zig");
const cli_doc = @import("cli/doc.zig");
const cli_upgrade = @import("cli/upgrade.zig");
const cli_clean = @import("cli/clean.zig");
const cli_why = @import("cli/why.zig");
const cli_preview = @import("cli/preview.zig");
const cli_compiler = @import("cli/compiler.zig");
const cli_remove = @import("cli/remove.zig");
const cli_update = @import("cli/update.zig");
const cli_outdated = @import("cli/outdated.zig");
const cli_list = @import("cli/list.zig");
const cli_link = @import("cli/link.zig");
const cli_unlink = @import("cli/unlink.zig");
const cli_pack = @import("cli/pack.zig");
const cli_publish = @import("cli/publish.zig");
const cli_eval = @import("cli/eval.zig");
const cli_create = @import("cli/create.zig");
const cli_doctor = @import("cli/doctor.zig");
const cli_completions = @import("cli/completions.zig");
const cli_task = @import("cli/task.zig");
const cli_inspect = @import("cli/inspect.zig");
const cli_trace = @import("cli/trace.zig");
const cli_audit = @import("cli/audit.zig");
const cli_login = @import("cli/login.zig");
const cli_logout = @import("cli/logout.zig");
const cli_whoami = @import("cli/whoami.zig");
const cli_search = @import("cli/search.zig");
const cli_env = @import("cli/env.zig");
const cli_config = @import("cli/config.zig");
const cli_serve = @import("cli/serve.zig");
const cli_help = @import("cli/help.zig");

/// CLI 入口：解析子命令与全局选项，分发到各子命令（含文档「还可实现的命令」占位）
pub fn main() !void {
    // 进程级 libcurl 初始化只做一次，避免 install/fetch 等路径每次请求都 curl_global_init（SSL/协议表开销大且非线程安全）
    const io_core = @import("io_core");
    io_core.http.ensureCurlGlobalInit();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    if (argv.len < 2) {
        try cli_help.printGlobalUsage();
        std.process.exit(1);
    }

    const subcommand = argv[1];
    // -v / --version 优先：无需子命令解析，直接打印版本并退出
    if (std.mem.eql(u8, subcommand, "-v") or std.mem.eql(u8, subcommand, "--version")) {
        try cli_version.printVersion();
        return;
    }
    if (std.mem.eql(u8, subcommand, "--help") or std.mem.eql(u8, subcommand, "-h")) {
        try cli_help.printGlobalUsage();
        return;
    }

    const rest = argv[2..];
    const parse_result = cli_args.parse(rest);

    if (parse_result.parsed.help) {
        try cli_help.printGlobalUsage();
        return;
    }
    if (std.mem.eql(u8, subcommand, "help")) {
        try cli_help.help(allocator, parse_result.positional);
        return;
    }

    if (std.mem.eql(u8, subcommand, "run")) {
        cli_run.run(allocator, parse_result.parsed, parse_result.positional, argv) catch |e| {
            if (e == error.MissingEntry or e == std.fs.File.OpenError.FileNotFound) std.process.exit(1);
            return e;
        };
        return;
    }
    if (std.mem.eql(u8, subcommand, "install") or std.mem.eql(u8, subcommand, "-i")) {
        cli_install.install(allocator, parse_result.parsed, parse_result.positional) catch {
            // 错误信息已由 install 打印，此处仅退出码，避免 Debug 下打印错误栈
            std.process.exit(1);
        };
        return;
    }
    if (std.mem.eql(u8, subcommand, "add")) {
        cli_add.add(allocator, parse_result.parsed, parse_result.positional) catch {
            std.process.exit(1);
        };
        return;
    }
    if (std.mem.eql(u8, subcommand, "build")) {
        try cli_build.build(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "test")) {
        try cli_test.runTest(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "check")) {
        try cli_check.check(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "lint")) {
        try cli_lint.lint(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "fmt")) {
        try cli_fmt.fmt(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "version")) {
        try cli_version.printVersion();
        return;
    }
    if (std.mem.eql(u8, subcommand, "init")) {
        try cli_init.init(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "x")) {
        try cli_x.x(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "cache")) {
        try cli_cache.cache(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "info")) {
        try cli_info.info(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "repl")) {
        try cli_repl.repl(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "doc")) {
        try cli_doc.doc(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "upgrade")) {
        try cli_upgrade.upgrade(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "clean")) {
        try cli_clean.clean(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "why")) {
        try cli_why.why(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "preview")) {
        try cli_preview.preview(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "compiler")) {
        try cli_compiler.compiler(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "remove")) {
        try cli_remove.remove(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "update")) {
        try cli_update.update(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "outdated")) {
        try cli_outdated.outdated(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "list") or std.mem.eql(u8, subcommand, "ls")) {
        try cli_list.list(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "link")) {
        try cli_link.link(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "unlink")) {
        try cli_unlink.unlink(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "pack")) {
        try cli_pack.pack(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "publish")) {
        try cli_publish.publish(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "eval")) {
        try cli_eval.eval(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "create")) {
        try cli_create.create(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "doctor")) {
        try cli_doctor.doctor(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "completions")) {
        try cli_completions.completions(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "task") or std.mem.eql(u8, subcommand, "tasks")) {
        try cli_task.task(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "inspect")) {
        try cli_inspect.inspect(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "trace")) {
        try cli_trace.trace(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "audit")) {
        try cli_audit.audit(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "login")) {
        try cli_login.login(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "logout")) {
        try cli_logout.logout(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "whoami")) {
        try cli_whoami.whoami(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "search")) {
        try cli_search.search(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "env")) {
        try cli_env.env(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "config")) {
        try cli_config.config(allocator, parse_result.parsed, parse_result.positional);
        return;
    }
    if (std.mem.eql(u8, subcommand, "serve")) {
        try cli_serve.serve(allocator, parse_result.parsed, parse_result.positional);
        return;
    }

    try printToStdout("Unknown subcommand: {s}\n", .{subcommand});
    try cli_help.printGlobalUsage();
    std.process.exit(1);
}

fn printToStdout(comptime fmt: []const u8, args: anytype) !void {
    var buf: [256]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const out = &w.interface;
    try out.print(fmt, args);
    try out.flush();
}
