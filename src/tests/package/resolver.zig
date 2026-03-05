//! package/resolver 纯逻辑单元测试：jsrSpecToScopeName。
//! 被测：src/package/resolver.zig。

const std = @import("std");
const resolver = @import("../../package/resolver.zig");

test "resolver.jsrSpecToScopeName: jsr:@scope/name" {
    const allocator = std.testing.allocator;
    const name = try resolver.jsrSpecToScopeName(allocator, "jsr:@scope/name");
    defer allocator.free(name);
    try std.testing.expectEqualStrings(name, "@scope/name");
}

test "resolver.jsrSpecToScopeName: jsr:@scope/name@version" {
    const allocator = std.testing.allocator;
    const name = try resolver.jsrSpecToScopeName(allocator, "jsr:@dreamer/view@1.0.0");
    defer allocator.free(name);
    try std.testing.expectEqualStrings(name, "@dreamer/view");
}

test "resolver.jsrSpecToScopeName: invalid no jsr: prefix" {
    const allocator = std.testing.allocator;
    const r = resolver.jsrSpecToScopeName(allocator, "@scope/name");
    try std.testing.expectError(error.InvalidJsrSpecifier, r);
}

test "resolver.jsrSpecToScopeName: invalid no at after jsr:" {
    const allocator = std.testing.allocator;
    const r = resolver.jsrSpecToScopeName(allocator, "jsr:scope/name");
    try std.testing.expectError(error.InvalidJsrSpecifier, r);
}

test "resolver.jsrSpecToScopeName: invalid no slash" {
    const allocator = std.testing.allocator;
    const r = resolver.jsrSpecToScopeName(allocator, "jsr:@scope");
    try std.testing.expectError(error.InvalidJsrSpecifier, r);
}

test "resolver.jsrSpecToScopeName: empty after jsr:" {
    const allocator = std.testing.allocator;
    const r = resolver.jsrSpecToScopeName(allocator, "jsr:");
    try std.testing.expectError(error.InvalidJsrSpecifier, r);
}
