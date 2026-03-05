//! Shu.tty 集成测试：通过 shu -e 执行脚本，覆盖 tty.isTTY、ReadStream/WriteStream 占位。
//! 依赖：zig build test 前会 install，故 zig-out/bin/shu 存在。

const std = @import("std");
const shu_run = @import("shu_run.zig");

fn run(allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    return shu_run.runShuWithScript(allocator, script, &.{});
}

test "Shu.tty.isTTY: returns boolean" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const tty = require('shu:tty');
        \\const v = tty.isTTY(1);
        \\console.log(typeof v === 'boolean' ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.tty.isTTY: fd 0" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const tty = require('shu:tty');
        \\console.log(typeof tty.isTTY(0) === 'boolean' ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.tty.ReadStream: returns object with fd and isTTY" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const tty = require('shu:tty');
        \\const r = tty.ReadStream(0);
        \\console.log(r && typeof r.fd === 'number' && typeof r.isTTY === 'boolean' ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.tty.WriteStream: returns object with fd and isTTY" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const tty = require('shu:tty');
        \\const w = tty.WriteStream(1);
        \\console.log(w && typeof w.fd === 'number' && typeof w.isTTY === 'boolean' ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}
