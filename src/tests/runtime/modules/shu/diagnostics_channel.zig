//! Shu.diagnostics_channel 集成测试：通过 shu -e 执行脚本，覆盖 channel、subscribe、publish、hasSubscribers。
//! 依赖：zig build test 前会 install，故 zig-out/bin/shu 存在。

const std = @import("std");
const shu_run = @import("shu_run.zig");

fn run(allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    return shu_run.runShuWithScript(allocator, script, &.{});
}

test "Shu.diagnostics_channel.channel: create and hasSubscribers" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const dc = require('shu:diagnostics_channel');
        \\const ch = dc.channel('test');
        \\console.log(dc.hasSubscribers('test') ? 'yes' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("no", out);
}

test "Shu.diagnostics_channel: subscribe and publish" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const dc = require('shu:diagnostics_channel');
        \\let received = null;
        \\dc.subscribe('ev', function(msg) { received = msg; });
        \\dc.publish('ev', { x: 1 });
        \\console.log(received && received.x === 1 ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.diagnostics_channel: hasSubscribers after subscribe" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const dc = require('shu:diagnostics_channel');
        \\dc.subscribe('has', function() {});
        \\const has = dc.hasSubscribers('has');
        \\dc.unsubscribe('has', function() {});
        \\console.log(has ? 'yes' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("yes", out);
}
