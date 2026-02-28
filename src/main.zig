// CLI 入口，解析子命令并分发到 run/install/build/test/check/lint/fmt
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1
// Zig 0.15.2：stdout/stderr 使用 std.fs.File.stdout().writer(...)，无旧版 API

const std = @import("std");
const cli_args = @import("cli/args.zig");
const cli_run = @import("cli/run.zig");
const cli_install = @import("cli/install.zig");
const cli_build = @import("cli/build.zig");
const cli_test = @import("cli/test.zig");
const cli_check = @import("cli/check.zig");
const cli_lint = @import("cli/lint.zig");
const cli_fmt = @import("cli/fmt.zig");

/// CLI 入口：解析子命令与全局选项，分发到 run/install/build/test/check/lint/fmt
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    if (argv.len < 2) {
        try printUsageToStdout();
        std.process.exit(1);
    }

    const subcommand = argv[1];
    const rest = argv[2..];
    const parse_result = cli_args.parse(rest);

    if (parse_result.parsed.help) {
        try printUsageToStdout();
        return;
    }

    if (std.mem.eql(u8, subcommand, "run")) {
        cli_run.run(allocator, parse_result.parsed, parse_result.positional, argv) catch |e| {
            if (e == error.MissingEntry or e == std.fs.File.OpenError.FileNotFound) std.process.exit(1);
            return e;
        };
        return;
    }
    if (std.mem.eql(u8, subcommand, "install")) {
        try cli_install.install(allocator, parse_result.parsed, parse_result.positional);
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

    try printToStdout("Unknown subcommand: {s}\n", .{subcommand});
    try printUsageToStdout();
    std.process.exit(1);
}

/// Zig 0.15.2：通过 std.fs.File.stdout().writer() 写 stdout
fn printUsageToStdout() !void {
    var buf: [256]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const out = &w.interface;
    try out.writeAll(
        \\Usage: shu <subcommand> [options...]
        \\Subcommands: run | install | build | test | check | lint | fmt
        \\Global options: --allow-net, --allow-read, --allow-env, --allow-write, --help
        \\
    );
    try out.flush();
}

fn printToStdout(comptime fmt: []const u8, args: anytype) !void {
    var buf: [256]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    const out = &w.interface;
    try out.print(fmt, args);
    try out.flush();
}
