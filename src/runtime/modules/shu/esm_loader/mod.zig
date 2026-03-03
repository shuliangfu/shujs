// ESM 模块：import/export（与 CJS require 分开实现，各写各的）
// 解析 import/export、构建模块图、按依赖顺序执行；入口为 .mjs/.mts 时由此加载器执行
// 仅支持相对路径（./ ../），需 --allow-read；说明符可带 ?query（如 "xxx.ts?v=time"），路径用于读文件，path+query 作为模块键实现不缓存/缓存隔离

const std = @import("std");
const jsc = @import("jsc");
const globals = @import("../../../globals.zig");
const errors = @import("errors");
const libs_process = @import("libs_process");
const node_builtin = @import("../../node/builtin.zig");
const shu_builtin = @import("../builtin.zig");
const pkg_resolver = @import("../../../../package/resolver.zig");
const libs_io = @import("libs_io");

/// 单条 import 的绑定类型
const ImportKind = enum { default_import, named_imports, namespace };
/// 单条 import：说明符 + 绑定方式
const ImportSpec = struct {
    specifier: []const u8,
    kind: ImportKind,
    /// default_import: 单个名字；named_imports: 名字列表（调用方会复制）；namespace: 单个名字
    binding: []const u8,
    /// 仅当 kind == named_imports 时有效
    named_list: []const []const u8,
};

/// 模块解析结果：依赖说明符、导出信息、以及用于生成包装体的原始源码
const ParseResult = struct {
    imports: std.ArrayList(ImportSpec),
    /// 是否有 export default
    has_default_export: bool,
    /// export default 后面的表达式原文（到分号止）
    default_expr: []const u8,
    /// export { a, b } 或 export const/let/var 的名字
    named_exports: std.ArrayList([]const u8),
    /// 去掉 import/export 行后的“体”源码（保留 export const x = 1 中的 const x = 1，并追加 __exports.x = x）
    body: std.ArrayList(u8),
};

/// 图中一个模块：路径、源码、解析结果、依赖在该图中的下标；node:path / node:fs 等内置仅有 prebuilt_exports，不执行源码
const ModuleRecord = struct {
    path: []const u8,
    source: []const u8,
    parse: ParseResult,
    /// 依赖模块在 modules 列表中的下标（与 parse.imports 一一对应）
    dep_indices: std.ArrayList(usize),
    /// 非 null 时表示内置模块（node:xxx），直接使用此 exports，不执行 transform/IIFE
    prebuilt_exports: ?jsc.JSValueRef = null,
};

