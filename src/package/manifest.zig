// package.json / package.jsonc 与 deno.json 解析（main、exports、dependencies、scripts、imports、tasks）
// 参考：docs/PACKAGE_DESIGN.md §1
// 约定：load 使用 Arena，返回的 Manifest 内字符串/表均指向 Arena 内存，调用方在 Arena 生命周期内使用
// TODO: migrate to io_core (rule §3.0); current file I/O via std.fs (openDir, openFile, readToEndAlloc, createFile)

const std = @import("std");

/// 剥离 JSONC 注释（// 行注释与 /* */ 块注释），不剥离字符串字面量内的内容。返回的切片由调用方 free。
fn stripJsoncComments(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var list = std.ArrayList(u8).initCapacity(allocator, content.len) catch return error.OutOfMemory;
    defer list.deinit(allocator);
    var i: usize = 0;
    var in_string = false;
    while (i < content.len) {
        const c = content[i];
        if (in_string) {
            if (c == '\\' and i + 1 < content.len) {
                list.appendSlice(allocator, content[i .. i + 2]) catch return error.OutOfMemory;
                i += 2;
                continue;
            }
            if (c == '"') {
                in_string = false;
            }
            list.append(allocator, c) catch return error.OutOfMemory;
            i += 1;
            continue;
        }
        if (c == '"') {
            in_string = true;
            list.append(allocator, c) catch return error.OutOfMemory;
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < content.len) {
            if (content[i + 1] == '/') {
                i += 2;
                while (i < content.len and content[i] != '\n') i += 1;
                if (i < content.len) {
                    list.append(allocator, '\n') catch return error.OutOfMemory;
                    i += 1;
                }
                continue;
            }
            if (content[i + 1] == '*') {
                i += 2;
                while (i + 1 < content.len and !(content[i] == '*' and content[i + 1] == '/')) i += 1;
                if (i + 1 < content.len) i += 2;
                continue;
            }
        }
        list.append(allocator, c) catch return error.OutOfMemory;
        i += 1;
    }
    return list.toOwnedSlice(allocator);
}

