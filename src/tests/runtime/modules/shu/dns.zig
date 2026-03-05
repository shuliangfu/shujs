//! Shu.dns 集成测试：通过 shu -e 执行脚本，覆盖 dns.isIP、dns.lookup（异步）等。
//! 依赖：zig build test 前会 install，故 zig-out/bin/shu 存在。

const std = @import("std");
const shu_run = @import("shu_run.zig");

fn run(allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    return shu_run.runShuWithScript(allocator, script, &.{});
}

test "Shu.dns.isIP: IPv4" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const dns = require('shu:dns');
        \\console.log(dns.isIP('127.0.0.1'));
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("4", out);
}

test "Shu.dns.isIP: IPv6" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const dns = require('shu:dns');
        \\console.log(dns.isIP('::1'));
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("6", out);
}

test "Shu.dns.isIP: invalid returns 0" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const dns = require('shu:dns');
        \\console.log(dns.isIP('not-an-ip'));
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("0", out);
}

test "Shu.dns.isIP: empty string" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const dns = require('shu:dns');
        \\console.log(dns.isIP(''));
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("0", out);
}
