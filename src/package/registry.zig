// npm/JSR registry：解析版本、获取 tarball URL、下载 tarball 到缓存
// 参考：docs/PACKAGE_DESIGN.md §7；与 cache.zig、install.zig 配合
// 文件 I/O 经 io_core（§3.0）；网络优先 std.http.Client，DNS 失败时回退到系统 curl（与 Bun 同环境可用）

const std = @import("std");
const builtin = @import("builtin");
const io_core = @import("io_core");
const cache = @import("cache.zig");
const npmrc = @import("npmrc.zig");

/// 默认 npm registry 根 URL（无末尾斜杠），与 REGISTRY_LIST[0] 一致
pub const DEFAULT_REGISTRY = "https://registry.npmjs.org";

/// 判断是否为默认 registry（含 .npmrc 中带尾斜杠的写法），以便走多镜像探测与 curl 回退
fn isDefaultRegistry(registry_base: []const u8) bool {
    if (std.mem.eql(u8, registry_base, DEFAULT_REGISTRY)) return true;
    if (std.mem.eql(u8, registry_base, "https://registry.npmjs.org/")) return true;
    return false;
}
/// 当默认 registry 不可用时并发探测的列表（官方、常见镜像等）；第一个为默认。探测到响应最快的会写入 ~/.shu/registry 供后续直接使用。
pub const REGISTRY_LIST = [_][]const u8{
    "https://registry.npmjs.org",
    "https://registry.npmmirror.com",
    "https://registry.yarnpkg.com",
    "https://registry.pnpm.io",
};
/// 全量探测时每个镜像的最大等待时间（秒），避免不可达镜像一直卡住
const PROBE_TIMEOUT_SEC = 5;
/// JSR npm 兼容层 registry
pub const JSR_REGISTRY = "https://registry.npmjs.org";

/// 从 ~/.shu/registry 读取上次可用的 registry URL（一行，trim）；不存在或读失败返回 null。调用方 free 返回的切片。
fn getCachedRegistry(allocator: std.mem.Allocator) ?[]const u8 {
    const shu_home = cache.getShuHome(allocator) catch return null;
    defer allocator.free(shu_home);
    const registry_path = io_core.pathJoin(allocator, &.{ shu_home, "registry" }) catch return null;
    defer allocator.free(registry_path);
    var f = io_core.openFileAbsolute(registry_path, .{}) catch return null;
    defer f.close();
    var buf: [512]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = f.read(buf[total..]) catch return null;
        if (n == 0) break;
        total += n;
    }
    const line = std.mem.trim(u8, buf[0..total], " \t\r\n");
    if (line.len == 0) return null;
    return allocator.dupe(u8, line) catch null;
}

/// 将可用的 registry URL 写入 ~/.shu/registry（单行），供后续优先使用。会先创建 ~/.shu 目录。
fn setCachedRegistry(allocator: std.mem.Allocator, url: []const u8) void {
    const shu_home = cache.getShuHome(allocator) catch return;
    defer allocator.free(shu_home);
    io_core.makePathAbsolute(shu_home) catch return;
    const registry_path = io_core.pathJoin(allocator, &.{ shu_home, "registry" }) catch return;
    defer allocator.free(registry_path);
    var f = io_core.createFileAbsolute(registry_path, .{}) catch return;
    defer f.close();
    f.writeAll(url) catch {};
    f.writeAll("\n") catch {};
}

/// 单次探测结果：响应耗时（纳秒）与 body；主线程顺序探测时使用，避免多线程共享 allocator（GPA 非线程安全）导致全部失败。
const ProbeResult = struct {
    elapsed_ns: u64 = 0,
    body: ?[]const u8 = null,
};