/// 解析后的项目 manifest 视图（package.json + 可选 deno.json 合并）
/// 所有切片与 HashMap 均指向 load 时传入的 Arena，调用方负责保持 Arena 有效
pub const Manifest = struct {
    /// 项目名（package.json name）
    name: []const u8 = "",
    /// 项目版本（package.json version）
    version: []const u8 = "",
    /// 包入口（package.json main）
    main: ?[]const u8 = null,
    /// 包类型：module / commonjs（package.json type）
    type: ?[]const u8 = null,
    /// package.json exports 字段的 JSON 值（字符串或对象），供 export_map 解析；若为 null 表示无 exports
    exports_value: ?std.json.Value = null,
    /// package.json dependencies（key=包名, value=版本范围）
    dependencies: std.StringArrayHashMap([]const u8) = undefined,
    /// package.json scripts（key=脚本名, value=命令）
    scripts: std.StringArrayHashMap([]const u8) = undefined,
    /// deno.json imports（import map）：key=裸说明符, value=映射后的说明符（如 jsr:...、npm:...、相对路径）
    imports: std.StringArrayHashMap([]const u8) = undefined,
    /// deno.json tasks（key=任务名, value=命令）
    tasks: std.StringArrayHashMap([]const u8) = undefined,

    /// 释放 dependencies/scripts/imports/tasks 占用的内存（若使用 Arena 则由 Arena.deinit 统一释放，可不调用）
    pub fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        self.dependencies.deinit();
        self.scripts.deinit();
        self.imports.deinit();
        self.tasks.deinit();
        _ = allocator;
    }

    /// 从目录 dir 读取 package.json / package.jsonc（必选其一）与 deno.json/deno.jsonc（可选），合并为一份 Manifest。
    /// 使用 Arena 分配，返回的 Manifest 与 arena 绑定；调用方 deinit arena 前不得使用 Manifest。
    /// 返回的 arena 由调用方 deinit；Manifest 内字段均指向 arena 内存。
    pub fn load(allocator: std.mem.Allocator, dir: []const u8) !struct { arena: std.heap.ArenaAllocator, manifest: Manifest } {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        var manifest: Manifest = .{};
        manifest.dependencies = std.StringArrayHashMap([]const u8).init(a);
        manifest.scripts = std.StringArrayHashMap([]const u8).init(a);
        manifest.imports = std.StringArrayHashMap([]const u8).init(a);
        manifest.tasks = std.StringArrayHashMap([]const u8).init(a);

        var dir_handle = if (std.fs.path.isAbsolute(dir))
            std.fs.openDirAbsolute(dir, .{}) catch |e| {
                if (e == error.FileNotFound) return error.ManifestNotFound;
                return e;
            }
        else
            std.fs.cwd().openDir(dir, .{}) catch |e| {
                if (e == error.FileNotFound) return error.ManifestNotFound;
                return e;
            };
        defer dir_handle.close();

        // package.jsonc 或 package.json（优先 jsonc，便于写注释）
        const pkg_paths = [_][]const u8{ "package.jsonc", "package.json" };
        var pkg_content: []const u8 = undefined;
        var pkg_is_jsonc = false;
        for (pkg_paths) |name| {
            const pkg_file = dir_handle.openFile(name, .{}) catch continue;
            defer pkg_file.close();
            pkg_content = pkg_file.readToEndAlloc(a, std.math.maxInt(usize)) catch return error.OutOfMemory;
            pkg_is_jsonc = std.mem.endsWith(u8, name, ".jsonc");
            break;
        } else return error.ManifestNotFound;
        const to_parse = if (pkg_is_jsonc) blk: {
            const stripped = stripJsoncComments(a, pkg_content) catch return error.OutOfMemory;
            defer a.free(stripped);
            break :blk stripped;
        } else pkg_content;
        var pkg_parsed = try std.json.parseFromSlice(std.json.Value, a, to_parse, .{ .allocate = .alloc_always });
        defer pkg_parsed.deinit();
        const root = pkg_parsed.value;
        if (root != .object) return error.InvalidPackageJson;

        const obj = root.object;
        if (obj.get("name")) |v| { if (v == .string) manifest.name = v.string; }
        if (obj.get("version")) |v| { if (v == .string) manifest.version = v.string; }
        if (obj.get("main")) |v| { if (v == .string) manifest.main = v.string; }
        if (obj.get("type")) |v| { if (v == .string) manifest.type = v.string; }
        if (obj.get("exports")) |v| manifest.exports_value = v;

        if (obj.get("dependencies")) |v| {
            if (v == .object) {
                var it = v.object.iterator();
                while (it.next()) |entry| {
                    const val = entry.value_ptr.*;
                    const ver = if (val == .string) val.string else "";
                    try manifest.dependencies.put(entry.key_ptr.*, ver);
                }
            }
        }
        if (obj.get("scripts")) |v| {
            if (v == .object) {
                var it = v.object.iterator();
                while (it.next()) |entry| {
                    const val = entry.value_ptr.*;
                    const cmd = if (val == .string) val.string else "";
                    try manifest.scripts.put(entry.key_ptr.*, cmd);
                }
            }
        }

        // deno.json 或 deno.jsonc（优先 jsonc）
        const deno_paths = [_][]const u8{ "deno.jsonc", "deno.json" };
        for (deno_paths) |name| {
            const deno_file = dir_handle.openFile(name, .{}) catch continue;
            defer deno_file.close();
            const deno_content = deno_file.readToEndAlloc(a, std.math.maxInt(usize)) catch continue;
            // .jsonc: deno_to_parse is newly allocated by stripJsoncComments (caller frees). .json: deno_to_parse is deno_content (arena), do not free.
            const deno_to_parse = if (std.mem.endsWith(u8, name, ".jsonc"))
                stripJsoncComments(a, deno_content) catch continue
            else
                deno_content;
            defer if (std.mem.endsWith(u8, name, ".jsonc")) a.free(deno_to_parse);
            var deno_parsed = std.json.parseFromSlice(std.json.Value, a, deno_to_parse, .{ .allocate = .alloc_always }) catch continue;
            defer deno_parsed.deinit();
            const d_root = deno_parsed.value;
            if (d_root != .object) continue;
            const d_obj = d_root.object;
            if (d_obj.get("imports")) |v| {
                if (v == .object) {
                    var it = v.object.iterator();
                    while (it.next()) |entry| {
                        const val = entry.value_ptr.*;
                        const mapped = if (val == .string) val.string else "";
                        try manifest.imports.put(entry.key_ptr.*, mapped);
                    }
                }
            }
            if (d_obj.get("tasks")) |v| {
                if (v == .object) {
                    var it = v.object.iterator();
                    while (it.next()) |entry| {
                        const val = entry.value_ptr.*;
                        const cmd = if (val == .string) val.string else "";
                        try manifest.tasks.put(entry.key_ptr.*, cmd);
                    }
                }
            }
            break;
        }

        return .{ .arena = arena, .manifest = manifest };
    }

    /// 从目录 dir 仅加载 package.json / package.jsonc（用于包目录内解析 main/exports），不读 deno.json。
    /// 返回的 arena 由调用方 deinit；Manifest 内字段指向 arena 内存。
    pub fn loadPackageOnly(allocator: std.mem.Allocator, dir: []const u8) !struct { arena: std.heap.ArenaAllocator, manifest: Manifest } {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        var manifest: Manifest = .{};
        manifest.dependencies = std.StringArrayHashMap([]const u8).init(a);
        manifest.scripts = std.StringArrayHashMap([]const u8).init(a);
        manifest.imports = std.StringArrayHashMap([]const u8).init(a);
        manifest.tasks = std.StringArrayHashMap([]const u8).init(a);

        var dir_handle = if (std.fs.path.isAbsolute(dir))
            std.fs.openDirAbsolute(dir, .{}) catch |e| {
                if (e == error.FileNotFound) return error.ManifestNotFound;
                return e;
            }
        else
            std.fs.cwd().openDir(dir, .{}) catch |e| {
                if (e == error.FileNotFound) return error.ManifestNotFound;
                return e;
            };
        defer dir_handle.close();
        const pkg_paths = [_][]const u8{ "package.jsonc", "package.json" };
        var pkg_content: []const u8 = undefined;
        var pkg_is_jsonc = false;
        for (pkg_paths) |name| {
            const pkg_file = dir_handle.openFile(name, .{}) catch continue;
            defer pkg_file.close();
            pkg_content = pkg_file.readToEndAlloc(a, std.math.maxInt(usize)) catch return error.OutOfMemory;
            pkg_is_jsonc = std.mem.endsWith(u8, name, ".jsonc");
            break;
        } else return error.ManifestNotFound;
        const to_parse = if (pkg_is_jsonc) blk: {
            const stripped = stripJsoncComments(a, pkg_content) catch return error.OutOfMemory;
            defer a.free(stripped);
            break :blk stripped;
        } else pkg_content;
        var pkg_parsed = try std.json.parseFromSlice(std.json.Value, a, to_parse, .{ .allocate = .alloc_always });
        defer pkg_parsed.deinit();
        const root = pkg_parsed.value;
        if (root != .object) return error.InvalidPackageJson;

        const obj = root.object;
        if (obj.get("name")) |v| { if (v == .string) manifest.name = v.string; }
        if (obj.get("version")) |v| { if (v == .string) manifest.version = v.string; }
        if (obj.get("main")) |v| { if (v == .string) manifest.main = v.string; }
        if (obj.get("type")) |v| { if (v == .string) manifest.type = v.string; }
        if (obj.get("exports")) |v| manifest.exports_value = v;

        if (obj.get("dependencies")) |v| {
            if (v == .object) {
                var it = v.object.iterator();
                while (it.next()) |entry| {
                    const val = entry.value_ptr.*;
                    try manifest.dependencies.put(entry.key_ptr.*, if (val == .string) val.string else "");
                }
            }
        }
        if (obj.get("scripts")) |v| {
            if (v == .object) {
                var it = v.object.iterator();
                while (it.next()) |entry| {
                    const val = entry.value_ptr.*;
                    try manifest.scripts.put(entry.key_ptr.*, if (val == .string) val.string else "");
                }
            }
        }

        return .{ .arena = arena, .manifest = manifest };
    }
};

