//! Shu.perf_hooks 集成测试：通过 shu -e 执行脚本，覆盖 performance.now()。
//! 依赖：zig build test 前会 install，故 zig-out/bin/shu 存在。

const std = @import("std");
const shu_run = @import("shu_run.zig");

fn run(allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    return shu_run.runShuWithScript(allocator, script, &.{});
}

test "Shu.perf_hooks.performance.now: returns number" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const { performance } = require('shu:perf_hooks');
        \\const t = performance.now();
        \\console.log(typeof t === 'number' && t >= 0 ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.perf_hooks.performance.timeOrigin: is number" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const { performance } = require('shu:perf_hooks');
        \\console.log(typeof performance.timeOrigin === 'number' ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.perf_hooks.performance.mark: and getEntriesByName" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const { performance } = require('shu:perf_hooks');
        \\performance.mark('a');
        \\const entries = performance.getEntriesByName('a');
        \\console.log(Array.isArray(entries) && entries.length >= 1 ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.perf_hooks.performance.measure: and getEntriesByType" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const { performance } = require('shu:perf_hooks');
        \\performance.mark('m1');
        \\performance.mark('m2');
        \\performance.measure('m', 'm1', 'm2');
        \\const entries = performance.getEntriesByType('measure');
        \\console.log(Array.isArray(entries) && entries.length >= 1 ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.perf_hooks.performance.clearMarks" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const { performance } = require('shu:perf_hooks');
        \\performance.mark('x');
        \\performance.clearMarks('x');
        \\const e = performance.getEntriesByName('x');
        \\console.log(e.length === 0 ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.perf_hooks.performance.getEntries: returns array" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const { performance } = require('shu:perf_hooks');
        \\const entries = performance.getEntries();
        \\console.log(Array.isArray(entries) ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}
