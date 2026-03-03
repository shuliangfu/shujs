// package.json / package.jsonc 与 deno.json 解析（main、exports、dependencies、scripts、imports、tasks）
// 参考：docs/PACKAGE_DESIGN.md §1
// 约定：load 使用 Arena，返回的 Manifest 内字符串/表均指向 Arena 内存，调用方在 Arena 生命周期内使用
// 文件/目录与路径经 io_core（§3.0）

const std = @import("std");
const errors = @import("errors");
const libs_io = @import("libs_io");
const libs_process = @import("libs_process");

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
    /// package.json devDependencies（key=包名, value=版本范围）；install 时一并安装
    dev_dependencies: std.StringArrayHashMap([]const u8) = undefined,
    /// package.json scripts（key=脚本名, value=命令）
    scripts: std.StringArrayHashMap([]const u8) = undefined,
    /// deno.json imports（import map）：key=裸说明符, value=映射后的说明符（如 jsr:...、npm:...、相对路径）
    imports: std.StringArrayHashMap([]const u8) = undefined,
    /// deno.json tasks（key=任务名, value=命令）
    tasks: std.StringArrayHashMap([]const u8) = undefined,
    /// package.json / deno.json 的 test 配置（include、exclude、permissions 等）；供 shu test 使用，合并时 deno 优先
    test_value: ?std.json.Value = null,
    /// package.json / deno.json 的 fmt 配置（useTabs、lineWidth、include、exclude 等）；供 shu fmt 使用
    fmt_value: ?std.json.Value = null,
    /// package.json / deno.json 的 lint 配置（include、exclude、rules 等）；供 shu lint 使用
    lint_value: ?std.json.Value = null,
    /// package.json / deno.json 的 compilerOptions（TypeScript 选项）；供编译/类型检查使用
    compiler_options_value: ?std.json.Value = null,

    /// 释放 dependencies/dev_dependencies/scripts/imports/tasks 占用的内存（若使用 Arena 则由 Arena.deinit 统一释放，可不调用）
    pub fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        self.dependencies.deinit();
        self.dev_dependencies.deinit();
        self.scripts.deinit();
        self.imports.deinit();
        self.tasks.deinit();
        _ = allocator;
    }

    /// 从目录 dir 读取 package.json / package.jsonc 与 deno.json/deno.jsonc。与 Deno 兼容：可有 package.json、或仅 deno.json、或两者同时存在；至少需其一。
    /// 使用 Arena 分配，返回的 Manifest 与 arena 绑定；调用方 deinit arena 前不得使用 Manifest。
    /// 返回的 arena 由调用方 deinit；Manifest 内字段均指向 arena 内存。
    pub fn load(allocator: std.mem.Allocator, dir: []const u8) !struct { arena: std.heap.ArenaAllocator, manifest: Manifest } {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        var manifest: Manifest = .{};
        manifest.dependencies = std.StringArrayHashMap([]const u8).init(a);
        manifest.dev_dependencies = std.StringArrayHashMap([]const u8).init(a);
        manifest.scripts = std.StringArrayHashMap([]const u8).init(a);
        manifest.imports = std.StringArrayHashMap([]const u8).init(a);
        manifest.tasks = std.StringArrayHashMap([]const u8).init(a);

        const io = libs_process.getProcessIo() orelse return error.ProcessIoNotSet;
        var dir_handle = if (libs_io.pathIsAbsolute(dir))
            libs_io.openDirAbsolute(dir, .{}) catch |e| {
                if (e == libs_io.FileOpenError.FileNotFound) return error.ManifestNotFound;
                return e;
            }
        else
            libs_io.openDirCwd(dir, .{}) catch |e| {
                if (e == libs_io.FileOpenError.FileNotFound) return error.ManifestNotFound;
                return e;
            };
        defer dir_handle.close(io);

        // package.jsonc 或 package.json（优先 jsonc）
        const pkg_paths = [_][]const u8{ "package.jsonc", "package.json" };
        var pkg_content: []const u8 = undefined;
        var pkg_is_jsonc = false;
        var has_pkg = false;
        for (pkg_paths) |name| {
            pkg_content = dir_handle.readFileAlloc(io, name, a, .unlimited) catch continue;
            pkg_is_jsonc = std.mem.endsWith(u8, name, ".jsonc");
            has_pkg = true;
            break;
        }
        if (has_pkg) {
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
            if (obj.get("name")) |v| {
                if (v == .string) manifest.name = v.string;
            }
            if (obj.get("version")) |v| {
                if (v == .string) manifest.version = v.string;
            }
            if (obj.get("main")) |v| {
                if (v == .string) manifest.main = v.string;
            }
            if (obj.get("type")) |v| {
                if (v == .string) manifest.type = v.string;
            }
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
            if (obj.get("devDependencies")) |v| {
                if (v == .object) {
                    var it = v.object.iterator();
                    while (it.next()) |entry| {
                        const val = entry.value_ptr.*;
                        const ver = if (val == .string) val.string else "";
                        try manifest.dev_dependencies.put(entry.key_ptr.*, ver);
                    }
                }
            }
            if (obj.get("test")) |v| manifest.test_value = v;
            if (obj.get("fmt")) |v| manifest.fmt_value = v;
            if (obj.get("lint")) |v| manifest.lint_value = v;
            if (obj.get("compilerOptions")) |v| manifest.compiler_options_value = v;
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
            // package.json 的 imports（与 deno 同格式：specifier -> jsr:/npm:/path），供 install 与 deno 一致从 imports 安装
            if (obj.get("imports")) |v| {
                if (v == .object) {
                    var it = v.object.iterator();
                    while (it.next()) |entry| {
                        const val = entry.value_ptr.*;
                        const mapped = if (val == .string) val.string else "";
                        try manifest.imports.put(entry.key_ptr.*, mapped);
                    }
                }
            }

            // deno.json 或 deno.jsonc（优先 jsonc）
            const deno_paths = [_][]const u8{ "deno.jsonc", "deno.json" };
            for (deno_paths) |name| {
                const deno_content = dir_handle.readFileAlloc(io, name, a, .unlimited) catch continue;
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
                if (manifest.test_value == null) {
                    if (d_obj.get("test")) |v| manifest.test_value = v;
                }
                if (manifest.fmt_value == null) {
                    if (d_obj.get("fmt")) |v| manifest.fmt_value = v;
                }
                if (manifest.lint_value == null) {
                    if (d_obj.get("lint")) |v| manifest.lint_value = v;
                }
                if (manifest.compiler_options_value == null) {
                    if (d_obj.get("compilerOptions")) |v| manifest.compiler_options_value = v;
                }
                break;
            }
            return .{ .arena = arena, .manifest = manifest };
        }
        // 仅 deno.json：与 Deno 一致，无 package.json 时仅从 deno.json 加载
        const deno_only_paths = [_][]const u8{ "deno.jsonc", "deno.json" };
        for (deno_only_paths) |name| {
            const deno_content = dir_handle.readFileAlloc(io, name, a, .unlimited) catch continue;
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
            if (d_obj.get("name")) |v| {
                if (v == .string) manifest.name = v.string;
            }
            if (d_obj.get("version")) |v| {
                if (v == .string) manifest.version = v.string;
            }
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
            if (d_obj.get("test")) |v| manifest.test_value = v;
            if (d_obj.get("fmt")) |v| manifest.fmt_value = v;
            if (d_obj.get("lint")) |v| manifest.lint_value = v;
            if (d_obj.get("compilerOptions")) |v| manifest.compiler_options_value = v;
            return .{ .arena = arena, .manifest = manifest };
        }
        return error.ManifestNotFound;
    }

    /// 从目录 dir 仅加载 package.json / package.jsonc（用于包目录内解析 main/exports），不读 deno.json。
    /// 返回的 arena 由调用方 deinit；Manifest 内字段指向 arena 内存。
    pub fn loadPackageOnly(allocator: std.mem.Allocator, dir: []const u8) !struct { arena: std.heap.ArenaAllocator, manifest: Manifest } {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        var manifest: Manifest = .{};
        manifest.dependencies = std.StringArrayHashMap([]const u8).init(a);
        manifest.dev_dependencies = std.StringArrayHashMap([]const u8).init(a);
        manifest.scripts = std.StringArrayHashMap([]const u8).init(a);
        manifest.imports = std.StringArrayHashMap([]const u8).init(a);
        manifest.tasks = std.StringArrayHashMap([]const u8).init(a);

        const io = libs_process.getProcessIo() orelse return error.ProcessIoNotSet;
        var dir_handle = if (libs_io.pathIsAbsolute(dir))
            libs_io.openDirAbsolute(dir, .{}) catch |e| {
                if (e == libs_io.FileOpenError.FileNotFound) return error.ManifestNotFound;
                return e;
            }
        else
            libs_io.openDirCwd(dir, .{}) catch |e| {
                if (e == libs_io.FileOpenError.FileNotFound) return error.ManifestNotFound;
                return e;
            };
        defer dir_handle.close(io);
        const pkg_paths = [_][]const u8{ "package.jsonc", "package.json" };
        var pkg_content: []const u8 = undefined;
        var pkg_is_jsonc = false;
        for (pkg_paths) |name| {
            pkg_content = dir_handle.readFileAlloc(io, name, a, .unlimited) catch continue;
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
        if (obj.get("name")) |v| {
            if (v == .string) manifest.name = v.string;
        }
        if (obj.get("version")) |v| {
            if (v == .string) manifest.version = v.string;
        }
        if (obj.get("main")) |v| {
            if (v == .string) manifest.main = v.string;
        }
        if (obj.get("type")) |v| {
            if (v == .string) manifest.type = v.string;
        }
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
        if (obj.get("devDependencies")) |v| {
            if (v == .object) {
                var it = v.object.iterator();
                while (it.next()) |entry| {
                    const val = entry.value_ptr.*;
                    try manifest.dev_dependencies.put(entry.key_ptr.*, if (val == .string) val.string else "");
                }
            }
        }
        if (obj.get("test")) |v| manifest.test_value = v;
        if (obj.get("fmt")) |v| manifest.fmt_value = v;
        if (obj.get("lint")) |v| manifest.lint_value = v;
        if (obj.get("compilerOptions")) |v| manifest.compiler_options_value = v;
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

/// 释放由 deepCopyJsonValue / addPackageDependency 构建的 std.json.Value 树（递归释放 .string/.number_string/.object/.array 并 deinit 实际 map/array，调用方须用与构建时相同的 allocator）。接受 *Value 以便对真实的 object/array 调用 deinit。
fn freeJsonValue(allocator: std.mem.Allocator, v: *const std.json.Value) void {
    switch (v.*) {
        .string => allocator.free(v.string),
        .number_string => allocator.free(v.number_string),
        .object => {
            var it = v.object.iterator();
            while (it.next()) |e| {
                allocator.free(e.key_ptr.*);
                freeJsonValue(allocator, e.value_ptr);
            }
            @constCast(&v.object).deinit();
        },
        .array => {
            for (v.array.items) |*item| {
                freeJsonValue(allocator, item);
            }
            @constCast(&v.array).deinit();
        },
        .null, .bool, .integer, .float => {},
    }
}

/// 深拷贝 std.json.Value，所有 key/string 均用 a 分配，避免 stringify 时依赖解析器分配的内存。
fn deepCopyJsonValue(a: std.mem.Allocator, v: std.json.Value) !std.json.Value {
    switch (v) {
        .string => return .{ .string = try a.dupe(u8, v.string) },
        .object => {
            var new_map = std.json.ObjectMap.init(a);
            var it = v.object.iterator();
            while (it.next()) |e| {
                const k = try a.dupe(u8, e.key_ptr.*);
                const child = try deepCopyJsonValue(a, e.value_ptr.*);
                try new_map.put(k, child);
            }
            return .{ .object = new_map };
        },
        .array => {
            var new_arr = std.json.Array.initCapacity(a, v.array.items.len) catch return error.OutOfMemory;
            for (v.array.items) |item| {
                try new_arr.append(try deepCopyJsonValue(a, item));
            }
            return .{ .array = new_arr };
        },
        .float => return .{ .float = v.float },
        .number_string => return .{ .number_string = try a.dupe(u8, v.number_string) },
        .integer => return .{ .integer = v.integer },
        .bool => return .{ .bool = v.bool },
        .null => return .{ .null = {} },
    }
}

/// 在 dir 下向 package.json 或 package.jsonc 的 dependencies 或 devDependencies 添加/覆盖 name -> version，写回同一文件（写为 JSON，jsonc 会丢失注释）。
/// dev 为 true 时写入 devDependencies，否则写入 dependencies。
/// 使用 Arena 构建全新 root 树再 stringify，避免 stringify 时读到解析器已失效的 key（0xaa 崩溃）。
pub fn addPackageDependency(allocator: std.mem.Allocator, dir: []const u8, name: []const u8, version: []const u8, dev: bool) !void {
    const io = libs_process.getProcessIo() orelse return error.ProcessIoNotSet;
    const section = if (dev) "devDependencies" else "dependencies";
    var dir_handle = if (libs_io.pathIsAbsolute(dir))
        try libs_io.openDirAbsolute(dir, .{})
    else
        try libs_io.openDirCwd(dir, .{});
    defer dir_handle.close(io);
    const pkg_paths = [_][]const u8{ "package.jsonc", "package.json" };
    for (pkg_paths) |name_path| {
        const content = dir_handle.readFileAlloc(io, name_path, allocator, .unlimited) catch continue;
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

        // 用同一 allocator 构建新树，避免 Arena 导致 Stringify 对 allocator 的 comptime 要求
        const a = allocator;

        // 新 dependencies 对象：拷贝原 section 内容并加入 name -> version
        var new_deps = std.json.ObjectMap.init(a);
        if (root.object.get(section)) |sec_val| {
            if (sec_val == .object) {
                var it = sec_val.object.iterator();
                while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.*, name)) continue;
                    const k = try a.dupe(u8, entry.key_ptr.*);
                    const ev = entry.value_ptr.*;
                    if (ev == .string) {
                        try new_deps.put(k, .{ .string = try a.dupe(u8, ev.string) });
                    } else {
                        try new_deps.put(k, try deepCopyJsonValue(a, ev));
                    }
                }
            }
        }
        try new_deps.put(try a.dupe(u8, name), .{ .string = try a.dupe(u8, version) });

        // 新 root：逐 key 深拷贝，section 用 new_deps 替换；若原 manifest 无 section 则遍历时不会出现，故最后统一写入 section
        var new_root = std.json.ObjectMap.init(a);
        var it = root.object.iterator();
        while (it.next()) |e| {
            const k = try a.dupe(u8, e.key_ptr.*);
            const val: std.json.Value = if (std.mem.eql(u8, e.key_ptr.*, section))
                std.json.Value{ .object = new_deps }
            else
                try deepCopyJsonValue(a, e.value_ptr.*);
            try new_root.put(k, val);
        }
        // 仅当原 manifest 无 section 时写入，避免重复 put 导致替换后泄漏本次 dupe(section) 的 key
        if (root.object.get(section) == null) {
            try new_root.put(try a.dupe(u8, section), std.json.Value{ .object = new_deps });
        }

        const out = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = new_root }, .{ .whitespace = .indent_2 });
        defer allocator.free(out);
        var out_file = try dir_handle.createFile(io, name_path, .{});
        defer out_file.close(io);
        try out_file.writeStreamingAll(io, out);
        // 按确定顺序释放：先释放 new_deps（含 name/version 的 dupe），再释放 new_root（遇到 section 不再递归，避免二次 deinit）
        {
            var it_deps = new_deps.iterator();
            while (it_deps.next()) |e| {
                allocator.free(e.key_ptr.*);
                freeJsonValue(allocator, e.value_ptr);
            }
            new_deps.deinit();
        }
        {
            var it_root = new_root.iterator();
            while (it_root.next()) |e| {
                const is_section = std.mem.eql(u8, e.key_ptr.*, section);
                allocator.free(e.key_ptr.*);
                if (!is_section) {
                    freeJsonValue(allocator, e.value_ptr);
                }
            }
            new_root.deinit();
        }
        return;
    }
    return error.ManifestNotFound;
}

