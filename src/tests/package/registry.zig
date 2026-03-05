//! package/registry 纯逻辑单元测试：buildTarballUrl。
//! 被测：src/package/registry.zig。

const std = @import("std");
const registry = @import("../../package/registry.zig");

test "registry.buildTarballUrl: simple name" {
    const allocator = std.testing.allocator;
    const url = try registry.buildTarballUrl(allocator, "https://registry.npmjs.org", "preact", "10.0.0");
    defer allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "/-/") != null);
    try std.testing.expect(std.mem.endsWith(u8, url, "preact-10.0.0.tgz"));
}

test "registry.buildTarballUrl: scoped package encodes slash" {
    const allocator = std.testing.allocator;
    const url = try registry.buildTarballUrl(allocator, "https://registry.npmjs.org", "@dreamer/view", "1.0.0");
    defer allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "%2F") != null);
    try std.testing.expect(std.mem.endsWith(u8, url, "view-1.0.0.tgz"));
}

test "registry.buildTarballUrl: base with trailing slash stripped" {
    const allocator = std.testing.allocator;
    const url = try registry.buildTarballUrl(allocator, "https://registry.npmjs.org/", "pkg", "1.0.0");
    defer allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "//") == null);
    try std.testing.expect(std.mem.endsWith(u8, url, "pkg-1.0.0.tgz"));
}

test "registry.buildTarballUrl: format contains base name and version" {
    const allocator = std.testing.allocator;
    const url = try registry.buildTarballUrl(allocator, "https://r.example.com", "lodash", "4.17.21");
    defer allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "r.example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "lodash") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "4.17.21") != null);
    try std.testing.expect(std.mem.endsWith(u8, url, ".tgz"));
}
