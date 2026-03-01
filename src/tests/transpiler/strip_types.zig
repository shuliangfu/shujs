// strip_types 单元测试：类型擦除与 findNextOfAny
// 被测模块：入口在 src/test_runner.zig（根为 src/），此处可直接按路径导入
const std = @import("std");
const strip_types = @import("../../transpiler/strip_types.zig");

test "strip_types: variable annotation" {
    const allocator = std.testing.allocator;
    const out = try strip_types.strip(allocator, "const x: number = 1;");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("const x = 1;", out);
}

test "strip_types: return type" {
    const allocator = std.testing.allocator;
    const out = try strip_types.strip(allocator, "function f(): void { }");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("function f() { }", out);
}

test "strip_types: string with colon" {
    const allocator = std.testing.allocator;
    const out = try strip_types.strip(allocator, "console.log(\"TS:\", x: number);");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("console.log(\"TS:\", x);", out);
}

test "findNextOfAny" {
    const needles = [_]u8{ ':', ')', '<' };
    try std.testing.expect(strip_types.findNextOfAny(", x: number);", &needles) == 3);
    try std.testing.expect(strip_types.findNextOfAny("abc", &needles) == 3);
    try std.testing.expect(strip_types.findNextOfAny(")", &needles) == 0);
}
