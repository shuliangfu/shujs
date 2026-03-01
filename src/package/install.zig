// 安装与缓存：根据 manifest 与 lockfile 将依赖从缓存解压到 node_modules；未命中则从 registry 下载后写入缓存并解压；安装完成后写回 shu.lock
// 参考：docs/PACKAGE_DESIGN.md §4、§7
// TODO: migrate to io_core (rule §3.0); 解压 tgz 已用 io_core.mapFileReadOnly；其余 I/O 仍为 std.fs（makePath、createFile、writeAll 等），待 io_core 提供通用文件/目录 API 后迁移。

const std = @import("std");
const io_core = @import("io_core");
const manifest = @import("manifest.zig");
const lockfile = @import("lockfile.zig");
const cache = @import("cache.zig");
const registry = @import("registry.zig");

/// registry 主机名（用于 cache key），与 registry.zig 的默认 URL 对应
const DEFAULT_REGISTRY_HOST = "registry.npmjs.org";
const REGISTRY_BASE_URL = "https://registry.npmjs.org";

/// 根据 manifest 与 lockfile 安装依赖到 cwd/node_modules：对每个依赖先查缓存，未命中则从 registry 解析版本并下载，解压后写回 shu.lock。
/// 若 lockfile 存在则用其精确版本；否则用 manifest 中的版本字面量；需下载时会向 registry 解析为精确版本并写入 lock。
pub fn install(allocator: std.mem.Allocator, cwd: []const u8) !void {
    var loaded = manifest.Manifest.load(allocator, cwd) catch |e| {
        if (e == error.ManifestNotFound) return error.NoManifest;
        return e;
    };
    defer loaded.arena.deinit();
    const m = &loaded.manifest;

    const lock_path = try std.fs.path.join(allocator, &.{ cwd, lockfile.lock_file_name });
    defer allocator.free(lock_path);
    var locked = lockfile.load(allocator, lock_path) catch return error.OutOfMemory;
    defer locked.deinit();

    const cache_root = try cache.getCacheRoot(allocator);
    defer allocator.free(cache_root);

    const nm_dir = try std.fs.path.join(allocator, &.{ cwd, "node_modules" });
    defer allocator.free(nm_dir);
    std.fs.cwd().makePath(nm_dir) catch {};

    var resolved = std.StringArrayHashMap([]const u8).init(allocator);
    defer resolved.deinit();

    const temp_tgz = try std.fs.path.join(allocator, &.{ cache_root, ".tmp-download.tgz" });
    defer allocator.free(temp_tgz);

    var it = m.dependencies.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const version_spec = entry.value_ptr.*;
        var version = locked.get(name) orelse version_spec;
        var version_owned: ?[]const u8 = null;
        defer if (version_owned) |v| allocator.free(v);

        var key = try cache.cacheKey(allocator, DEFAULT_REGISTRY_HOST, name, version);
        defer allocator.free(key);
        var tgz_path = cache.getCachedTarball(allocator, cache_root, key);
        if (tgz_path == null) {
            const res = registry.resolveVersionAndTarball(allocator, REGISTRY_BASE_URL, name, version_spec) catch continue;
            defer allocator.free(res.version);
            defer allocator.free(res.tarball_url);
            version_owned = try allocator.dupe(u8, res.version);
            version = version_owned.?;
            allocator.free(key);
            key = try cache.cacheKey(allocator, DEFAULT_REGISTRY_HOST, name, version);
            defer allocator.free(key);
            registry.downloadToPath(allocator, res.tarball_url, temp_tgz) catch continue;
            cache.putCachedTarball(allocator, cache_root, key, temp_tgz) catch {};
            std.fs.deleteFileAbsolute(temp_tgz) catch {};
            tgz_path = cache.getCachedTarball(allocator, cache_root, key);
        }
        if (tgz_path) |p| {
            defer allocator.free(p);
            extractTarballToNodeModules(allocator, p, nm_dir, name) catch {};
        }
        try resolved.put(try allocator.dupe(u8, name), try allocator.dupe(u8, version));
    }

    try lockfile.save(allocator, lock_path, resolved);
    var free_it = resolved.iterator();
    while (free_it.next()) |e| {
        allocator.free(e.key_ptr.*);
        allocator.free(e.value_ptr.*);
    }
}

/// 将 .tgz 解压到 node_modules/<pkg_name>。使用 io_core.mapFileReadOnly 映射 tgz（零拷贝、按需换页 §1.7），再 std.compress.flate.Decompress + gzip 解压，解析 tar 并 strip package/ 前缀写入。
fn extractTarballToNodeModules(allocator: std.mem.Allocator, tgz_path: []const u8, node_modules_dir: []const u8, pkg_name: []const u8) !void {
    var mapped = io_core.mapFileReadOnly(tgz_path) catch return error.InvalidGzip;
    defer mapped.deinit();
    const tgz_content = mapped.slice();
    if (tgz_content.len < 10) return error.InvalidGzip;

    var in_reader = std.io.Reader.fixed(tgz_content);
    var dec_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var dec = std.compress.flate.Decompress.init(&in_reader, .gzip, &dec_buf);

    var tar_list = std.ArrayList(u8).initCapacity(allocator, 1024 * 1024) catch return error.OutOfMemory;
    defer tar_list.deinit(allocator);
    var chunk: [8192]u8 = undefined;
    var chunk_writer = std.io.Writer.fixed(&chunk);
    while (true) {
        const n = dec.reader.stream(&chunk_writer, .limited(chunk.len)) catch |e| {
            if (e == error.EndOfStream) break;
            return e;
        };
        if (n == 0) break;
        try tar_list.appendSlice(allocator, chunk[0..n]);
    }
    const tar = tar_list.items;
    var offset: usize = 0;
    const prefix = "package/";
    const prefix_len = prefix.len;
    const dest_base = try std.fs.path.join(allocator, &.{ node_modules_dir, pkg_name });
    defer allocator.free(dest_base);
    try std.fs.cwd().makePath(dest_base);
    while (offset + 512 <= tar.len) {
        const name_end = std.mem.indexOfScalar(u8, tar[offset..][0..100], 0) orelse 100;
        const name = tar[offset..][0..name_end];
        if (name.len == 0) break;
        var size: usize = 0;
        for (tar[offset + 124 ..][0..12]) |c| {
            if (c >= '0' and c <= '7') size = size * 8 + (c - '0');
        }
        const typeflag = if (offset + 156 < tar.len) tar[offset + 156] else '0';
        offset += 512;
        if (!std.mem.startsWith(u8, name, prefix)) {
            offset += (size + 511) / 512 * 512;
            continue;
        }
        const rel = name[prefix_len..];
        if (rel.len == 0) {
            offset += (size + 511) / 512 * 512;
            continue;
        }
        const dest_path = try std.fs.path.join(allocator, &.{ dest_base, rel });
        defer allocator.free(dest_path);
        if (typeflag == '5') {
            std.fs.cwd().makePath(dest_path) catch {};
        } else {
            if (std.fs.path.dirname(dest_path)) |d| std.fs.cwd().makePath(d) catch {};
            const out_file = std.fs.cwd().createFile(dest_path, .{}) catch {
                offset += (size + 511) / 512 * 512;
                continue;
            };
            defer out_file.close();
            if (size > 0 and offset + size <= tar.len) {
                try out_file.writeAll(tar[offset..][0..size]);
            }
        }
        offset += (size + 511) / 512 * 512;
    }
}
