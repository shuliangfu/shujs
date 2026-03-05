//! package/npmrc 纯逻辑单元测试：hostFromRegistryUrl（不测 load/getRegistryForPackage 等 I/O）。
//! 被测：src/package/npmrc.zig。

const std = @import("std");
const npmrc = @import("../../package/npmrc.zig");

test "npmrc.hostFromRegistryUrl: standard registry" {
    const allocator = std.testing.allocator;
    const host = try npmrc.hostFromRegistryUrl(allocator, "https://registry.npmjs.org/");
    defer allocator.free(host);
    try std.testing.expectEqualStrings(host, "registry.npmjs.org");
}

test "npmrc.hostFromRegistryUrl: no path" {
    const allocator = std.testing.allocator;
    const host = try npmrc.hostFromRegistryUrl(allocator, "https://custom.registry.example.com");
    defer allocator.free(host);
    try std.testing.expectEqualStrings(host, "custom.registry.example.com");
}

test "npmrc.hostFromRegistryUrl: with path returns host only" {
    const allocator = std.testing.allocator;
    const host = try npmrc.hostFromRegistryUrl(allocator, "https://r.example.com/path/to/registry");
    defer allocator.free(host);
    try std.testing.expectEqualStrings(host, "r.example.com");
}

test "npmrc.hostFromRegistryUrl: no scheme returns default" {
    const allocator = std.testing.allocator;
    const host = try npmrc.hostFromRegistryUrl(allocator, "registry.npmjs.org");
    defer allocator.free(host);
    try std.testing.expectEqualStrings(host, "registry.npmjs.org");
}

test "npmrc.hostFromRegistryUrl: port in host" {
    const allocator = std.testing.allocator;
    const host = try npmrc.hostFromRegistryUrl(allocator, "https://localhost:4873/");
    defer allocator.free(host);
    try std.testing.expectEqualStrings(host, "localhost");
}
