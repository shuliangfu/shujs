//! package/export_map 单元测试：exports 解析、主入口与子路径、条件、边界与非法输入。
//! 被测模块：src/package/export_map.zig（仅依赖 std）。

const std = @import("std");
const export_map = @import("../../package/export_map.zig");

/// 从 JSON 字符串解析为 Value，调用 resolve，deinit 解析结果；caller_owns 时由调用方 free path。
fn resolveFromJson(allocator: std.mem.Allocator, json_str: []const u8, subpath: []const u8, condition: export_map.Condition) !?export_map.ResolveExportResult {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    return try export_map.resolve(allocator, parsed.value, subpath, condition);
}

// ---------- 字符串 exports ----------

test "export_map.resolve: string exports main entry" {
    const allocator = std.testing.allocator;
    const result = try resolveFromJson(allocator, "\"./index.js\"", "", .import);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(result.?.path, "./index.js");
    try std.testing.expect(!result.?.caller_owns);
}

test "export_map.resolve: string exports main entry require" {
    const allocator = std.testing.allocator;
    const result = try resolveFromJson(allocator, "\"./cjs.js\"", "", .require);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(result.?.path, "./cjs.js");
}

test "export_map.resolve: string exports subpath request returns null" {
    const allocator = std.testing.allocator;
    const result = try resolveFromJson(allocator, "\"./index.js\"", "utils", .import);
    try std.testing.expect(result == null);
}

// ---------- 对象 exports "." ----------

test "export_map.resolve: object exports . key" {
    const allocator = std.testing.allocator;
    const result = try resolveFromJson(allocator, "{\".\": \"./dist/index.js\"}", "", .require);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(result.?.path, "./dist/index.js");
}

test "export_map.resolve: subpath exact match" {
    const allocator = std.testing.allocator;
    const result = try resolveFromJson(allocator, "{\".\": \"./index.js\", \"./utils\": \"./lib/utils.js\"}", "utils", .import);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(result.?.path, "./lib/utils.js");
}

// ---------- 条件 import/require/default ----------

test "export_map.resolve: conditional import vs require" {
    const allocator = std.testing.allocator;
    const json = "{\".\": {\"import\": \"./esm.js\", \"require\": \"./cjs.js\", \"default\": \"./cjs.js\"}}";
    const imp = try resolveFromJson(allocator, json, "", .import);
    const req = try resolveFromJson(allocator, json, "", .require);
    try std.testing.expect(imp != null and req != null);
    try std.testing.expectEqualStrings(imp.?.path, "./esm.js");
    try std.testing.expectEqualStrings(req.?.path, "./cjs.js");
}

test "export_map.resolve: conditional default only" {
    const allocator = std.testing.allocator;
    const json = "{\".\": {\"default\": \"./main.js\"}}";
    const imp = try resolveFromJson(allocator, json, "", .import);
    const req = try resolveFromJson(allocator, json, "", .require);
    try std.testing.expect(imp != null and req != null);
    try std.testing.expectEqualStrings(imp.?.path, "./main.js");
    try std.testing.expectEqualStrings(req.?.path, "./main.js");
}

test "export_map.resolve: conditional import string require non-string returns null for require" {
    const allocator = std.testing.allocator;
    const json = "{\".\": {\"import\": \"./esm.js\", \"require\": 123}}";
    const imp = try resolveFromJson(allocator, json, "", .import);
    const req = try resolveFromJson(allocator, json, "", .require);
    try std.testing.expect(imp != null);
    try std.testing.expectEqualStrings(imp.?.path, "./esm.js");
    try std.testing.expect(req == null);
}

// ---------- 未找到 / 非法类型 ----------

test "export_map.resolve: not found subpath" {
    const allocator = std.testing.allocator;
    const result = try resolveFromJson(allocator, "{\".\": \"./index.js\"}", "nonexistent", .import);
    try std.testing.expect(result == null);
}

test "export_map.resolve: exports is empty object no . key returns null for main" {
    const allocator = std.testing.allocator;
    const result = try resolveFromJson(allocator, "{}", "", .import);
    try std.testing.expect(result == null);
}