/// 从 registry 获取包元数据（GET /<name>），解析出 dist-tags.latest 与 versions[].dist.tarball。
/// 当 registry_base 为 DEFAULT_REGISTRY 时：先读 ~/.shu/registry 用缓存的 URL；若缓存不存在或缓存的 URL 不可用（请求失败或返回空/非 JSON），则对 REGISTRY_LIST 顺序探测（逐个请求、记时），选响应最快且返回有效 JSON 的镜像写入缓存并返回。顺序探测避免多线程共享 allocator 导致请求全部失败。非默认 registry 时仅使用传入的 registry_base。返回的 version 与 tarball_url 由调用方 free。
pub fn resolveVersionAndTarball(
    allocator: std.mem.Allocator,
    registry_base: []const u8,
    name: []const u8,
    version_spec: []const u8,
) !struct { version: []const u8, tarball_url: []const u8 } {
    // 优先读元数据缓存，避免重复请求 registry
    const cache_root = cache.getCacheRoot(allocator) catch null;
    var registry_host: ?[]const u8 = null;
    if (cache_root != null) registry_host = npmrc.hostFromRegistryUrl(allocator, registry_base) catch null;
    defer if (cache_root) |c| allocator.free(c);
    defer if (registry_host) |h| allocator.free(h);
    if (cache_root != null and registry_host != null) {
        const cached_body = cache.getCachedMetadata(allocator, cache_root.?, registry_host.?, name);
        if (cached_body) |b| {
            defer allocator.free(b);
            const body_trimmed = std.mem.trim(u8, b, " \t\r\n");
            if (body_trimmed.len > 0 and body_trimmed[0] == '{') {
                const parsed = parseRegistryResponse(allocator, body_trimmed, version_spec) catch null;
                if (parsed) |p| return .{ .version = p.version, .tarball_url = p.tarball_url };
            }
        }
    }
    if (isDefaultRegistry(registry_base)) {
        // 默认：先尝试 ~/.shu/registry 缓存的 URL；若缓存不存在或缓存的 URL 访问失败/返回无效，则顺序探测所有镜像，选最快的写入缓存
        try_cached: {
            const cached = getCachedRegistry(allocator) orelse break :try_cached;
            defer allocator.free(cached);
            const url = buildRegistryUrl(allocator, cached, name) catch break :try_cached;
            defer allocator.free(url);
            const body = httpGet(allocator, url, 5 * 1024 * 1024) catch break :try_cached; // 访问不了则跳出，下面重新探测
            defer allocator.free(body);
            const body_trimmed = std.mem.trim(u8, body, " \t\r\n");
            if (body_trimmed.len == 0 or body_trimmed[0] != '{') break :try_cached;
            const parsed = parseRegistryResponse(allocator, body_trimmed, version_spec) catch break :try_cached;
            setCachedRegistry(allocator, cached);
            if (cache_root != null and registry_host != null) cache.putCachedMetadata(allocator, cache_root.?, registry_host.?, name, body) catch {};
            return .{ .version = parsed.version, .tarball_url = parsed.tarball_url };
        }
        // 无缓存或缓存的 URL 不可用：对 REGISTRY_LIST 全部发请求、记时，选响应时间最短的镜像写入缓存并返回；若 Zig httpGet 全部失败再回退到 curl 顺序试
        var results: [REGISTRY_LIST.len]ProbeResult = undefined;
        for (&results) |*r| r.* = .{ .elapsed_ns = 0, .body = null };
        defer for (&results) |*r| {
            if (r.body) |b| allocator.free(b);
        };
        var last_probe_err: anyerror = error.EmptyRegistryResponse;
        for (REGISTRY_LIST, &results) |base, *res| {
            const url = buildRegistryUrl(allocator, base, name) catch |e| {
                last_probe_err = e;
                continue;
            };
            defer allocator.free(url);
            const start = std.time.nanoTimestamp();
            const body = httpGetViaCurlWithTimeout(allocator, url, 5 * 1024 * 1024, PROBE_TIMEOUT_SEC) catch |e| {
                last_probe_err = e;
                continue;
            };
            const end = std.time.nanoTimestamp();
            res.elapsed_ns = if (end >= start) @intCast(end - start) else 0;
            res.body = body;
        }
        var best: ?usize = null;
        var best_ns: u64 = std.math.maxInt(u64);
        for (results, 0..) |r, i| {
            const body = r.body orelse continue;
            const trimmed = std.mem.trim(u8, body, " \t\r\n");
            if (trimmed.len == 0 or trimmed[0] != '{') continue;
            if (r.elapsed_ns < best_ns) {
                best_ns = r.elapsed_ns;
                best = i;
            }
        }
        const winner = best;
        if (winner == null) {
            for (REGISTRY_LIST) |base| {
                const url_curl = buildRegistryUrl(allocator, base, name) catch continue;
                defer allocator.free(url_curl);
                const body_curl = httpGetViaCurl(allocator, url_curl, 5 * 1024 * 1024) catch continue;
                defer allocator.free(body_curl);
                const trimmed = std.mem.trim(u8, body_curl, " \t\r\n");
                if (trimmed.len == 0 or trimmed[0] != '{') continue;
                const parsed = parseRegistryResponse(allocator, trimmed, version_spec) catch continue;
                setCachedRegistry(allocator, base);
                if (cache_root != null and registry_host != null) cache.putCachedMetadata(allocator, cache_root.?, registry_host.?, name, body_curl) catch {};
                return .{ .version = parsed.version, .tarball_url = parsed.tarball_url };
            }
            return last_probe_err;
        }
        setCachedRegistry(allocator, REGISTRY_LIST[winner.?]);
        const body_trimmed = std.mem.trim(u8, results[winner.?].body.?, " \t\r\n");
        const parsed = try parseRegistryResponse(allocator, body_trimmed, version_spec);
        if (cache_root != null and registry_host != null) cache.putCachedMetadata(allocator, cache_root.?, registry_host.?, name, results[winner.?].body.?) catch {};
        return .{ .version = parsed.version, .tarball_url = parsed.tarball_url };
    }
    const url = try buildRegistryUrl(allocator, registry_base, name);
    defer allocator.free(url);
    const body = httpGet(allocator, url, 5 * 1024 * 1024) catch blk: {
        break :blk httpGetViaCurl(allocator, url, 5 * 1024 * 1024) catch |e| return e;
    };
    defer allocator.free(body);
    const body_trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (body_trimmed.len == 0) return error.EmptyRegistryResponse;
    if (body_trimmed[0] != '{') return error.RegistryReturnedNonJson;
    const parsed = try parseRegistryResponse(allocator, body_trimmed, version_spec);
    if (cache_root != null and registry_host != null) cache.putCachedMetadata(allocator, cache_root.?, registry_host.?, name, body) catch {};
    return .{ .version = parsed.version, .tarball_url = parsed.tarball_url };
}