/// 在 dir 下向 package.json 或 package.jsonc 的 imports 添加/覆盖 specifier -> value（与 deno.json 同格式，如 "@dreamer/view" -> "jsr:@dreamer/view@1.1.2"）。写回同一文件。
pub fn addPackageImport(allocator: std.mem.Allocator, dir: []const u8, specifier: []const u8, value: []const u8) !void {
    const io = libs_process.getProcessIo() orelse return error.ProcessIoNotSet;
    var dir_handle = if (libs_io.pathIsAbsolute(dir))
        try libs_io.openDirAbsolute(dir, .{})
    else
        try libs_io.openDirCwd(dir, .{});
    defer dir_handle.close(io);
    const pkg_paths = [_][]const u8{ "package.jsonc", "package.json" };
    for (pkg_paths) |name_path| {
        const content = dir_handle.readFileAlloc(io, name_path, allocator, .unlimited) catch continue;
        defer allocator.free(content);
        const to_parse = if (std.mem.endsWith(u8, name_path, ".jsonc")) blk: {
            const s = stripJsoncComments(allocator, content) catch return error.OutOfMemory;
            defer allocator.free(s);
            break :blk s;
        } else content;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, to_parse, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        // 必须改 parsed.value，不能改拷贝；root 仅用于读/清理，stringify 用 parsed.value
        if (parsed.value != .object) return error.InvalidPackageJson;
        const root_ptr = &parsed.value;
        const specifier_key = try allocator.dupe(u8, specifier);
        const value_dup = try allocator.dupe(u8, value);
        var imports_key_owned: ?[]const u8 = null;
        if (@constCast(root_ptr).object.getPtr("imports")) |imports_ptr| {
            if (imports_ptr.* == .object) {
                try imports_ptr.*.object.put(specifier_key, .{ .string = value_dup });
            }
        } else {
            var new_imports = std.json.ObjectMap.init(allocator);
            try new_imports.put(specifier_key, .{ .string = value_dup });
            imports_key_owned = try allocator.dupe(u8, "imports");
            try @constCast(root_ptr).object.put(imports_key_owned.?, .{ .object = new_imports });
        }
        const out = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
        defer allocator.free(out);
        // 用绝对路径写入，确保与读取的是同一文件（避免 dir 与 handle 歧义导致未落盘）
        const full_path = try libs_io.pathJoin(allocator, &.{ dir, name_path });
        defer allocator.free(full_path);
        var out_file = try libs_io.createFileAbsolute(full_path, .{});
        defer out_file.close(io);
        try out_file.writeStreamingAll(io, out);
        out_file.sync(io) catch {}; // 确保落盘，避免 IDE/用户未看到更新
        // parsed.deinit() 不释放由 put 加入的 key/value，须 swapRemove 并 free 避免泄漏（与 addPackageDependency 一致）
        if (@constCast(root_ptr).object.getPtr("imports")) |imports_ptr| {
            if (imports_ptr.* == .object) {
                if (imports_ptr.*.object.get(specifier_key)) |val| {
                    if (val == .string) allocator.free(val.string);
                }
                _ = imports_ptr.*.object.swapRemove(specifier_key);
            }
        }
        allocator.free(specifier_key);
        // value_dup 已在上方 get().string 时 free，不再重复 free
        if (imports_key_owned) |imports_key| {
            if (root_ptr.object.get(imports_key)) |v| {
                if (v == .object) @constCast(&v.object).deinit();
            }
            _ = @constCast(root_ptr).object.swapRemove(imports_key);
            allocator.free(imports_key);
        }
        return;
    }
    return error.ManifestNotFound;
}

