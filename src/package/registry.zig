// npm/JSR registry：解析版本、获取 tarball URL、下载 tarball 到缓存
// 参考：docs/PACKAGE_DESIGN.md §7；与 cache.zig、install.zig 配合
// 文件 I/O 经 io_core（§3.0）；网络请求统一经 io_core.http（Zig 路径）

const std = @import("std");
const io_core = @import("io_core");
const cache = @import("cache.zig");
const npmrc = @import("npmrc.zig");

/// 默认 npm registry 根 URL（无末尾斜杠），与 REGISTRY_LIST[0] 一致
pub const DEFAULT_REGISTRY = "https://registry.npmjs.org";

/// 判断是否为默认 registry（含 .npmrc 中带尾斜杠的写法），以便走多镜像探测与回退
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
/// 无 client 时 registryGet 使用的超时（秒）；保留 API 兼容，当前 Zig 路径未实现请求超时
const REGISTRY_GET_FALLBACK_TIMEOUT_SEC: u32 = 30;
/// 单包 registry 元数据最大响应体字节数：默认 2GB，实际包元数据不会接近此值，相当于不限制。可通过环境变量 SHU_REGISTRY_META_MAX_BYTES 调低（如省内存）。
const REGISTRY_META_MAX_BYTES_DEFAULT = 2 * 1024 * 1024 * 1024;

/// 返回当前生效的 registry 元数据最大字节数：若设置了 SHU_REGISTRY_META_MAX_BYTES 则解析该值（clamp 到 1MB～2GB），否则用 REGISTRY_META_MAX_BYTES_DEFAULT（2GB）。
fn getRegistryMetaMaxBytes() usize {
    const v = std.posix.getenv("SHU_REGISTRY_META_MAX_BYTES") orelse return REGISTRY_META_MAX_BYTES_DEFAULT;
    const n = std.fmt.parseInt(usize, v, 10) catch return REGISTRY_META_MAX_BYTES_DEFAULT;
    return std.math.clamp(n, 1024 * 1024, REGISTRY_META_MAX_BYTES_DEFAULT);
}

/// JSR npm 兼容层 registry（JSR 包通过此地址解析版本与 tarball，与 Deno 一致）
pub const JSR_NPM_REGISTRY = "https://npm.jsr.io";

/// 当 SHU_DEBUG_REGISTRY 非空时向 stderr 打印缓存路径与读取结果，便于排查「有 ~/.shu/registry 仍走 pnpm」等问题。
fn debugLogRegistryCache(path: []const u8, ok: bool, url: ?[]const u8) void {
    const env = std.posix.getenv("SHU_DEBUG_REGISTRY") orelse return;
    if (env.len == 0) return;
    var buf: [512]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    if (url) |u|
        w.interface.print("[shu registry] cache path={s} read_ok={} url={s}\n", .{ path, ok, u }) catch return
    else
        w.interface.print("[shu registry] cache path={s} read_ok={} url=null\n", .{ path, ok }) catch return;
    w.interface.flush() catch return;
}

/// 从 ~/.shu/registry 读取上次可用的 registry URL（一行，trim）；不存在或读失败返回 null。调用方 free 返回的切片。供 install 在存在缓存时优先使用，覆盖 .npmrc 的 registry。
pub fn getCachedRegistry(allocator: std.mem.Allocator) ?[]const u8 {
    const shu_home = cache.getShuHome(allocator) catch {
        if (std.posix.getenv("SHU_DEBUG_REGISTRY")) |e| {
            if (e.len > 0) _ = std.posix.write(2, "[shu registry] getShuHome failed\n") catch {};
        }
        return null;
    };
    defer allocator.free(shu_home);
    const registry_path = io_core.pathJoin(allocator, &.{ shu_home, "registry" }) catch return null;
    defer allocator.free(registry_path);
    var f = io_core.openFileAbsolute(registry_path, .{}) catch {
        debugLogRegistryCache(registry_path, false, null);
        return null;
    };
    defer f.close();
    var buf: [512]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = f.read(buf[total..]) catch return null;
        if (n == 0) break;
        total += n;
    }
    const line = std.mem.trim(u8, buf[0..total], " \t\r\n");
    if (line.len == 0) {
        debugLogRegistryCache(registry_path, true, null);
        return null;
    }
    const result = allocator.dupe(u8, line) catch return null;
    debugLogRegistryCache(registry_path, true, result);
    return result;
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