/// 与 resolveVersionAndTarball 相同，但额外返回该版本的 dependencies（用于传递依赖）。调用方须 free version、tarball_url，并 free dependencies 的 key/value 且 deinit(dependencies)。
pub fn resolveVersionTarballAndDeps(
    allocator: std.mem.Allocator,
    registry_base: []const u8,
    name: []const u8,
    version_spec: []const u8,
) !struct { version: []const u8, tarball_url: []const u8, dependencies: std.StringArrayHashMap([]const u8) } {
    // 优先读元数据缓存，避免重复请求 registry
    const cache_root = cache.getCacheRoot(allocator) catch null;
    var registry_host: ?[]const u8 = null;
    if (cache_root != null) registry_host = npmrc.hostFromRegistryUrl(allocator, registry_base) catch null;
    defer if (cache_root) |c| allocator.free(c);
    defer if (registry_host) |h| allocator.free(h);
    if (cache_root != null and registry_host != null) {
        const cached_body = cache.getCachedMetadata(allocator, cache_root.?, registry_host.?, name);
        if (cached_body) |b| {
            defer allocator.free(b);
            const body_trimmed = std.mem.trim(u8, b, " \t\r\n");
            if (body_trimmed.len > 0 and body_trimmed[0] == '{') {
                const parsed = parseRegistryResponseWithDeps(allocator, body_trimmed, version_spec) catch null;
                if (parsed) |p| return .{ .version = p.version, .tarball_url = p.tarball_url, .dependencies = p.dependencies };
            }
        }
    }
    if (isDefaultRegistry(registry_base)) {
        try_cached: {
            const cached = getCachedRegistry(allocator) orelse break :try_cached;
            defer allocator.free(cached);
            const url = buildRegistryUrl(allocator, cached, name) catch break :try_cached;
            defer allocator.free(url);
            const body = httpGet(allocator, url, 5 * 1024 * 1024) catch break :try_cached;
            defer allocator.free(body);
            const body_trimmed = std.mem.trim(u8, body, " \t\r\n");
            if (body_trimmed.len == 0 or body_trimmed[0] != '{') break :try_cached;
            const parsed = parseRegistryResponseWithDeps(allocator, body_trimmed, version_spec) catch break :try_cached;
            setCachedRegistry(allocator, cached);
            if (cache_root != null and registry_host != null) cache.putCachedMetadata(allocator, cache_root.?, registry_host.?, name, body) catch {};
            return .{ .version = parsed.version, .tarball_url = parsed.tarball_url, .dependencies = parsed.dependencies };
        }
        // 与 resolveVersionAndTarball 一致：对 REGISTRY_LIST 全部请求、记时，选响应最短的镜像
        var results: [REGISTRY_LIST.len]ProbeResult = undefined;
        for (&results) |*r| r.* = .{ .elapsed_ns = 0, .body = null };
        defer for (&results) |*r| {
            if (r.body) |b| allocator.free(b);
        };
        var last_probe_err: anyerror = error.EmptyRegistryResponse;
        for (REGISTRY_LIST, &results) |base, *res| {
            const url = buildRegistryUrl(allocator, base, name) catch |e| {
                last_probe_err = e;
                continue;
            };
            defer allocator.free(url);
            const start = std.time.nanoTimestamp();
            const body = httpGetViaCurlWithTimeout(allocator, url, 5 * 1024 * 1024, PROBE_TIMEOUT_SEC) catch |e| {
                last_probe_err = e;
                continue;
            };
            const end = std.time.nanoTimestamp();
            res.elapsed_ns = if (end >= start) @intCast(end - start) else 0;
            res.body = body;
        }
        var best: ?usize = null;
        var best_ns: u64 = std.math.maxInt(u64);
        for (results, 0..) |r, i| {
            const body = r.body orelse continue;
            const trimmed = std.mem.trim(u8, body, " \t\r\n");
            if (trimmed.len == 0 or trimmed[0] != '{') continue;
            if (r.elapsed_ns < best_ns) {
                best_ns = r.elapsed_ns;
                best = i;
            }
        }
        if (best) |winner_i| {
            setCachedRegistry(allocator, REGISTRY_LIST[winner_i]);
            const body_trimmed = std.mem.trim(u8, results[winner_i].body.?, " \t\r\n");
            const parsed = try parseRegistryResponseWithDeps(allocator, body_trimmed, version_spec);
            if (cache_root != null and registry_host != null) cache.putCachedMetadata(allocator, cache_root.?, registry_host.?, name, results[winner_i].body.?) catch {};
            return .{ .version = parsed.version, .tarball_url = parsed.tarball_url, .dependencies = parsed.dependencies };
        }
        for (REGISTRY_LIST) |base| {
            const url_curl = buildRegistryUrl(allocator, base, name) catch continue;
            defer allocator.free(url_curl);
            const body_curl = httpGetViaCurl(allocator, url_curl, 5 * 1024 * 1024) catch continue;
            defer allocator.free(body_curl);
            const trimmed = std.mem.trim(u8, body_curl, " \t\r\n");
            if (trimmed.len == 0 or trimmed[0] != '{') continue;
            const parsed = parseRegistryResponseWithDeps(allocator, trimmed, version_spec) catch continue;
            setCachedRegistry(allocator, base);
            if (cache_root != null and registry_host != null) cache.putCachedMetadata(allocator, cache_root.?, registry_host.?, name, body_curl) catch {};
            return .{ .version = parsed.version, .tarball_url = parsed.tarball_url, .dependencies = parsed.dependencies };
        }
        return error.AllRegistriesUnreachable;
    }
    const url = try buildRegistryUrl(allocator, registry_base, name);
    defer allocator.free(url);
    const body = httpGet(allocator, url, 5 * 1024 * 1024) catch blk: {
        break :blk httpGetViaCurl(allocator, url, 5 * 1024 * 1024) catch |e| return e;
    };
    defer allocator.free(body);
    const body_trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (body_trimmed.len == 0) return error.EmptyRegistryResponse;
    if (body_trimmed[0] != '{') return error.RegistryReturnedNonJson;
    const parsed = try parseRegistryResponseWithDeps(allocator, body_trimmed, version_spec);
    if (cache_root != null and registry_host != null) cache.putCachedMetadata(allocator, cache_root.?, registry_host.?, name, body) catch {};
    return .{ .version = parsed.version, .tarball_url = parsed.tarball_url, .dependencies = parsed.dependencies };
}

