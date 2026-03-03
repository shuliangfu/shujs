// 依赖缓存：npm 包按 (registry, name, version) 存已解压目录（不压缩，与 Deno/Bun 一致）；HTTPS URL 单文件按 URL 哈希缓存
// 参考：docs/PACKAGE_DESIGN.md §7
// 约定：调用方负责 free 返回的路径字符串（getCacheRoot、getCachedPackageDirPath/getCachedPackageDir、getCachedUrlPath、urlCachePath 的返回值）
// 文件/目录与路径经 io_core（§3.0）

const std = @import("std");
const errors = @import("errors");
const libs_io = @import("libs_io");
const libs_process = @import("libs_process");

/// 默认缓存子目录名（位于 getCacheRoot() 下）
const CONTENT_DIR = "content";
/// HTTPS URL 缓存子目录名（位于 getCacheRoot() 下），仅支持 https://，不支持 http://
const URL_CACHE_DIR = "url";
/// Registry 元数据缓存子目录名（位于 getCacheRoot() 下），按 registry_host/包名.json 存 GET /<name> 的 JSON，避免重复请求
const METADATA_DIR = "metadata";

/// 返回 shu 配置/缓存根目录（~/.shu 或 %LOCALAPPDATA%\\shu）；用于存放 registry 等配置。优先 SHU_HOME，否则 HOME/USERPROFILE + /.shu。调用方 free。
pub fn getShuHome(allocator: std.mem.Allocator) ![]const u8 {
    if (std.c.getenv("SHU_HOME")) |v| return allocator.dupe(u8, std.mem.span(v));
    const home_z = std.c.getenv("HOME") orelse std.c.getenv("USERPROFILE") orelse return error.NoHomeDir;
    const home = std.mem.span(home_z);
    return std.fmt.allocPrint(allocator, "{s}/.shu", .{home});
}

