//! transpiler/ts.zig 单元测试：transpile（类型擦除）委托 strip_types，覆盖边界与各类 TS 输入。
//! 被测模块：src/transpiler/ts.zig。

const std = @import("std");
const ts = @import("../../transpiler/ts.zig");

test "ts.transpile: type annotation removed" {
    const allocator = std.testing.allocator;
    const out = try ts.transpile(allocator, "const x: number = 1;", false);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "number") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "x") != null);
}

test "ts.transpile: check_types true still strips" {
    const allocator = std.testing.allocator;
    const out = try ts.transpile(allocator, "let a: string = 'hi';", true);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "string") == null);
}

test "ts.transpile: empty string" {
    const allocator = std.testing.allocator;
    const out = try ts.transpile(allocator, "", false);
    defer allocator.free(out);
    try std.testing.expect(out.len == 0);
}

test "ts.transpile: whitespace only" {
    const allocator = std.testing.allocator;
    const out = try ts.transpile(allocator, "   \n\t  ", false);
    defer allocator.free(out);
    try std.testing.expect(out.len == 7);
}

test "ts.transpile: no type annotation unchanged" {
    const allocator = std.testing.allocator;
    const src = "const x = 1;";
    const out = try ts.transpile(allocator, src, false);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(out, src);
}

test "ts.transpile: function return type" {
    const allocator = std.testing.allocator;
    const out = try ts.transpile(allocator, "function f(): number { return 1; }", false);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "number") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "function") != null);
}

test "ts.transpile: generic bracket stripped" {
    const allocator = std.testing.allocator;
    const out = try ts.transpile(allocator, "const x: Array<number> = [];", false);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Array") != null);
}