/// 从已获取的 registry JSON 切片解析 version 与 tarball_url；body_trimmed 为 trim 后的响应体。调用方 free 返回的 version、tarball_url。
fn parseRegistryResponse(
    allocator: std.mem.Allocator,
    body_trimmed: []const u8,
    version_spec: []const u8,
) !struct { version: []const u8, tarball_url: []const u8 } {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body_trimmed, .{ .allocate = .alloc_always }) catch return error.InvalidRegistryResponse;
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
        if (obj.get("versions")) |v| {
            if (v == .object) {
                // 仅选稳定版，避免解析到 canary/beta 等预发布
                if (maxSatisfyingVersion(allocator, v.object, version_spec, true)) |chosen| {
                    break :blk chosen;
                }
            }
        }
        if (obj.get("dist-tags")) |dt| {
            if (dt == .object) {
                if (dt.object.get("latest")) |lat| {
                    if (lat == .string and isStableVersion(lat.string)) {
                        break :blk try allocator.dupe(u8, lat.string);
                    }
                }
            }
        }
        // latest 非稳定版时，退化为在 versions 中取满足 ">=0.0.0" 的最大稳定版
        if (obj.get("versions")) |v| {
            if (v == .object) {
                if (maxSatisfyingVersion(allocator, v.object, ">=0.0.0", true)) |chosen| {
                    break :blk chosen;
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

/// 从已获取的 registry JSON 解析 version、tarball_url 及该版本的 dependencies（package 的 dependencies 字段）；用于传递依赖收集。调用方 free 返回的 version、tarball_url，以及 dependencies 的 key/value 并 deinit map。
fn parseRegistryResponseWithDeps(
    allocator: std.mem.Allocator,
    body_trimmed: []const u8,
    version_spec: []const u8,
) !struct { version: []const u8, tarball_url: []const u8, dependencies: std.StringArrayHashMap([]const u8) } {
    const parsed = try parseRegistryResponse(allocator, body_trimmed, version_spec);
    errdefer allocator.free(parsed.version);
    errdefer allocator.free(parsed.tarball_url);
    var deps = std.StringArrayHashMap([]const u8).init(allocator);
    errdefer {
        var it = deps.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        deps.deinit();
    }
    var p = std.json.parseFromSlice(std.json.Value, allocator, body_trimmed, .{ .allocate = .alloc_always }) catch return .{
        .version = parsed.version,
        .tarball_url = parsed.tarball_url,
        .dependencies = deps,
    };
    defer p.deinit();
    const root = p.value;
    if (root == .object) {
        if (root.object.get("versions")) |v| {
            if (v == .object) {
                if (v.object.get(parsed.version)) |ver_entry| {
                    if (ver_entry == .object) {
                        if (ver_entry.object.get("dependencies")) |deps_obj| {
                            if (deps_obj == .object) {
                                var it = deps_obj.object.iterator();
                                while (it.next()) |entry| {
                                    const k = entry.key_ptr.*;
                                    const val = if (entry.value_ptr.* == .string) entry.value_ptr.*.string else continue;
                                    try deps.put(try allocator.dupe(u8, k), try allocator.dupe(u8, val));
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    return .{ .version = parsed.version, .tarball_url = parsed.tarball_url, .dependencies = deps };
}

/// 判断版本是否为稳定版（无 semver 预发布后缀，即不含 "-"；如 10.28.4 为稳定版，19.3.0-canary-xxx 为预发布）。
fn isStableVersion(ver: []const u8) bool {
    return std.mem.indexOf(u8, ver, "-") == null;
}

/// 判断 version_spec 是否为精确版本（无 ^、~、* 等范围符）。"latest"、"next" 等为 dist-tag，不算精确版本。
fn isExactVersion(spec: []const u8) bool {
    if (spec.len == 0) return false;
    if (std.mem.eql(u8, spec, "latest") or std.mem.eql(u8, spec, "next") or std.mem.eql(u8, spec, "canary") or std.mem.eql(u8, spec, "beta") or std.mem.eql(u8, spec, "alpha")) return false;
    for (spec) |c| {
        switch (c) {
            '^', '~', '*', 'x', 'X', ' ', '|', '<', '>', '=' => return false,
            else => {},
        }
    }
    return true;
}

/// 解析 "major.minor.patch" 或 "major.minor.patch-pre" 为数字；不合法返回 null。
fn parseVersionParts(s: []const u8) ?struct { major: u32, minor: u32, patch: u32 } {
    var i: usize = 0;
    var part: u32 = 0;
    var parts: [3]u32 = .{ 0, 0, 0 };
    var idx: usize = 0;
    while (i < s.len and idx < 3) : (i += 1) {
        const c = s[i];
        if (c == '.' or c == '-' or c == '+') {
            if (idx < 3) parts[idx] = part;
            idx += 1;
            part = 0;
            if (c != '.') break;
            continue;
        }
        if (c >= '0' and c <= '9') part = part * 10 + (c - '0') else return null;
    }
    if (idx < 3) parts[idx] = part;
    return .{ .major = parts[0], .minor = parts[1], .patch = parts[2] };
}

/// 版本比较：-1 表示 a < b，0 表示 a == b，1 表示 a > b；解析失败则 a 视为小于 b。
fn compareVersion(a: []const u8, b: []const u8) i8 {
    const pa = parseVersionParts(a) orelse return -1;
    const pb = parseVersionParts(b) orelse return 1;
    if (pa.major != pb.major) return if (pa.major > pb.major) 1 else -1;
    if (pa.minor != pb.minor) return if (pa.minor > pb.minor) 1 else -1;
    if (pa.patch != pb.patch) return if (pa.patch > pb.patch) 1 else -1;
    return 0;
}

/// 判断版本字符串 ver 是否满足范围 spec（^1.2.3、~1.2.3、>=1.0.0）；不满足或解析失败返回 false。
fn satisfiesRange(ver: []const u8, spec: []const u8) bool {
    if (spec.len == 0) return false;
    const pver = parseVersionParts(ver) orelse return false;
    if (spec[0] == '^') {
        const base = parseVersionParts(spec[1..]) orelse return false;
        if (base.major == 0) {
            if (base.minor == 0) return pver.major == 0 and pver.minor == 0 and pver.patch >= base.patch;
            return pver.major == 0 and pver.minor == base.minor and pver.patch >= base.patch;
        }
        return pver.major == base.major and (pver.minor > base.minor or (pver.minor == base.minor and pver.patch >= base.patch));
    }
    if (spec[0] == '~') {
        const base = parseVersionParts(spec[1..]) orelse return false;
        return pver.major == base.major and pver.minor == base.minor and pver.patch >= base.patch;
    }
    if (std.mem.startsWith(u8, spec, ">=")) {
        _ = parseVersionParts(spec[2..]) orelse return false;
        return compareVersion(ver, spec[2..]) >= 0;
    }
    return false;
}

/// 从 registry 的 versions 对象中选出满足 spec 的最大版本；stable_only 为 true 时仅考虑稳定版（排除 -canary、-beta 等）。返回的切片由调用方 free，无满足版本返回 null。
fn maxSatisfyingVersion(allocator: std.mem.Allocator, versions_obj: std.json.ObjectMap, spec: []const u8, stable_only: bool) ?[]const u8 {
    var best: ?[]const u8 = null;
    var it = versions_obj.iterator();
    while (it.next()) |entry| {
        const ver = entry.key_ptr.*;
        if (stable_only and !isStableVersion(ver)) continue;
        if (!satisfiesRange(ver, spec)) continue;
        if (best) |b| {
            if (compareVersion(ver, b) > 0) {
                allocator.free(b);
                best = allocator.dupe(u8, ver) catch continue;
            }
        } else {
            best = allocator.dupe(u8, ver) catch continue;
        }
    }
    return best;
}

/// 构建 GET 包元数据的 URL：registry_base 无末尾斜杠，name 可为 @scope/pkg。
/// 与 Bun 一致：部分 registry（如 AWS CodeArtifact）只认 path 里 / 编码为 %2F，故对 name 中的 / 做编码。
fn buildRegistryUrl(allocator: std.mem.Allocator, registry_base: []const u8, name: []const u8) ![]const u8 {
    const encoded_name = if (std.mem.indexOf(u8, name, "/")) |_|
        try std.mem.replaceOwned(u8, allocator, name, "/", "%2F")
    else
        try allocator.dupe(u8, name);
    defer allocator.free(encoded_name);
    var list = std.ArrayList(u8).initCapacity(allocator, registry_base.len + 1 + encoded_name.len + 1) catch return error.OutOfMemory;
    defer list.deinit(allocator);
    try list.appendSlice(allocator, registry_base);
    if (registry_base.len > 0 and registry_base[registry_base.len - 1] == '/') {}
    else try list.append(allocator, '/');
    try list.appendSlice(allocator, encoded_name);
    return list.toOwnedSlice(allocator);
}

/// 发往 registry 的请求使用的 User-Agent，避免部分 registry/代理返回空（npm 等均会发送）
const REGISTRY_USER_AGENT = "shu/1.0 (registry client)";
/// npm 官方与部分镜像（如 JFrog）要求的 Accept，与 Bun 一致：https://github.com/oven-sh/bun/blob/main/src/install/NetworkTask.zig
const REGISTRY_ACCEPT = "application/vnd.npm.install-v1+json; q=1.0, application/json; q=0.8, */*";

/// 同步 GET url，将响应体读入内存（最多 max_bytes）；自动处理 Content-Encoding: gzip 与重定向（最多 5 次）。调用方 free 返回的切片。
/// 连接/发送/接收失败时返回真实错误（如 ConnectionRefused、CertificateBundleLoadFailure），便于排查。
fn httpGet(allocator: std.mem.Allocator, url: []const u8, max_bytes: usize) ![]const u8 {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    const accept_header = std.http.Header{ .name = "Accept", .value = REGISTRY_ACCEPT };
    var req = client.request(.GET, uri, .{
        .redirect_behavior = std.http.Client.Request.RedirectBehavior.init(5),
        .headers = .{
            .user_agent = .{ .override = REGISTRY_USER_AGENT },
            .accept_encoding = .{ .override = "gzip, deflate" },
        },
        .extra_headers = &.{ accept_header },
    }) catch |e| return e;
    defer req.deinit();
    req.sendBodiless() catch |e| return e;
    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch |e| return e;
    const status = @intFromEnum(response.head.status);
    if (status < 200 or status >= 300) return error.BadStatus;
    var transfer_buf: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const decompress_buf = allocator.alloc(u8, std.compress.flate.max_window_len) catch return error.ResponseTooLarge;
    defer allocator.free(decompress_buf);
    const reader = response.readerDecompressing(&transfer_buf, &decompress, decompress_buf);
    return io_core.readReaderUpTo(allocator, reader, max_bytes);
}

/// 使用指定可执行路径的 curl 发 GET，带 Accept/User-Agent，返回 stdout；调用方 free。内部用。
fn httpGetViaCurlWithExe(allocator: std.mem.Allocator, curl_exe: []const u8, url: []const u8, max_bytes: usize) ![]const u8 {
    return httpGetViaCurlWithExeTimeout(allocator, curl_exe, url, max_bytes, 0);
}

/// 同上，但支持超时：timeout_sec > 0 时追加 curl -m timeout_sec，避免不可达镜像卡住。用于全量探测。
fn httpGetViaCurlWithExeTimeout(allocator: std.mem.Allocator, curl_exe: []const u8, url: []const u8, max_bytes: usize, timeout_sec: u32) ![]const u8 {
    const accept_hdr = std.fmt.allocPrint(allocator, "Accept: {s}", .{REGISTRY_ACCEPT}) catch return error.OutOfMemory;
    defer allocator.free(accept_hdr);
    const ua_hdr = std.fmt.allocPrint(allocator, "User-Agent: {s}", .{REGISTRY_USER_AGENT}) catch return error.OutOfMemory;
    defer allocator.free(ua_hdr);
    const result = if (timeout_sec > 0) blk: {
        var timeout_buf: [16]u8 = undefined;
        const timeout_str = std.fmt.bufPrint(&timeout_buf, "{d}", .{timeout_sec}) catch return error.OutOfMemory;
        break :blk std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ curl_exe, "-sL", "-m", timeout_str, "-H", accept_hdr, "-H", ua_hdr, url },
            .max_output_bytes = max_bytes,
        }) catch return error.CurlFailed;
    } else std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ curl_exe, "-sL", "-H", accept_hdr, "-H", ua_hdr, url },
        .max_output_bytes = max_bytes,
    }) catch return error.CurlFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) return error.CurlFailed;
    return allocator.dupe(u8, result.stdout);
}

/// 使用系统 curl 请求 url，将 stdout 读入内存（最多 max_bytes）。用于 Zig 的 HTTP 失败时回退，与 Bun 同终端下可复用系统解析器。npm 要求 Accept: application/vnd.npm.install-v1+json; q=1.0, application/json; q=0.8, */*
/// 返回的切片由调用方 free。curl 未找到或非 0 退出时返回 error.CurlFailed。macOS 上会先试 PATH 中的 curl，失败再试 /usr/bin/curl。
fn httpGetViaCurl(allocator: std.mem.Allocator, url: []const u8, max_bytes: usize) ![]const u8 {
    return httpGetViaCurlWithExe(allocator, "curl", url, max_bytes) catch |e| {
        if (e == error.CurlFailed and (builtin.os.tag == .macos or builtin.os.tag == .freebsd))
            return httpGetViaCurlWithExe(allocator, "/usr/bin/curl", url, max_bytes);
        return e;
    };
}

/// 使用系统 curl 发 GET，带 timeout_sec 超时（-m），用于全量探测时避免单镜像卡住。调用方 free 返回的切片。
fn httpGetViaCurlWithTimeout(allocator: std.mem.Allocator, url: []const u8, max_bytes: usize, timeout_sec: u32) ![]const u8 {
    return httpGetViaCurlWithExeTimeout(allocator, "curl", url, max_bytes, timeout_sec) catch |e| {
        if (e == error.CurlFailed and (builtin.os.tag == .macos or builtin.os.tag == .freebsd))
            return httpGetViaCurlWithExeTimeout(allocator, "/usr/bin/curl", url, max_bytes, timeout_sec);
        return e;
    };
}

/// 使用指定可执行路径的 curl 下载 url 到 dest_path。内部用。
fn downloadToPathViaCurlWithExe(allocator: std.mem.Allocator, curl_exe: []const u8, url: []const u8, dest_path: []const u8) !void {
    var full_argv: [5][]const u8 = .{ curl_exe, "-sL", "-o", dest_path, url };
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &full_argv,
        .max_output_bytes = 64 * 1024,
    }) catch return error.CurlFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .Exited or result.term.Exited != 0) return error.CurlFailed;
}

/// 使用系统 curl 将 url 下载到 dest_path（覆盖已有文件）。用于 Zig 的 downloadToPath 失败（如 ReadFailed）时回退。macOS 上会先试 PATH 中的 curl，失败再试 /usr/bin/curl。
fn downloadToPathViaCurl(allocator: std.mem.Allocator, url: []const u8, dest_path: []const u8) !void {
    downloadToPathViaCurlWithExe(allocator, "curl", url, dest_path) catch |e| {
        if (e == error.CurlFailed and (builtin.os.tag == .macos or builtin.os.tag == .freebsd))
            return downloadToPathViaCurlWithExe(allocator, "/usr/bin/curl", url, dest_path);
        return e;
    };
}

/// 将 https:// URL 指向的资源下载到 dest_path（覆盖已有文件）；仅支持 https://，http:// 返回 error.HttpNotSupported。响应体最多 50MB。
pub fn downloadUrlToPath(allocator: std.mem.Allocator, url: []const u8, dest_path: []const u8) !void {
    if (std.mem.startsWith(u8, url, "http://")) return error.HttpNotSupported;
    if (!std.mem.startsWith(u8, url, "https://")) return error.InvalidUrl;
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    var req = client.request(.GET, uri, .{
        .headers = .{
            .user_agent = .{ .override = REGISTRY_USER_AGENT },
            .accept_encoding = .{ .override = "gzip, deflate" },
        },
    }) catch return error.NetworkError;
    defer req.deinit();
    req.sendBodiless() catch return error.NetworkError;
    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return error.NetworkError;
    const status = @intFromEnum(response.head.status);
    if (status < 200 or status >= 300) return error.BadStatus;
    var transfer_buf: [8192]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const decompress_buf = allocator.alloc(u8, std.compress.flate.max_window_len) catch return error.ResponseTooLarge;
    defer allocator.free(decompress_buf);
    const reader = response.readerDecompressing(&transfer_buf, &decompress, decompress_buf);
    const body = io_core.readReaderUpTo(allocator, reader, 50 * 1024 * 1024) catch return error.ResponseTooLarge;
    defer allocator.free(body);
    var file = try io_core.createFileAbsolute(dest_path, .{});
    defer file.close();
    try file.writeAll(body);
}

/// 将 url 指向的 tarball 下载到 dest_path（覆盖已有文件）；用于先写临时文件再 putCachedTarball。响应体最多 50MB；自动处理 gzip。
/// 优先用系统 curl（与元数据一致，终端下常可用），失败再用 Zig HTTP。
pub fn downloadToPath(allocator: std.mem.Allocator, url: []const u8, dest_path: []const u8) !void {
    downloadToPathViaCurl(allocator, url, dest_path) catch |e| {
        downloadToPathZig(allocator, url, dest_path) catch return e;
        return;
    };
}

/// Zig 标准库 HTTP 下载到文件；内部用，失败时由 downloadToPath 尝试 curl 回退。
fn downloadToPathZig(allocator: std.mem.Allocator, url: []const u8, dest_path: []const u8) anyerror!void {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    var req = client.request(.GET, uri, .{
        .headers = .{
            .user_agent = .{ .override = REGISTRY_USER_AGENT },
            .accept_encoding = .{ .override = "gzip, deflate" },
        },
    }) catch return error.NetworkError;
    defer req.deinit();
    req.sendBodiless() catch return error.NetworkError;
    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch return error.NetworkError;
    const status = @intFromEnum(response.head.status);
    if (status < 200 or status >= 300) return error.BadStatus;
    var transfer_buf: [8192]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const decompress_buf = allocator.alloc(u8, std.compress.flate.max_window_len) catch return error.ResponseTooLarge;
    defer allocator.free(decompress_buf);
    const reader = response.readerDecompressing(&transfer_buf, &decompress, decompress_buf);
    const body = io_core.readReaderUpTo(allocator, reader, 50 * 1024 * 1024) catch return error.ResponseTooLarge;
    defer allocator.free(body);
    var file = try io_core.createFileAbsolute(dest_path, .{});
    defer file.close();
    try file.writeAll(body);
}
