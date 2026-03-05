//! Shu.zlib 集成测试：通过 shu -e 执行脚本，覆盖 deflateSync、gzipSync。
//! 依赖：zig build test 前会 install，故 zig-out/bin/shu 存在。
//! 说明：当前仅暴露压缩接口（deflateSync/gzipSync/brotliSync），无 JS 侧解压接口，故只测压缩输出。

const std = @import("std");
const shu_run = @import("shu_run.zig");

fn run(allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    return shu_run.runShuWithScript(allocator, script, &.{});
}

test "Shu.zlib.deflateSync: returns Uint8Array" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const zlib = require('shu:zlib');
        \\const B = require('shu:buffer').Buffer;
        \\const raw = B.from('hello');
        \\const compressed = zlib.deflateSync(raw);
        \\console.log(compressed && compressed.length > 0 && compressed.length < raw.length ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}

test "Shu.zlib.gzipSync: returns Uint8Array" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const zlib = require('shu:zlib');
        \\const B = require('shu:buffer').Buffer;
        \\const raw = B.from('data');
        \\const compressed = zlib.gzipSync(raw);
        \\console.log(compressed && compressed.length > 0 ? 'ok' : 'no');
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("ok", out);
}
