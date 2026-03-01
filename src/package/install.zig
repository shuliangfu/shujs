// 安装与缓存：根据 manifest 与 lockfile 将依赖从缓存解压到 node_modules；未命中则从 registry 下载后写入缓存并解压；安装完成后写回 shu.lock
// 参考：docs/PACKAGE_DESIGN.md §4、§7
// 文件/目录与路径经 io_core（§3.0）；解压 tgz 用 io_core.mapFileReadOnly

const std = @import("std");
const io_core = @import("io_core");
const manifest = @import("manifest.zig");
const lockfile = @import("lockfile.zig");
const cache = @import("cache.zig");
const registry = @import("registry.zig");
const npmrc = @import("npmrc.zig");

/// 无 .npmrc 时使用的默认 registry host 与 URL（与 npmrc.DEFAULT_REGISTRY_URL 一致）
const DEFAULT_REGISTRY_HOST = "registry.npmjs.org";
const REGISTRY_BASE_URL = npmrc.DEFAULT_REGISTRY_URL;

/// 安装进度回调：onResolving 本次要解析的数量；onStart(new_count) 本次新安装数量，进度条用；onPackage(..., newly_installed)；onDone(total_count, new_count)。
/// onPackageAdded(name, version)：add 流程下 install 结束后对 added_names 中在 resolved 的包各调用一次，用于打印「+ name@version」。
pub const InstallReporter = struct {
    ctx: ?*anyopaque = null,
    onResolving: ?*const fn (?*anyopaque, []const u8, usize, usize) void = null,
    onStart: ?*const fn (?*anyopaque, usize) void = null,
    onPackage: ?*const fn (?*anyopaque, usize, usize, []const u8, []const u8, bool) void = null,
    onDone: ?*const fn (?*anyopaque, usize, usize) void = null,
    onPackageAdded: ?*const fn (?*anyopaque, []const u8, []const u8) void = null,
};

