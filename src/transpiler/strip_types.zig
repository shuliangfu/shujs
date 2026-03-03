// 仅去掉 TS 类型，供运行与打包共用
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1；性能：§1.1 显式 allocator、§1.2 内部 Arena、§2.4 SIMD、§5.2 内联、§7 无 allocPrint
// Phase 0：简单擦除 : Type、): Type、<T> 等常见形式，不做完整语法分析

const std = @import("std");

const VECTOR_LANES = 16;

/// §2.4 在 block 内查找第一个等于 needles 中任一字节的位置；块长可小于 VECTOR_LANES 时安全。
/// 返回相对 block 的偏移，未找到返回 block.len。供非字符串分支快速跳过无关字节。对外 pub 供 src/tests 使用。
pub inline fn findNextOfAny(block: []const u8, needles: []const u8) usize {
    var i: usize = 0;
    while (i + VECTOR_LANES <= block.len) {
        const chunk = block[i..][0..VECTOR_LANES];
        const v: @Vector(VECTOR_LANES, u8) = chunk.*;
        var mask: @Vector(VECTOR_LANES, bool) = @splat(false);
        for (needles) |b| {
            const needle_vec: @Vector(VECTOR_LANES, u8) = @splat(b);
            mask = mask | (v == needle_vec);
        }
        var j: usize = 0;
        while (j < VECTOR_LANES) : (j += 1) {
            if (mask[j]) return i + j;
        }
        i += VECTOR_LANES;
    }
    while (i < block.len) {
        for (needles) |b| {
            if (block[i] == b) return i;
        }
        i += 1;
    }
    return block.len;
}

/// 对 TS 源码做类型擦除，返回纯 JS（调用方负责 free 返回的 slice）。
/// 内部使用 Arena 做单次任务级分配，结束时将结果复制到 caller allocator，减少碎片（§1.2）。
pub fn strip(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();
    var list = try std.ArrayList(u8).initCapacity(arena_alloc, source.len);
    var i: usize = 0;
    var in_string: bool = false;
    var quote: u8 = 0;
    while (i < source.len) {
        const c = source[i];
        if (in_string) {
            if (c == '\\' and i + 1 < source.len) {
                try list.append(arena_alloc, c);
                try list.append(arena_alloc, source[i + 1]);
                i += 2;
                continue;
            }
            if (c == quote) {
                in_string = false;
            }
            try list.append(arena_alloc, c);
            i += 1;
            continue;
        }
        if ((c == '"' or c == '\'') and (i == 0 or source[i - 1] != '\\')) {
            in_string = true;
            quote = c;
            try list.append(arena_alloc, c);
            i += 1;
            continue;
        }
        // §2.4 SIMD 候选：此处可先 findNextOfAny(source[i..], ":)<") 再整段 append，当前保持逐字节以保证行为一致
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
                    try list.append(arena_alloc, ')');
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
                if (source[k] == '<') depth += 1 else if (source[k] == '>') depth -= 1;
                k += 1;
            }
            i = k;
            continue;
        }
        try list.append(arena_alloc, c);
        i += 1;
    }
    // 结果复制到 caller allocator，使返回值在 arena.deinit 后仍有效
    return try allocator.dupe(u8, list.items);
}

/// 从 type 起始位置跳过类型注解，返回跳过后的下标（§5.2 内联）
inline fn skipTypeAnnotation(source: []const u8, start: usize) usize {
    var i = start;
    while (i < source.len and isIdChar(source[i])) : (i += 1) {}
    // 不跳过类型后的空格，留给主循环输出，保证 "x: number = 1" -> "x = 1"
    if (i < source.len and source[i] == '<') {
        var depth: u32 = 1;
        i += 1;
        while (i < source.len and depth > 0) {
            if (source[i] == '<') depth += 1 else if (source[i] == '>') depth -= 1;
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

/// 是否为空白或换行（§5.2 内联）
inline fn isSpaceOrNewline(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}
/// 是否为类型/标识符允许字符（§5.2 内联）
inline fn isIdChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '|' or c == '&';
}
