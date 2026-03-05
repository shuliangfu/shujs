//! Shu.url 集成测试：通过 shu -e 执行脚本，覆盖 parse / format（及 URL 若已挂载）。
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
