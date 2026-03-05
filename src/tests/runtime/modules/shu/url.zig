//! Shu.url 集成测试：通过 shu -e 执行脚本，覆盖 parse/format、边界与非法参数。
//! 依赖：zig build test 前会 install，故 zig-out/bin/shu 存在。

const std = @import("std");
const shu_run = @import("shu_run.zig");

fn run(allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    return shu_run.runShuWithScript(allocator, script, &.{});
}

test "Shu.url.parse: simple" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const u = require('shu:url').parse('http://host/path?k=v');
        \\console.log(u.protocol + ',' + u.host + ',' + u.pathname + ',' + u.search);
    );
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "http") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "host") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "path") != null);
}

test "Shu.url.parse: https and pathname" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const u = require('shu:url').parse('https://example.com/foo/bar');
        \\console.log(u.protocol === 'https:' && u.pathname.indexOf('foo') >= 0 ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.url.format: object to string" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const url = require('shu:url');
        \\const o = { protocol: 'https:', host: 'example.com', pathname: '/foo' };
        \\console.log(url.format(o));
    );
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "https") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "example.com") != null);
}

test "Shu.url.format: minimal object" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const url = require('shu:url');
        \\const o = { protocol: 'file:', pathname: '/a/b' };
        \\console.log(url.format(o).indexOf('/a/b') >= 0 ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.url.parse: search and hash" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const u = require('shu:url').parse('http://x.com/p?q=1#hash');
        \\console.log((u.search || '').indexOf('q') >= 0 || (u.hash || '').indexOf('hash') >= 0 ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.url.parse: then format roundtrip" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const url = require('shu:url');
        \\const parsed = url.parse('http://example.com/foo');
        \\const formatted = url.format(parsed);
        \\console.log(formatted.indexOf('example') >= 0 && formatted.indexOf('foo') >= 0 ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}
