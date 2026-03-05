//! Shu.string_decoder 集成测试：通过 shu -e 执行脚本，覆盖 StringDecoder。
//! 依赖：zig build test 前会 install，故 zig-out/bin/shu 存在。

const std = @import("std");
const shu_run = @import("shu_run.zig");

fn run(allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    return shu_run.runShuWithScript(allocator, script, &.{});
}

test "Shu.string_decoder.StringDecoder: write and end" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const { StringDecoder } = require('shu:string_decoder');
        \\const B = require('shu:buffer').Buffer;
        \\const sd = new StringDecoder('utf8');
        \\const a = sd.write(B.from('hello'));
        \\const b = sd.end(B.from(' world'));
        \\console.log(a + b);
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("hello world", out);
}

test "Shu.string_decoder.StringDecoder: end without buffer" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const { StringDecoder } = require('shu:string_decoder');
        \\const B = require('shu:buffer').Buffer;
        \\const sd = new StringDecoder('utf8');
        \\const a = sd.write(B.from('hi'));
        \\const b = sd.end();
        \\console.log((a + b) === 'hi' ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.string_decoder.StringDecoder: encoding utf8" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const { StringDecoder } = require('shu:string_decoder');
        \\const sd = new StringDecoder('utf8');
        \\console.log(sd.encoding || 'utf8');
    );
    defer allocator.free(out);
    try std.testing.expect(std.mem.eql(u8, out, "utf8"));
}
