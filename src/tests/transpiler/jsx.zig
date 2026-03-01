// jsx 单元测试：JSX 变换（view / React / Preact）
// 被测模块：入口在 src/test_runner.zig（根为 src/），此处可直接按路径导入
const std = @import("std");
const jsx = @import("../../transpiler/jsx.zig");

test "jsx: self-closing (view default)" {
    const allocator = std.testing.allocator;
    const out = try jsx.transformDefault(allocator, "<br />");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("jsx(\"br\", {})", out);
}

test "jsx: element with text child (view default)" {
    const allocator = std.testing.allocator;
    const out = try jsx.transformDefault(allocator, "<h1>Hello</h1>");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("jsxs(\"h1\", {children: [\"Hello\"] })", out);
}

test "jsx: element with attribute (view default)" {
    const allocator = std.testing.allocator;
    const out = try jsx.transformDefault(allocator, "<div className=\"box\">x</div>");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "className") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"box\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "jsxs") != null);
}

test "jsx: classic React (createElement)" {
    const allocator = std.testing.allocator;
    const out = try jsx.transformWithOptions(allocator, "<span>hi</span>", jsx.TransformOptions.forReact());
    defer allocator.free(out);
    try std.testing.expectEqualStrings("React.createElement(\"span\", null, \"hi\")", out);
}

test "jsx: pragma h (Preact classic)" {
    const allocator = std.testing.allocator;
    const out = try jsx.transform(allocator, "<span>hi</span>", "h");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("h(\"span\", null, \"hi\")", out);
}

test "jsx: expression child (view default)" {
    const allocator = std.testing.allocator;
    const out = try jsx.transformDefault(allocator, "<div>{name}</div>");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "name") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "jsxs") != null);
}

test "jsx: nested elements (view default)" {
    const allocator = std.testing.allocator;
    const out = try jsx.transformDefault(allocator, "<a><b>nested</b></a>");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"b\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "nested") != null);
}

test "jsx: fragment (view default)" {
    const allocator = std.testing.allocator;
    const out = try jsx.transformDefault(allocator, "<>a</>");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Fragment") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"a\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "jsxs") != null);
}

test "jsx: fragment with children (view default)" {
    const allocator = std.testing.allocator;
    const out = try jsx.transformDefault(allocator, "<><span>1</span><span>2</span></>");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Fragment") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"2\"") != null);
}

test "jsx: comment skipped" {
    const allocator = std.testing.allocator;
    const out = try jsx.transformDefault(allocator, "<div>{/* comment */}x</div>");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "comment") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"x\"") != null);
}

test "jsx: namespaced tag" {
    const allocator = std.testing.allocator;
    const out = try jsx.transformDefault(allocator, "<svg:path d=\"M0 0\"/>");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "svg:path") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "M0 0") != null);
}

test "jsx: fragment with custom type (view options)" {
    const allocator = std.testing.allocator;
    const out = try jsx.transformWithOptions(allocator, "<>hi</>", .{ .pragma = "h", .fragment_type = "Fragment" });
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "Fragment") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"hi\"") != null);
}
