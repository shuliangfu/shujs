// JSX 转译（完整语法）
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1；默认对齐 @dreamer/view。性能：§1.1 显式 allocator、§5.2 内联、§7 热路径无 allocPrint（tag/close 直接写 out）
// 支持：元素/自闭合/属性/子节点/{expr}/Fragment <>...</>/JSX 注释 {/* */}/命名空间标签 <ns:tag>

const std = @import("std");

/// JSX 输出格式：classic = React.createElement(type, props, ...children)；automatic = jsx/jsxs(type, { ...props, children })（React 17+ / @dreamer/view）
pub const JsxRuntime = enum {
    /// React.createElement(type, props, ...children)，与 Bun/React 经典用法一致
    classic,
    /// jsx(type, props) / jsxs(type, { ...props, children: [...] })，与 @dreamer/view、React 17+ automatic runtime 一致
    automatic,
};

/// 可选配置：运行时格式、pragma、Fragment 类型
pub const TransformOptions = struct {
    /// 输出格式，默认 automatic（@dreamer/view）
    runtime: JsxRuntime = .automatic,
    /// 单元素/自闭合时调用的函数，automatic 时为 "jsx"，classic 时为 "React.createElement"
    pragma: []const u8 = "jsx",
    /// 多子节点时调用的函数，仅 automatic 使用，如 "jsxs"
    pragma_plural: []const u8 = "jsxs",
    /// Fragment 的类型实参，如 "Fragment"（view）或 "React.Fragment"（React）
    fragment_type: []const u8 = "Fragment",

    /// 返回 @dreamer/view 的默认配置（automatic + jsx/jsxs/Fragment）
    pub fn forView() TransformOptions {
        return .{
            .runtime = .automatic,
            .pragma = "jsx",
            .pragma_plural = "jsxs",
            .fragment_type = "Fragment",
        };
    }

    /// 返回 React/Bun 经典配置（createElement + React.Fragment）
    pub fn forReact() TransformOptions {
        return .{
            .runtime = .classic,
            .pragma = "React.createElement",
            .pragma_plural = "React.createElement",
            .fragment_type = "React.Fragment",
        };
    }
};

/// 将 JSX 源码转译为 JS（完整语法）。返回的切片由调用方使用同一 allocator 负责 free。
pub fn transformWithOptions(allocator: std.mem.Allocator, source: []const u8, options: TransformOptions) ![]const u8 {
    return transformImpl(allocator, source, options);
}

/// 将 JSX 源码转译为 JS（使用传入的 pragma；classic 时与 React.createElement 一致）。
/// 返回的切片由调用方使用同一 allocator 负责 free。
pub fn transform(allocator: std.mem.Allocator, source: []const u8, pragma: []const u8) ![]const u8 {
    return transformImpl(allocator, source, .{
        .runtime = .classic,
        .pragma = pragma,
        .pragma_plural = pragma,
        .fragment_type = "React.Fragment",
    });
}

