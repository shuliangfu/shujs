//! CLI 全局参数解析单元测试：覆盖 parse()、所有权限、help、边界与非法/合法参数。
//! 被测模块：src/cli/args.zig（仅依赖 std，无 process/io）。

const std = @import("std");
const args = @import("../../cli/args.zig");

// ---------- 空与单元素边界 ----------

test "args.parse: empty argv" {
    const argv: []const []const u8 = &.{};
    const result = args.parse(argv);
    try std.testing.expect(result.positional.len == 0);
    try std.testing.expect(!result.parsed.help);
    try std.testing.expect(!result.parsed.allow_net);
}

test "args.parse: single positional no options" {
    const argv = [_][]const u8{"run"};
    const result = args.parse(&argv);
    try std.testing.expect(result.positional.len == 1);
    try std.testing.expectEqualStrings(result.positional[0], "run");
    try std.testing.expect(!result.parsed.help);
    try std.testing.expect(!result.parsed.allow_net);
}

test "args.parse: positional only multiple" {
    const argv = [_][]const u8{ "run", "script.js", "extra" };
    const result = args.parse(&argv);
    try std.testing.expect(result.positional.len == 3);
    try std.testing.expectEqualStrings(result.positional[0], "run");
    try std.testing.expectEqualStrings(result.positional[1], "script.js");
    try std.testing.expectEqualStrings(result.positional[2], "extra");
}

// ---------- help ----------

test "args.parse: --help sets help" {
    const argv = [_][]const u8{ "--help", "run" };
    const result = args.parse(&argv);
    try std.testing.expect(result.parsed.help);
    try std.testing.expect(result.positional.len == 1);
    try std.testing.expectEqualStrings(result.positional[0], "run");
}

test "args.parse: -h sets help" {
    const argv = [_][]const u8{"-h"};
    const result = args.parse(&argv);
    try std.testing.expect(result.parsed.help);
    try std.testing.expect(result.positional.len == 0);
}

test "args.parse: -h with positional" {
    const argv = [_][]const u8{ "-h", "run" };
    const result = args.parse(&argv);
    try std.testing.expect(result.parsed.help);
    try std.testing.expect(result.positional.len == 1);
}

// ---------- 各权限单独与组合 ----------

test "args.parse: --allow-net" {
    const argv = [_][]const u8{ "--allow-net", "run" };
    const result = args.parse(&argv);
    try std.testing.expect(result.parsed.allow_net);
    try std.testing.expect(!result.parsed.allow_read);
    try std.testing.expectEqualStrings(result.positional[0], "run");
}

test "args.parse: --allow-read" {
    const argv = [_][]const u8{"--allow-read"};
    const result = args.parse(&argv);
    try std.testing.expect(result.parsed.allow_read);
    try std.testing.expect(result.positional.len == 0);
}

test "args.parse: --allow-env" {
    const argv = [_][]const u8{ "--allow-env", "x" };
    const result = args.parse(&argv);
    try std.testing.expect(result.parsed.allow_env);
    try std.testing.expectEqualStrings(result.positional[0], "x");
}

test "args.parse: --allow-write" {
    const argv = [_][]const u8{"--allow-write"};
    const result = args.parse(&argv);
    try std.testing.expect(result.parsed.allow_write);
}

test "args.parse: --allow-run" {
    const argv = [_][]const u8{"--allow-run"};
    const result = args.parse(&argv);
    try std.testing.expect(result.parsed.allow_run);
}

test "args.parse: --allow-hrtime" {
    const argv = [_][]const u8{"--allow-hrtime"};
    const result = args.parse(&argv);
    try std.testing.expect(result.parsed.allow_hrtime);
}

test "args.parse: --allow-ffi" {
    const argv = [_][]const u8{"--allow-ffi"};
    const result = args.parse(&argv);
    try std.testing.expect(result.parsed.allow_ffi);
}

test "args.parse: --allow-all sets all permissions" {
    const argv = [_][]const u8{ "--allow-all", "run" };
    const result = args.parse(&argv);
    try std.testing.expect(result.parsed.allow_net);
    try std.testing.expect(result.parsed.allow_read);
    try std.testing.expect(result.parsed.allow_env);
    try std.testing.expect(result.parsed.allow_write);
    try std.testing.expect(result.parsed.allow_run);
    try std.testing.expect(result.parsed.allow_hrtime);
    try std.testing.expect(result.parsed.allow_ffi);
}

