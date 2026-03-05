//! CLI scan 模块单元测试：isExcludedDir、hasExtension 及扩展名常量。
//! 被测：src/cli/scan.zig（纯逻辑，不测 collectFilesRecursive 的 I/O）。

const std = @import("std");
const scan = @import("../../cli/scan.zig");

// ---------- isExcludedDir ----------

test "scan.isExcludedDir: default excluded dirs match" {
    try std.testing.expect(scan.isExcludedDir("node_modules"));
    try std.testing.expect(scan.isExcludedDir(".git"));
    try std.testing.expect(scan.isExcludedDir("dist"));
    try std.testing.expect(scan.isExcludedDir("build"));
    try std.testing.expect(scan.isExcludedDir("out"));
    try std.testing.expect(scan.isExcludedDir(".shu"));
    try std.testing.expect(scan.isExcludedDir("coverage"));
    try std.testing.expect(scan.isExcludedDir("vendor"));
}

test "scan.isExcludedDir: non-excluded returns false" {
    try std.testing.expect(!scan.isExcludedDir("src"));
    try std.testing.expect(!scan.isExcludedDir("tests"));
    try std.testing.expect(!scan.isExcludedDir(""));
    try std.testing.expect(!scan.isExcludedDir("node_module")); // 少 s
    try std.testing.expect(!scan.isExcludedDir("NODE_MODULES")); // 大小写
}

// ---------- hasExtension ----------

test "scan.hasExtension: match test_extensions" {
    try std.testing.expect(scan.hasExtension("foo.test.ts", &scan.test_extensions));
    try std.testing.expect(scan.hasExtension("bar.test.js", &scan.test_extensions));
    try std.testing.expect(scan.hasExtension("baz.spec.ts", &scan.test_extensions));
    try std.testing.expect(scan.hasExtension("q.spec.js", &scan.test_extensions));
}

test "scan.hasExtension: match fmt_extensions" {
    try std.testing.expect(scan.hasExtension("a.ts", &scan.fmt_extensions));
    try std.testing.expect(scan.hasExtension("b.json", &scan.fmt_extensions));
    try std.testing.expect(scan.hasExtension("c.md", &scan.fmt_extensions));
    try std.testing.expect(scan.hasExtension("d.zig", &scan.fmt_extensions));
}

test "scan.hasExtension: match lint_extensions" {
    try std.testing.expect(scan.hasExtension("x.js", &scan.lint_extensions));
    try std.testing.expect(scan.hasExtension("y.jsonc", &scan.lint_extensions));
}

test "scan.hasExtension: no match" {
    try std.testing.expect(!scan.hasExtension("file.txt", &scan.test_extensions));
    try std.testing.expect(!scan.hasExtension("file.ts", &scan.test_extensions)); // .ts 不在 test_extensions
    try std.testing.expect(!scan.hasExtension("noext", &scan.fmt_extensions));
}

test "scan.hasExtension: empty path or empty list" {
    try std.testing.expect(!scan.hasExtension("", &scan.fmt_extensions));
    const empty: []const []const u8 = &.{};
    try std.testing.expect(!scan.hasExtension("a.js", empty));
}

// ---------- constants ----------

test "scan.default_exclude_dirs: contains expected entries" {
    var found_node_modules = false;
    var found_dot_git = false;
    for (scan.default_exclude_dirs) |d| {
        if (std.mem.eql(u8, d, "node_modules")) found_node_modules = true;
        if (std.mem.eql(u8, d, ".git")) found_dot_git = true;
    }
    try std.testing.expect(found_node_modules);
    try std.testing.expect(found_dot_git);
}

test "scan.test_extensions: contains expected" {
    try std.testing.expect(scan.hasExtension("a.test.ts", &scan.test_extensions));
    try std.testing.expect(scan.hasExtension("a.spec.js", &scan.test_extensions));
}
