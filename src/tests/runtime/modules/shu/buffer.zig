//! Shu.buffer 集成测试：通过 shu -e 执行脚本，覆盖 Buffer.from / alloc / isBuffer / concat。
//! 依赖：zig build test 前会 install，故 zig-out/bin/shu 存在。

const std = @import("std");
const shu_run = @import("shu_run.zig");

fn run(allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    return shu_run.runShuWithScript(allocator, script, &.{});
}

test "Shu.buffer: Buffer.from string" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const B = require('shu:buffer').Buffer;
        \\const b = B.from('hello');
        \\console.log(b.toString());
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("hello", out);
}

test "Shu.buffer: Buffer.alloc and length" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const B = require('shu:buffer').Buffer;
        \\const b = B.alloc(8);
        \\console.log(b.length);
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("8", out);
}

test "Shu.buffer: Buffer.isBuffer" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const B = require('shu:buffer').Buffer;
        \\const b = B.from('x');
        \\console.log(B.isBuffer(b) ? 'yes' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("yes", out);
}

test "Shu.buffer: Buffer.concat" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const B = require('shu:buffer').Buffer;
        \\const a = B.from('ab');
        \\const c = B.from('cd');
        \\const r = B.concat([a, c]);
        \\console.log(r.toString());
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("abcd", out);
}

test "Shu.buffer: Buffer.alloc(0)" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const B = require('shu:buffer').Buffer;
        \\const b = B.alloc(0);
        \\console.log(b.length);
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("0", out);
}

test "Shu.buffer: Buffer.from empty string" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const B = require('shu:buffer').Buffer;
        \\const b = B.from('');
        \\console.log(b.length);
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("0", out);
}

test "Shu.buffer: Buffer.isBuffer non-Buffer" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const B = require('shu:buffer').Buffer;
        \\console.log(B.isBuffer({}) ? 'yes' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("no", out);
}

test "Shu.buffer: Buffer.concat empty list" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const B = require('shu:buffer').Buffer;
        \\const r = B.concat([]);
        \\console.log(r.length);
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("0", out);
}

test "Shu.buffer: Buffer.concat single buffer" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const B = require('shu:buffer').Buffer;
        \\const r = B.concat([B.from('x')]);
        \\console.log(r.toString());
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("x", out);
}

test "Shu.buffer: Buffer.allocUnsafe" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const B = require('shu:buffer').Buffer;
        \\const b = B.allocUnsafe(4);
        \\console.log(b.length);
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("4", out);
}

test "Shu.buffer: Buffer.from array" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const B = require('shu:buffer').Buffer;
        \\const b = B.from([65, 66, 67]);
        \\console.log(b.toString());
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ABC", out);
}
