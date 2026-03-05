//! Shu.stream 集成测试：通过 shu -e 执行脚本，覆盖 Readable、PassThrough 等。
//! 依赖：zig build test 前会 install，故 zig-out/bin/shu 存在。

const std = @import("std");
const shu_run = @import("shu_run.zig");

fn run(allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    return shu_run.runShuWithScript(allocator, script, &.{});
}

test "Shu.stream.Readable: constructor" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const { Readable } = require('shu:stream');
        \\const r = new Readable();
        \\console.log(r.readable !== undefined ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.stream.PassThrough: pipe" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const { PassThrough } = require('shu:stream');
        \\const a = new PassThrough();
        \\const b = new PassThrough();
        \\var out = '';
        \\b.on('data', function(chunk) { out += chunk.toString(); });
        \\b.on('end', function() { console.log(out); });
        \\a.pipe(b);
        \\a.end('hello');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("hello", out);
}

test "Shu.stream.Writable: write and end" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const { Writable } = require('shu:stream');
        \\var buf = '';
        \\const w = new Writable();
        \\w._write = function(chunk, enc, cb) { buf += chunk.toString(); cb(); };
        \\w.write('a');
        \\w.end('b');
        \\w.on('finish', function() { console.log(buf); });
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ab", out);
}

test "Shu.stream.Duplex: read and write" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const { Duplex } = require('shu:stream');
        \\const d = new Duplex();
        \\d.push('x');
        \\d.push(null);
        \\var s = '';
        \\d.on('data', function(c) { s += c.toString(); });
        \\d.on('end', function() { console.log(s); });
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("x", out);
}

test "Shu.stream.pipeline: passes data" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const stream = require('shu:stream');
        \\const a = new stream.PassThrough();
        \\const b = new stream.PassThrough();
        \\var result = '';
        \\b.on('data', function(c) { result += c.toString(); });
        \\stream.pipeline(a, b, function(err) {
        \\  if (err) { console.log('err'); return; }
        \\  console.log(result);
        \\});
        \\a.end('piped');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("piped", out);
}

test "Shu.stream.finished: callback on end" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const stream = require('shu:stream');
        \\const r = new stream.PassThrough();
        \\r.end();
        \\stream.finished(r, function(err) { console.log(err ? 'err' : 'ok'); });
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}
