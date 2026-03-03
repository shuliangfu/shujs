// 锁文件读写：记录已解析的依赖精确版本与每包依赖列表，供 install 增量解析与可选的 resolve 复现
// 参考：docs/PACKAGE_DESIGN.md §4
// 格式（支持同包多版本）：{ "packages": { "name@version": { "dependencies": ["depName@depVersion", ...] }, ... }, "rootDependencies": ["name@version", ...], "jsrPackages": ["name@version", ...] }
// 锁文件名与 deno.lock、bun.lock 对齐，使用 shu.lock
// 文件 I/O 经 io_core（§3.0）；path 由调用方传绝对路径（如 pathJoin(cwd, lock_file_name)）

const std = @import("std");
const errors = @import("errors");
const libs_io = @import("libs_io");
const libs_process = @import("libs_process");

/// 锁文件名（项目根目录下），与 deno.lock、bun.lock 命名一致
pub const lock_file_name = "shu.lock";

/// 锁文件读入字节上限，防止损坏或恶意大文件导致 OOM（§ 性能规则）
const load_max_bytes = 1024 * 1024;

/// 从 "name@version" 解析出 name（最后一个 @ 之前）与 version（之后）；scoped 包如 @dreamer/view@1.0 正确拆为 name=@dreamer/view, version=1.0。调用方 free 返回的 name、version。
pub fn parseNameAtVersion(allocator: std.mem.Allocator, name_at_version: []const u8) !struct { name: []const u8, version: []const u8 } {
    const last_at = std.mem.lastIndexOfScalar(u8, name_at_version, '@') orelse return error.InvalidNameAtVersion;
    if (last_at == 0) return error.InvalidNameAtVersion;
    return .{
        .name = try allocator.dupe(u8, name_at_version[0..last_at]),
        .version = try allocator.dupe(u8, name_at_version[last_at + 1 ..]),
    };
}

/// 带 name@version 图与根依赖的锁文件加载结果；支持同包多版本。调用方须 free packages 的 key/value 与各 list 的 item 并 deinit，再 free root_dependencies、jsr_packages 各 item 并 deinit。
pub const LoadWithDepsResult = struct {
    /// 包身份为 name@version；值为该包的依赖列表（每项为 depName@depVersion）
    packages: std.StringArrayHashMap(std.ArrayList([]const u8)),
    /// 项目直接依赖的 name@version 列表，用于安装顺序与 node_modules 顶层
    root_dependencies: std.ArrayList([]const u8),
    /// 来自 JSR 的 name@version 列表，安装时走 jsr_tasks
    jsr_packages: std.ArrayList([]const u8),
};

/// 从 path 读取锁文件。格式：packages 为 name@version -> { dependencies: [depName@depVersion] }，rootDependencies、jsrPackages 为 name@version 数组。文件不存在或非 object 则返回空结构。
pub fn loadWithDeps(allocator: std.mem.Allocator, path: []const u8) !LoadWithDepsResult {
    var packages = std.StringArrayHashMap(std.ArrayList([]const u8)).init(allocator);
    var root_dependencies = std.ArrayList([]const u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
    var jsr_packages = std.ArrayList([]const u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
    errdefer {
        var it = packages.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            for (e.value_ptr.*.items) |p| allocator.free(p);
            e.value_ptr.*.deinit(allocator);
        }
        packages.deinit();
        for (root_dependencies.items) |p| allocator.free(p);
        root_dependencies.deinit(allocator);
        for (jsr_packages.items) |p| allocator.free(p);
        jsr_packages.deinit(allocator);
    }
    const io = libs_process.getProcessIo() orelse return error.ProcessIoNotSet;
    const file = libs_io.openFileAbsolute(path, .{}) catch |e| {
        if (e == libs_io.FileOpenError.FileNotFound) return .{ .packages = packages, .root_dependencies = root_dependencies, .jsr_packages = jsr_packages };
        return e;
    };
    defer file.close(io);
    var file_reader = file.reader(io, &.{});
    const content = file_reader.interface.allocRemaining(allocator, std.Io.Limit.limited(load_max_bytes)) catch |e| switch (e) {
        error.ReadFailed => return file_reader.err orelse error.ReadFailed,
        error.OutOfMemory, error.StreamTooLong => return .{ .packages = packages, .root_dependencies = root_dependencies, .jsr_packages = jsr_packages },
    };
    defer allocator.free(content);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{ .allocate = .alloc_always }) catch return .{ .packages = packages, .root_dependencies = root_dependencies, .jsr_packages = jsr_packages };
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return .{ .packages = packages, .root_dependencies = root_dependencies, .jsr_packages = jsr_packages };
    if (root.object.get("packages")) |pkg_obj| {
        if (pkg_obj == .object) {
            var it = pkg_obj.object.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const val = entry.value_ptr.*;
                const key_dup = try allocator.dupe(u8, key);
                var deps_list = std.ArrayList([]const u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
                if (val == .object) {
                    if (val.object.get("dependencies")) |d| {
                        if (d == .array) {
                            for (d.array.items) |item| {
                                if (item == .string) deps_list.append(allocator, try allocator.dupe(u8, item.string)) catch return error.OutOfMemory;
                            }
                        }
                    }
                }
                try packages.put(key_dup, deps_list);
            }
        }
    }
    if (root.object.get("rootDependencies")) |arr| {
        if (arr == .array) {
            for (arr.array.items) |item| {
                if (item == .string) root_dependencies.append(allocator, try allocator.dupe(u8, item.string)) catch return error.OutOfMemory;
            }
        }
    }
    if (root.object.get("jsrPackages")) |arr| {
        if (arr == .array) {
            for (arr.array.items) |item| {
                if (item == .string) jsr_packages.append(allocator, try allocator.dupe(u8, item.string)) catch return error.OutOfMemory;
            }
        }
    }
    return .{ .packages = packages, .root_dependencies = root_dependencies, .jsr_packages = jsr_packages };
}