/// 返回依赖缓存根目录；优先读环境变量 SHU_CACHE 或 SHU_CACHE_DIR，否则用 getShuHome()/cache。调用方负责 free。§7：用 writer 替代 allocPrint 减少热路径临时分配。
pub fn getCacheRoot(allocator: std.mem.Allocator) ![]const u8 {
    if (std.c.getenv("SHU_CACHE")) |v| return allocator.dupe(u8, std.mem.span(v));
    if (std.c.getenv("SHU_CACHE_DIR")) |v| return allocator.dupe(u8, std.mem.span(v));
    const shu_home = try getShuHome(allocator);
    defer allocator.free(shu_home);
    return libs_io.pathJoin(allocator, &.{ shu_home, "cache" });
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

/// 生成缓存键：registry_host 与 name、version 组成唯一键；name 会做安全化。调用方负责 free。§7：用 writer 替代 allocPrint 减少热路径临时分配。
pub fn cacheKey(allocator: std.mem.Allocator, registry_host: []const u8, name: []const u8, version: []const u8) ![]const u8 {
    const safe_name = try sanitizeName(allocator, name);
    defer allocator.free(safe_name);
    return std.fmt.allocPrint(allocator, "npm/{s}/{s}/{s}", .{ registry_host, safe_name, version });
}

/// 返回 registry 元数据缓存文件路径：cache_root/metadata/<registry_host>/<safe_name>.json。调用方 free。
fn metadataCachePath(allocator: std.mem.Allocator, cache_root: []const u8, registry_host: []const u8, name: []const u8) ![]const u8 {
    const safe_name = try sanitizeName(allocator, name);
    defer allocator.free(safe_name);
    const json_name = try std.mem.concat(allocator, u8, &.{ safe_name, ".json" });
    defer allocator.free(json_name);
    const dir = try libs_io.pathJoin(allocator, &.{ cache_root, METADATA_DIR, registry_host });
    defer allocator.free(dir);
    return libs_io.pathJoin(allocator, &.{ dir, json_name });
}

/// 若该包在元数据缓存中已有 GET /<name> 的 JSON，则读取并返回；否则返回 null。返回的切片由调用方 free。
pub fn getCachedMetadata(allocator: std.mem.Allocator, cache_root: []const u8, registry_host: []const u8, name: []const u8) ?[]const u8 {
    const path = metadataCachePath(allocator, cache_root, registry_host, name) catch return null;
    defer allocator.free(path);
    const io = libs_process.getProcessIo() orelse return null;
    var f = libs_io.openFileAbsolute(path, .{}) catch return null;
    defer f.close(io);
    var file_reader = f.reader(io, &.{});
    const content = file_reader.interface.allocRemaining(allocator, std.Io.Limit.limited(1024 * 1024)) catch return null;
    defer allocator.free(content);
    return allocator.dupe(u8, content) catch return null;
}

/// 将 GET /<name> 的 JSON 写入元数据缓存；会创建 registry_host 子目录。用于安装/解析后避免重复请求。
pub fn putCachedMetadata(allocator: std.mem.Allocator, cache_root: []const u8, registry_host: []const u8, name: []const u8, body: []const u8) !void {
    const safe_name = try sanitizeName(allocator, name);
    defer allocator.free(safe_name);
    const dir = try libs_io.pathJoin(allocator, &.{ cache_root, METADATA_DIR, registry_host });
    defer allocator.free(dir);
    const io = libs_process.getProcessIo() orelse return error.ProcessIoNotSet;
    libs_io.makePathAbsolute(cache_root) catch {};
    var cache_dir = try libs_io.openDirAbsolute(cache_root, .{});
    defer cache_dir.close(io);
    const meta_dir = try libs_io.pathJoin(allocator, &.{ METADATA_DIR, registry_host });
    defer allocator.free(meta_dir);
    const dir_abs = try libs_io.pathJoin(allocator, &.{ cache_root, meta_dir });
    defer allocator.free(dir_abs);
    libs_io.makePathAbsolute(dir_abs) catch {};
    const filename = try std.mem.concat(allocator, u8, &.{ safe_name, ".json" });
    defer allocator.free(filename);
    const file_abs = try libs_io.pathJoin(allocator, &.{ dir_abs, filename });
    defer allocator.free(file_abs);
    var f = try libs_io.createFileAbsolute(file_abs, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, body);
}

// -----------------------------------------------------------------------------
// npm 包缓存：与 Deno/Bun 一致，存已解压目录（不存 .tgz 压缩），路径为 content/<key>/（含 package.json 等）
// -----------------------------------------------------------------------------

/// 返回缓存包目录的绝对路径（用于解压或复制）；key 如 npm/registry.npmjs.org/name/version。调用方 free。
pub fn getCachedPackageDirPath(allocator: std.mem.Allocator, cache_root: []const u8, key: []const u8) ![]const u8 {
    return libs_io.pathJoin(allocator, &.{ cache_root, CONTENT_DIR, key });
}

/// 若缓存中已有该 key 的已解压包目录（且含 package.json），返回其绝对路径；否则返回 null。返回的路径由调用方 free。
pub fn getCachedPackageDir(allocator: std.mem.Allocator, cache_root: []const u8, key: []const u8) ?[]const u8 {
    const dir_path = libs_io.pathJoin(allocator, &.{ cache_root, CONTENT_DIR, key }) catch return null;
    defer allocator.free(dir_path);
    const io = libs_process.getProcessIo() orelse return null;
    var d = libs_io.openDirAbsolute(dir_path, .{}) catch return null;
    defer d.close(io);
    const pkg_json = libs_io.pathJoin(allocator, &.{ dir_path, "package.json" }) catch return null;
    defer allocator.free(pkg_json);
    var f = libs_io.openFileAbsolute(pkg_json, .{}) catch return null;
    f.close(io);
    return allocator.dupe(u8, dir_path) catch return null;
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
    return libs_io.pathJoin(allocator, &.{ cache_root, URL_CACHE_DIR, name });
}

/// 若该 https:// URL 已缓存则返回其绝对路径，否则返回 null；http:// 返回 null。调用方 free 返回的路径。
pub fn getCachedUrlPath(allocator: std.mem.Allocator, cache_root: []const u8, url: []const u8) ?[]const u8 {
    const io = libs_process.getProcessIo() orelse return null;
    const path = urlCachePath(allocator, cache_root, url) catch return null;
    var f = libs_io.openFileAbsolute(path, .{}) catch {
        allocator.free(path);
        return null;
    };
    defer f.close(io);
    return path;
}
