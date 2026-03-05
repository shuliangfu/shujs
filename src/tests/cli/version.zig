//! CLI version 模块单元测试：VERSION 常量。
//! 被测：src/cli/version.zig。printVersion/printCommandHeader 需 io，此处仅测常量。

const std = @import("std");
const version = @import("../../cli/version.zig");

test "version.VERSION: non-empty and semantic-like" {
    try std.testing.expect(version.VERSION.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, version.VERSION, ".") != null);
}

test "version.VERSION: current value" {
    try std.testing.expectEqualStrings(version.VERSION, "0.1.0");
}
