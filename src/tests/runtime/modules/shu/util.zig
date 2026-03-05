//! Shu.util 集成测试：通过 shu -e 执行脚本，覆盖 util.inspect、util.promisify 等。
//! 依赖：zig build test 前会 install，故 zig-out/bin/shu 存在。

const std = @import("std");
const shu_run = @import("shu_run.zig");

fn run(allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    return shu_run.runShuWithScript(allocator, script, &.{});
}

test "Shu.util.inspect: object" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const u = require('shu:util');
        \\const s = u.inspect({ a: 1, b: 'x' });
        \\console.log(s.includes('a') && s.includes('1') && s.includes('b') && s.includes('x') ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.util.inspect: array" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const u = require('shu:util');
        \\const s = u.inspect([1, 2, 3]);
        \\console.log(s);
    );
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "1") != null and std.mem.indexOf(u8, out, "2") != null);
}

test "Shu.util.promisify: returns function" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const u = require('shu:util');
        \\function fn(cb) { setImmediate(function() { cb(null, 1); }); }
        \\const p = u.promisify(fn);
        \\console.log(typeof p === 'function' ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.util.types.isArray: true for array" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const u = require('shu:util');
        \\console.log(u.types.isArray([]) ? 'yes' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("yes", out);
}

test "Shu.util.types.isArray: false for object" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const u = require('shu:util');
        \\console.log(u.types.isArray({}) ? 'yes' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("no", out);
}

test "Shu.util.types.isFunction: true for function" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const u = require('shu:util');
        \\console.log(u.types.isFunction(function(){}) ? 'yes' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("yes", out);
}

test "Shu.util.types.isString: true for string" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const u = require('shu:util');
        \\console.log(u.types.isString('x') ? 'yes' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("yes", out);
}

test "Shu.util.types.isNumber: true for number" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const u = require('shu:util');
        \\console.log(u.types.isNumber(42) ? 'yes' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("yes", out);
}

test "Shu.util.types.isBoolean: true for boolean" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const u = require('shu:util');
        \\console.log(u.types.isBoolean(true) ? 'yes' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("yes", out);
}

test "Shu.util.types.isNull: true for null" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const u = require('shu:util');
        \\console.log(u.types.isNull(null) ? 'yes' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("yes", out);
}

test "Shu.util.types.isUndefined: true for undefined" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const u = require('shu:util');
        \\console.log(u.types.isUndefined(undefined) ? 'yes' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("yes", out);
}
