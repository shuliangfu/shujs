//! Shu.module 集成测试：通过 shu -e 执行脚本，覆盖 isBuiltin、builtinModules。
//! 依赖：zig build test 前会 install，故 zig-out/bin/shu 存在。

const std = @import("std");
const shu_run = @import("shu_run.zig");

fn run(allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    return shu_run.runShuWithScript(allocator, script, &.{});
}

test "Shu.module.isBuiltin: shu:path" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const m = require('shu:module');
        \\console.log(m.isBuiltin('shu:path') ? 'yes' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("yes", out);
}

test "Shu.module.isBuiltin: non-builtin" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const m = require('shu:module');
        \\console.log(m.isBuiltin('not-builtin') ? 'yes' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("no", out);
}

test "Shu.module.builtinModules: includes shu:path" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const m = require('shu:module');
        \\console.log(Array.isArray(m.builtinModules) && m.builtinModules.indexOf('shu:path') >= 0 ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.module.createRequire: returns function" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const m = require('shu:module');
        \\const req = m.createRequire(process.cwd() + '/package.json');
        \\console.log(typeof req === 'function' && typeof req.resolve === 'function' ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.module.createRequire().resolve: shu:path" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const m = require('shu:module');
        \\const req = m.createRequire(process.cwd() + '/package.json');
        \\const path = req.resolve('shu:path');
        \\console.log(path && path.length > 0 ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}
