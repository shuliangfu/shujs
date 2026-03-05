//! 全局 atob/btoa（encoding 模块注册）集成测试：通过 shu -e 执行脚本。
//! 依赖：zig build test 前会 install，故 zig-out/bin/shu 存在。

const std = @import("std");
const shu_run = @import("shu_run.zig");

fn run(allocator: std.mem.Allocator, script: []const u8) ![]const u8 {
    return shu_run.runShuWithScript(allocator, script, &.{});
}

test "encoding.btoa: single char" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\console.log(btoa('a'));
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("YQ==", out);
}

test "encoding.atob: roundtrip" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\const b = btoa('hello');
        \\console.log(atob(b));
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("hello", out);
}

test "encoding.atob: invalid throws" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\try { atob('!!!'); console.log('no'); } catch (e) { console.log('caught'); }
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("caught", out);
}

test "encoding.btoa: empty string" {
    const allocator = std.testing.allocator;
    const out = try run(allocator,
        \\console.log(btoa('').length);
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("0", out);
}
