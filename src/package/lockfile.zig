// 锁文件读写：记录已解析的依赖精确版本，供 install 与可选的 resolve 复现
// 参考：docs/PACKAGE_DESIGN.md §4
// 格式：简单 JSON { "packages": { "<name>": "<version>", ... } }，与 package.json dependencies 的 name 对应
// 锁文件名与 deno.lock、bun.lock 对齐，使用 shu.lock
// TODO: migrate to io_core (rule §3.0); current file I/O via std.fs (openFile, createFile, readToEndAlloc, writeAll)

const std = @import("std");

/// 锁文件名（项目根目录下），与 deno.lock、bun.lock 命名一致
pub const lock_file_name = "shu.lock";

/// 从 path 读取锁文件，解析出 name -> version 映射；若文件不存在或为空则返回空 map。调用方负责 deinit 返回的 map。
pub fn load(allocator: std.mem.Allocator, path: []const u8) !std.StringArrayHashMap([]const u8) {
    var map = std.StringArrayHashMap([]const u8).init(allocator);
    errdefer map.deinit();
    const file = std.fs.cwd().openFile(path, .{}) catch |e| {
        if (e == error.FileNotFound) return map;
        return e;
    };
    defer file.close();
    const content = file.readToEndAlloc(allocator, std.math.maxInt(usize)) catch return map;
    defer allocator.free(content);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{ .allocate = .alloc_always }) catch return map;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return map;
    if (root.object.get("packages")) |pkg_obj| {
        if (pkg_obj == .object) {
            var it = pkg_obj.object.iterator();
            while (it.next()) |entry| {
                const val = entry.value_ptr.*;
                const ver = if (val == .string) val.string else "";
                try map.put(entry.key_ptr.*, ver);
            }
        }
    }
    return map;
}

/// 将 name -> version 映射写入 path；若目录不存在则创建父目录。
pub fn save(allocator: std.mem.Allocator, path: []const u8, packages: std.StringArrayHashMap([]const u8)) !void {
    var list = std.ArrayList(u8).initCapacity(allocator, 4096) catch return error.OutOfMemory;
    defer list.deinit(allocator);
    try list.appendSlice(allocator, "{\n  \"packages\": {\n");
    var first = true;
    var it = packages.iterator();
    while (it.next()) |entry| {
        if (!first) try list.appendSlice(allocator, ",\n");
        first = false;
        try std.fmt.format(list.writer(allocator), "    \"{s}\": \"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
    try list.appendSlice(allocator, "\n  }\n}\n");
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch {};
    }
    const file = std.fs.cwd().createFile(path, .{}) catch return error.CannotCreateLockfile;
    defer file.close();
    try file.writeAll(list.items);
}