/// 解析 ESM 源码：提取 import、export default、export { ... }、export const/let/var，并生成可执行 body
/// §1.3 解析期：imports/named_exports 用 initCapacity(8) 减少扩容；body 按 source.len 预分配
fn parseModule(allocator: std.mem.Allocator, source: []const u8) !ParseResult {
    var imports = try std.ArrayList(ImportSpec).initCapacity(allocator, 8);
    errdefer imports.deinit(allocator);
    var named_exports = try std.ArrayList([]const u8).initCapacity(allocator, 8);
    errdefer named_exports.deinit(allocator);
    var body = std.ArrayList(u8).initCapacity(allocator, source.len) catch return error.OutOfMemory;
    errdefer body.deinit(allocator);

    var has_default_export = false;
    var default_expr: []const u8 = "";

    var line_start: usize = 0;
    while (line_start < source.len) {
        const line_end = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;
        const line = std.mem.trim(u8, source[line_start..line_end], " \t\r\n");

        if (line.len == 0 or line.len >= 2 and line[0] == '/' and line[1] == '/') {
            line_start = line_end + @as(usize, @intFromBool(line_end < source.len));
            continue;
        }

        // import ... from "path";
        if (std.mem.startsWith(u8, line, "import ")) {
            const rest = line["import ".len..];
            if (std.mem.indexOf(u8, rest, " from ")) |from_pos| {
                const before_from = std.mem.trim(u8, rest[0..from_pos], " \t\r\n");
                const after_from = std.mem.trim(u8, rest[from_pos + " from ".len ..], " \t\r\n");
                const specifier = extractQuotedSpecifier(after_from);
                if (specifier) |spec| {
                    if (std.mem.startsWith(u8, before_from, "* as ")) {
                        const binding = std.mem.trim(u8, before_from["* as ".len..], " \t\r\n");
                        try imports.append(allocator, .{
                            .specifier = spec,
                            .kind = .namespace,
                            .binding = binding,
                            .named_list = &.{},
                        });
                    } else if (before_from.len > 0 and before_from[0] == '{') {
                        const close = std.mem.indexOfScalar(u8, before_from, '}') orelse {
                            line_start = line_end + @as(usize, @intFromBool(line_end < source.len));
                            continue;
                        };
                        const inner = std.mem.trim(u8, before_from[1..close], " \t\r\n");
                        var names = try std.ArrayList([]const u8).initCapacity(allocator, 4);
                        defer names.deinit(allocator);
                        var it = std.mem.splitScalar(u8, inner, ',');
                        while (it.next()) |part| {
                            const name = std.mem.trim(u8, part, " \t\r\n");
                            if (name.len > 0)
                                try names.append(allocator, try allocator.dupe(u8, name));
                        }
                        const names_slice = try names.toOwnedSlice(allocator);
                        try imports.append(allocator, .{
                            .specifier = spec,
                            .kind = .named_imports,
                            .binding = "",
                            .named_list = names_slice,
                        });
                    } else {
                        try imports.append(allocator, .{
                            .specifier = spec,
                            .kind = .default_import,
                            .binding = before_from,
                            .named_list = &.{},
                        });
                    }
                }
            }
            line_start = line_end + @as(usize, @intFromBool(line_end < source.len));
            continue;
        }

        // export default <expr>;
        if (std.mem.startsWith(u8, line, "export default ")) {
            has_default_export = true;
            const expr_part = std.mem.trim(u8, line["export default ".len..], " \t\r\n");
            const semicolon = std.mem.indexOfScalar(u8, expr_part, ';');
            default_expr = if (semicolon) |s| std.mem.trim(u8, expr_part[0..s], " \t\r\n") else expr_part;
            line_start = line_end + @as(usize, @intFromBool(line_end < source.len));
            continue;
        }

        // export { a, b };
        if (std.mem.startsWith(u8, line, "export {")) {
            const inner_start = std.mem.indexOfScalar(u8, line, '{').? + 1;
            const inner_end = std.mem.indexOfScalar(u8, line[inner_start..], '}') orelse inner_start;
            const inner = line[inner_start .. inner_start + inner_end];
            var it = std.mem.splitScalar(u8, inner, ',');
            while (it.next()) |part| {
                const name = std.mem.trim(u8, part, " \t\r\n");
                if (name.len > 0)
                    try named_exports.append(allocator, try allocator.dupe(u8, name));
            }
            line_start = line_end + @as(usize, @intFromBool(line_end < source.len));
            continue;
        }

        // export const/let/var x = ...; 或 export function/class
        if (std.mem.startsWith(u8, line, "export ")) {
            const after_export = std.mem.trim(u8, line["export ".len..], " \t\r\n");
            if (std.mem.startsWith(u8, after_export, "const ")) {
                const name_end = std.mem.indexOfAny(u8, after_export["const ".len..], " =") orelse after_export.len;
                const name = std.mem.trim(u8, after_export["const ".len..][0..name_end], " \t\r\n");
                try named_exports.append(allocator, try allocator.dupe(u8, name));
            } else if (std.mem.startsWith(u8, after_export, "let ")) {
                const name_end = std.mem.indexOfAny(u8, after_export["let ".len..], " =") orelse after_export.len;
                const name = std.mem.trim(u8, after_export["let ".len..][0..name_end], " \t\r\n");
                try named_exports.append(allocator, try allocator.dupe(u8, name));
            } else if (std.mem.startsWith(u8, after_export, "var ")) {
                const name_end = std.mem.indexOfAny(u8, after_export["var ".len..], " =") orelse after_export.len;
                const name = std.mem.trim(u8, after_export["var ".len..][0..name_end], " \t\r\n");
                try named_exports.append(allocator, try allocator.dupe(u8, name));
            } else if (std.mem.startsWith(u8, after_export, "function ")) {
                const name = std.mem.trim(u8, after_export["function ".len..], " \t\r\n");
                const paren = std.mem.indexOfScalar(u8, name, '(') orelse name.len;
                try named_exports.append(allocator, try allocator.dupe(u8, name[0..paren]));
            } else if (std.mem.startsWith(u8, after_export, "class ")) {
                const name = std.mem.trim(u8, after_export["class ".len..], " \t\r\n");
                const space = std.mem.indexOfScalar(u8, name, ' ') orelse name.len;
                const brace = std.mem.indexOfScalar(u8, name, '{') orelse name.len;
                const len = @min(space, brace);
                try named_exports.append(allocator, try allocator.dupe(u8, name[0..len]));
            }
            // 把 export 去掉，保留声明，后面会统一追加 __exports.xxx = xxx
            body.appendSlice(allocator, after_export) catch return error.OutOfMemory;
            body.appendSlice(allocator, "\n") catch return error.OutOfMemory;
            line_start = line_end + @as(usize, @intFromBool(line_end < source.len));
            continue;
        }

        body.appendSlice(allocator, source[line_start..line_end]) catch return error.OutOfMemory;
        if (line_end < source.len)
            body.append(allocator, '\n') catch return error.OutOfMemory;
        line_start = line_end + @as(usize, @intFromBool(line_end < source.len));
    }

    return .{
        .imports = imports,
        .has_default_export = has_default_export,
        .default_expr = default_expr,
        .named_exports = named_exports,
        .body = body,
    };
}