/// 内部使用 Arena 做单次转译的任务级分配，结束时将结果复制到 caller allocator（§1.2）
fn transformImpl(allocator: std.mem.Allocator, source: []const u8, options: TransformOptions) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();
    var out = try std.ArrayList(u8).initCapacity(arena_alloc, source.len * 2);
    var i: usize = 0;
    var in_string: bool = false;
    var quote: u8 = 0;
    var in_template: bool = false;
    var brace_depth: u32 = 0; // 仅在「属性或子节点」的 { } 内时 > 0
    while (i < source.len) {
        const c = source[i];
        if (in_string) {
            if (c == '\\' and i + 1 < source.len) {
                try out.append(arena_alloc, c);
                try out.append(arena_alloc, source[i + 1]);
                i += 2;
                continue;
            }
            if (c == quote) in_string = false;
            try out.append(arena_alloc, c);
            i += 1;
            continue;
        }
        if (in_template) {
            if (c == '`') in_template = false else if (c == '\\') {
                try out.append(arena_alloc, c);
                i += 1;
                if (i < source.len) {
                    try out.append(arena_alloc, source[i]);
                    i += 1;
                }
                continue;
            }
            try out.append(arena_alloc, c);
            i += 1;
            continue;
        }
        if (brace_depth > 0) {
            if (c == '{') brace_depth += 1 else if (c == '}') brace_depth -= 1;
            try out.append(arena_alloc, c);
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            in_string = true;
            quote = c;
            try out.append(arena_alloc, c);
            i += 1;
            continue;
        }
        if (c == '`') {
            in_template = true;
            try out.append(arena_alloc, c);
            i += 1;
            continue;
        }
        if (c == '{') {
            brace_depth = 1;
            try out.append(arena_alloc, c);
            i += 1;
            continue;
        }
        // 检测 JSX 开始：< 后接字母、_、/ 或 >（Fragment）
        if (c == '<' and i + 1 < source.len) {
            const next = source[i + 1];
            if (std.ascii.isAlphabetic(next) or next == '_' or next == '/' or next == '>' or next == ' ' or next == '\t' or next == '\r' or next == '\n') {
                i = try transformJsxElement(arena_alloc, source, &options, &out, i);
                continue;
            }
        }
        try out.append(arena_alloc, c);
        i += 1;
    }
    return try allocator.dupe(u8, out.items);
}

/// 默认使用 @dreamer/view 的 JSX 格式（jsx/jsxs/Fragment）；返回的切片由调用方 free。
pub fn transformDefault(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    return transformWithOptions(allocator, source, TransformOptions.forView());
}

/// §1.3 栈上小 buffer：先写满 512 字节栈，溢出再切 ArrayList，减少热路径分配
fn PropsBuf(comptime stack_cap: usize) type {
    return struct {
        stack: [stack_cap]u8 = undefined,
        len: usize = 0,
        overflow: ?std.ArrayList(u8) = null,
        allocator: std.mem.Allocator,

        fn appendByte(self: *@This(), b: u8) !void {
            if (self.overflow) |*l| return l.append(self.allocator, b);
            if (self.len >= stack_cap) return self.spillThenAppend(&.{b});
            self.stack[self.len] = b;
            self.len += 1;
        }
        fn appendSlice(self: *@This(), s: []const u8) !void {
            if (self.overflow) |*l| return l.appendSlice(self.allocator, s);
            if (self.len + s.len > stack_cap) return self.spillThenAppend(s);
            @memcpy(self.stack[self.len..][0..s.len], s);
            self.len += s.len;
        }
        fn spillThenAppend(self: *@This(), s: []const u8) !void {
            var list = try std.ArrayList(u8).initCapacity(self.allocator, self.len + s.len + 256);
            try list.appendSlice(self.allocator, self.stack[0..self.len]);
            try list.appendSlice(self.allocator, s);
            self.overflow = list;
        }
        fn getSlice(self: *const @This()) []const u8 {
            if (self.overflow) |*l| return l.items;
            return self.stack[0..self.len];
        }
    };
}