/// 删除 ~/.shu/registry，使下次 getCachedRegistry 返回 null。当缓存的 URL 请求失败（如 DNS 不可达）时调用，避免反复使用不可用镜像。
fn clearCachedRegistry(allocator: std.mem.Allocator) void {
    const shu_home = cache.getShuHome(allocator) catch return;
    defer allocator.free(shu_home);
    const registry_path = io_core.pathJoin(allocator, &.{ shu_home, "registry" }) catch return;
    defer allocator.free(registry_path);
    io_core.deleteFileAbsolute(registry_path) catch {};
}

/// 单次探测结果：响应耗时（纳秒）与 body；主线程顺序探测时使用，避免多线程共享 allocator（GPA 非线程安全）导致全部失败。
const ProbeResult = struct {
    elapsed_ns: u64 = 0,
    body: ?[]const u8 = null,
};

/// resolveVersionTarballAndDeps / probeRegistriesWithPingThenResolvePackage 的返回类型；调用方须 free version、tarball_url 及 dependencies 的 key/value 并 deinit(dependencies)。
pub const TarballAndDepsResult = struct {
    version: []const u8,
    tarball_url: []const u8,
    dependencies: std.StringArrayHashMap([]const u8),
};

/// 用「包请求」探测镜像：对 REGISTRY_LIST 顺序发 GET /包名、记时，选响应最快且含 "versions" 的镜像写入缓存，返回该镜像的 body。调用方 free 返回的 body。供 ping 全部失败时兜底。全部不可达时返回 error.AllRegistriesUnreachable。
fn probeRegistriesByPackageRequestAndSetCache(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
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
        const body = registryGet(allocator, url, getRegistryMetaMaxBytes(), PROBE_TIMEOUT_SEC) catch |e| {
            last_probe_err = e;
            continue;
        };
        const end = std.time.nanoTimestamp();
        res.elapsed_ns = if (end >= start) @intCast(end - start) else 0;
        res.body = body;
    }
    var best: ?usize = null;
    var best_ns: u64 = std.math.maxInt(u64);
    const versions_key = "\"versions\"";
    for (results, 0..) |r, i| {
        const body = r.body orelse continue;
        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] != '{') continue;
        if (std.mem.indexOf(u8, trimmed, versions_key) == null) continue;
        if (r.elapsed_ns < best_ns) {
            best_ns = r.elapsed_ns;
            best = i;
        }
    }
    if (best == null) {
        for (results, 0..) |r, i| {
            const body = r.body orelse continue;
            const trimmed = std.mem.trim(u8, body, " \t\r\n");
            if (trimmed.len == 0 or trimmed[0] != '{') continue;
            if (r.elapsed_ns < best_ns) {
                best_ns = r.elapsed_ns;
                best = i;
            }
        }
    }
    if (best) |winner_i| {
        setCachedRegistry(allocator, REGISTRY_LIST[winner_i]);
        return allocator.dupe(u8, results[winner_i].body.?);
    }
    for (REGISTRY_LIST) |base| {
        const url_curl = buildRegistryUrl(allocator, base, name) catch continue;
        defer allocator.free(url_curl);
        const body_curl = registryGet(allocator, url_curl, getRegistryMetaMaxBytes(), REGISTRY_GET_FALLBACK_TIMEOUT_SEC) catch continue;
        defer allocator.free(body_curl);
        const trimmed = std.mem.trim(u8, body_curl, " \t\r\n");
        if (trimmed.len == 0 or trimmed[0] != '{') continue;
        setCachedRegistry(allocator, base);
        return allocator.dupe(u8, body_curl);
    }
    // 所有镜像均不可达，返回明确错误供上层提示用户配置 .npmrc 或使用 VPN
    return error.AllRegistriesUnreachable;
}