/// 在 dir 下向 package.json 或 package.jsonc 的 dependencies 添加/覆盖 name -> version，写回同一文件（写为 JSON，jsonc 会丢失注释）。
pub fn addPackageDependency(allocator: std.mem.Allocator, dir: []const u8, name: []const u8, version: []const u8) !void {
    var dir_handle = if (std.fs.path.isAbsolute(dir))
        try std.fs.openDirAbsolute(dir, .{})
    else
        try std.fs.cwd().openDir(dir, .{});
    defer dir_handle.close();
    const pkg_paths = [_][]const u8{ "package.jsonc", "package.json" };
    for (pkg_paths) |name_path| {
        const f = dir_handle.openFile(name_path, .{}) catch continue;
        defer f.close();
        const content = f.readToEndAlloc(allocator, std.math.maxInt(usize)) catch return error.OutOfMemory;
        defer allocator.free(content);
        const to_parse = if (std.mem.endsWith(u8, name_path, ".jsonc")) blk: {
            const s = stripJsoncComments(allocator, content) catch return error.OutOfMemory;
            defer allocator.free(s);
            break :blk s;
        } else content;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, to_parse, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return error.InvalidPackageJson;
        if (root.object.get("dependencies")) |v| {
            if (v == .object) {
                try @constCast(&v.object).put(try allocator.dupe(u8, name), .{ .string = try allocator.dupe(u8, version) });
            }
        } else {
            var new_deps = std.json.ObjectMap.init(allocator);
            try new_deps.put(try allocator.dupe(u8, name), .{ .string = try allocator.dupe(u8, version) });
            try @constCast(&root.object).put(try allocator.dupe(u8, "dependencies"), .{ .object = new_deps });
        }
        const out = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
        defer allocator.free(out);
        var out_file = try dir_handle.createFile(name_path, .{});
        defer out_file.close();
        try out_file.writeAll(out);
        return;
    }
    return error.ManifestNotFound;
}