/// 从 "path" 或 'path' 中取出 path
fn extractQuotedSpecifier(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len >= 2 and (trimmed[0] == '"' or trimmed[0] == '\'')) {
        const end = std.mem.indexOfScalarPos(u8, trimmed, 1, trimmed[0]) orelse return null;
        return trimmed[1..end];
    }
    return null;
}

/// 将说明符拆成路径部分与 query（? 及之后）
fn splitSpecifierQuery(specifier: []const u8) struct { path_part: []const u8, query: []const u8 } {
    if (std.mem.indexOfScalar(u8, specifier, '?')) |q_pos| {
        return .{ .path_part = specifier[0..q_pos], .query = specifier[q_pos..] };
    }
    return .{ .path_part = specifier, .query = "" };
}

/// 解析结果：file_path 用于读文件与 __filename；cache_key 用于模块图去重（有 ?query 时为 path+query）
const ResolveResult = struct { file_path: []const u8, cache_key: []const u8 };

/// 解析说明符为绝对路径：相对路径 ./ ../、裸说明符（node_modules + main/exports）、jsr:；可带 ?query，返回 file_path + cache_key
fn resolveSpecifier(allocator: std.mem.Allocator, parent_dir: []const u8, specifier: []const u8) !ResolveResult {
    if (std.mem.startsWith(u8, specifier, "node:")) {
        errors.reportToStderr(.{ .code = .type_error, .message = "ESM import(node:...) is not implemented yet" }) catch {};
        return error.NotImplemented;
    }
    if (std.mem.startsWith(u8, specifier, ".")) {
        const split = splitSpecifierQuery(specifier);
        const file_path = try std.fs.path.resolve(allocator, &.{ parent_dir, split.path_part });
        errdefer allocator.free(file_path);
        if (split.query.len == 0) {
            return .{ .file_path = file_path, .cache_key = file_path };
        }
        const cache_key = try std.mem.concat(allocator, u8, &.{ file_path, split.query });
        return .{ .file_path = file_path, .cache_key = cache_key };
    }
    const pkg_result = pkg_resolver.resolve(allocator, parent_dir, specifier, .import) catch |e| {
        if (e == error.ModuleNotFound) {
            var msg_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&msg_buf, "Cannot find module: {s}", .{specifier}) catch "Cannot find module";
            errors.reportToStderr(.{ .code = .file_not_found, .message = msg }) catch {};
        }
        return e;
    };
    return .{ .file_path = pkg_result.file_path, .cache_key = pkg_result.cache_key };
}

/// 读取文件内容。Zig 0.16：经 io_core 打开，reader + allocRemaining 读全文件；调用方 free 返回切片。
fn readFileContent(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const io = libs_process.getProcessIo() orelse return error.ProcessIoNotSet;
    const file = libs_io.openFileAbsolute(path, .{}) catch |e| {
        var msg_buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&msg_buf, "Cannot find module: {s}", .{path}) catch "Cannot find module";
        errors.reportToStderr(.{ .code = .file_not_found, .message = msg }) catch {};
        return e;
    };
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, read_buf[0..]);
    return file_reader.interface.allocRemaining(allocator, std.Io.Limit.unlimited);
}

