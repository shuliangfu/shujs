//! Shu.path 单元测试：通过运行 shu -e "script" 覆盖 join、resolve、dirname、basename、extname、normalize、isAbsolute、relative、parse、format、root、name、sep、delimiter、posix、win32、filePathToUrl、urlToFilePath、toNamespacedPath。
//! 依赖：zig build test 前会 install，故 zig-out/bin/shu 存在。

const std = @import("std");
const builtin = @import("builtin");

const sep: []const u8 = if (builtin.os.tag == .windows) "\\" else "/";
const delimiter: []const u8 = if (builtin.os.tag == .windows) ";" else ":";

fn run(allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    return runShuWithScript(allocator, script, &.{});
}

test "Shu.path.join: two parts" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.log(Shu.path.join('a','b'))");
    defer allocator.free(out);
    const expected = try std.fmt.allocPrint(allocator, "a{s}b", .{sep});
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, out);
}

test "Shu.path.join: multiple parts" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.log(Shu.path.join('a','b','c'))");
    defer allocator.free(out);
    const expected = try std.fmt.allocPrint(allocator, "a{s}b{s}c", .{ sep, sep });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, out);
}

test "Shu.path.join: single part" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.log(Shu.path.join('a'))");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("a", out);
}

test "Shu.path.join: with empty segment" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.log(Shu.path.join('a','','c'))");
    defer allocator.free(out);
    const expected = try std.fmt.allocPrint(allocator, "a{s}{s}c", .{ sep, sep });
    defer allocator.free(expected);
    try std.testing.expectEqualStrings(expected, out);
}

test "Shu.path.dirname" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.log(Shu.path.dirname('/a/b/c'))");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("/a/b", out);
}

test "Shu.path.basename" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.log(Shu.path.basename('/a/b/foo.zig'))");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("foo.zig", out);
}

test "Shu.path.basename with ext" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.log(Shu.path.basename('/a/b/foo.zig', '.zig'))");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("foo", out);
}

test "Shu.path.extname" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.log(Shu.path.extname('file.zig'))");
    defer allocator.free(out);
    try std.testing.expectEqualStrings(".zig", out);
}

test "Shu.path.extname: no extension" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.log(Shu.path.extname('file'))");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "Shu.path.dirname: single segment" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.log(Shu.path.dirname('foo'))");
    defer allocator.free(out);
    try std.testing.expectEqualStrings(".", out);
}

test "Shu.path.normalize: dot and dotdot" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.log(Shu.path.normalize('/a/./b/../c'))");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("/a/c", out);
}

test "Shu.path.isAbsolute: absolute" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.log(Shu.path.isAbsolute('/foo'))");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("true", out);
}

test "Shu.path.isAbsolute: relative" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.log(Shu.path.isAbsolute('foo'))");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("false", out);
}

test "Shu.path.normalize" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.log(Shu.path.normalize('/a/b/../c'))");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("/a/c", out);
}

test "Shu.path.relative" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.log(Shu.path.relative('/a/b/c','/a/d'))");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "..") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "d") != null);
}

test "Shu.path.sep" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.log(Shu.path.sep)");
    defer allocator.free(out);
    try std.testing.expectEqualStrings(sep, out);
}

test "Shu.path.delimiter" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.log(Shu.path.delimiter)");
    defer allocator.free(out);
    try std.testing.expectEqualStrings(delimiter, out);
}

test "Shu.path.parse" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "const p = Shu.path.parse('/a/b/foo.zig'); console.log(p.root + '|' + p.dir + '|' + p.base + '|' + p.name + '|' + p.ext)");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "foo.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, ".zig") != null);
}

test "Shu.path.format" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.log(Shu.path.format({ root: '/', dir: '/a/b', base: 'foo.zig', name: 'foo', ext: '.zig' }))");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "foo.zig") != null);
}

test "Shu.path.root" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.log(Shu.path.root('/a/b'))");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("/", out);
}

test "Shu.path.name" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.log(Shu.path.name('/a/b/foo.zig'))");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("foo", out);
}

test "Shu.path.resolve: single relative" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.log(Shu.path.resolve('x'))");
    defer allocator.free(out);
    try std.testing.expect(std.mem.endsWith(u8, out, "x") or std.mem.endsWith(u8, out, sep ++ "x"));
}

test "Shu.path.posix.join" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.log(Shu.path.posix.join('a','b'))");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("a/b", out);
}

test "Shu.path.win32.join" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.log(Shu.path.win32.join('a','b'))");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("a\\b", out);
}

test "Shu.path.filePathToUrl and urlToFilePath roundtrip" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const p = '/a/b/c';
        \\const u = Shu.path.filePathToUrl(p);
        \\const back = Shu.path.urlToFilePath(u);
        \\console.log(back);
    );
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "a") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "b") != null);
}

test "Shu.path.toNamespacedPath: non-Windows returns path" {
    if (builtin.os.tag == .windows) return;
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.log(Shu.path.toNamespacedPath('/a/b'))");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "a") != null);
}

const runShuWithScript = @import("shu_run.zig").runShuWithScript;