/// 从 dir 下 package.json 或 package.jsonc 的 dependencies 与 devDependencies 中移除指定 name，写回同一文件。若 name 不存在则静默成功。
/// 返回是否实际移除了该包（至少从 dependencies 或 devDependencies 之一移除）。
pub fn removePackageDependency(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) !bool {
    const io = libs_process.getProcessIo() orelse return error.ProcessIoNotSet;
    var dir_handle = if (libs_io.pathIsAbsolute(dir))
        try libs_io.openDirAbsolute(dir, .{})
    else
        try libs_io.openDirCwd(dir, .{});
    defer dir_handle.close(io);
    const pkg_paths = [_][]const u8{ "package.jsonc", "package.json" };
    for (pkg_paths) |name_path| {
        const content = dir_handle.readFileAlloc(io, name_path, allocator, .unlimited) catch continue;
        defer allocator.free(content);
        const to_parse = if (std.mem.endsWith(u8, name_path, ".jsonc")) blk: {
            const s = stripJsoncComments(allocator, content) catch return error.OutOfMemory;
            defer allocator.free(s);
            break :blk s;
        } else content;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, to_parse, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidPackageJson;
        const root_ptr = &parsed.value;
        // 必须用 getPtr 取得树中节点的指针，swapRemove 才会作用到 parsed.value，stringify 时不会读到无效指针（否则改的是副本会崩）。
        var changed = false;
        if (@constCast(root_ptr).object.getPtr("dependencies")) |deps_ptr| {
            if (deps_ptr.* == .object) {
                if (@constCast(&deps_ptr.*.object).swapRemove(name)) changed = true;
            }
        }
        if (@constCast(root_ptr).object.getPtr("devDependencies")) |dev_ptr| {
            if (dev_ptr.* == .object) {
                if (@constCast(&dev_ptr.*.object).swapRemove(name)) changed = true;
            }
        }
        if (!changed) return false;
        const out = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
        defer allocator.free(out);
        var out_file = try dir_handle.createFile(io, name_path, .{});
        defer out_file.close(io);
        try out_file.writeStreamingAll(io, out);
        return true;
    }
    return error.ManifestNotFound;
}

