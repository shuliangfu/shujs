//! Shu.vm 集成测试：通过 shu -e 执行脚本，覆盖 vm.createContext、runInNewContext。
//! 依赖：zig build test 前会 install，故 zig-out/bin/shu 存在。

const std = @import("std");
const shu_run = @import("shu_run.zig");

fn run(allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    return shu_run.runShuWithScript(allocator, script, &.{});
}

test "Shu.vm.createContext: returns object" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const vm = require('shu:vm');
        \\const ctx = vm.createContext({});
        \\console.log(typeof ctx === 'object' && ctx !== null ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.vm.runInNewContext: isolated sandbox" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const vm = require('shu:vm');
        \\const sandbox = { x: 0 };
        \\vm.runInNewContext('x = 42', sandbox);
        \\console.log(sandbox.x);
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("42", out);
}

test "Shu.vm.runInNewContext: return value" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const vm = require('shu:vm');
        \\const res = vm.runInNewContext('1 + 2', {});
        \\console.log(res);
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("3", out);
}

test "Shu.vm.createContext: with initial object" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const vm = require('shu:vm');
        \\const ctx = vm.createContext({ foo: 10 });
        \\const res = vm.runInNewContext('foo + 1', ctx);
        \\console.log(res);
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("11", out);
}

test "Shu.vm.runInThisContext: runs in global" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const vm = require('shu:vm');
        \\globalThis._vmTest = 0;
        \\vm.runInThisContext('globalThis._vmTest = 99');
        \\console.log(globalThis._vmTest);
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("99", out);
}

test "Shu.vm.isContext: true for contextified object" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const vm = require('shu:vm');
        \\const ctx = vm.createContext({});
        \\console.log(vm.isContext(ctx) ? 'yes' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("yes", out);
}

test "Shu.vm.isContext: false for plain object" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const vm = require('shu:vm');
        \\console.log(vm.isContext({}) ? 'yes' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("no", out);
}

test "Shu.vm.Script: runInNewContext" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const vm = require('shu:vm');
        \\const script = new vm.Script('a + b');
        \\const res = script.runInNewContext({ a: 2, b: 3 });
        \\console.log(res);
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("5", out);
}

test "Shu.vm.runInContext: sandbox" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const vm = require('shu:vm');
        \\const ctx = vm.createContext({ n: 0 });
        \\vm.runInContext('n = 5', ctx);
        \\console.log(ctx.n);
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("5", out);
}
