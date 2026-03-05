//! Shu.events 集成测试：通过 shu -e 执行脚本，覆盖 EventEmitter、on、emit。
//! 依赖：zig build test 前会 install，故 zig-out/bin/shu 存在。

const std = @import("std");
const shu_run = @import("shu_run.zig");

fn run(allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    return shu_run.runShuWithScript(allocator, script, &.{});
}

test "Shu.events: EventEmitter on and emit" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const { EventEmitter } = require('shu:events');
        \\const e = new EventEmitter();
        \\let n = 0;
        \\e.on('tick', function() { n++; });
        \\e.emit('tick');
        \\e.emit('tick');
        \\console.log(n);
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("2", out);
}

test "Shu.events: emit with argument" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const { EventEmitter } = require('shu:events');
        \\const e = new EventEmitter();
        \\e.on('msg', function(x) { console.log(x); });
        \\e.emit('msg', 'hello');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("hello", out);
}

test "Shu.events: emit with no listeners" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const { EventEmitter } = require('shu:events');
        \\const e = new EventEmitter();
        \\e.emit('nobody');
        \\console.log('ok');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.events: off removes listener" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const { EventEmitter } = require('shu:events');
        \\const e = new EventEmitter();
        \\let n = 0;
        \\function fn() { n++; }
        \\e.on('x', fn);
        \\e.emit('x');
        \\e.off('x', fn);
        \\e.emit('x');
        \\console.log(n);
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("1", out);
}

test "Shu.events: once fires only once" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const { EventEmitter } = require('shu:events');
        \\const e = new EventEmitter();
        \\let n = 0;
        \\e.once('y', function() { n++; });
        \\e.emit('y');
        \\e.emit('y');
        \\console.log(n);
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("1", out);
}
