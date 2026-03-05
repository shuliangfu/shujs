//! Shu.intl 集成测试：通过 shu -e 执行脚本，覆盖 getIntl、Segmenter。
//! 依赖：zig build test 前会 install，故 zig-out/bin/shu 存在。

const std = @import("std");
const shu_run = @import("shu_run.zig");

fn run(allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    return shu_run.runShuWithScript(allocator, script, &.{});
}

test "Shu.intl.getIntl: returns Intl" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const intl = require('shu:intl');
        \\const I = intl.getIntl();
        \\console.log(I && typeof I === 'object' ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.intl.getIntl: same as global Intl" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const intl = require('shu:intl');
        \\const I = intl.getIntl();
        \\console.log(I === globalThis.Intl ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.intl.Segmenter: exists or undefined" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const intl = require('shu:intl');
        \\const S = intl.Segmenter;
        \\console.log(typeof S === 'function' || S === undefined ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}