/// 从 dir 下 package.json 或 package.jsonc 的 imports 中移除指定 specifier（如 "@dreamer/console"），写回同一文件。若 specifier 不存在则静默返回 false。
/// 返回是否实际移除了该项。JSR 包若通过 shu add jsr:@scope/name 添加，会写在 imports 中，remove 时需同时调本函数与 removePackageDependency。
pub fn removePackageImport(allocator: std.mem.Allocator, dir: []const u8, specifier: []const u8) !bool {
    const io = libs_process.getProcessIo() orelse return error.ProcessIoNotSet;
    var dir_handle = if (libs_io.pathIsAbsolute(dir))
        try libs_io.openDirAbsolute(dir, .{})
    else
        try libs_io.openDirCwd(dir, .{});
    defer dir_handle.close(io);
    const pkg_paths = [_][]const u8{ "package.jsonc", "package.json" };
    for (pkg_paths) |name_path| {
        const content = dir_handle.readFileAlloc(io, name_path, allocator, .unlimited) catch continue;
        defer allocator.free(content);
        const to_parse = if (std.mem.endsWith(u8, name_path, ".jsonc")) blk: {
            const s = stripJsoncComments(allocator, content) catch return error.OutOfMemory;
            defer allocator.free(s);
            break :blk s;
        } else content;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, to_parse, .{ .allocate = .alloc_always });
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidPackageJson;
        const root_ptr = &parsed.value;
        var changed = false;
        if (@constCast(root_ptr).object.getPtr("imports")) |imports_ptr| {
            if (imports_ptr.* == .object) {
                var it = imports_ptr.*.object.iterator();
                while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.*, specifier)) {
                        // 只 swapRemove，不 free value：解析器分配的内存在 parsed.deinit() 时统一释放；若在此处用 allocator.free(entry.value_ptr.*.string) 会与解析器内部 allocator 不一致导致 Invalid free
                        _ = @constCast(&imports_ptr.*.object).swapRemove(entry.key_ptr.*);
                        changed = true;
                        break;
                    }
                }
            }
        }
        if (!changed) return false;
        const out = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
        defer allocator.free(out);
        var out_file = try dir_handle.createFile(io, name_path, .{});
        defer out_file.close(io);
        try out_file.writeStreamingAll(io, out);
        return true;
    }
    return error.ManifestNotFound;
}