/// 构建模块图：从入口开始递归加载，返回线性列表（含入口），dep_indices 指向同列表下标；入口 source 会被复制一份以统一释放
/// 入口无 query 时 cache_key 与 file_path 均为 entry_path；ctx 用于 node: 内置模块
fn loadModuleGraph(
    allocator: std.mem.Allocator,
    ctx: jsc.JSContextRef,
    entry_path: []const u8,
    entry_source: []const u8,
) !std.ArrayList(ModuleRecord) {
    var modules = try std.ArrayList(ModuleRecord).initCapacity(allocator, 4);
    var path_to_index = std.StringHashMap(usize).init(allocator);
    defer path_to_index.deinit();
    const entry_source_owned = try allocator.dupe(u8, entry_source);
    try loadOneModule(allocator, ctx, entry_path, entry_path, entry_source_owned, &modules, &path_to_index);
    return modules;
}

/// cache_key 用于 path_to_index 去重（含 ?query 时实现不缓存/按 query 隔离）；file_path 用于读文件与 ModuleRecord.path（__filename）
fn loadOneModule(
    allocator: std.mem.Allocator,
    ctx: jsc.JSContextRef,
    cache_key: []const u8,
    file_path: []const u8,
    source: []const u8,
    modules: *std.ArrayList(ModuleRecord),
    path_to_index: *std.StringHashMap(usize),
) !void {
    if (path_to_index.get(cache_key)) |_| return;

    var parse = try parseModule(allocator, source);
    errdefer {
        parse.imports.deinit(allocator);
        parse.named_exports.deinit(allocator);
        parse.body.deinit(allocator);
    }

    const parent_dir = std.fs.path.dirname(file_path) orelse ".";
    var dep_indices = try std.ArrayList(usize).initCapacity(allocator, 8);
    errdefer dep_indices.deinit(allocator);

    for (parse.imports.items) |imp| {
        if (node_builtin.isSupportedNodeBuiltin(imp.specifier)) {
            try ensureNodeBuiltinModule(allocator, ctx, imp.specifier, modules, path_to_index);
            const idx = path_to_index.get(imp.specifier).?;
            try dep_indices.append(allocator, idx);
            continue;
        }
        if (shu_builtin.isSupportedShuBuiltin(imp.specifier)) {
            try ensureShuBuiltinModule(allocator, ctx, imp.specifier, modules, path_to_index);
            const idx = path_to_index.get(imp.specifier).?;
            try dep_indices.append(allocator, idx);
            continue;
        }
        const result = try resolveSpecifier(allocator, parent_dir, imp.specifier);
        defer allocator.free(result.file_path);
        defer if (result.cache_key.ptr != result.file_path.ptr) allocator.free(result.cache_key);
        const dep_source = try readFileContent(allocator, result.file_path);
        defer allocator.free(dep_source);
        const dep_source_owned = try allocator.dupe(u8, dep_source);
        try loadOneModule(allocator, ctx, result.cache_key, result.file_path, dep_source_owned, modules, path_to_index);
        const idx = path_to_index.get(result.cache_key).?;
        try dep_indices.append(allocator, idx);
    }

    const cache_key_owned = try allocator.dupe(u8, cache_key);
    const file_path_owned = try allocator.dupe(u8, file_path);
    try path_to_index.put(cache_key_owned, modules.items.len);

    try modules.append(allocator, .{
        .path = file_path_owned,
        .source = source,
        .parse = parse,
        .dep_indices = dep_indices,
        .prebuilt_exports = null,
    });
}

/// 将 node:path / node:fs 等内置加入模块图（若尚未存在），不读文件，exports 由 getNodeBuiltin 提供
fn ensureNodeBuiltinModule(
    allocator: std.mem.Allocator,
    ctx: jsc.JSContextRef,
    specifier: []const u8,
    modules: *std.ArrayList(ModuleRecord),
    path_to_index: *std.StringHashMap(usize),
) !void {
    if (path_to_index.get(specifier)) |_| return;
    const path_owned = try allocator.dupe(u8, specifier);
    errdefer allocator.free(path_owned);
    const empty = try allocator.dupe(u8, "");
    errdefer allocator.free(empty);
    var parse = try parseModule(allocator, empty);
    errdefer {
        parse.imports.deinit(allocator);
        parse.named_exports.deinit(allocator);
        parse.body.deinit(allocator);
    }
    const dep_indices = try std.ArrayList(usize).initCapacity(allocator, 0);
    try path_to_index.put(path_owned, modules.items.len);
    try modules.append(allocator, .{
        .path = path_owned,
        .source = empty,
        .parse = parse,
        .dep_indices = dep_indices,
        .prebuilt_exports = node_builtin.getNodeBuiltin(ctx, allocator, specifier),
    });
}