/// 根据 manifest 与 lockfile 安装依赖到 cwd/node_modules。若 added_names 非 null（add 流程），install 结束后对其中在 resolved 的包调用 reporter.onPackageAdded。
/// §1.2：整次 install 用 Arena 分配临时路径与 key，仅 resolved map 的 key/value 用主 allocator（供 save 后释放），减少 alloc/free 与碎片。
pub fn install(allocator: std.mem.Allocator, cwd: []const u8, reporter: ?*const InstallReporter, added_names: ?[]const []const u8) !void {
    var loaded = manifest.Manifest.load(allocator, cwd) catch |e| {
        if (e == error.ManifestNotFound) return error.NoManifest;
        return e;
    };
    defer loaded.arena.deinit();
    const m = &loaded.manifest;

    var task_arena = std.heap.ArenaAllocator.init(allocator);
    defer task_arena.deinit();
    const a = task_arena.allocator();

    const lock_path = try io_core.pathJoin(a, &.{ cwd, lockfile.lock_file_name });
    var locked_result = lockfile.loadWithDeps(allocator, lock_path) catch return error.OutOfMemory;
    defer {
        var it = locked_result.resolved.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        locked_result.resolved.deinit();
        var dit = locked_result.deps_of.iterator();
        while (dit.next()) |e| {
            allocator.free(e.key_ptr.*);
            for (e.value_ptr.*.items) |p| allocator.free(p);
            e.value_ptr.*.deinit(allocator);
        }
        locked_result.deps_of.deinit();
    }

    const cache_root = try cache.getCacheRoot(a);
    // 安装前确保缓存根与 content 目录存在，避免 putCachedTarball/getCachedTarball 时 FileNotFound
    try io_core.makePathAbsolute(cache_root);
    const cache_content_dir = try io_core.pathJoin(a, &.{ cache_root, "content" });
    try io_core.makePathAbsolute(cache_content_dir);
    const nm_dir = try io_core.pathJoin(a, &.{ cwd, "node_modules" });
    io_core.makePathAbsolute(nm_dir) catch {};

    var resolved = std.StringArrayHashMap([]const u8).init(allocator);
    defer {
        var free_it = resolved.iterator();
        while (free_it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        resolved.deinit();
    }
    // 每个包名 -> 其 dependencies 的包名列表（用于 store 布局下在包内建 node_modules 符号链接）
    var deps_of = std.StringArrayHashMap(std.ArrayList([]const u8)).init(allocator);
    defer {
        var it = deps_of.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            for (e.value_ptr.*.items) |p| allocator.free(p);
            e.value_ptr.*.deinit(allocator);
        }
        deps_of.deinit();
    }
    // 从 lockfile 预填 resolved 与 deps_of，实现增量解析：仅解析新包或旧格式缺 deps 的包
    var lock_res = locked_result.resolved.iterator();
    while (lock_res.next()) |e| {
        try resolved.put(try allocator.dupe(u8, e.key_ptr.*), try allocator.dupe(u8, e.value_ptr.*));
    }
    var lock_deps = locked_result.deps_of.iterator();
    while (lock_deps.next()) |e| {
        var list = std.ArrayList([]const u8).initCapacity(allocator, e.value_ptr.*.items.len) catch return error.OutOfMemory;
        for (e.value_ptr.*.items) |dep| try list.append(allocator, try allocator.dupe(u8, dep));
        try deps_of.put(try allocator.dupe(u8, e.key_ptr.*), list);
    }

    const temp_tgz = try io_core.pathJoin(a, &.{ cache_root, ".tmp-download.tgz" });
    const store_dir = try io_core.pathJoin(a, &.{ nm_dir, ".shu", "store" });
    if (io_core.pathDirname(store_dir)) |shu_dir| io_core.makePathAbsolute(shu_dir) catch {};
    io_core.makePathAbsolute(store_dir) catch {};

    // 直接依赖名集合（用于安装顺序：先装传递依赖，再装直接依赖；以及最后只在顶层 node_modules 为直接依赖建链）
    var direct_set = std.StringArrayHashMap(void).init(a);
    defer direct_set.deinit();
    var dep_it = m.dependencies.iterator();
    while (dep_it.next()) |e| _ = direct_set.put(try a.dupe(u8, e.key_ptr.*), {}) catch {};
    var dev_it = m.dev_dependencies.iterator();
    while (dev_it.next()) |e| _ = direct_set.put(try a.dupe(u8, e.key_ptr.*), {}) catch {};

    // 待解析队列：仅加入「未在 resolved」或「在 resolved 但不在 deps_of（旧格式需补解析）」的包；新 lock 格式下只解析新包
    var to_process = std.ArrayList(struct { name: []const u8, spec: []const u8 }).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer {
        for (to_process.items) |item| {
            allocator.free(item.name);
            allocator.free(item.spec);
        }
        to_process.deinit(allocator);
    }
    var queue_it = m.dependencies.iterator();
    while (queue_it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (resolved.get(name) != null and deps_of.contains(name)) continue;
        const spec = resolved.get(name) orelse entry.value_ptr.*;
        try to_process.append(allocator, .{ .name = try allocator.dupe(u8, name), .spec = try allocator.dupe(u8, spec) });
    }
    var queue_dev = m.dev_dependencies.iterator();
    while (queue_dev.next()) |entry| {
        const name = entry.key_ptr.*;
        if (resolved.get(name) != null and deps_of.contains(name)) continue;
        const spec = resolved.get(name) orelse entry.value_ptr.*;
        try to_process.append(allocator, .{ .name = try allocator.dupe(u8, name), .spec = try allocator.dupe(u8, spec) });
    }

    const total_to_resolve = to_process.items.len;
    var first_error: ?anyerror = null;
    var idx: usize = 0;
    while (idx < to_process.items.len) : (idx += 1) {
        const item = to_process.items[idx];
        const already_has_deps = deps_of.contains(item.name);
        if (resolved.contains(item.name) and already_has_deps) continue;
        if (reporter) |r| {
            if (r.onResolving) |cb| cb(r.ctx, item.name, idx, total_to_resolve);
        }
        const registry_url = npmrc.getRegistryForPackage(a, cwd, item.name) catch try a.dupe(u8, REGISTRY_BASE_URL);
        var res = registry.resolveVersionTarballAndDeps(allocator, registry_url, item.name, item.spec) catch |e| {
            if (first_error == null) first_error = e;
            continue;
        };
        defer allocator.free(res.version);
        defer allocator.free(res.tarball_url);
        defer {
            var dit = res.dependencies.iterator();
            while (dit.next()) |e| {
                allocator.free(e.key_ptr.*);
                allocator.free(e.value_ptr.*);
            }
            res.dependencies.deinit();
        }
        if (resolved.getPtr(item.name)) |vptr| {
            allocator.free(vptr.*);
            vptr.* = try allocator.dupe(u8, res.version);
        } else {
            try resolved.put(try allocator.dupe(u8, item.name), try allocator.dupe(u8, res.version));
        }
        var dep_names = std.ArrayList([]const u8).initCapacity(allocator, res.dependencies.count()) catch {
            if (first_error == null) first_error = error.OutOfMemory;
            continue;
        };
        var dep_iter = res.dependencies.iterator();
        while (dep_iter.next()) |e| {
            const dname = e.key_ptr.*;
            const dspec = e.value_ptr.*;
            dep_names.append(allocator, try allocator.dupe(u8, dname)) catch {
                if (first_error == null) first_error = error.OutOfMemory;
                continue;
            };
            if (!resolved.contains(dname)) {
                to_process.append(allocator, .{ .name = try allocator.dupe(u8, dname), .spec = try allocator.dupe(u8, dspec) }) catch {
                    if (first_error == null) first_error = error.OutOfMemory;
                    continue;
                };
            }
        }
        if (deps_of.getPtr(item.name)) |ptr| {
            for (ptr.*.items) |p| allocator.free(p);
            ptr.*.deinit(allocator);
            ptr.* = dep_names;
        } else {
            deps_of.put(try allocator.dupe(u8, item.name), dep_names) catch {
                for (dep_names.items) |p| allocator.free(p);
                dep_names.deinit(allocator);
                if (first_error == null) first_error = error.OutOfMemory;
                continue;
            };
        }
    }
    if (first_error) |e| return e;

    // 安装顺序：先传递依赖（不在 direct_set），再直接依赖
    var install_order = std.ArrayList([]const u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer install_order.deinit(allocator);
    var res_it = resolved.iterator();
    while (res_it.next()) |e| {
        if (!direct_set.contains(e.key_ptr.*)) {
            install_order.append(allocator, e.key_ptr.*) catch return error.OutOfMemory;
        }
    }
    var add_dep = m.dependencies.iterator();
    while (add_dep.next()) |e| {
        const name = e.key_ptr.*;
        if (resolved.contains(name)) install_order.append(allocator, name) catch return error.OutOfMemory;
    }
    var add_dev = m.dev_dependencies.iterator();
    while (add_dev.next()) |e| {
        const name = e.key_ptr.*;
        if (resolved.contains(name)) install_order.append(allocator, name) catch return error.OutOfMemory;
    }

    const total_count = install_order.items.len;
    // 本次需要新安装的数量（store 中尚不存在的包），进度条与结束语只针对此数量
    var new_count: usize = 0;
    for (install_order.items) |name| {
        const version = resolved.get(name).?;
        const pkg_store = storePkgDir(a, store_dir, name, version) catch continue;
        var d = io_core.openDirAbsolute(pkg_store, .{}) catch {
            new_count += 1;
            continue;
        };
        d.close();
    }
    if (reporter) |r| {
        if (r.onStart) |cb| cb(r.ctx, new_count);
    }

    first_error = null;
    var new_index: usize = 0;
    for (install_order.items) |name| {
        const version = resolved.get(name).?;
        const pkg_store = storePkgDir(a, store_dir, name, version) catch |e| {
            if (first_error == null) first_error = e;
            continue;
        };
        if (io_core.pathDirname(pkg_store)) |parent| io_core.makePathAbsolute(parent) catch {};
        const already_in_store = blk: {
            var d = io_core.openDirAbsolute(pkg_store, .{}) catch break :blk false;
            d.close();
            break :blk true;
        };
        if (!already_in_store) {
            const registry_url = npmrc.getRegistryForPackage(a, cwd, name) catch try a.dupe(u8, REGISTRY_BASE_URL);
            const registry_host = npmrc.hostFromRegistryUrl(a, registry_url) catch try a.dupe(u8, DEFAULT_REGISTRY_HOST);
            var key = try cache.cacheKey(a, registry_host, name, version);
            var tgz_path = cache.getCachedTarball(a, cache_root, key);
            if (tgz_path == null) {
                const res = registry.resolveVersionAndTarball(allocator, registry_url, name, version) catch |e| {
                    if (first_error == null) first_error = e;
                    continue;
                };
                defer allocator.free(res.version);
                defer allocator.free(res.tarball_url);
                key = try cache.cacheKey(a, registry_host, name, res.version);
                registry.downloadToPath(allocator, res.tarball_url, temp_tgz) catch |e| {
                    if (first_error == null) first_error = e;
                    continue;
                };
                cache.putCachedTarball(a, cache_root, key, temp_tgz) catch {};
                io_core.deleteFileAbsolute(temp_tgz) catch {};
                tgz_path = cache.getCachedTarball(a, cache_root, key);
            }
            if (tgz_path) |p| {
                extractTarballToDir(a, p, pkg_store) catch |e| {
                    if (first_error == null) first_error = e;
                    continue;
                };
            }
        }
        if (!already_in_store) {
            if (reporter) |r| {
                if (r.onPackage) |cb| cb(r.ctx, new_index, new_count, name, version, true);
            }
            new_index += 1;
        }
    }

    if (first_error) |e| return e;

    // 顶层 node_modules 只放直接依赖：在目录内用 Dir.symLink 创建相对目标，避免 symLinkAbsolute 要求绝对 target
    var direct_iter = direct_set.iterator();
    while (direct_iter.next()) |e| {
        const name = e.key_ptr.*;
        const version = resolved.get(name).?;
        const link_path = io_core.pathJoin(a, &.{ nm_dir, name }) catch continue;
        const parent = io_core.pathDirname(link_path) orelse continue;
        const link_name = io_core.pathBasename(link_path);
        const name_at_ver = std.fmt.allocPrint(a, "{s}@{s}", .{ name, version }) catch continue;
        const target_rel = if (std.mem.indexOf(u8, name, "/")) |_|
            std.fmt.allocPrint(a, "../.shu/store/{s}", .{name_at_ver}) catch continue
        else
            io_core.pathJoin(a, &.{ ".shu", "store", name_at_ver }) catch continue;
        io_core.makePathAbsolute(parent) catch {};
        io_core.deleteFileAbsolute(link_path) catch |err| if (err == error.IsDir) io_core.deleteTreeAbsolute(link_path) catch {};
        var dir = io_core.openDirAbsolute(parent, .{}) catch continue;
        defer dir.close();
        dir.symLink(target_rel, link_name, .{ .is_directory = true }) catch {};
    }

    // 每个包（含传递依赖）在 store 内建 node_modules/<dep> -> ../../<dep>@<version>，供 require 解析
    var deps_it = deps_of.iterator();
    while (deps_it.next()) |entry| {
        const pkg_name = entry.key_ptr.*;
        const deps_list = entry.value_ptr.*;
        const version = resolved.get(pkg_name).?;
        const pkg_store = storePkgDir(a, store_dir, pkg_name, version) catch continue;
        const nm_inside = io_core.pathJoin(a, &.{ pkg_store, "node_modules" }) catch continue;
        io_core.makePathAbsolute(nm_inside) catch {};
        for (deps_list.items) |dep_name| {
            const dep_ver = resolved.get(dep_name).?;
            const target_rel = std.fmt.allocPrint(a, "../../{s}@{s}", .{ dep_name, dep_ver }) catch continue;
            const dep_link_path = io_core.pathJoin(a, &.{ nm_inside, dep_name }) catch continue;
            io_core.deleteFileAbsolute(dep_link_path) catch |err| if (err == error.IsDir) io_core.deleteTreeAbsolute(dep_link_path) catch {};
            const parent = io_core.pathDirname(dep_link_path) orelse continue;
            const link_name = io_core.pathBasename(dep_link_path);
            io_core.makePathAbsolute(parent) catch {};
            var dep_dir = io_core.openDirAbsolute(parent, .{}) catch continue;
            dep_dir.symLink(target_rel, link_name, .{ .is_directory = true }) catch {};
            dep_dir.close();
        }
    }

    if (reporter) |r| {
        if (added_names) |names| {
            if (r.onPackageAdded) |cb| {
                for (names) |name| {
                    if (resolved.get(name)) |ver| cb(r.ctx, name, ver);
                }
            }
        }
        if (r.onDone) |cb| cb(r.ctx, total_count, new_index);
    }
    try lockfile.save(allocator, lock_path, resolved, &deps_of);
}

/// 从解压流 dec 中读取恰好 buf.len 字节写入 buf，用 work 作为读缓冲。用于 tar 头等定长块。
fn streamReadExactlyToBuffer(dec: anytype, buf: []u8, work: []u8) !void {
    var pos: usize = 0;
    while (pos < buf.len) {
        const to_read = @min(work.len, buf.len - pos);
        var w = std.io.Writer.fixed(work[0..to_read]);
        const n = dec.reader.stream(&w, .limited(to_read)) catch |e| {
            if (e == error.EndOfStream) return error.UnexpectedEof;
            return e;
        };
        if (n == 0) return error.UnexpectedEof;
        @memcpy(buf[pos..][0..n], work[0..n]);
        pos += n;
    }
}

/// 从解压流 dec 中读取恰好 need 字节并写入 file，用 chunk 作为读缓冲。用于 tar 文件条目内容。
fn streamReadExactlyToFile(dec: anytype, file: std.fs.File, need: usize, chunk: []u8) !void {
    var pos: usize = 0;
    while (pos < need) {
        const to_read = @min(chunk.len, need - pos);
        var w = std.io.Writer.fixed(chunk[0..to_read]);
        const n = dec.reader.stream(&w, .limited(to_read)) catch |e| {
            if (e == error.EndOfStream) return error.UnexpectedEof;
            return e;
        };
        if (n == 0) return error.UnexpectedEof;
        try file.writeAll(chunk[0..n]);
        pos += n;
    }
}

/// 从解压流 dec 中跳过恰好 need 字节（读入 chunk 后丢弃），用于跳过非 package/ 条目或 padding。
fn streamSkipExactly(dec: anytype, need: usize, chunk: []u8) !void {
    var pos: usize = 0;
    while (pos < need) {
        const to_read = @min(chunk.len, need - pos);
        var w = std.io.Writer.fixed(chunk[0..to_read]);
        const n = dec.reader.stream(&w, .limited(to_read)) catch |e| {
            if (e == error.EndOfStream) return error.UnexpectedEof;
            return e;
        };
        if (n == 0) return error.UnexpectedEof;
        pos += n;
    }
}

/// 返回 store 中某包的目录路径：store_dir/<name>@<version>（如 @scope/pkg 则 store_dir/@scope/pkg@1.0.0）。调用方 free。
fn storePkgDir(allocator: std.mem.Allocator, store_dir: []const u8, name: []const u8, version: []const u8) ![]const u8 {
    return io_core.pathJoin(allocator, &.{ store_dir, try std.fmt.allocPrint(allocator, "{s}@{s}", .{ name, version }) });
}

/// 将 .tgz 解压到指定目录 dest_dir（tgz 内 package/ 前缀下的内容写入 dest_dir）。用于 store 布局。使用 io_core.mapFileReadOnly 映射 tgz，gzip 解压后流式解析 tar。
fn extractTarballToDir(allocator: std.mem.Allocator, tgz_path: []const u8, dest_dir: []const u8) !void {
    var mapped = io_core.mapFileReadOnly(tgz_path) catch return error.InvalidGzip;
    defer mapped.deinit();
    const tgz_content = mapped.slice();
    if (tgz_content.len < 10) return error.InvalidGzip;

    var in_reader = std.io.Reader.fixed(tgz_content);
    var dec_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var dec = std.compress.flate.Decompress.init(&in_reader, .gzip, &dec_buf);

    const prefix = "package/";
    const prefix_len = prefix.len;
    try io_core.makePathAbsolute(dest_dir);

    var header_buf: [512]u8 = undefined;
    var chunk: [8192]u8 = undefined;

    while (true) {
        streamReadExactlyToBuffer(&dec, header_buf[0..512], &chunk) catch |e| {
            if (e == error.UnexpectedEof) break;
            return e;
        };
        const name_end = std.mem.indexOfScalar(u8, header_buf[0..100], 0) orelse 100;
        const name = header_buf[0..name_end];
        if (name.len == 0) break;

        var size: usize = 0;
        for (header_buf[124..136]) |c| {
            if (c >= '0' and c <= '7') size = size * 8 + (c - '0');
        }
        const typeflag = if (header_buf.len > 156) header_buf[156] else '0';

        const block_rounded = (size + 511) / 512 * 512;

        if (!std.mem.startsWith(u8, name, prefix)) {
            try streamSkipExactly(&dec, block_rounded, &chunk);
            continue;
        }
        const rel = name[prefix_len..];
        if (rel.len == 0) {
            try streamSkipExactly(&dec, block_rounded, &chunk);
            continue;
        }

        const dest_path = try io_core.pathJoin(allocator, &.{ dest_dir, rel });
        defer allocator.free(dest_path);

        if (typeflag == '5') {
            io_core.makePathAbsolute(dest_path) catch {};
            try streamSkipExactly(&dec, block_rounded, &chunk);
        } else {
            if (io_core.pathDirname(dest_path)) |d| io_core.makePathAbsolute(d) catch {};
            const out_file = io_core.createFileAbsolute(dest_path, .{}) catch {
                try streamSkipExactly(&dec, block_rounded, &chunk);
                continue;
            };
            defer out_file.close();
            if (size > 0) {
                streamReadExactlyToFile(&dec, out_file, size, &chunk) catch {
                    try streamSkipExactly(&dec, block_rounded - size, &chunk);
                    continue;
                };
            }
            const padding = block_rounded - size;
            if (padding > 0) try streamSkipExactly(&dec, padding, &chunk);
        }
    }
}