/// 用「ping」探测镜像再解析包：无缓存时对 REGISTRY_LIST 顺序请求 GET base/-/ping、记时，选延时最短的镜像写入缓存，再只对缓存 URL 发一次包请求并返回解析结果；全部 ping 失败则退化为「包请求探测」。
/// 供 install 在「无缓存时先完成探测再发后续请求」时调用；也供 resolveVersionTarballAndDeps 无缓存路径复用。调用方须 free 返回的 version、tarball_url，以及 dependencies 的 key/value 并 deinit(dependencies)。
pub fn probeRegistriesWithPingThenResolvePackage(
    allocator: std.mem.Allocator,
    name: []const u8,
    version_spec: []const u8,
) !TarballAndDepsResult {
    // 探测改为 ping：对 REGISTRY_LIST 顺序请求 GET base/-/ping、记时，选响应延时最短的镜像写入缓存
    const ping_max_bytes = 1024;
    var ping_results: [REGISTRY_LIST.len]struct { elapsed_ns: u64 = 0, ok: bool = false } = undefined;
    for (REGISTRY_LIST, &ping_results) |base, *res| {
        const trim_len = if (base.len > 0 and base[base.len - 1] == '/') base.len - 1 else base.len;
        const ping_url = std.mem.concat(allocator, u8, &.{ base[0..trim_len], "/-/ping" }) catch continue;
        defer allocator.free(ping_url);
        const start = std.time.nanoTimestamp();
        const body = registryGet(allocator, ping_url, ping_max_bytes, PROBE_TIMEOUT_SEC) catch continue;
        defer allocator.free(body);
        const end = std.time.nanoTimestamp();
        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        if (trimmed.len > 0) {
            res.elapsed_ns = if (end >= start) @intCast(end - start) else 0;
            res.ok = true;
        }
    }
    var best_i: ?usize = null;
    var best_ns: u64 = std.math.maxInt(u64);
    for (ping_results, 0..) |r, i| {
        if (r.ok and r.elapsed_ns < best_ns) {
            best_ns = r.elapsed_ns;
            best_i = i;
        }
    }
    if (best_i) |i| setCachedRegistry(allocator, REGISTRY_LIST[i]);
    if (getCachedRegistry(allocator)) |cached| {
        defer allocator.free(cached);
        const url = buildRegistryUrl(allocator, cached, name) catch return error.OutOfMemory;
        defer allocator.free(url);
        const body = registryGet(allocator, url, getRegistryMetaMaxBytes(), REGISTRY_GET_FALLBACK_TIMEOUT_SEC) catch |e| return e;
        defer allocator.free(body);
        const body_trimmed = std.mem.trim(u8, body, " \t\r\n");
        if (body_trimmed.len == 0 or body_trimmed[0] != '{') return error.EmptyRegistryResponse;
        const cache_root = cache.getCacheRoot(allocator) catch null;
        var registry_host: ?[]const u8 = null;
        if (cache_root != null) registry_host = npmrc.hostFromRegistryUrl(allocator, DEFAULT_REGISTRY) catch null;
        defer if (cache_root) |c| allocator.free(c);
        defer if (registry_host) |h| allocator.free(h);
        const parsed = try parseRegistryResponseWithDeps(allocator, body_trimmed, version_spec);
        if (cache_root != null and registry_host != null) cache.putCachedMetadata(allocator, cache_root.?, registry_host.?, name, body) catch {};
        return .{ .version = parsed.version, .tarball_url = parsed.tarball_url, .dependencies = parsed.dependencies };
    }
    // ping 全部失败时退化为原来的发包请求探测
    const cache_root = cache.getCacheRoot(allocator) catch null;
    var registry_host: ?[]const u8 = null;
    if (cache_root != null) registry_host = npmrc.hostFromRegistryUrl(allocator, DEFAULT_REGISTRY) catch null;
    defer if (cache_root) |c| allocator.free(c);
    defer if (registry_host) |h| allocator.free(h);
    const body = try probeRegistriesByPackageRequestAndSetCache(allocator, name);
    defer allocator.free(body);
    const body_trimmed = std.mem.trim(u8, body, " \t\r\n");
    const parsed = try parseRegistryResponseWithDeps(allocator, body_trimmed, version_spec);
    if (cache_root != null and registry_host != null) cache.putCachedMetadata(allocator, cache_root.?, registry_host.?, name, body) catch {};
    return .{ .version = parsed.version, .tarball_url = parsed.tarball_url, .dependencies = parsed.dependencies };
}

