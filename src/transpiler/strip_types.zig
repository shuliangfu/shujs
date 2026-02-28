// 仅去掉 TS 类型，供运行与打包共用
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1
// Phase 0：简单擦除 : Type、): Type、<T> 等常见形式，不做完整语法分析

const std = @import("std");

/// 对 TS 源码做类型擦除，返回纯 JS（调用方负责 free 返回的 slice）
/// 简单跟踪是否在字符串内，避免把 "TS:" 等当作类型注解
pub fn strip(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var list = try std.ArrayList(u8).initCapacity(allocator, source.len);
    errdefer list.deinit(allocator);
    var i: usize = 0;
    var in_string: bool = false;
    var quote: u8 = 0;
    while (i < source.len) {
        const c = source[i];
        if (in_string) {
            if (c == '\\' and i + 1 < source.len) {
                try list.append(allocator, c);
                try list.append(allocator, source[i + 1]);
                i += 2;
                continue;
            }
            if (c == quote) {
                in_string = false;
            }
            try list.append(allocator, c);
            i += 1;
            continue;
        }
        if ((c == '"' or c == '\'') and (i == 0 or source[i - 1] != '\\')) {
            in_string = true;
            quote = c;
            try list.append(allocator, c);
            i += 1;
            continue;
        }
        // 检测 ": Identifier" 或 "): Identifier"（参数/变量/返回值类型），且不在字符串内
        if (c == ':' and i + 1 < source.len and isSpaceOrNewline(source[i + 1])) {
            var j = i + 1;
            while (j < source.len and isSpaceOrNewline(source[j])) : (j += 1) {}
            if (j < source.len and isIdChar(source[j])) {
                i = skipTypeAnnotation(source, j);
                continue;
            }
        }
        // 返回值类型 ): Type — 先输出 ")" 再跳过 ": Type"
        if (c == ')' and i + 1 < source.len) {
            var j = i + 1;
            while (j < source.len and isSpaceOrNewline(source[j])) : (j += 1) {}
            if (j < source.len and source[j] == ':') {
                var k = j + 1;
                while (k < source.len and isSpaceOrNewline(source[k])) : (k += 1) {}
                if (k < source.len and isIdChar(source[k])) {
                    try list.append(allocator, ')');
                    i = skipTypeAnnotation(source, k);
                    continue;
                }
            }
        }
        // 简单跳过 <...> 泛型（不处理嵌套）
        if (c == '<' and i + 1 < source.len and (isIdChar(source[i + 1]) or source[i + 1] == '>')) {
            var depth: u32 = 1;
            var k = i + 1;
            while (k < source.len and depth > 0) {
                if (source[k] == '<') depth += 1
                else if (source[k] == '>') depth -= 1;
                k += 1;
            }
            i = k;
            continue;
        }
        try list.append(allocator, c);
        i += 1;
    }
    return try list.toOwnedSlice(allocator);
}

/// 从 type 起始位置跳过类型注解，返回跳过后的下标
fn skipTypeAnnotation(source: []const u8, start: usize) usize {
    var i = start;
    while (i < source.len and isIdChar(source[i])) : (i += 1) {}
    // 不跳过类型后的空格，留给主循环输出，保证 "x: number = 1" -> "x = 1"
    if (i < source.len and source[i] == '<') {
        var depth: u32 = 1;
        i += 1;
        while (i < source.len and depth > 0) {
            if (source[i] == '<') depth += 1
            else if (source[i] == '>') depth -= 1;
            i += 1;
        }
    }
    if (i < source.len and source[i] == '[') {
        i += 1;
        while (i < source.len and source[i] != ']') : (i += 1) {}
        if (i < source.len) i += 1;
    }
    return i;
}

fn isSpaceOrNewline(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}
fn isIdChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '|' or c == '&';
}

test "strip_types: variable annotation" {
    const allocator = std.testing.allocator;
    const out = try strip(allocator, "const x: number = 1;");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("const x = 1;", out);
}

test "strip_types: return type" {
    const allocator = std.testing.allocator;
    const out = try strip(allocator, "function f(): void { }");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("function f() { }", out);
}

test "strip_types: string with colon" {
    const allocator = std.testing.allocator;
    const out = try strip(allocator, "console.log(\"TS:\", x: number);");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("console.log(\"TS:\", x);", out);
}