// 从 source[i] 的 '<' 开始解析一个完整 JSX 元素（或 Fragment），写入 out，返回消费后的下标。
fn transformJsxElement(
    allocator: std.mem.Allocator,
    source: []const u8,
    options: *const TransformOptions,
    out: *std.ArrayList(u8),
    start: usize,
) !usize {
    var i = start;
    std.debug.assert(source[i] == '<');
    i += 1;
    if (i < source.len and source[i] == '/') {
        try out.appendSlice(allocator, "<");
        return start + 1;
    }
    i = skipSpaces(source, i);
    // Fragment：<> ... </>
    if (i < source.len and source[i] == '>') {
        i += 1;
        const frag = options.fragment_type;
        if (options.runtime == .classic) {
            try out.appendSlice(allocator, options.pragma);
            try out.appendSlice(allocator, "(");
            try out.appendSlice(allocator, frag);
            try out.appendSlice(allocator, ", null");
        } else {
            try out.appendSlice(allocator, options.pragma_plural);
            try out.appendSlice(allocator, "(");
            try out.appendSlice(allocator, frag);
            try out.appendSlice(allocator, ", { children: [");
        }
        var first_child = true;
        while (i + 3 <= source.len and !(source[i] == '<' and source[i + 1] == '/' and source[i + 2] == '>')) {
            i = skipSpaces(source, i);
            if (i + 3 <= source.len and source[i] == '<' and source[i + 1] == '/' and source[i + 2] == '>') break;
            if (i >= source.len) break;
            if (source[i] == '<') {
                if (i + 1 < source.len and source[i + 1] == '/') break;
                if (!first_child) try out.appendSlice(allocator, ", ");
                const next_i = try transformJsxElement(allocator, source, options, out, i);
                if (next_i == i + 1) {
                    try out.append(allocator, '<');
                    i += 1;
                } else {
                    first_child = false;
                    i = next_i;
                }
                continue;
            }
            if (source[i] == '{') {
                if (i + 2 < source.len and source[i + 1] == '/' and source[i + 2] == '*') {
                    i = skipJsxComment(source, i);
                    continue;
                }
                if (!first_child) try out.appendSlice(allocator, ", ");
                var depth: u32 = 1;
                i += 1;
                while (i < source.len and depth > 0) {
                    const ch = source[i];
                    if (ch == '{') depth += 1 else if (ch == '}') depth -= 1;
                    try out.append(allocator, ch);
                    i += 1;
                }
                first_child = false;
                continue;
            }
            const text_start = i;
            while (i < source.len and source[i] != '<' and source[i] != '{') : (i += 1) {}
            const text = source[text_start..i];
            if (text.len > 0) {
                if (!first_child) try out.appendSlice(allocator, ", ");
                try appendEscapedJsString(allocator, out, text);
                first_child = false;
            }
        }
        if (options.runtime == .classic) {
            try out.appendSlice(allocator, ")");
        } else {
            try out.appendSlice(allocator, "] })");
        }
        if (i + 3 <= source.len) i += 3;
        return i;
    }
    // 开放标签：读 tag 名（含命名空间 svg:path）
    const tag_start = i;
    while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '_' or source[i] == '.' or source[i] == ':')) : (i += 1) {}
    const tag = source[tag_start..i];
    if (tag.len == 0) {
        try out.append(allocator, '<');
        return start + 1;
    }
    i = skipSpaces(source, i);
    // 解析属性 -> props 字符串（§1.3 栈 512 字节，溢出再 ArrayList）
    var props_buf = PropsBuf(512){ .allocator = allocator };
    defer if (props_buf.overflow) |*l| l.deinit(allocator);
    var has_props = false;
    while (i < source.len and source[i] != '/' and source[i] != '>') {
        i = skipSpaces(source, i);
        if (i >= source.len or source[i] == '/' or source[i] == '>') break;
        if (source[i] == '.' and i + 2 < source.len and source[i + 1] == '.' and source[i + 2] == '.') {
            // {...expr}
            try props_buf.appendSlice("...");
            i += 3;
            var depth: u32 = 0;
            while (i < source.len) {
                const ch = source[i];
                if (ch == '{') depth += 1 else if (ch == '}') {
                    if (depth == 0) break;
                    depth -= 1;
                }
                try props_buf.appendByte(ch);
                i += 1;
            }
            if (i < source.len) try props_buf.appendByte(source[i]);
            i += 1;
            has_props = true;
            continue;
        }
        // name 或 name=
        const attr_start = i;
        while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '_' or source[i] == '-')) : (i += 1) {}
        const name = source[attr_start..i];
        if (name.len == 0) break;
        i = skipSpaces(source, i);
        if (i < source.len and source[i] == '=') {
            i += 1;
            i = skipSpaces(source, i);
            if (has_props) try props_buf.appendSlice(", ");
            try props_buf.appendSlice(name);
            try props_buf.appendSlice(": ");
            if (i < source.len and (source[i] == '"' or source[i] == '\'')) {
                const q = source[i];
                i += 1;
                try props_buf.appendByte(q);
                while (i < source.len and source[i] != q) {
                    if (source[i] == '\\') {
                        try props_buf.appendByte(source[i]);
                        i += 1;
                        if (i < source.len) {
                            try props_buf.appendByte(source[i]);
                            i += 1;
                        }
                        continue;
                    }
                    try props_buf.appendByte(source[i]);
                    i += 1;
                }
                if (i < source.len) try props_buf.appendByte(source[i]);
                i += 1;
                has_props = true;
            } else if (i < source.len and source[i] == '{') {
                i += 1;
                try props_buf.appendByte('{');
                var depth: u32 = 1;
                while (i < source.len and depth > 0) {
                    const ch = source[i];
                    if (ch == '{') depth += 1 else if (ch == '}') depth -= 1;
                    try props_buf.appendByte(ch);
                    i += 1;
                }
                has_props = true;
            }
        } else {
            // 布尔属性 name
            if (has_props) try props_buf.appendSlice(", ");
            try props_buf.appendSlice(name);
            try props_buf.appendSlice(": true");
            has_props = true;
        }
    }
    i = skipSpaces(source, i);
    const props_slice = props_buf.getSlice();
    if (i < source.len and source[i] == '/' and i + 1 < source.len and source[i + 1] == '>') {
        // 自闭合 <Tag ... />
        if (options.runtime == .classic) {
            try out.appendSlice(allocator, options.pragma);
            try out.appendSlice(allocator, "(");
            try appendTagAsJsType(allocator, out, tag);
            if (has_props) {
                try out.appendSlice(allocator, ", {");
                try out.appendSlice(allocator, props_slice);
                try out.appendSlice(allocator, "})");
            } else {
                try out.appendSlice(allocator, ", null)");
            }
        } else {
            try out.appendSlice(allocator, options.pragma);
            try out.appendSlice(allocator, "(");
            try appendTagAsJsType(allocator, out, tag);
            if (has_props) {
                try out.appendSlice(allocator, ", {");
                try out.appendSlice(allocator, props_slice);
                try out.appendSlice(allocator, "})");
            } else {
                try out.appendSlice(allocator, ", {})");
            }
        }
        return i + 2;
    }
    if (i < source.len and source[i] == '>') {
        i += 1;
        const close_len = closeTagLen(tag);
        if (options.runtime == .classic) {
            try out.appendSlice(allocator, options.pragma);
            try out.appendSlice(allocator, "(");
            try appendTagAsJsType(allocator, out, tag);
            if (has_props) {
                try out.appendSlice(allocator, ", {");
                try out.appendSlice(allocator, props_slice);
                try out.appendSlice(allocator, "}");
            } else {
                try out.appendSlice(allocator, ", null");
            }
        } else {
            try out.appendSlice(allocator, options.pragma_plural);
            try out.appendSlice(allocator, "(");
            try appendTagAsJsType(allocator, out, tag);
            try out.appendSlice(allocator, ", {");
            if (has_props) {
                try out.appendSlice(allocator, props_slice);
                try out.appendSlice(allocator, ", children: [");
            } else {
                try out.appendSlice(allocator, "children: [");
            }
        }
        var first_child = true;
        while (i + close_len <= source.len and !matchesCloseTag(source, i, tag)) {
            i = skipSpaces(source, i);
            if (i + close_len <= source.len and matchesCloseTag(source, i, tag)) break;
            if (i >= source.len) break;
            if (source[i] == '<') {
                if (i + 1 < source.len and source[i + 1] == '/') break;
                if (first_child and options.runtime == .classic) try out.appendSlice(allocator, ", ");
                if (!first_child) try out.appendSlice(allocator, ", ");
                const next_i = try transformJsxElement(allocator, source, options, out, i);
                if (next_i == i + 1) {
                    try out.append(allocator, '<');
                    i += 1;
                } else {
                    first_child = false;
                    i = next_i;
                    continue;
                }
            }
            if (source[i] == '{') {
                if (i + 2 < source.len and source[i + 1] == '/' and source[i + 2] == '*') {
                    i = skipJsxComment(source, i);
                    continue;
                }
                if (first_child and options.runtime == .classic) try out.appendSlice(allocator, ", ");
                if (!first_child) try out.appendSlice(allocator, ", ");
                var depth: u32 = 1;
                i += 1;
                while (i < source.len and depth > 0) {
                    const ch = source[i];
                    if (ch == '{') depth += 1 else if (ch == '}') depth -= 1;
                    try out.append(allocator, ch);
                    i += 1;
                }
                first_child = false;
                continue;
            }
            const text_start = i;
            while (i < source.len and source[i] != '<' and source[i] != '{') : (i += 1) {}
            const text = source[text_start..i];
            if (text.len > 0) {
                if (first_child and options.runtime == .classic) try out.appendSlice(allocator, ", ");
                if (!first_child) try out.appendSlice(allocator, ", ");
                try appendEscapedJsString(allocator, out, text);
                first_child = false;
            }
        }
        if (options.runtime == .classic) {
            try out.appendSlice(allocator, ")");
        } else {
            try out.appendSlice(allocator, "] })");
        }
        if (i + close_len <= source.len) i += close_len;
        return i;
    }
    try out.append(allocator, '<');
    return start + 1;
}

