//! console 全局 / shu:console 集成测试：通过 shu -e 执行，覆盖 log、error。
//! 依赖：zig build test 前会 install，故 zig-out/bin/shu 存在。

const std = @import("std");
const shu_run = @import("shu_run.zig");

fn run(allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    return shu_run.runShuWithScript(allocator, script, &.{});
}

test "console.log: single arg" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.log('ok');");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "console.log: multiple args" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.log(1, 'x', 2);");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "1") != null and std.mem.indexOf(u8, out, "x") != null);
}

test "console.warn: output" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.warn('warn-msg');");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "warn-msg") != null);
}

test "console.error: output" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.error('err-msg');");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "err-msg") != null);
}

test "console.info: output" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.info('info-msg');");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "info-msg") != null);
}

test "console.debug: output" {
    const allocator = std.testing.allocator;
    const out = try run(allocator, "console.debug('dbg-msg');");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "dbg-msg") != null);
}

test "require shu:console has log" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const c = require('shu:console');
        \\console.log(typeof c.log === 'function' ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}
