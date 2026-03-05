//! Shu.os 集成测试：通过 shu -e 执行脚本，覆盖 platform、arch、EOL 等。
//! 依赖：zig build test 前会 install，故 zig-out/bin/shu 存在。

const std = @import("std");
const shu_run = @import("shu_run.zig");

fn run(allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    return shu_run.runShuWithScript(allocator, script, &.{});
}

test "Shu.os.platform: returns string" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const os = require('shu:os');
        \\const p = os.platform();
        \\console.log(p === 'darwin' || p === 'linux' || p === 'win32' ? 'ok' : p);
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.os.arch: returns string" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const os = require('shu:os');
        \\const a = os.arch();
        \\console.log(a === 'x64' || a === 'arm64' || a === 'ia32' ? 'ok' : a);
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.os.EOL: is string" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const os = require('shu:os');
        \\console.log(os.EOL.length >= 1 ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.os.homedir: returns string" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const os = require('shu:os');
        \\const h = os.homedir();
        \\console.log(typeof h === 'string' && h.length >= 1 ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.os.tmpdir: returns string" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const os = require('shu:os');
        \\const t = os.tmpdir();
        \\console.log(typeof t === 'string' && t.length >= 1 ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.os.hostname: returns string" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const os = require('shu:os');
        \\const n = os.hostname();
        \\console.log(typeof n === 'string' ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.os.type: returns string" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const os = require('shu:os');
        \\const ty = os.type();
        \\console.log(typeof ty === 'string' && ty.length >= 1 ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.os.cpus: returns array" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const os = require('shu:os');
        \\const c = os.cpus();
        \\console.log(Array.isArray(c) && c.length >= 1 ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}