test "args.parse: --all sets all permissions" {
    const argv = [_][]const u8{"--all"};
    const result = args.parse(&argv);
    try std.testing.expect(result.parsed.allow_net);
    try std.testing.expect(result.parsed.allow_ffi);
}

test "args.parse: -A sets all permissions" {
    const argv = [_][]const u8{ "-A", "run" };
    const result = args.parse(&argv);
    try std.testing.expect(result.parsed.allow_net);
    try std.testing.expect(result.parsed.allow_ffi);
}

test "args.parse: multiple permissions cumulative" {
    const argv = [_][]const u8{ "--allow-net", "--allow-read", "--allow-write" };
    const result = args.parse(&argv);
    try std.testing.expect(result.parsed.allow_net);
    try std.testing.expect(result.parsed.allow_read);
    try std.testing.expect(result.parsed.allow_write);
    try std.testing.expect(!result.parsed.allow_ffi);
}

// ---------- 未知选项保留在 positional（遇首个非已知全局选项即停止消费） ----------

test "args.parse: unknown long option stops parsing and goes to positional" {
    const argv = [_][]const u8{ "--allow-net", "--unknown-flag", "run" };
    const result = args.parse(&argv);
    try std.testing.expect(result.parsed.allow_net);
    try std.testing.expect(result.positional.len == 2);
    try std.testing.expectEqualStrings(result.positional[0], "--unknown-flag");
    try std.testing.expectEqualStrings(result.positional[1], "run");
}

test "args.parse: single dash is not global option so in positional" {
    const argv = [_][]const u8{ "-", "run" };
    const result = args.parse(&argv);
    try std.testing.expect(result.positional.len == 2);
    try std.testing.expectEqualStrings(result.positional[0], "-");
    try std.testing.expectEqualStrings(result.positional[1], "run");
}

test "args.parse: double dash only is global option form but unknown so positional" {
    const argv = [_][]const u8{ "--", "run" };
    const result = args.parse(&argv);
    try std.testing.expect(result.positional.len == 2);
    try std.testing.expectEqualStrings(result.positional[0], "--");
    try std.testing.expectEqualStrings(result.positional[1], "run");
}

test "args.parse: -x not known short option stays positional" {
    const argv = [_][]const u8{ "-x", "run" };
    const result = args.parse(&argv);
    try std.testing.expect(result.positional.len == 2);
    try std.testing.expectEqualStrings(result.positional[0], "-x");
}

test "args.parse: no options when first arg is positional" {
    const argv = [_][]const u8{ "run", "--allow-net" };
    const result = args.parse(&argv);
    try std.testing.expect(!result.parsed.allow_net);
    try std.testing.expect(result.positional.len == 2);
    try std.testing.expectEqualStrings(result.positional[0], "run");
    try std.testing.expectEqualStrings(result.positional[1], "--allow-net");
}

// ---------- 默认值与边界 ----------

test "args.parse: all permissions false when no flags" {
    const argv = [_][]const u8{"run"};
    const result = args.parse(&argv);
    try std.testing.expect(!result.parsed.allow_net);
    try std.testing.expect(!result.parsed.allow_read);
    try std.testing.expect(!result.parsed.allow_env);
    try std.testing.expect(!result.parsed.allow_write);
    try std.testing.expect(!result.parsed.allow_run);
    try std.testing.expect(!result.parsed.allow_hrtime);
    try std.testing.expect(!result.parsed.allow_ffi);
    try std.testing.expect(!result.parsed.help);
}

test "args.parse: only --help no positional" {
    const argv = [_][]const u8{"--help"};
    const result = args.parse(&argv);
    try std.testing.expect(result.parsed.help);
    try std.testing.expect(result.positional.len == 0);
}

test "args.parse: -v not known stays in positional" {
    const argv = [_][]const u8{ "-v", "run" };
    const result = args.parse(&argv);
    try std.testing.expect(result.positional.len == 2);
    try std.testing.expectEqualStrings(result.positional[0], "-v");
    try std.testing.expectEqualStrings(result.positional[1], "run");
}

test "args.parse: mixed order flags then positional" {
    const argv = [_][]const u8{ "--allow-read", "--allow-net", "run", "script.js" };
    const result = args.parse(&argv);
    try std.testing.expect(result.parsed.allow_read);
    try std.testing.expect(result.parsed.allow_net);
    try std.testing.expect(result.positional.len == 2);
    try std.testing.expectEqualStrings(result.positional[0], "run");
    try std.testing.expectEqualStrings(result.positional[1], "script.js");
}
