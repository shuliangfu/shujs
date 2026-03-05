//! 全局 setTimeout/clearTimeout 集成测试：通过 shu -e 执行脚本。
//! 依赖：zig build test 前会 install，故 zig-out/bin/shu 存在。

const std = @import("std");
const shu_run = @import("shu_run.zig");

fn run(allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    return shu_run.runShuWithScript(allocator, script, &.{});
}

test "setTimeout: fires once" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\var n = 0;
        \\setTimeout(function() { n++; console.log(n); }, 0);
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("1", out);
}

test "clearTimeout: cancels callback" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\var n = 0;
        \\var id = setTimeout(function() { n++; }, 10);
        \\clearTimeout(id);
        \\setTimeout(function() { console.log(n); }, 20);
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("0", out);
}

test "setInterval: fires multiple times" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\var n = 0;
        \\var id = setInterval(function() {
        \\  n++;
        \\  if (n >= 2) { clearInterval(id); console.log(n); }
        \\}, 0);
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("2", out);
}

test "clearInterval: stops interval" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\var n = 0;
        \\var id = setInterval(function() { n++; }, 0);
        \\clearInterval(id);
        \\setTimeout(function() { console.log(n); }, 10);
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("0", out);
}

test "setImmediate: runs after sync" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\var s = '';
        \\setImmediate(function() { s += 'b'; console.log(s); });
        \\s = 'a';
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ab", out);
}

test "clearImmediate: cancels" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\var n = 0;
        \\var id = setImmediate(function() { n++; });
        \\clearImmediate(id);
        \\setImmediate(function() { console.log(n); });
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("0", out);
}

test "shu:timers setTimeout" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const timers = require('shu:timers');
        \\var n = 0;
        \\timers.setTimeout(function() { n++; console.log(n); }, 0);
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("1", out);
}

test "queueMicrotask: runs before setTimeout" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\var s = '';
        \\setTimeout(function() { s += 't'; console.log(s); }, 0);
        \\queueMicrotask(function() { s += 'm'; });
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("mt", out);
}
