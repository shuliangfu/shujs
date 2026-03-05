//! Shu.readline 集成测试：通过 shu -e 执行脚本，覆盖 createInterface 等。
//! 依赖：zig build test 前会 install，故 zig-out/bin/shu 存在。

const std = @import("std");
const shu_run = @import("shu_run.zig");

fn run(allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    return shu_run.runShuWithScript(allocator, script, &.{});
}

test "Shu.readline: module loads" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const rl = require('shu:readline');
        \\console.log(rl && typeof rl.createInterface === 'function' ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.readline.createInterface: returns object with on and close" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const rl = require('shu:readline');
        \\const { PassThrough } = require('shu:stream');
        \\const input = new PassThrough();
        \\const iface = rl.createInterface({ input });
        \\console.log(iface && typeof iface.on === 'function' && typeof iface.close === 'function' ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}
