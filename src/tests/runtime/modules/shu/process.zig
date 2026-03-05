//! process 全局对象集成测试：通过 shu -e 执行，覆盖 process.cwd、process.argv。
//! 依赖：zig build test 前会 install，故 zig-out/bin/shu 存在。

const std = @import("std");
const shu_run = @import("shu_run.zig");

fn run(allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    return shu_run.runShuWithScript(allocator, script, &.{});
}

test "process.cwd: returns string" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\console.log(typeof process.cwd());
        \\console.log(process.cwd().length > 0 ? 'has-cwd' : 'empty');
    );
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "string") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "has-cwd") != null);
}

test "process.argv: is array" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\console.log(Array.isArray(process.argv) ? 'array' : 'no');
        \\console.log(process.argv.length >= 1 ? 'has-argv' : 'empty');
    );
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "array") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "has-argv") != null);
}

test "process.env: is object" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\console.log(process.env !== null && typeof process.env === 'object' ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "process.cwd: callable" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const cwd = process.cwd();
        \\console.log(typeof cwd === 'string' ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}
