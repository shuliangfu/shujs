// 锁文件读写：记录已解析的依赖精确版本与每包依赖列表，供 install 增量解析与可选的 resolve 复现
// 参考：docs/PACKAGE_DESIGN.md §4
// 格式（新）：{ "packages": { "<name>": { "version": "<version>", "deps": ["<dep>", ...] }, ... } }
// 兼容旧格式：{ "packages": { "<name>": "<version>", ... } } 读入时 deps 为空，install 会补解析一次
// 锁文件名与 deno.lock、bun.lock 对齐，使用 shu.lock
// 文件 I/O 经 io_core（§3.0）；path 由调用方传绝对路径（如 pathJoin(cwd, lock_file_name)）

const std = @import("std");
const io_core = @import("io_core");

/// 锁文件名（项目根目录下），与 deno.lock、bun.lock 命名一致
pub const lock_file_name = "shu.lock";

/// 锁文件读入字节上限，防止损坏或恶意大文件导致 OOM（§ 性能规则）
const load_max_bytes = 1024 * 1024;

/// 带依赖列表的锁文件加载结果；调用方须先 free resolved 的 key/value、deps_of 的 key 与各 list 的 item 并 deinit list，再 deinit 两个 map。
pub const LoadWithDepsResult = struct {
    resolved: std.StringArrayHashMap([]const u8),
    deps_of: std.StringArrayHashMap(std.ArrayList([]const u8)),
};

/// 从 path 读取锁文件，解析出 name->version 与 name->deps；若文件不存在或为空则返回空 map。新格式含 deps，旧格式仅 version 则 deps 为空数组。
pub fn loadWithDeps(allocator: std.mem.Allocator, path: []const u8) !LoadWithDepsResult {
    var resolved = std.StringArrayHashMap([]const u8).init(allocator);
    var deps_of = std.StringArrayHashMap(std.ArrayList([]const u8)).init(allocator);
    errdefer {
        var it = resolved.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        resolved.deinit();
        var dit = deps_of.iterator();
        while (dit.next()) |e| {
            allocator.free(e.key_ptr.*);
            for (e.value_ptr.*.items) |p| allocator.free(p);
            e.value_ptr.*.deinit(allocator);
        }
        deps_of.deinit();
    }
    const file = io_core.openFileAbsolute(path, .{}) catch |e| {
        if (e == io_core.FileOpenError.FileNotFound) return .{ .resolved = resolved, .deps_of = deps_of };
        return e;
    };
    defer file.close();
    const content = file.readToEndAlloc(allocator, load_max_bytes) catch return .{ .resolved = resolved, .deps_of = deps_of };
    defer allocator.free(content);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{ .allocate = .alloc_always }) catch return .{ .resolved = resolved, .deps_of = deps_of };
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return .{ .resolved = resolved, .deps_of = deps_of };
    if (root.object.get("packages")) |pkg_obj| {
        if (pkg_obj == .object) {
            var it = pkg_obj.object.iterator();
            while (it.next()) |entry| {
                const name = try allocator.dupe(u8, entry.key_ptr.*);
                const val = entry.value_ptr.*;
                var version: []const u8 = "";
                var deps_list = std.ArrayList([]const u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
                if (val == .string) {
                    version = try allocator.dupe(u8, val.string);
                    try resolved.put(name, version);
                    // 旧格式无 deps，不加入 deps_of，install 会将这些包加入 to_process 以补解析
                } else if (val == .object) {
                    if (val.object.get("version")) |v| {
                        if (v == .string) version = try allocator.dupe(u8, v.string);
                    }
                    if (val.object.get("deps")) |d| {
                        if (d == .array) {
                            for (d.array.items) |item| {
                                if (item == .string) deps_list.append(allocator, try allocator.dupe(u8, item.string)) catch return error.OutOfMemory;
                            }
                        }
                    }
                    try resolved.put(name, version);
                    try deps_of.put(try allocator.dupe(u8, entry.key_ptr.*), deps_list);
                }
            }
        }
    }
    return .{ .resolved = resolved, .deps_of = deps_of };
}

/// 从 path 读取锁文件，解析出 name -> version 映射（兼容旧调用方）；若文件不存在或为空则返回空 map。
pub fn load(allocator: std.mem.Allocator, path: []const u8) !std.StringArrayHashMap([]const u8) {
    var result = try loadWithDeps(allocator, path);
    defer {
        var it = result.deps_of.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            for (e.value_ptr.*.items) |p| allocator.free(p);
            e.value_ptr.*.deinit(allocator);
        }
        result.deps_of.deinit();
    }
    return result.resolved;
}

/// 将 JSON 字符串中的 " \ 及控制字符转义后追加到 list，避免 lock 文件非法 JSON；调用方保证 list 已 init。
fn appendJsonEscaped(allocator: std.mem.Allocator, list: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) try std.fmt.format(list.writer(allocator), "\\u{d:0>4}", .{c}) else try list.append(allocator, c);
            },
        }
    }
}

/// 将 name -> version 写入 path；若 deps_of 非 null 则写新格式（含 deps），否则写旧格式仅 version。若目录不存在则创建父目录。
pub fn save(
    allocator: std.mem.Allocator,
    path: []const u8,
    packages: std.StringArrayHashMap([]const u8),
    deps_of: ?*const std.StringArrayHashMap(std.ArrayList([]const u8)),
) !void {
    var list = std.ArrayList(u8).initCapacity(allocator, 4096) catch return error.OutOfMemory;
    defer list.deinit(allocator);
    try list.appendSlice(allocator, "{\n  \"packages\": {\n");
    var first = true;
    var it = packages.iterator();
    while (it.next()) |entry| {
        if (!first) try list.appendSlice(allocator, ",\n");
        first = false;
        try list.appendSlice(allocator, "    \"");
        try appendJsonEscaped(allocator, &list, entry.key_ptr.*);
        if (deps_of) |deps| {
            try list.appendSlice(allocator, "\": { \"version\": \"");
            try appendJsonEscaped(allocator, &list, entry.value_ptr.*);
            try list.appendSlice(allocator, "\", \"deps\": [");
            if (deps.get(entry.key_ptr.*)) |arr| {
                for (arr.items, 0..) |dep, i| {
                    if (i > 0) try list.appendSlice(allocator, ", ");
                    try list.append(allocator, '"');
                    try appendJsonEscaped(allocator, &list, dep);
                    try list.append(allocator, '"');
                }
            }
            try list.appendSlice(allocator, "] }");
        } else {
            try list.appendSlice(allocator, "\": \"");
            try appendJsonEscaped(allocator, &list, entry.value_ptr.*);
            try list.append(allocator, '"');
        }
    }
    try list.appendSlice(allocator, "\n  }\n}\n");
    if (io_core.pathDirname(path)) |dir| {
        io_core.makePathAbsolute(dir) catch {};
    }
    const file = io_core.createFileAbsolute(path, .{}) catch return error.CannotCreateLockfile;
    defer file.close();
    try file.writeAll(list.items);
}
