// 从 src/runtime/engine/BUILTINS.md 解析「一、已实现」表格，生成面向用户的 JS API 参考文档
// 运行：zig run scripts/generate_js_api_docs.zig [-- <builtins_path> [output_path]]
// 默认：builtins = src/runtime/engine/BUILTINS.md，output = docs/JS_API_REFERENCE.md

const std = @import("std");

/// 单行 API 条目：分类、名称、说明、权限/备注
const ApiRow = struct {
    category: []const u8,
    name: []const u8,
    desc: []const u8,
    note: []const u8,
};

/// 从整行（含首尾 |）解析表格单元格，返回 trim 后的切片（调用方需 free 返回的 slice）
fn parseTableRow(line: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
    var list = try std.ArrayList([]const u8).initCapacity(allocator, 8);
    var start: usize = 0;
    var i: usize = 0;
    while (i <= line.len) {
        const at_end = i == line.len;
        const is_sep = !at_end and (line[i] == '|');
        if (is_sep or at_end) {
            if (start < i) {
                var cell = line[start..i];
                while (cell.len > 0 and (cell[0] == ' ' or cell[0] == '\t')) cell = cell[1..];
                while (cell.len > 0 and (cell[cell.len - 1] == ' ' or cell[cell.len - 1] == '\t')) cell = cell[0 .. cell.len - 1];
                try list.append(allocator, cell);
            }
            start = i + 1;
        }
        i += 1;
    }
    return list.toOwnedSlice(allocator);
}

/// 判断是否为表格分隔行（| --- | --- | ...）
fn isTableSeparator(line: []const u8) bool {
    var trimmed = line;
    while (trimmed.len > 0 and (trimmed[0] == ' ' or trimmed[0] == '\t')) trimmed = trimmed[1..];
    while (trimmed.len > 0 and (trimmed[trimmed.len - 1] == ' ' or trimmed[trimmed.len - 1] == '\r')) trimmed = trimmed[0 .. trimmed.len - 1];
    if (trimmed.len < 2 or trimmed[0] != '|') return false;
    const rest = trimmed[1..];
    return std.mem.indexOf(u8, rest, "---") != null;
}

/// 从 BUILTINS.md 内容中提取「一、已实现」下的表格行，返回 ApiRow 列表（调用方负责释放）
fn extractImplementedTable(content: []const u8, allocator: std.mem.Allocator) !std.ArrayList(ApiRow) {
    const marker = "## 一、已实现";
    var result = try std.ArrayList(ApiRow).initCapacity(allocator, 64);
    const pos = std.mem.indexOf(u8, content, marker) orelse return result;
    const stream = content[pos + marker.len ..];
    var line_iter = std.mem.splitScalar(u8, stream, '\n');
    var header_done = false;
    var seen_any_row = false;
    while (line_iter.next()) |line_raw| {
        var line = line_raw;
        while (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) line = line[1..];
        while (line.len > 0 and (line[line.len - 1] == '\r' or line[line.len - 1] == ' ')) line = line[0 .. line.len - 1];
        if (line.len == 0) {
            if (seen_any_row) break;
            continue;
        }
        if (line[0] != '|') {
            if (seen_any_row) break;
            continue;
        }
        if (isTableSeparator(line)) {
            header_done = true;
            continue;
        }
        const cells = try parseTableRow(line, allocator);
        defer allocator.free(cells);
        if (cells.len < 5) continue;
        if (!header_done) continue; // 跳过表头
        const category = cells[0];
        const name = cells[1];
        const desc = cells[2];
        const note = cells[4];
        seen_any_row = true;
        try result.append(allocator, .{
            .category = category,
            .name = name,
            .desc = desc,
            .note = note,
        });
    }
    return result;
}

/// 按分类名排序用的键：全局 < process 子项(空格) < Shu.fs < Shu.path < Shu.system < Shu.thread < Shu
fn categoryOrder(cat: []const u8) u8 {
    if (std.mem.eql(u8, cat, "全局")) return 0;
    if (cat.len == 0 or std.mem.startsWith(u8, cat, "    ") or std.mem.trim(u8, cat, " \t").len == 0) return 1; // process 子项（空或全空格）
    if (std.mem.eql(u8, cat, "Shu.fs")) return 2;
    if (std.mem.eql(u8, cat, "Shu.path")) return 3;
    if (std.mem.eql(u8, cat, "Shu.system")) return 4;
    if (std.mem.eql(u8, cat, "Shu.thread")) return 5;
    if (std.mem.eql(u8, cat, "Shu") or std.mem.eql(u8, cat, "Shu / 全局")) return 6;
    return 7;
}

fn categoryTitle(cat: []const u8) []const u8 {
    if (cat.len == 0 or std.mem.trim(u8, cat, " \t").len == 0) return "process（子属性/方法）";
    if (std.mem.startsWith(u8, cat, "    ")) return "process（子属性/方法）";
    return cat;
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    var builtins_path: []const u8 = "src/runtime/engine/BUILTINS.md";
    var output_path: []const u8 = "docs/JS_API_REFERENCE.md";
    if (args.next()) |a| builtins_path = a;
    if (args.next()) |a| output_path = a;

    const content = std.fs.cwd().readFileAlloc(allocator, builtins_path, 2 * 1024 * 1024) catch |e| {
        std.debug.print("read file failed: {s}\n", .{builtins_path});
        return e;
    };
    defer allocator.free(content);

    var rows = try extractImplementedTable(content, allocator);
    defer rows.deinit(allocator);

    // 按分类排序，同分类内保持原序
    const sort_ctx = struct {
        fn lessThan(_: void, a: ApiRow, b: ApiRow) bool {
            const oa = categoryOrder(a.category);
            const ob = categoryOrder(b.category);
            if (oa != ob) return oa < ob;
            return false;
        }
    };
    std.mem.sort(ApiRow, rows.items, {}, sort_ctx.lessThan);

    // 先写入内存，再一次性写入文件（Zig 0.16.0-dev：ArrayList/Writer API）
    var output = try std.ArrayList(u8).initCapacity(allocator, 16384);
    defer output.deinit(allocator);
    const w = output.writer(allocator);

    try w.writeAll("# Shu 运行时 JavaScript API 参考\n\n");
    try w.writeAll("本文档由 `scripts/generate_js_api_docs.zig` 从 `src/runtime/engine/BUILTINS.md` 自动生成，仅包含**已实现并注册**的宿主 API。\n\n");
    try w.writeAll("---\n\n");

    var current_cat: []const u8 = "";
    for (rows.items) |row| {
        const cat_title = categoryTitle(row.category);
        if (!std.mem.eql(u8, current_cat, row.category)) {
            current_cat = row.category;
            try w.print("## {s}\n\n", .{cat_title});
            try w.writeAll("| API | 说明 | 权限/备注 |\n");
            try w.writeAll("|-----|------|----------|\n");
        }
        try w.print("| {s} | {s} | {s} |\n", .{ row.name, row.desc, row.note });
    }

    const out_file = std.fs.cwd().createFile(output_path, .{}) catch |e| {
        std.debug.print("create output failed: {s}\n", .{output_path});
        return e;
    };
    defer out_file.close();
    try out_file.writeAll(output.items);
    std.debug.print("Generated: {s}\n", .{output_path});
}