/// 从 path 读取锁文件，解析出 name -> version 映射（多版本时每 name 只保留一个 version，供 update 等使用）。调用方负责 free 返回的 map 的 key/value 并 deinit。
pub fn load(allocator: std.mem.Allocator, path: []const u8) !std.StringArrayHashMap([]const u8) {
    var result = try loadWithDeps(allocator, path);
    defer {
        var it = result.packages.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            for (e.value_ptr.*.items) |p| allocator.free(p);
            e.value_ptr.*.deinit(allocator);
        }
        result.packages.deinit();
        for (result.root_dependencies.items) |p| allocator.free(p);
        result.root_dependencies.deinit(allocator);
        for (result.jsr_packages.items) |p| allocator.free(p);
        result.jsr_packages.deinit(allocator);
    }
    var resolved = std.StringArrayHashMap([]const u8).init(allocator);
    var it = result.packages.iterator();
    while (it.next()) |e| {
        const parsed = parseNameAtVersion(allocator, e.key_ptr.*) catch continue;
        defer allocator.free(parsed.name);
        defer allocator.free(parsed.version);
        const name_dup = try allocator.dupe(u8, parsed.name);
        const ver_dup = try allocator.dupe(u8, parsed.version);
        const gop = try resolved.getOrPut(name_dup);
        if (gop.found_existing) {
            allocator.free(gop.value_ptr.*);
            allocator.free(name_dup);
        }
        gop.value_ptr.* = ver_dup;
    }
    return resolved;
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
                if (c < 0x20) {
                    var buf: [8]u8 = undefined;
                    const part = std.fmt.bufPrint(&buf, "\\u{d:0>4}", .{c}) catch return;
                    try list.appendSlice(allocator, part);
                } else try list.append(allocator, c);
            },
        }
    }
}

