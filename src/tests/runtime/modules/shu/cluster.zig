//! Shu.cluster 集成测试：通过 shu -e 执行脚本，覆盖 cluster.fork、setupPrimary、disconnect 等占位 API。
//! 依赖：zig build test 前会 install，故 zig-out/bin/shu 存在。

const std = @import("std");
const shu_run = @import("shu_run.zig");

fn run(allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    return shu_run.runShuWithScript(allocator, script, &.{});
}

test "Shu.cluster: module loads" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const cluster = require('shu:cluster');
        \\console.log(cluster && typeof cluster.fork === 'function' ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.cluster.setupPrimary: no-op" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const cluster = require('shu:cluster');
        \\cluster.setupPrimary({});
        \\console.log('ok');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.cluster.disconnect: no-op" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const cluster = require('shu:cluster');
        \\cluster.disconnect();
        \\console.log('ok');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}
