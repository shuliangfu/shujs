//! Shu.net 集成测试：通过 shu -e 执行脚本，覆盖 net.isIP、net.isIPv4、net.isIPv6。
//! 依赖：zig build test 前会 install，故 zig-out/bin/shu 存在。

const std = @import("std");
const shu_run = @import("shu_run.zig");

fn run(allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    return shu_run.runShuWithScript(allocator, script, &.{});
}

test "Shu.net.isIP: IPv4" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const net = require('shu:net');
        \\console.log(net.isIP('192.168.1.1'));
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("4", out);
}

test "Shu.net.isIPv4: valid" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const net = require('shu:net');
        \\console.log(net.isIPv4('10.0.0.1') ? 'true' : 'false');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("true", out);
}

test "Shu.net.isIPv4: IPv6 returns false" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const net = require('shu:net');
        \\console.log(net.isIPv4('::1') ? 'true' : 'false');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("false", out);
}

test "Shu.net.isIPv6: valid" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const net = require('shu:net');
        \\console.log(net.isIPv6('::1') ? 'true' : 'false');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("true", out);
}

test "Shu.net.isIPv6: IPv4 returns false" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const net = require('shu:net');
        \\console.log(net.isIPv6('127.0.0.1') ? 'true' : 'false');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("false", out);
}