/// 从 source[i] 的 '{' 起跳过 JSX 注释 {/* ... */}，返回跳过后的下标（含 */}）。（§5.2 内联）
inline fn skipJsxComment(source: []const u8, i: usize) usize {
    if (i + 2 >= source.len or source[i] != '{' or source[i + 1] != '/' or source[i + 2] != '*') return i;
    var j: usize = i + 3;
    while (j + 2 < source.len) {
        if (source[j] == '*' and source[j + 1] == '/' and source[j + 2] == '}') return j + 3;
        j += 1;
    }
    return source.len;
}

/// 从 source[i] 起跳过空白，返回跳过后的下标（§5.2 小函数内联）
inline fn skipSpaces(source: []const u8, i: usize) usize {
    var j = i;
    while (j < source.len and (source[j] == ' ' or source[j] == '\t' or source[j] == '\r' or source[j] == '\n')) : (j += 1) {}
    return j;
}

/// 将标签名按 JS 实参形式写入 out：小写开头写 "tag"，否则写 tag（不分配，符合 §7 热路径避免 allocPrint）
inline fn appendTagAsJsType(allocator: std.mem.Allocator, out: *std.ArrayList(u8), tag: []const u8) !void {
    if (tag.len > 0 and std.ascii.isLower(tag[0])) {
        try out.append(allocator, '"');
        try out.appendSlice(allocator, tag);
        try out.append(allocator, '"');
    } else {
        try out.appendSlice(allocator, tag);
    }
}