/// 将 name@version 图写入 path（新格式：packages、rootDependencies、jsrPackages）。若目录不存在则创建父目录。不拥有 packages/root_dependencies/jsr_packages 内存。
pub fn save(
    allocator: std.mem.Allocator,
    path: []const u8,
    packages: std.StringArrayHashMap(std.ArrayList([]const u8)),
    root_dependencies: std.ArrayList([]const u8),
    jsr_packages: ?std.ArrayList([]const u8),
) !void {
    var list = std.ArrayList(u8).initCapacity(allocator, 8192) catch return error.OutOfMemory;
    defer list.deinit(allocator);
    try list.appendSlice(allocator, "{\n  \"packages\": {\n");
    var first_pkg = true;
    var it = packages.iterator();
    while (it.next()) |entry| {
        if (!first_pkg) try list.appendSlice(allocator, ",\n");
        first_pkg = false;
        try list.appendSlice(allocator, "    \"");
        try appendJsonEscaped(allocator, &list, entry.key_ptr.*);
        try list.appendSlice(allocator, "\": {\n      \"dependencies\": [\n");
        const deps = entry.value_ptr.*.items;
        for (deps, 0..) |dep, i| {
            if (i > 0) try list.appendSlice(allocator, ",\n");
            try list.appendSlice(allocator, "        \"");
            try appendJsonEscaped(allocator, &list, dep);
            try list.append(allocator, '"');
        }
        try list.appendSlice(allocator, "\n      ]\n    }");
    }
    try list.appendSlice(allocator, "\n  }");
    if (root_dependencies.items.len > 0) {
        try list.appendSlice(allocator, ",\n  \"rootDependencies\": [\n");
        for (root_dependencies.items, 0..) |p, i| {
            if (i > 0) try list.appendSlice(allocator, ",\n");
            try list.appendSlice(allocator, "    \"");
            try appendJsonEscaped(allocator, &list, p);
            try list.append(allocator, '"');
        }
        try list.appendSlice(allocator, "\n  ]");
    }
    if (jsr_packages) |jsr| {
        if (jsr.items.len > 0) {
            try list.appendSlice(allocator, ",\n  \"jsrPackages\": [\n");
            for (jsr.items, 0..) |p, i| {
                if (i > 0) try list.appendSlice(allocator, ",\n");
                try list.appendSlice(allocator, "    \"");
                try appendJsonEscaped(allocator, &list, p);
                try list.append(allocator, '"');
            }
            try list.appendSlice(allocator, "\n  ]");
        }
    }
    try list.appendSlice(allocator, "\n}\n");
    if (libs_io.pathDirname(path)) |dir| {
        libs_io.makePathAbsolute(dir) catch {};
    }
    const io = libs_process.getProcessIo() orelse return error.CannotCreateLockfile;
    const file = libs_io.createFileAbsolute(path, .{}) catch return error.CannotCreateLockfile;
    defer file.close(io);
    try file.writeStreamingAll(io, list.items);
}

/// 从旧式 resolved(name->version) + 可选 deps_of(name->deps 名字) 与 jsr 包名集合，构建新格式并写入 path；供 update 等只持有 resolved 的调用方使用。调用方不释放传入的 map/list。
pub fn saveFromResolved(
    allocator: std.mem.Allocator,
    path: []const u8,
    resolved: std.StringArrayHashMap([]const u8),
    deps_of: ?*const std.StringArrayHashMap(std.ArrayList([]const u8)),
    jsr_packages: ?*const std.StringArrayHashMap(void),
) !void {
    var packages = std.StringArrayHashMap(std.ArrayList([]const u8)).init(allocator);
    defer {
        var it = packages.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            for (e.value_ptr.*.items) |p| allocator.free(p);
            e.value_ptr.*.deinit(allocator);
        }
        packages.deinit();
    }
    var root_deps = std.ArrayList([]const u8).initCapacity(allocator, resolved.count()) catch return error.OutOfMemory;
    defer {
        for (root_deps.items) |p| allocator.free(p);
        root_deps.deinit(allocator);
    }
    var jsr_list = std.ArrayList([]const u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer {
        for (jsr_list.items) |p| allocator.free(p);
        jsr_list.deinit(allocator);
    }
    var it = resolved.iterator();
    while (it.next()) |e| {
        const name_at_ver = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ e.key_ptr.*, e.value_ptr.* });
        var deps_list = std.ArrayList([]const u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
        if (deps_of) |d| {
            if (d.get(e.key_ptr.*)) |arr| {
                for (arr.items) |dep_name| {
                    const ver = resolved.get(dep_name) orelse "";
                    deps_list.append(allocator, try std.fmt.allocPrint(allocator, "{s}@{s}", .{ dep_name, ver })) catch return error.OutOfMemory;
                }
            }
        }
        try packages.put(name_at_ver, deps_list);
        root_deps.append(allocator, try allocator.dupe(u8, name_at_ver)) catch return error.OutOfMemory;
    }
    if (jsr_packages) |jsr| {
        var jit = jsr.iterator();
        while (jit.next()) |e| {
            const ver = resolved.get(e.key_ptr.*) orelse "";
            jsr_list.append(allocator, try std.fmt.allocPrint(allocator, "{s}@{s}", .{ e.key_ptr.*, ver })) catch return error.OutOfMemory;
        }
    }
    try save(allocator, path, packages, root_deps, jsr_list);
}