/// 从 registry 获取包元数据（GET /<name>），解析出 dist-tags.latest 与 versions[].dist.tarball。
/// 当 registry_base 为 DEFAULT_REGISTRY 时：先读 ~/.shu/registry 用缓存的 URL；
/// 若缓存不存在或缓存的 URL 不可用，则对 REGISTRY_LIST 用 GET base/-/ping 探测、记时，选延时最短的镜像写入缓存后只对该 URL 发一次包请求；
/// 全部 ping 失败再退化为发包请求探测、记时选最快。
/// 非默认 registry 时仅使用传入的 registry_base。返回的 version 与 tarball_url 由调用方 free。
/// client 非 null 时在单 URL 路径（缓存的 URL、非默认 registry）用其复用连接。
pub fn resolveVersionAndTarball(
    allocator: std.mem.Allocator,
    registry_base: []const u8,
    name: []const u8,
    version_spec: []const u8,
    client: ?*std.http.Client,
) !struct { version: []const u8, tarball_url: []const u8 } {
    // client 非 null 时在单 URL 路径用 registryGetWithClient 复用连接；否则 registryGet 内部用一次性 Client（均 Zig 路径）
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
            const body = if (client) |c| registryGetWithClient(c, allocator, url, getRegistryMetaMaxBytes()) catch {
                clearCachedRegistry(allocator);
                break :try_cached;
            } else registryGet(allocator, url, getRegistryMetaMaxBytes(), REGISTRY_GET_FALLBACK_TIMEOUT_SEC) catch {
                clearCachedRegistry(allocator);
                break :try_cached;
            };
            defer allocator.free(body);
            const body_trimmed = std.mem.trim(u8, body, " \t\r\n");
            if (body_trimmed.len == 0 or body_trimmed[0] != '{') break :try_cached;
            const parsed = parseRegistryResponse(allocator, body_trimmed, version_spec) catch break :try_cached;
            setCachedRegistry(allocator, cached);
            if (cache_root != null and registry_host != null) cache.putCachedMetadata(allocator, cache_root.?, registry_host.?, name, body) catch {};
            return .{ .version = parsed.version, .tarball_url = parsed.tarball_url };
        }
        // 无缓存或缓存的 URL 不可用：ping 探测、记时，选延时最短的镜像写入缓存后只对该 URL 发一次包请求；全部 ping 失败再退化为发包请求探测
        const ping_max_bytes = 1024;
        var ping_results: [REGISTRY_LIST.len]struct { elapsed_ns: u64 = 0, ok: bool = false } = undefined;
        for (REGISTRY_LIST, &ping_results) |base, *res| {
            const trim_len = if (base.len > 0 and base[base.len - 1] == '/') base.len - 1 else base.len;
            const ping_url = std.mem.concat(allocator, u8, &.{ base[0..trim_len], "/-/ping" }) catch continue;
            defer allocator.free(ping_url);
            const start = std.time.nanoTimestamp();
            const ping_body = registryGet(allocator, ping_url, ping_max_bytes, PROBE_TIMEOUT_SEC) catch continue;
            defer allocator.free(ping_body);
            const end = std.time.nanoTimestamp();
            const trimmed = std.mem.trim(u8, ping_body, " \t\r\n");
            if (trimmed.len > 0) {
                res.elapsed_ns = if (end >= start) @intCast(end - start) else 0;
                res.ok = true;
            }
        }
        var best_i: ?usize = null;
        var best_ns: u64 = std.math.maxInt(u64);
        for (ping_results, 0..) |r, i| {
            if (r.ok and r.elapsed_ns < best_ns) {
                best_ns = r.elapsed_ns;
                best_i = i;
            }
        }
        if (best_i) |i| setCachedRegistry(allocator, REGISTRY_LIST[i]);
        try_after_ping: {
            const cached = getCachedRegistry(allocator) orelse break :try_after_ping;
            defer allocator.free(cached);
            const url = buildRegistryUrl(allocator, cached, name) catch break :try_after_ping;
            defer allocator.free(url);
            const body = if (client) |c| registryGetWithClient(c, allocator, url, getRegistryMetaMaxBytes()) catch {
                clearCachedRegistry(allocator);
                break :try_after_ping;
            } else registryGet(allocator, url, getRegistryMetaMaxBytes(), REGISTRY_GET_FALLBACK_TIMEOUT_SEC) catch {
                clearCachedRegistry(allocator);
                break :try_after_ping;
            };
            defer allocator.free(body);
            const body_trimmed = std.mem.trim(u8, body, " \t\r\n");
            if (body_trimmed.len == 0 or body_trimmed[0] != '{') break :try_after_ping;
            const parsed = parseRegistryResponse(allocator, body_trimmed, version_spec) catch break :try_after_ping;
            setCachedRegistry(allocator, cached);
            if (cache_root != null and registry_host != null) cache.putCachedMetadata(allocator, cache_root.?, registry_host.?, name, body) catch {};
            return .{ .version = parsed.version, .tarball_url = parsed.tarball_url };
        }
        // ping 全部失败：退化为原来的发包请求探测
        const body_probe = try probeRegistriesByPackageRequestAndSetCache(allocator, name);
        defer allocator.free(body_probe);
        const body_trimmed = std.mem.trim(u8, body_probe, " \t\r\n");
        const parsed = try parseRegistryResponse(allocator, body_trimmed, version_spec);
        if (cache_root != null and registry_host != null) cache.putCachedMetadata(allocator, cache_root.?, registry_host.?, name, body_probe) catch {};
        return .{ .version = parsed.version, .tarball_url = parsed.tarball_url };
    }
    const url = try buildRegistryUrl(allocator, registry_base, name);
    defer allocator.free(url);
    const body = if (client) |c| registryGetWithClient(c, allocator, url, getRegistryMetaMaxBytes()) else registryGet(allocator, url, getRegistryMetaMaxBytes(), REGISTRY_GET_FALLBACK_TIMEOUT_SEC);
    const body_slice = body catch |e| return e;
    defer allocator.free(body_slice);
    const body_trimmed = std.mem.trim(u8, body_slice, " \t\r\n");
    if (body_trimmed.len == 0) {
        debugLogRegistryResponse(url, body_trimmed);
        return error.EmptyRegistryResponse;
    }
    if (body_trimmed[0] != '{') {
        debugLogRegistryResponse(url, body_trimmed);
        return error.RegistryReturnedNonJson;
    }
    const parsed = try parseRegistryResponse(allocator, body_trimmed, version_spec);
    if (cache_root != null and registry_host != null) cache.putCachedMetadata(allocator, cache_root.?, registry_host.?, name, body_slice) catch {};
    return .{ .version = parsed.version, .tarball_url = parsed.tarball_url };
}

