// npm/JSR registry：解析版本、获取 tarball URL、下载 tarball 到缓存
// 参考：docs/PACKAGE_DESIGN.md §7；与 cache.zig、install.zig 配合
// TODO: migrate to io_core (rule §3.0); current network I/O via std.http.Client, file I/O via std.fs

const std = @import("std");

/// 默认 npm registry 根 URL（无末尾斜杠）
pub const DEFAULT_REGISTRY = "https://registry.npmjs.org";
/// JSR npm 兼容层 registry
pub const JSR_REGISTRY = "https://registry.npmjs.org";

/// 从 registry 获取包元数据（GET /<name>），解析出 dist-tags.latest 与 versions[].dist.tarball。
/// 返回的 version 与 tarball_url 由调用方 free；若 version_spec 为精确版本则校验存在并返回该 version 及对应 tarball。
pub fn resolveVersionAndTarball(
    allocator: std.mem.Allocator,
    registry_base: []const u8,
    name: []const u8,
    version_spec: []const u8,
) !struct { version: []const u8, tarball_url: []const u8 } {
    const url = try buildRegistryUrl(allocator, registry_base, name);
    defer allocator.free(url);
    const body = try httpGet(allocator, url, 5 * 1024 * 1024);
    defer allocator.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidRegistryResponse;
    const obj = root.object;

    const version = blk: {
        const exact = isExactVersion(version_spec);
        if (exact) {
            if (obj.get("versions")) |v| {
                if (v == .object) {
                    if (v.object.get(version_spec)) |ver_entry| {
                        if (ver_entry == .object) {
                            if (ver_entry.object.get("dist")) |dist| {
                                if (dist == .object) {
                                    if (dist.object.get("tarball")) |tb| {
                                        if (tb == .string) {
                                            break :blk try allocator.dupe(u8, version_spec);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            return error.VersionNotFound;
        }
        if (obj.get("dist-tags")) |dt| {
            if (dt == .object) {
                if (dt.object.get("latest")) |lat| {
                    if (lat == .string) break :blk try allocator.dupe(u8, lat.string);
                }
            }
        }
        return error.NoLatestVersion;
    };
    errdefer allocator.free(version);

    const tarball_url = blk: {
        if (obj.get("versions")) |v| {
            if (v == .object) {
                if (v.object.get(version)) |ver_entry| {
                    if (ver_entry == .object) {
                        if (ver_entry.object.get("dist")) |dist| {
                            if (dist == .object) {
                                if (dist.object.get("tarball")) |tb| {
                                    if (tb == .string) break :blk try allocator.dupe(u8, tb.string);
                                }
                            }
                        }
                    }
                }
            }
        }
        allocator.free(version);
        return error.NoTarballUrl;
    };
    return .{ .version = version, .tarball_url = tarball_url };
}

/// 判断 version_spec 是否为精确版本（无 ^、~、* 等范围符）
fn isExactVersion(spec: []const u8) bool {
    if (spec.len == 0) return false;
    for (spec) |c| {
        switch (c) {
            '^', '~', '*', 'x', 'X', ' ', '|', '<', '>', '=' => return false,
            else => {},
        }
    }
    return true;
}

/// 构建 GET 包元数据的 URL：registry_base 无末尾斜杠，name 可为 @scope/pkg
fn buildRegistryUrl(allocator: std.mem.Allocator, registry_base: []const u8, name: []const u8) ![]const u8 {
    var list = std.ArrayList(u8).initCapacity(allocator, registry_base.len + 1 + name.len + 1) catch return error.OutOfMemory;
    defer list.deinit(allocator);
    try list.appendSlice(allocator, registry_base);
    if (registry_base.len > 0 and registry_base[registry_base.len - 1] == '/') {}
    else try list.append(allocator, '/');
    try list.appendSlice(allocator, name);
    return list.toOwnedSlice(allocator);
}

/// 同步 GET url，将响应体读入内存（最多 max_bytes）；调用方 free 返回的切片。
fn httpGet(allocator: std.mem.Allocator, url: []const u8, max_bytes: usize) ![]const u8 {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    var req = client.request(.GET, uri, .{}) catch return error.NetworkError;
    defer req.deinit();
    req.sendBodiless() catch return error.NetworkError;
    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return error.NetworkError;
    const status = @intFromEnum(response.head.status);
    if (status < 200 or status >= 300) return error.BadStatus;
    var transfer_buf: [64]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    const body = reader.allocRemaining(allocator, std.io.Limit.limited(max_bytes)) catch return error.ResponseTooLarge;
    return body;
}

/// 将 https:// URL 指向的资源下载到 dest_path（覆盖已有文件）；仅支持 https://，http:// 返回 error.HttpNotSupported。响应体最多 50MB。
pub fn downloadUrlToPath(allocator: std.mem.Allocator, url: []const u8, dest_path: []const u8) !void {
    if (std.mem.startsWith(u8, url, "http://")) return error.HttpNotSupported;
    if (!std.mem.startsWith(u8, url, "https://")) return error.InvalidUrl;
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    var req = client.request(.GET, uri, .{}) catch return error.NetworkError;
    defer req.deinit();
    req.sendBodiless() catch return error.NetworkError;
    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return error.NetworkError;
    const status = @intFromEnum(response.head.status);
    if (status < 200 or status >= 300) return error.BadStatus;
    var transfer_buf: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    const body = reader.allocRemaining(allocator, std.io.Limit.limited(50 * 1024 * 1024)) catch return error.ResponseTooLarge;
    defer allocator.free(body);
    var file = try std.fs.createFileAbsolute(dest_path, .{});
    defer file.close();
    try file.writeAll(body);
}

/// 将 url 指向的 tarball 下载到 dest_path（覆盖已有文件）；用于先写临时文件再 putCachedTarball。响应体最多 50MB。
pub fn downloadToPath(allocator: std.mem.Allocator, url: []const u8, dest_path: []const u8) !void {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    var req = client.request(.GET, uri, .{}) catch return error.NetworkError;
    defer req.deinit();
    req.sendBodiless() catch return error.NetworkError;
    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return error.NetworkError;
    const status = @intFromEnum(response.head.status);
    if (status < 200 or status >= 300) return error.BadStatus;
    var transfer_buf: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    const body = reader.allocRemaining(allocator, std.io.Limit.limited(50 * 1024 * 1024)) catch return error.ResponseTooLarge;
    defer allocator.free(body);
    var file = try std.fs.createFileAbsolute(dest_path, .{});
    defer file.close();
    try file.writeAll(body);
}