/// 将 shu:fs / shu:path / shu:zlib 等内置加入模块图（若尚未存在），exports 从 globalThis.Shu 取
fn ensureShuBuiltinModule(
    allocator: std.mem.Allocator,
    ctx: jsc.JSContextRef,
    specifier: []const u8,
    modules: *std.ArrayList(ModuleRecord),
    path_to_index: *std.StringHashMap(usize),
) !void {
    if (path_to_index.get(specifier)) |_| return;
    const path_owned = try allocator.dupe(u8, specifier);
    errdefer allocator.free(path_owned);
    const empty = try allocator.dupe(u8, "");
    errdefer allocator.free(empty);
    var parse = try parseModule(allocator, empty);
    errdefer {
        parse.imports.deinit(allocator);
        parse.named_exports.deinit(allocator);
        parse.body.deinit(allocator);
    }
    const dep_indices = try std.ArrayList(usize).initCapacity(allocator, 0);
    try path_to_index.put(path_owned, modules.items.len);
    try modules.append(allocator, .{
        .path = path_owned,
        .source = empty,
        .parse = parse,
        .dep_indices = dep_indices,
        .prebuilt_exports = shu_builtin.getShuBuiltin(ctx, allocator, specifier),
    });
}

/// 拓扑排序时单点访问（递归）：依赖先入队
fn visitTopo(
    idx: usize,
    mods: []const ModuleRecord,
    vis: []bool,
    out: *std.ArrayList(usize),
    alloc: std.mem.Allocator,
) !void {
    if (vis[idx]) return;
    vis[idx] = true;
    for (mods[idx].dep_indices.items) |dep| try visitTopo(dep, mods, vis, out, alloc);
    try out.append(alloc, idx);
}

/// 拓扑排序：依赖在前；§1.3 initCapacity(8) 减少扩容
fn topologicalOrder(allocator: std.mem.Allocator, modules: []const ModuleRecord) ![]usize {
    var order = try std.ArrayList(usize).initCapacity(allocator, 8);
    const visited = try allocator.alloc(bool, modules.len);
    defer allocator.free(visited);
    @memset(visited, false);
    for (0..modules.len) |i| try visitTopo(i, modules, visited, &order, allocator);
    return order.toOwnedSlice(allocator);
}

/// 将单个模块源码转换为 (function(__dep0, __dep1, ...) { ... return __exports; }) 形式
/// 将单模块解析结果转为 IIFE 源码，接收 __filename、__dirname 与各依赖的 exports（__dep0, __dep1, ...）
fn transformModuleToIIFE(
    allocator: std.mem.Allocator,
    parse: *const ParseResult,
    dep_indices: []const usize,
) ![]const u8 {
    var out = std.ArrayList(u8).initCapacity(allocator, parse.body.items.len + 2048) catch return error.OutOfMemory;
    defer out.deinit(allocator);

    out.appendSlice(allocator, "(function(__filename, __dirname, ") catch return error.OutOfMemory;
    var fmt_buf: [32]u8 = undefined;
    for (dep_indices, 0..) |_, i| {
        if (i > 0) out.appendSlice(allocator, ", ") catch {};
        const s = std.fmt.bufPrint(&fmt_buf, "__dep{d}", .{i}) catch return error.OutOfMemory;
        try out.appendSlice(allocator, s);
    }
    out.appendSlice(allocator, ") {\n\"use strict\";\nvar __exports = {};\n") catch return error.OutOfMemory;

    // 注入 import 绑定
    for (parse.imports.items, dep_indices) |imp, dep_i| {
        var line_buf: [256]u8 = undefined;
        switch (imp.kind) {
            .default_import => {
                const s = std.fmt.bufPrint(&line_buf, "var {s} = __dep{d}.default;\n", .{ imp.binding, dep_i }) catch return error.OutOfMemory;
                try out.appendSlice(allocator, s);
            },
            .namespace => {
                const s = std.fmt.bufPrint(&line_buf, "var {s} = __dep{d};\n", .{ imp.binding, dep_i }) catch return error.OutOfMemory;
                try out.appendSlice(allocator, s);
            },
            .named_imports => {
                for (imp.named_list) |n| {
                    const s = std.fmt.bufPrint(&line_buf, "var {s} = __dep{d}.{s};\n", .{ n, dep_i, n }) catch return error.OutOfMemory;
                    try out.appendSlice(allocator, s);
                }
            },
        }
    }

    out.appendSlice(allocator, parse.body.items) catch return error.OutOfMemory;

    // 命名导出：__exports.x = x
    var line_buf: [256]u8 = undefined;
    for (parse.named_exports.items) |n| {
        const s = std.fmt.bufPrint(&line_buf, "__exports[\"{s}\"] = {s};\n", .{ n, n }) catch return error.OutOfMemory;
        try out.appendSlice(allocator, s);
    }

    if (parse.has_default_export and parse.default_expr.len > 0) {
        const s = std.fmt.bufPrint(&line_buf, "__exports.default = {s};\n", .{parse.default_expr}) catch return error.OutOfMemory;
        try out.appendSlice(allocator, s);
    }

    out.appendSlice(allocator, "return __exports;\n})") catch return error.OutOfMemory;
    return out.toOwnedSlice(allocator);
}

