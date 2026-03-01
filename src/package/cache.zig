// 依赖缓存：npm/JSR 等 tarball 按 (registry, name, version) 存本地；HTTPS URL 单文件按 URL 哈希缓存
// 参考：docs/PACKAGE_DESIGN.md §7
// 约定：调用方负责 free 返回的路径字符串（getCacheRoot、getCachedTarball、getCachedUrlPath、urlCachePath 的返回值）
// TODO: migrate to io_core (rule §3.0); current file I/O via std.fs (openFileAbsolute, makePath, copyFileAbsolute, etc.)

const std = @import("std");

/// 默认缓存子目录名（位于 getCacheRoot() 下）
const CONTENT_DIR = "content";
/// HTTPS URL 缓存子目录名（位于 getCacheRoot() 下），仅支持 https://，不支持 http://
const URL_CACHE_DIR = "url";

/// 返回依赖缓存根目录；优先读环境变量 SHU_CACHE 或 SHU_CACHE_DIR，否则用默认 ~/.shu/cache（Windows：%LOCALAPPDATA%\\shu\\cache）。调用方负责 free。
pub fn getCacheRoot(allocator: std.mem.Allocator) ![]const u8 {
    if (std.posix.getenv("SHU_CACHE")) |v| return allocator.dupe(u8, v);
    if (std.posix.getenv("SHU_CACHE_DIR")) |v| return allocator.dupe(u8, v);
    const home = std.posix.getenv("HOME") orelse std.posix.getenv("USERPROFILE") orelse return error.NoHomeDir;
    return std.fmt.allocPrint(allocator, "{s}/.shu/cache", .{home});
}

/// 将包名中的 / 和 @ 等替换为安全文件名字符，用于缓存路径
fn sanitizeName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var list = std.ArrayList(u8).initCapacity(allocator, name.len + 4) catch return allocator.dupe(u8, name);
    for (name) |c| {
        switch (c) {
            '/', '\\' => list.appendSlice(allocator, "__") catch {},
            '@' => list.appendSlice(allocator, "_at_") catch {},
            else => list.append(allocator, c) catch {},
        }
    }
    return list.toOwnedSlice(allocator);
}

/// 生成缓存键：registry_host 与 name、version 组成唯一键；name 会做安全化。调用方负责 free。
pub fn cacheKey(allocator: std.mem.Allocator, registry_host: []const u8, name: []const u8, version: []const u8) ![]const u8 {
    const safe_name = try sanitizeName(allocator, name);
    defer allocator.free(safe_name);
    return std.fmt.allocPrint(allocator, "npm/{s}/{s}/{s}", .{ registry_host, safe_name, version });
}

/// 若缓存中已有该 key 的 tarball，返回其绝对路径；否则返回 null。返回的路径由调用方 free。
pub fn getCachedTarball(allocator: std.mem.Allocator, cache_root: []const u8, key: []const u8) ?[]const u8 {
    const filename = std.mem.concat(allocator, u8, &.{ key, ".tgz" }) catch return null;
    defer allocator.free(filename);
    const full = std.fs.path.join(allocator, &.{ cache_root, CONTENT_DIR, filename }) catch return null;
    var f = std.fs.openFileAbsolute(full, .{}) catch {
        allocator.free(full);
        return null;
    };
    f.close();
    return full;
}

/// 将 tarball_path 指向的文件复制到缓存目录下 key.tgz；必要时递归创建父目录。key 中可含子路径（如 npm/registry.npmjs.org/pkg/1.0.0），会创建对应子目录。
pub fn putCachedTarball(allocator: std.mem.Allocator, cache_root: []const u8, key: []const u8, tarball_path: []const u8) !void {
    var cache_dir = std.fs.openDirAbsolute(cache_root, .{}) catch blk: {
        try std.fs.cwd().makePath(cache_root);
        break :blk try std.fs.openDirAbsolute(cache_root, .{});
    };
    defer cache_dir.close();
    if (std.fs.path.dirname(key)) |dir| {
        const content_and_dir = try std.fs.path.join(allocator, &.{ CONTENT_DIR, dir });
        defer allocator.free(content_and_dir);
        cache_dir.makePath(content_and_dir) catch {}; // 已存在则忽略
    } else {
        cache_dir.makePath(CONTENT_DIR) catch {};
    }
    const filename = try std.mem.concat(allocator, u8, &.{ key, ".tgz" });
    defer allocator.free(filename);
    const content_filename = try std.fs.path.join(allocator, &.{ CONTENT_DIR, filename });
    defer allocator.free(content_filename);
    const dest_abs = try std.fs.path.join(allocator, &.{ cache_root, content_filename });
    defer allocator.free(dest_abs);
    try std.fs.copyFileAbsolute(tarball_path, dest_abs, .{});
}

/// 从 URL 中截取路径部分（首个 / 至 ? 或 # 或结尾），再取扩展名（如 .ts、.js）
fn urlPathExtension(url: []const u8) []const u8 {
    const proto_end = std.mem.indexOf(u8, url, "://") orelse return "";
    var i = proto_end + 3;
    while (i < url.len and url[i] != '/' and url[i] != '?' and url[i] != '#') i += 1;
    if (i >= url.len or url[i] != '/') return "";
    const path_start = i;
    while (i < url.len and url[i] != '?' and url[i] != '#') i += 1;
    const path = url[path_start..i];
    if (path.len == 0) return "";
    if (std.mem.lastIndexOfScalar(u8, path, '.')) |dot| {
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
            if (dot > slash) return path[dot..];
        } else return path[dot..];
    }
    return "";
}

/// 计算 URL 的缓存文件名：SHA256(url) 十六进制 + 路径扩展名；仅用于 https:// URL。
fn urlCacheFilename(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(url, &hash, .{});
    const hex = std.fmt.bytesToHex(&hash, .lower);
    const ext = urlPathExtension(url);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ &hex, ext });
}

/// 返回 URL 在缓存中的绝对路径（用于写入或读取）；仅接受 https://，http:// 返回 error.HttpNotSupported。调用方 free。
pub fn urlCachePath(allocator: std.mem.Allocator, cache_root: []const u8, url: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, url, "http://")) return error.HttpNotSupported;
    if (!std.mem.startsWith(u8, url, "https://")) return error.InvalidUrl;
    const name = try urlCacheFilename(allocator, url);
    defer allocator.free(name);
    return std.fs.path.join(allocator, &.{ cache_root, URL_CACHE_DIR, name });
}

/// 若该 https:// URL 已缓存则返回其绝对路径，否则返回 null；http:// 返回 null。调用方 free 返回的路径。
pub fn getCachedUrlPath(allocator: std.mem.Allocator, cache_root: []const u8, url: []const u8) ?[]const u8 {
    const path = urlCachePath(allocator, cache_root, url) catch return null;
    var f = std.fs.openFileAbsolute(path, .{}) catch {
        allocator.free(path);
        return null;
    };
    f.close();
    return path;
}
