// Node package.json「exports」条件与子路径解析
// 参考：docs/PACKAGE_DESIGN.md §4、Node Package exports
// 输入 (exports 值, 子路径, 条件 import/require) → 输出包内相对路径（如 ./index.js），调用方与包目录 join

const std = @import("std");

/// 解析条件：require 对应 CJS，import 对应 ESM
pub const Condition = enum { require, import };

/// 解析结果：path 为包内相对路径；caller_owns 为 true 时表示 path 由 allocator 分配，调用方须 free
pub const ResolveExportResult = struct { path: []const u8, caller_owns: bool };

/// 根据 package.json 的 exports 值与请求子路径、条件，解析出包内相对路径（以 ./ 开头）。
/// subpath 为空表示包主入口（即 "."）；否则为子路径且不含前导 "."，如 "utils" 表示 "./utils"。
/// 未找到返回 null。否则：caller_owns 为 true 时 [Allocates] result.path，调用方须 free；caller_owns 为 false 时 [Borrows]，调用方无需 free。
pub fn resolve(
    allocator: std.mem.Allocator,
    exports_value: std.json.Value,
    subpath: []const u8,
    condition: Condition,
) !?ResolveExportResult {
    const key = if (subpath.len == 0) "." else try std.fmt.allocPrint(allocator, "./{s}", .{subpath});
    defer if (subpath.len > 0) allocator.free(key);
    return resolveExportsValue(allocator, exports_value, key, condition);
}

// 递归解析 exports 值（string 或 object，含 "./*" 模式）；request_key 为 "." 或 "./subpath"，返回包内相对路径及 caller_owns
fn resolveExportsValue(allocator: std.mem.Allocator, exports_value: std.json.Value, request_key: []const u8, condition: Condition) ?ResolveExportResult {
    switch (exports_value) {
        .string => {
            if (std.mem.eql(u8, request_key, ".")) return .{ .path = exports_value.string, .caller_owns = false };
            return null;
        },
        .object => {
            if (exports_value.object.get(request_key)) |v| {
                if (resolveConditionalValue(v, condition)) |path| return .{ .path = path, .caller_owns = false };
                return null;
            }
            var best_len: usize = 0;
            var best_val: ?std.json.Value = null;
            var it = exports_value.object.iterator();
            while (it.next()) |entry| {
                const k = entry.key_ptr.*;
                if (k.len > 2 and k[k.len - 1] == '*' and std.mem.startsWith(u8, k, "./")) {
                    const prefix = k[0 .. k.len - 1];
                    if (std.mem.startsWith(u8, request_key, prefix) and prefix.len > best_len) {
                        best_len = prefix.len;
                        best_val = entry.value_ptr.*;
                    }
                }
            }
            if (best_val) |v| {
                const target = resolveConditionalValue(v, condition) orelse return null;
                if (target.len >= 2 and target[target.len - 1] == '*') {
                    const suffix = request_key[best_len..];
                    const expanded = std.fmt.allocPrint(allocator, "{s}{s}", .{ target[0 .. target.len - 1], suffix }) catch return null;
                    return .{ .path = expanded, .caller_owns = true };
                }
                return .{ .path = target, .caller_owns = false };
            }
            return null;
        },
        else => return null,
    }
}

/// 解析条件对象：优先 condition 对应键（import/require），否则 default
fn resolveConditionalValue(v: std.json.Value, condition: Condition) ?[]const u8 {
    switch (v) {
        .string => return v.string,
        .object => {
            const cond_key = switch (condition) {
                .import => "import",
                .require => "require",
            };
            if (v.object.get(cond_key)) |cond_v| {
                if (cond_v == .string) return cond_v.string;
            }
            if (v.object.get("default")) |def_v| {
                if (def_v == .string) return def_v.string;
            }
            return null;
        },
        else => return null,
    }
}
