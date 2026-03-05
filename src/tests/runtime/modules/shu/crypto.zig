//! Shu.crypto 集成测试：通过 shu -e 执行脚本，覆盖 crypto.digest 等。
//! 依赖：zig build test 前会 install，故 zig-out/bin/shu 存在。

const std = @import("std");
const shu_run = @import("shu_run.zig");

fn run(allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    return shu_run.runShuWithScript(allocator, script, &.{});
}

test "Shu.crypto.digest: SHA-256" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const crypto = require('shu:crypto');
        \\const hex = crypto.digest('SHA-256', 'hello');
        \\console.log(hex.length === 64 && /^[0-9a-f]+$/.test(hex) ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.crypto.digest: SHA-1" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const crypto = require('shu:crypto');
        \\const hex = crypto.digest('SHA-1', 'x');
        \\console.log(hex.length === 40 ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.crypto.digest: empty string" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const crypto = require('shu:crypto');
        \\const hex = crypto.digest('SHA-256', '');
        \\console.log(hex.length === 64 ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.crypto.digest: SHA-384" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const crypto = require('shu:crypto');
        \\const hex = crypto.digest('SHA-384', 'test');
        \\console.log(hex.length === 96 ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.crypto.digest: invalid algorithm throws" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const crypto = require('shu:crypto');
        \\try { crypto.digest('INVALID', 'x'); console.log('no'); } catch (e) { console.log('caught'); }
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("caught", out);
}

test "Shu.crypto.randomUUID: returns string" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const crypto = require('shu:crypto');
        \\const u = crypto.randomUUID();
        \\console.log(typeof u === 'string' && u.length === 36 && u[8] === '-' ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.crypto.randomUUID: unique each call" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const crypto = require('shu:crypto');
        \\const a = crypto.randomUUID();
        \\const b = crypto.randomUUID();
        \\console.log(a !== b ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.crypto.getRandomValues: exists" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const crypto = require('shu:crypto');
        \\console.log(typeof crypto.getRandomValues === 'function' ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}
