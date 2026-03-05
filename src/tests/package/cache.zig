//! package/cache 纯逻辑单元测试：cacheKey、getCachedPackageDirPath（不测 getShuHome/getCacheRoot 等依赖 env/io 的 API）。
//! 被测：src/package/cache.zig。

const std = @import("std");
const cache = @import("../../package/cache.zig");

// ---------- cacheKey ----------

test "cache.cacheKey: simple name and version" {
    const allocator = std.testing.allocator;
    const key = try cache.cacheKey(allocator, "registry.npmjs.org", "preact", "10.0.0");
    defer allocator.free(key);
    try std.testing.expectEqualStrings(key, "npm/registry.npmjs.org/preact/10.0.0");
}

test "cache.cacheKey: scoped package" {
    const allocator = std.testing.allocator;
    const key = try cache.cacheKey(allocator, "registry.npmjs.org", "@dreamer/view", "1.0.0");
    defer allocator.free(key);
    try std.testing.expect(std.mem.indexOf(u8, key, "_at_") != null);
    try std.testing.expect(std.mem.startsWith(u8, key, "npm/registry.npmjs.org/"));
    try std.testing.expect(std.mem.endsWith(u8, key, "/1.0.0"));
}

test "cache.cacheKey: name with slash sanitized" {
    const allocator = std.testing.allocator;
    const key = try cache.cacheKey(allocator, "r.example.com", "@scope/pkg", "1.0.0");
    defer allocator.free(key);
    try std.testing.expect(std.mem.indexOf(u8, key, "/") != null);
    try std.testing.expect(std.mem.indexOf(u8, key, "__") != null or std.mem.indexOf(u8, key, "_at_") != null);
}

// ---------- getCachedPackageDirPath ----------

test "cache.getCachedPackageDirPath: joins content and key" {
    const allocator = std.testing.allocator;
    const path = try cache.getCachedPackageDirPath(allocator, "/tmp/shu-cache", "npm/r.npmjs.org/pkg/1.0.0");
    defer allocator.free(path);
    try std.testing.expect(std.mem.indexOf(u8, path, "content") != null);
    try std.testing.expect(std.mem.indexOf(u8, path, "npm/r.npmjs.org/pkg/1.0.0") != null);
}

test "cache.getCachedPackageDirPath: empty key" {
    const allocator = std.testing.allocator;
    const path = try cache.getCachedPackageDirPath(allocator, "/root", "");
    defer allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "content"));
}
