//! package/lockfile 纯解析单元测试：parseNameAtVersion（不涉及 I/O）。
//! 被测模块：src/package/lockfile.zig；覆盖合法、非法与边界输入。

const std = @import("std");
const lockfile = @import("../../package/lockfile.zig");

fn parse(allocator: std.mem.Allocator, s: []const u8) !struct { name: []const u8, version: []const u8 } {
    const r = try lockfile.parseNameAtVersion(allocator, s);
    return r;
}

// ---------- 合法 ----------

test "lockfile.parseNameAtVersion: simple" {
    const allocator = std.testing.allocator;
    const r = try parse(allocator, "preact@10.0.0");
    defer allocator.free(r.name);
    defer allocator.free(r.version);
    try std.testing.expectEqualStrings(r.name, "preact");
    try std.testing.expectEqualStrings(r.version, "10.0.0");
}

test "lockfile.parseNameAtVersion: scoped package" {
    const allocator = std.testing.allocator;
    const r = try parse(allocator, "@dreamer/view@1.0.0");
    defer allocator.free(r.name);
    defer allocator.free(r.version);
    try std.testing.expectEqualStrings(r.name, "@dreamer/view");
    try std.testing.expectEqualStrings(r.version, "1.0.0");
}

test "lockfile.parseNameAtVersion: version with prerelease" {
    const allocator = std.testing.allocator;
    const r = try parse(allocator, "pkg@1.0.0-beta.1");
    defer allocator.free(r.name);
    defer allocator.free(r.version);
    try std.testing.expectEqualStrings(r.name, "pkg");
    try std.testing.expectEqualStrings(r.version, "1.0.0-beta.1");
}

test "lockfile.parseNameAtVersion: multiple at last wins" {
    const allocator = std.testing.allocator;
    const r = try parse(allocator, "a@b@1.0.0");
    defer allocator.free(r.name);
    defer allocator.free(r.version);
    try std.testing.expectEqualStrings(r.name, "a@b");
    try std.testing.expectEqualStrings(r.version, "1.0.0");
}

test "lockfile.parseNameAtVersion: single char name and version" {
    const allocator = std.testing.allocator;
    const r = try parse(allocator, "x@1");
    defer allocator.free(r.name);
    defer allocator.free(r.version);
    try std.testing.expectEqualStrings(r.name, "x");
    try std.testing.expectEqualStrings(r.version, "1");
}

test "lockfile.lock_file_name constant" {
    try std.testing.expectEqualStrings(lockfile.lock_file_name, "shu.lock");
}

// ---------- 非法 ----------

test "lockfile.parseNameAtVersion: invalid no at" {
    const allocator = std.testing.allocator;
    const r = lockfile.parseNameAtVersion(allocator, "nopackage");
    try std.testing.expectError(error.InvalidNameAtVersion, r);
}

test "lockfile.parseNameAtVersion: invalid leading at" {
    const allocator = std.testing.allocator;
    const r = lockfile.parseNameAtVersion(allocator, "@1.0.0");
    try std.testing.expectError(error.InvalidNameAtVersion, r);
}

test "lockfile.parseNameAtVersion: invalid only at" {
    const allocator = std.testing.allocator;
    const r = lockfile.parseNameAtVersion(allocator, "@");
    try std.testing.expectError(error.InvalidNameAtVersion, r);
}

test "lockfile.parseNameAtVersion: invalid empty string" {
    const allocator = std.testing.allocator;
    const r = lockfile.parseNameAtVersion(allocator, "");
    try std.testing.expectError(error.InvalidNameAtVersion, r);
}

test "lockfile.parseNameAtVersion: name@ empty version is valid" {
    const allocator = std.testing.allocator;
    const r = lockfile.parseNameAtVersion(allocator, "name@");
    try std.testing.expect(r) catch return;
    const res = r catch unreachable;
    defer allocator.free(res.name);
    defer allocator.free(res.version);
    try std.testing.expectEqualStrings(res.name, "name");
    try std.testing.expect(res.version.len == 0);
}

test "lockfile.parseNameAtVersion: version with build metadata" {
    const allocator = std.testing.allocator;
    const r = try parse(allocator, "pkg@1.0.0+build.1");
    defer allocator.free(r.name);
    defer allocator.free(r.version);
    try std.testing.expectEqualStrings(r.name, "pkg");
    try std.testing.expectEqualStrings(r.version, "1.0.0+build.1");
}

test "lockfile.parseNameAtVersion: three at signs last wins" {
    const allocator = std.testing.allocator;
    const r = try parse(allocator, "a@b@c@2.0.0");
    defer allocator.free(r.name);
    defer allocator.free(r.version);
    try std.testing.expectEqualStrings(r.name, "a@b@c");
    try std.testing.expectEqualStrings(r.version, "2.0.0");
}

test "lockfile.parseNameAtVersion: version only digit" {
    const allocator = std.testing.allocator;
    const r = try parse(allocator, "lib@1");
    defer allocator.free(r.name);
    defer allocator.free(r.version);
    try std.testing.expectEqualStrings(r.name, "lib");
    try std.testing.expectEqualStrings(r.version, "1");
}