/// 判断 source[i..] 是否等于 "</tag>"，不分配（§7 热路径避免 allocPrint）
inline fn matchesCloseTag(source: []const u8, i: usize, tag: []const u8) bool {
    if (i + 2 + tag.len >= source.len) return false;
    if (source[i] != '<' or source[i + 1] != '/') return false;
    if (!std.mem.eql(u8, source[i + 2 ..][0..tag.len], tag)) return false;
    return source[i + 2 + tag.len] == '>';
}

/// 闭合标签 "</tag>" 的长度，用于消费后前进
inline fn closeTagLen(tag: []const u8) usize {
    return 3 + tag.len; // "</" + tag + ">"
}

/// 将 s 去首尾空白后按 JS 字符串字面量转义写入 out（§5.2 内联）
inline fn appendEscapedJsString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t' or s[start] == '\r' or s[start] == '\n')) : (start += 1) {}
    var end = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r' or s[end - 1] == '\n')) : (end -= 1) {}
    const trimmed = s[start..end];
    if (trimmed.len == 0) return;
    try out.append(allocator, '"');
    for (trimmed) |b| {
        if (b == '\\' or b == '"' or b == '\n' or b == '\r') {
            try out.append(allocator, '\\');
            if (b == '\n') try out.append(allocator, 'n') else if (b == '\r') try out.append(allocator, 'r') else try out.append(allocator, b);
        } else {
            try out.append(allocator, b);
        }
    }
    try out.append(allocator, '"');
}

// 默认 transformDefault 使用 @dreamer/view（jsx/jsxs/Fragment）
// 单元测试已迁至 src/tests/transpiler/jsx.zig