/// 目录 dir 下是否存在 deno.json 或 deno.jsonc（用于 add 时决定写入 deno.json 还是 package.json）。
pub fn hasDenoJsonInDir(dir: []const u8) bool {
    const io = libs_process.getProcessIo() orelse return false;
    var dir_handle = if (libs_io.pathIsAbsolute(dir))
        libs_io.openDirAbsolute(dir, .{}) catch return false
    else
        libs_io.openDirCwd(dir, .{}) catch return false;
    defer dir_handle.close(io);
    for ([_][]const u8{ "deno.jsonc", "deno.json" }) |name| {
        const f = dir_handle.openFile(io, name, .{}) catch continue;
        f.close(io);
        return true;
    }
    return false;
}

/// 在 dir 下向 deno.json 或 deno.jsonc 的 imports 添加/覆盖 specifier -> value；无文件则创建 deno.json。
pub fn addDenoImport(allocator: std.mem.Allocator, dir: []const u8, specifier: []const u8, value: []const u8) !void {
    const io = libs_process.getProcessIo() orelse return error.ProcessIoNotSet;
    var dir_handle = if (libs_io.pathIsAbsolute(dir))
        try libs_io.openDirAbsolute(dir, .{})
    else
        try libs_io.openDirCwd(dir, .{});
    defer dir_handle.close(io);
    const deno_paths = [_][]const u8{ "deno.jsonc", "deno.json" };
    for (deno_paths) |name_path| {
        const content = dir_handle.readFileAlloc(io, name_path, allocator, .unlimited) catch continue;
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
        var out_file = try dir_handle.createFile(io, name_path, .{});
        defer out_file.close(io);
        try out_file.writeStreamingAll(io, out);
        return;
    }
    var new_root = std.json.ObjectMap.init(allocator);
    var new_imports = std.json.ObjectMap.init(allocator);
    try new_imports.put(try allocator.dupe(u8, specifier), .{ .string = try allocator.dupe(u8, value) });
    try new_root.put(try allocator.dupe(u8, "imports"), .{ .object = new_imports });
    const out = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = new_root }, .{ .whitespace = .indent_2 });
    defer allocator.free(out);
    var out_file = try dir_handle.createFile(io, "deno.json", .{});
    defer out_file.close(io);
    try out_file.writeStreamingAll(io, out);
}