/// 以 ESM 方式执行入口源码：解析 import/export、构建图、按依赖顺序执行；需 --allow-read
/// §1.3 解析期使用 ArenaAllocator，构建与执行阶段一次分配、结束时 arena.deinit() 统一释放，减少扩容与碎片
pub fn runAsEsmModule(
    ctx: jsc.JSContextRef,
    allocator: std.mem.Allocator,
    entry_path: []const u8,
    source: []const u8,
) void {
    const opts = globals.current_run_options orelse {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "ESM needs RunOptions" }) catch {};
        return;
    };
    if (!opts.permissions.allow_read) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "ESM import needs --allow-read" }) catch {};
        return;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var modules = loadModuleGraph(arena_alloc, ctx, entry_path, source) catch {
        errors.reportToStderr(.{ .code = .unknown, .message = "ESM loadModuleGraph failed" }) catch {};
        return;
    };

    const order = topologicalOrder(arena_alloc, modules.items) catch return;

    var exports_cache = arena_alloc.alloc(jsc.JSValueRef, modules.items.len) catch return;
    @memset(exports_cache, undefined);

    for (order) |idx| {
        const m = &modules.items[idx];
        if (m.prebuilt_exports) |prebuilt| {
            exports_cache[idx] = prebuilt;
            continue;
        }
        const transformed = transformModuleToIIFE(allocator, &m.parse, m.dep_indices.items) catch return;
        defer allocator.free(transformed);

        const script_z = allocator.dupeZ(u8, transformed) catch return;
        defer allocator.free(script_z);
        const script_ref = jsc.JSStringCreateWithUTF8CString(script_z.ptr);
        defer jsc.JSStringRelease(script_ref);
        const fn_val = jsc.JSEvaluateScript(ctx, script_ref, null, null, 1, null);
        const fn_obj = jsc.JSValueToObject(ctx, fn_val, null) orelse return;

        const m_dir = std.fs.path.dirname(m.path) orelse ".";
        const filename_z = allocator.dupeZ(u8, m.path) catch return;
        defer allocator.free(filename_z);
        const dirname_z = allocator.dupeZ(u8, m_dir) catch return;
        defer allocator.free(dirname_z);

        var args_buf: [32]jsc.JSValueRef = undefined;
        const filename_js = jsc.JSStringCreateWithUTF8CString(filename_z.ptr);
        defer jsc.JSStringRelease(filename_js);
        const dirname_js = jsc.JSStringCreateWithUTF8CString(dirname_z.ptr);
        defer jsc.JSStringRelease(dirname_js);
        args_buf[0] = jsc.JSValueMakeString(ctx, filename_js);
        args_buf[1] = jsc.JSValueMakeString(ctx, dirname_js);
        var argc: usize = 2;
        for (m.dep_indices.items) |dep_idx| {
            args_buf[argc] = exports_cache[dep_idx];
            argc += 1;
        }
        const result = jsc.JSObjectCallAsFunction(ctx, fn_obj, null, argc, &args_buf, null);
        exports_cache[idx] = result;
    }
}
