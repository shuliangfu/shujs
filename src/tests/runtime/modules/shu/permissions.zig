//! Shu.permissions 集成测试：通过 shu -e 执行脚本，覆盖 permissions.has()。
//! 默认无权限；带 --allow-read 等时 has 返回 true。依赖：zig build test 前会 install。

const std = @import("std");
const shu_run = @import("shu_run.zig");

/// 运行脚本且不带额外权限（默认 deny）
fn run(allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    return shu_run.runShuWithScript(allocator, script, &.{});
}

/// 运行脚本并传入 argv（如 --allow-read）
fn runWithArgs(allocator: std.mem.Allocator, script: []const u8, args: []const []const u8) ![]const u8 {
    return shu_run.runShuWithScript(allocator, script, args);
}

test "Shu.permissions.has: no arg returns boolean" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const p = require('shu:permissions');
        \\const h = p.has();
        \\console.log(typeof h === 'boolean' ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.permissions.has: net denied by default" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const p = require('shu:permissions');
        \\console.log(p.has('net') ? 'yes' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("no", out);
}

test "Shu.permissions.has: read granted with --allow-read" {
    const allocator = std.testing.allocator;
    const out = try runWithArgs(allocator,
        \\const p = require('shu:permissions');
        \\console.log(p.has('read') ? 'yes' : 'no');
    , &.{"--allow-read"});
    defer allocator.free(out);
    try std.testing.expectEqualStrings("yes", out);
}

test "Shu.permissions.request: returns state" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const p = require('shu:permissions');
        \\const r = p.request('net');
        \\console.log(r && typeof r.state === 'string' ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}
