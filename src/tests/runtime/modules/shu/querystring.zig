//! Shu.querystring 集成测试：通过 shu -e 执行脚本，覆盖 parse/stringify、边界与非法参数。
//! 依赖：zig build test 前会 install，故 zig-out/bin/shu 存在。

const std = @import("std");
const shu_run = @import("shu_run.zig");

fn run(allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    return shu_run.runShuWithScript(allocator, script, &.{});
}

test "Shu.querystring.parse: simple" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const q = require('shu:querystring');
        \\const o = q.parse('a=1&b=2');
        \\console.log(o.a + ',' + o.b);
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("1,2", out);
}

test "Shu.querystring.parse: with question mark" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const q = require('shu:querystring');
        \\const o = q.parse('?x=3');
        \\console.log(o.x);
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("3", out);
}

test "Shu.querystring.parse: empty string gives empty object" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const q = require('shu:querystring');
        \\const o = q.parse('');
        \\console.log(Object.keys(o).length);
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("0", out);
}

test "Shu.querystring.parse: single key value" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const q = require('shu:querystring');
        \\const o = q.parse('a=1');
        \\console.log(o.a);
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("1", out);
}

test "Shu.querystring.stringify: simple" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const q = require('shu:querystring');
        \\const s = q.stringify({ a: '1', b: '2' });
        \\console.log(s);
    );
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "a=1") != null and std.mem.indexOf(u8, out, "b=2") != null);
}

test "Shu.querystring.stringify: empty object" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const q = require('shu:querystring');
        \\const s = q.stringify({});
        \\console.log(s.length);
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("0", out);
}