/// 与 resolveVersionAndTarball 相同，但额外返回该版本的 dependencies（用于传递依赖）。client 非 null 时在单 URL 路径复用连接。
/// 调用方须 free version、tarball_url，并 free dependencies 的 key/value 且 deinit(dependencies)。
pub fn resolveVersionTarballAndDeps(
    allocator: std.mem.Allocator,
    registry_base: []const u8,
    name: []const u8,
    version_spec: []const u8,
    client: ?*std.http.Client,
) !TarballAndDepsResult {
    // 有 client 时走 registryGetWithClient（复用连接），无则走 registryGet（单次 Client）。
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
            const body = if (client) |c|
                registryGetWithClient(c, allocator, url, getRegistryMetaMaxBytes()) catch {
                    clearCachedRegistry(allocator);
                    break :try_cached;
                }
            else
                registryGet(allocator, url, getRegistryMetaMaxBytes(), REGISTRY_GET_FALLBACK_TIMEOUT_SEC) catch {
                    clearCachedRegistry(allocator);
                    break :try_cached;
                };
            defer allocator.free(body);
            const body_trimmed = std.mem.trim(u8, body, " \t\r\n");
            if (body_trimmed.len == 0 or body_trimmed[0] != '{') break :try_cached;
            const parsed = parseRegistryResponseWithDeps(allocator, body_trimmed, version_spec) catch break :try_cached;
            setCachedRegistry(allocator, cached);
            if (cache_root != null and registry_host != null) cache.putCachedMetadata(allocator, cache_root.?, registry_host.?, name, body) catch {};
            return .{ .version = parsed.version, .tarball_url = parsed.tarball_url, .dependencies = parsed.dependencies };
        }
        // 无缓存或缓存的 URL 不可用：复用统一探测逻辑，完成探测并写入缓存后返回
        return probeRegistriesWithPingThenResolvePackage(allocator, name, version_spec);
    }
    if (std.posix.getenv("SHU_DEBUG_HTTP")) |env| {
        if (env.len > 0) {
            var buf_single: [256]u8 = undefined;
            var w_single = std.fs.File.stderr().writer(&buf_single);
            w_single.interface.print("[shu registry] single_url name={s} base={s}\n", .{ name, registry_base }) catch {};
            w_single.interface.flush() catch {};
        }
    }
    const url = try buildRegistryUrl(allocator, registry_base, name);
    defer allocator.free(url);
    const body = if (client) |c|
        registryGetWithClient(c, allocator, url, getRegistryMetaMaxBytes()) catch |e| return e
    else
        registryGet(allocator, url, getRegistryMetaMaxBytes(), REGISTRY_GET_FALLBACK_TIMEOUT_SEC) catch |e| return e;
    defer allocator.free(body);
    const body_trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (body_trimmed.len == 0) {
        debugLogRegistryResponse(url, body_trimmed);
        return error.EmptyRegistryResponse;
    }
    if (body_trimmed[0] != '{') {
        debugLogRegistryResponse(url, body_trimmed);
        return error.RegistryReturnedNonJson;
    }
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
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body_trimmed, .{ .allocate = .alloc_always }) catch {
        debugLogInvalidRegistryResponse(body_trimmed);
        return error.InvalidRegistryResponse;
    };
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) {
        debugLogInvalidRegistryResponse(body_trimmed);
        return error.InvalidRegistryResponse;
    }
    const obj = root.object;

    const version = blk: {
        const exact = isExactVersion(version_spec);
        if (exact) {
            var had_versions = false;
            if (obj.get("versions")) |v| {
                if (v == .object) {
                    had_versions = true;
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
                    // 精确版本不存在：先选比请求版本稍新的最小版本（>=version_spec），没有再选比请求版本稍旧的最大版本（<version_spec），都没有则安装失败
                    if (minSatisfyingVersion(allocator, v.object, version_spec, true)) |chosen| break :blk chosen;
                    if (maxVersionLessThan(allocator, v.object, version_spec, true)) |chosen| break :blk chosen;
                }
            }
            debugLogRegistryVersionNotFound(version_spec, had_versions, body_trimmed.len);
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

/// 解析 "major.minor.patch" 或 "major.minor.patch-pre" 为数字；可选前导 "v"/"V" 会跳过。不合法返回 null。
fn parseVersionParts(s: []const u8) ?struct { major: u32, minor: u32, patch: u32 } {
    var rest = s;
    if (rest.len > 0 and (rest[0] == 'v' or rest[0] == 'V')) rest = rest[1..];
    var i: usize = 0;
    var part: u32 = 0;
    var parts: [3]u32 = .{ 0, 0, 0 };
    var idx: usize = 0;
    while (i < rest.len and idx < 3) : (i += 1) {
        const c = rest[i];
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

/// 从 registry 的 versions 对象中选出满足 ">=version_spec" 的最小版本（比请求版本稍新）；stable_only 为 true 时仅考虑稳定版。返回的切片由调用方 free，无满足版本返回 null。
fn minSatisfyingVersion(allocator: std.mem.Allocator, versions_obj: std.json.ObjectMap, version_spec: []const u8, stable_only: bool) ?[]const u8 {
    const spec = std.fmt.allocPrint(allocator, ">={s}", .{version_spec}) catch return null;
    defer allocator.free(spec);
    var best: ?[]const u8 = null;
    var it = versions_obj.iterator();
    while (it.next()) |entry| {
        const ver = entry.key_ptr.*;
        if (stable_only and !isStableVersion(ver)) continue;
        if (!satisfiesRange(ver, spec)) continue;
        if (best) |b| {
            if (compareVersion(ver, b) < 0) {
                allocator.free(b);
                best = allocator.dupe(u8, ver) catch continue;
            }
        } else {
            best = allocator.dupe(u8, ver) catch continue;
        }
    }
    return best;
}

/// 从 registry 的 versions 对象中选出严格小于 version_spec 的最大版本（比请求版本稍旧）；stable_only 为 true 时仅考虑稳定版。返回的切片由调用方 free，无满足版本返回 null。
fn maxVersionLessThan(allocator: std.mem.Allocator, versions_obj: std.json.ObjectMap, version_spec: []const u8, stable_only: bool) ?[]const u8 {
    var best: ?[]const u8 = null;
    var it = versions_obj.iterator();
    while (it.next()) |entry| {
        const ver = entry.key_ptr.*;
        if (stable_only and !isStableVersion(ver)) continue;
        if (compareVersion(ver, version_spec) >= 0) continue;
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

/// 根据 registry_base、包名、版本构造 npm tarball 的 URL；与 npm 约定一致，无需请求元数据。
/// 格式：{registry_base}/{name}/-/{tarball_filename}.tgz；scoped 包 @scope/name 的 tarball 文件名为 name-version.tgz（仅取 / 后一段），与 registry.npmjs.org 一致。调用方 free 返回值。
pub fn buildTarballUrl(allocator: std.mem.Allocator, registry_base: []const u8, name: []const u8, version: []const u8) ![]const u8 {
    var base = registry_base;
    if (base.len > 0 and base[base.len - 1] == '/') base = base[0 .. base.len - 1];
    const tarball_name = if (std.mem.indexOf(u8, name, "/")) |slash_pos|
        try allocator.dupe(u8, name[slash_pos + 1 ..])
    else
        try allocator.dupe(u8, name);
    defer allocator.free(tarball_name);
    const suffix = try std.fmt.allocPrint(allocator, "-{s}.tgz", .{version});
    defer allocator.free(suffix);
    const encoded_name = if (std.mem.indexOf(u8, name, "/")) |_|
        try std.mem.replaceOwned(u8, allocator, name, "/", "%2F")
    else
        try allocator.dupe(u8, name);
    defer allocator.free(encoded_name);
    const cap = base.len + 1 + encoded_name.len + "/-/".len + tarball_name.len + suffix.len;
    var list = std.ArrayList(u8).initCapacity(allocator, cap) catch return error.OutOfMemory;
    defer list.deinit(allocator);
    try list.appendSlice(allocator, base);
    try list.append(allocator, '/');
    try list.appendSlice(allocator, encoded_name);
    try list.appendSlice(allocator, "/-/");
    try list.appendSlice(allocator, tarball_name);
    try list.appendSlice(allocator, suffix);
    return list.toOwnedSlice(allocator);
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
    if (registry_base.len > 0 and registry_base[registry_base.len - 1] == '/') {} else try list.append(allocator, '/');
    try list.appendSlice(allocator, encoded_name);
    return list.toOwnedSlice(allocator);
}

/// 发往 registry 的请求使用的 User-Agent，避免部分 registry/代理返回空（npm 等均会发送）
const REGISTRY_USER_AGENT = "shu/1.0 (registry client)";
/// npm 官方与部分镜像（如 JFrog）要求的 Accept，与 Bun 一致：https://github.com/oven-sh/bun/blob/main/src/install/NetworkTask.zig
const REGISTRY_ACCEPT = "application/vnd.npm.install-v1+json; q=1.0, application/json; q=0.8, */*";

/// 当 SHU_DEBUG_HTTP 非空时打印 VersionNotFound 时的 version_spec、是否含 versions、body 长度，便于排查精确版本 fallback 是否生效。
fn debugLogRegistryVersionNotFound(version_spec: []const u8, had_versions: bool, body_len: usize) void {
    const env = std.posix.getenv("SHU_DEBUG_HTTP") orelse return;
    if (env.len == 0) return;
    var buf: [256]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.print("[shu registry] VersionNotFound spec={s} had_versions={} body_len={d}\n", .{ version_spec, had_versions, body_len }) catch return;
    w.interface.flush() catch return;
}

/// 当 SHU_DEBUG_REGISTRY 或 SHU_DEBUG_HTTP 非空时，向 stderr 打印 InvalidRegistryResponse 时的 body 长度与预览，便于排查 JSON 解析失败（截断、限流页等）。
fn debugLogInvalidRegistryResponse(body_trimmed: []const u8) void {
    const env = std.posix.getenv("SHU_DEBUG_REGISTRY") orelse std.posix.getenv("SHU_DEBUG_HTTP") orelse return;
    if (env.len == 0) return;
    var buf: [1024]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.print("[shu registry] InvalidRegistryResponse body_len={d}\n", .{body_trimmed.len}) catch return;
    const preview_len = @min(384, body_trimmed.len);
    if (preview_len > 0) {
        const preview = body_trimmed[0..preview_len];
        w.interface.print("[shu registry] body_preview: {s}\n", .{preview}) catch return;
    }
    w.interface.flush() catch return;
}

/// 当环境变量 SHU_DEBUG_HTTP 非空时，向 stderr 打印 registry 请求的 URL、body 长度与内容预览，用于排查空 body 或非 JSON。Zig 0.15：stderr 用 std.fs.File.stderr().writer(&buf)。
fn debugLogRegistryResponse(url: []const u8, body_trimmed: []const u8) void {
    const env = std.posix.getenv("SHU_DEBUG_HTTP") orelse return;
    if (env.len == 0) return;
    var buf: [1024]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.print("[shu registry debug] url={s}\n", .{url}) catch return;
    w.interface.print("[shu registry debug] body_len={d}\n", .{body_trimmed.len}) catch return;
    const preview_len = @min(512, body_trimmed.len);
    if (preview_len > 0) {
        const preview = body_trimmed[0..preview_len];
        w.interface.print("[shu registry debug] body_preview (first {d} bytes):\n{s}\n", .{ preview_len, preview }) catch return;
    } else {
        w.interface.print("[shu registry debug] body_preview: (empty)\n", .{}) catch return;
    }
    w.interface.flush() catch return;
}

/// 使用 io_core.http 发 GET，带 npm registry 的 Accept 与 User-Agent。accept_encoding = "identity" 避免服务端返回 br/gzip 导致解压失败。调用方 free 返回的切片。
fn registryGet(allocator: std.mem.Allocator, url: []const u8, max_bytes: usize, timeout_sec: u32) ![]const u8 {
    if (timeout_sec > 0) {
        return io_core.http.get(allocator, url, .{
            .accept = REGISTRY_ACCEPT,
            .accept_encoding = "identity",
            .max_bytes = max_bytes,
            .timeout_sec = timeout_sec,
            .user_agent = REGISTRY_USER_AGENT,
        });
    }
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    return registryGetWithClient(&client, allocator, url, max_bytes);
}

/// 与 registryGet 相同，但使用已有 Client 以复用连接；走 Zig 路径、无超时。accept_encoding = "identity" 避免解压失败。
fn registryGetWithClient(client: *std.http.Client, allocator: std.mem.Allocator, url: []const u8, max_bytes: usize) ![]const u8 {
    return io_core.http.getWithClient(client, allocator, url, .{
        .accept = REGISTRY_ACCEPT,
        .accept_encoding = "identity",
        .max_bytes = max_bytes,
        .timeout_sec = 0,
        .user_agent = REGISTRY_USER_AGENT,
    });
}

/// 使用自定义 Accept 头 GET url（供 JSR 等非 npm registry 使用）；Zig 路径、一次性 Client。调用方 free 返回的切片。
pub fn fetchUrlWithAccept(allocator: std.mem.Allocator, url: []const u8, accept_value: []const u8, max_bytes: usize) ![]const u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    return fetchUrlWithAcceptWithClient(&client, allocator, url, accept_value, max_bytes);
}

/// 与 fetchUrlWithAccept 相同，但使用已有 Client 以复用连接；走 Zig 路径、无超时。
pub fn fetchUrlWithAcceptWithClient(client: *std.http.Client, allocator: std.mem.Allocator, url: []const u8, accept_value: []const u8, max_bytes: usize) ![]const u8 {
    return io_core.http.getWithClient(client, allocator, url, .{
        .accept = accept_value,
        .max_bytes = max_bytes,
        .timeout_sec = 0,
        .user_agent = REGISTRY_USER_AGENT,
    });
}

/// 使用 Zig 路径（一次性 std.http.Client）GET url，Accept application/json；供 JSR 元数据拉取。
pub fn fetchUrlForJsrMeta(allocator: std.mem.Allocator, url: []const u8, max_bytes: usize) ![]const u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    return fetchUrlForJsrMetaWithClient(&client, allocator, url, max_bytes);
}

/// 与 fetchUrlForJsrMeta 相同，但使用已有 std.http.Client 以复用连接（Keep-Alive）；走 Zig 路径、无超时。供 JSR 下载 worker 多请求复用同一连接。
/// JSR (jsr.io) 返回 Transfer-Encoding: chunked + Content-Encoding: gzip，npm 镜像多返回 Content-Length，故 JSR 易触发 Zig chunked 读 0 字节、npm 不报错。
/// 使用 accept_encoding = "identity" 时 CDN 常回 Content-Length，走 content-length 路径可避免 chunked 导致的 ReadFailed；用 gzip 则需接受偶发 ReadFailed。
pub fn fetchUrlForJsrMetaWithClient(client: *std.http.Client, allocator: std.mem.Allocator, url: []const u8, max_bytes: usize) ![]const u8 {
    return io_core.http.getWithClient(client, allocator, url, .{
        .accept = "application/json",
        // .accept_encoding = "identity",
        .accept_encoding = "gzip, deflate",
        .max_bytes = max_bytes,
        .user_agent = REGISTRY_USER_AGENT,
        .timeout_sec = 0,
        .extra_headers = &.{.{ .name = "Sec-Fetch-Dest", .value = "empty" }},
    });
}

/// 将 url 指向的资源下载到 dest_path（覆盖已有文件）；经 io_core.http GET（Zig 路径、一次性 Client），响应体最多 50MB。
pub fn downloadToPath(allocator: std.mem.Allocator, url: []const u8, dest_path: []const u8) !void {
    if (std.mem.startsWith(u8, url, "http://")) return error.HttpNotSupported;
    if (!std.mem.startsWith(u8, url, "https://")) return error.InvalidUrl;
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    try downloadToPathWithClient(&client, allocator, url, dest_path);
}

/// 与 downloadToPath 相同，但使用已有 std.http.Client 以复用连接；走 Zig 路径、无超时。供 install 阶段连续下载多个 npm tgz 时复用同一连接。
pub fn downloadToPathWithClient(client: *std.http.Client, allocator: std.mem.Allocator, url: []const u8, dest_path: []const u8) !void {
    if (std.mem.startsWith(u8, url, "http://")) return error.HttpNotSupported;
    if (!std.mem.startsWith(u8, url, "https://")) return error.InvalidUrl;
    const body = io_core.http.getWithClient(client, allocator, url, .{
        .accept = "*/*",
        .max_bytes = 50 * 1024 * 1024,
        .user_agent = REGISTRY_USER_AGENT,
        .timeout_sec = 0,
    }) catch return error.NetworkError;
    defer allocator.free(body);
    var file = try io_core.createFileAbsolute(dest_path, .{});
    defer file.close();
    try file.writeAll(body);
}

/// 与 downloadToPath 相同；仅支持 https://，http:// 返回 error.HttpNotSupported。供 cli/install 等调用。
pub fn downloadUrlToPath(allocator: std.mem.Allocator, url: []const u8, dest_path: []const u8) !void {
    return downloadToPath(allocator, url, dest_path);
}