test "export_map.resolve: exports is number returns null" {
    const allocator = std.testing.allocator;
    const result = try resolveFromJson(allocator, "42", "", .import);
    try std.testing.expect(result == null);
}

test "export_map.resolve: exports is array returns null" {
    const allocator = std.testing.allocator;
    const result = try resolveFromJson(allocator, "[\"./a.js\"]", "", .import);
    try std.testing.expect(result == null);
}

// ---------- 通配符 ----------

test "export_map.resolve: wildcard ./utils/*" {
    const allocator = std.testing.allocator;
    const result = try resolveFromJson(allocator, "{\"./utils/*\": \"./lib/*\"}", "utils/foo", .import);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(result.?.path, "./lib/foo");
    try std.testing.expect(result.?.caller_owns);
    if (result.?.caller_owns) allocator.free(result.?.path);
}

test "export_map.resolve: wildcard longest match" {
    const allocator = std.testing.allocator;
    const json = "{\"./utils/*\": \"./lib1/*\", \"./utils/bar/*\": \"./lib2/*\"}";
    const r1 = try resolveFromJson(allocator, json, "utils/bar/x", .import);
    try std.testing.expect(r1 != null);
    try std.testing.expectEqualStrings(r1.?.path, "./lib2/x");
    if (r1.?.caller_owns) allocator.free(r1.?.path);
    const r2 = try resolveFromJson(allocator, json, "utils/foo", .import);
    try std.testing.expect(r2 != null);
    try std.testing.expectEqualStrings(r2.?.path, "./lib1/foo");
    if (r2.?.caller_owns) allocator.free(r2.?.path);
}

test "export_map.resolve: wildcard no match for subpath" {
    const allocator = std.testing.allocator;
    const result = try resolveFromJson(allocator, "{\"./utils/*\": \"./lib/*\"}", "other/foo", .import);
    try std.testing.expect(result == null);
}

test "export_map.resolve: wildcard value no star returns target as-is" {
    const allocator = std.testing.allocator;
    const result = try resolveFromJson(allocator, "{\"./utils/*\": \"./lib/fixed.js\"}", "utils/anything", .import);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(result.?.path, "./lib/fixed.js");
    try std.testing.expect(!result.?.caller_owns);
}

test "export_map.resolve: subpath with multiple segments" {
    const allocator = std.testing.allocator;
    const result = try resolveFromJson(allocator, "{\"./a/b/c/*\": \"./out/*\"}", "a/b/c/d/e", .import);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(result.?.path, "./out/d/e");
    if (result.?.caller_owns) allocator.free(result.?.path);
}

// ---------- 条件值为非字符串 / 缺 default ----------

test "export_map.resolve: conditional object import non-string falls back to default" {
    const allocator = std.testing.allocator;
    const json = "{\".\": {\"import\": {}, \"require\": \"cjs.js\", \"default\": \"./main.js\"}}";
    const imp = try resolveFromJson(allocator, json, "", .import);
    try std.testing.expect(imp != null);
    try std.testing.expectEqualStrings(imp.?.path, "./main.js");
}

test "export_map.resolve: conditional object no string value returns null" {
    const allocator = std.testing.allocator;
    const json = "{\".\": {\"import\": 1, \"require\": 2, \"default\": null}}";
    const imp = try resolveFromJson(allocator, json, "", .import);
    try std.testing.expect(imp == null);
}

test "export_map.resolve: main entry subpath empty string" {
    const allocator = std.testing.allocator;
    const result = try resolveFromJson(allocator, "{\".\": \"./index.js\"}", "", .import);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(result.?.path, "./index.js");
}

test "export_map.resolve: wildcard single segment" {
    const allocator = std.testing.allocator;
    const result = try resolveFromJson(allocator, "{\"./*\": \"./dist/*\"}", "foo", .import);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings(result.?.path, "./dist/foo");
    if (result.?.caller_owns) allocator.free(result.?.path);
}
