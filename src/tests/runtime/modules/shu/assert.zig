//! Shu.assert 集成测试：通过 shu -e 执行脚本，覆盖 strictEqual、ok、throws、边界与非法参数。
//! 依赖：zig build test 前会 install，故 zig-out/bin/shu 存在。

const std = @import("std");
const shu_run = @import("shu_run.zig");

fn run(allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    return shu_run.runShuWithScript(allocator, script, &.{});
}

test "Shu.assert.strictEqual: equal passes" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const assert = require('shu:assert');
        \\assert.strictEqual(1, 1);
        \\console.log('ok');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.assert.strictEqual: equal strings" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const assert = require('shu:assert');
        \\assert.strictEqual('a', 'a');
        \\console.log('ok');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.assert.strictEqual: equal null" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const assert = require('shu:assert');
        \\assert.strictEqual(null, null);
        \\console.log('ok');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.assert.ok: truthy passes" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const assert = require('shu:assert');
        \\assert.ok(true);
        \\assert.ok(1);
        \\console.log('ok');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.assert.ok: false throws" {
    const allocator = std.testing.allocator;
    const s = try run(allocator,
        \\const assert = require('shu:assert');
        \\try { assert.ok(false); } catch (e) { console.log('caught'); }
    );
    defer allocator.free(s);
    try std.testing.expectEqualStrings("caught", s);
}

test "Shu.assert.strictEqual: unequal throws" {
    const allocator = std.testing.allocator;
    const s = try run(allocator,
        \\const assert = require('shu:assert');
        \\try { assert.strictEqual(1, 2); } catch (e) { console.log('caught'); }
    );
    defer allocator.free(s);
    try std.testing.expectEqualStrings("caught", s);
}

test "Shu.assert.strictEqual: 1 vs '1' throws" {
    const allocator = std.testing.allocator;
    const s = try run(allocator,
        \\const assert = require('shu:assert');
        \\try { assert.strictEqual(1, '1'); } catch (e) { console.log('caught'); }
    );
    defer allocator.free(s);
    try std.testing.expectEqualStrings("caught", s);
}

test "Shu.assert.deepStrictEqual: equal objects passes" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const assert = require('shu:assert');
        \\assert.deepStrictEqual({ a: 1 }, { a: 1 });
        \\console.log('ok');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.assert.deepStrictEqual: unequal throws" {
    const allocator = std.testing.allocator;
    const s = try run(allocator,
        \\const assert = require('shu:assert');
        \\try { assert.deepStrictEqual({ a: 1 }, { a: 2 }); } catch (e) { console.log('caught'); }
    );
    defer allocator.free(s);
    try std.testing.expectEqualStrings("caught", s);
}

test "Shu.assert.fail: throws" {
    const allocator = std.testing.allocator;
    const s = try run(allocator,
        \\const assert = require('shu:assert');
        \\try { assert.fail('msg'); } catch (e) { console.log('caught'); }
    );
    defer allocator.free(s);
    try std.testing.expectEqualStrings("caught", s);
}

test "Shu.assert.throws: fn that throws passes" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const assert = require('shu:assert');
        \\assert.throws(function() { throw new Error('x'); });
        \\console.log('ok');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.assert.throws: fn that does not throw fails" {
    const allocator = std.testing.allocator;
    const s = try run(allocator,
        \\const assert = require('shu:assert');
        \\try { assert.throws(function() {}); } catch (e) { console.log('caught'); }
    );
    defer allocator.free(s);
    try std.testing.expectEqualStrings("caught", s);
}

test "Shu.assert.doesNotThrow: fn that does not throw passes" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const assert = require('shu:assert');
        \\assert.doesNotThrow(function() {});
        \\console.log('ok');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}