/// 在 dir 下向 deno.json 或 deno.jsonc 的 imports 添加/覆盖 specifier -> value；无文件则创建 deno.json。
pub fn addDenoImport(allocator: std.mem.Allocator, dir: []const u8, specifier: []const u8, value: []const u8) !void {
    var dir_handle = if (std.fs.path.isAbsolute(dir))
        try std.fs.openDirAbsolute(dir, .{})
    else
        try std.fs.cwd().openDir(dir, .{});
    defer dir_handle.close();
    const deno_paths = [_][]const u8{ "deno.jsonc", "deno.json" };
    for (deno_paths) |name_path| {
        const f = dir_handle.openFile(name_path, .{}) catch continue;
        defer f.close();
        const content = f.readToEndAlloc(allocator, std.math.maxInt(usize)) catch return error.OutOfMemory;
        defer allocator.free(content);
        const to_parse = if (std.mem.endsWith(u8, name_path, ".jsonc")) blk: {
            const s = stripJsoncComments(allocator, content) catch return error.OutOfMemory;
            defer allocator.free(s);
            break :blk s;
        } else content;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, to_parse, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return error.InvalidPackageJson;
        if (root.object.get("imports")) |v| {
            if (v == .object) {
                try @constCast(&v.object).put(try allocator.dupe(u8, specifier), .{ .string = try allocator.dupe(u8, value) });
            }
        } else {
            var new_imports = std.json.ObjectMap.init(allocator);
            try new_imports.put(try allocator.dupe(u8, specifier), .{ .string = try allocator.dupe(u8, value) });
            try @constCast(&root.object).put(try allocator.dupe(u8, "imports"), .{ .object = new_imports });
        }
        const out = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
        defer allocator.free(out);
        var out_file = try dir_handle.createFile(name_path, .{});
        defer out_file.close();
        try out_file.writeAll(out);
        return;
    }
    var new_root = std.json.ObjectMap.init(allocator);
    var new_imports = std.json.ObjectMap.init(allocator);
    try new_imports.put(try allocator.dupe(u8, specifier), .{ .string = try allocator.dupe(u8, value) });
    try new_root.put(try allocator.dupe(u8, "imports"), .{ .object = new_imports });
    const out = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = new_root }, .{ .whitespace = .indent_2 });
    defer allocator.free(out);
    var out_file = try dir_handle.createFile("deno.json", .{});
    defer out_file.close();
    try out_file.writeAll(out);
}
