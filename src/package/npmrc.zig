// 可选 .npmrc 解析：registry、@scope:registry；无 .npmrc 时使用默认 registry，保证「有则识别、无则正常」
// 参考：Bun/npm 行为；仅解析 key=value，支持 # 行注释；项目根 .npmrc 优先于 ~/.npmrc
// 文件 I/O 经 io_core（§3.0）

const std = @import("std");
const io_core = @import("io_core");

/// 默认 registry URL（无 .npmrc 或未配置 registry 时使用）
pub const DEFAULT_REGISTRY_URL = "https://registry.npmjs.org";
/// JSR 包使用的 npm 兼容 registry（与 Deno/Bun 一致，.npmrc 未配置 @jsr:registry 时使用）
pub const JSR_NPM_REGISTRY = "https://npm.jsr.io";

/// 从 ~/.npmrc 读入并合并进 map（存在则解析，不存在则跳过）
fn loadUserNpmrc(allocator: std.mem.Allocator, map: *std.StringArrayHashMap([]const u8)) void {
    const home = std.posix.getenv("HOME") orelse return;
    const path = io_core.pathJoin(allocator, &.{ home, ".npmrc" }) catch return;
    defer allocator.free(path);
    const f = io_core.openFileAbsolute(path, .{}) catch return;
    defer f.close();
    const raw = f.readToEndAlloc(allocator, 64 * 1024) catch return;
    defer allocator.free(raw);
    parseInto(allocator, map, raw) catch return;
}

/// 从 dir 下 .npmrc 读入并合并进 map（存在则解析，不存在则跳过）；项目配置覆盖用户配置
fn loadProjectNpmrc(allocator: std.mem.Allocator, map: *std.StringArrayHashMap([]const u8), dir: []const u8) void {
    var dir_handle = if (io_core.pathIsAbsolute(dir))
        io_core.openDirAbsolute(dir, .{}) catch return
    else
        io_core.openDirCwd(dir, .{}) catch return;
    defer dir_handle.close();
    const content = dir_handle.openFile(".npmrc", .{}) catch return;
    defer content.close();
    const raw = content.readToEndAlloc(allocator, 64 * 1024) catch return;
    defer allocator.free(raw);
    parseInto(allocator, map, raw) catch return;
}

/// 从 dir 下 .npmrc 与可选 ~/.npmrc 合并解析出 key -> value 表；仅解析 registry 与 @scope:registry。先用户后项目，项目覆盖用户。
/// 返回的 map 由调用方 deinit；map 内 key/value 由本函数用 allocator 分配，调用方在 deinit 前须遍历并 free 每个 key 与 value。
/// 若两个文件都不存在或为空则返回空 map（调用方用 DEFAULT_REGISTRY_URL）。
pub fn load(allocator: std.mem.Allocator, dir: []const u8) !std.StringArrayHashMap([]const u8) {
    var map = std.StringArrayHashMap([]const u8).init(allocator);
    errdefer map.deinit();
    loadUserNpmrc(allocator, &map);
    loadProjectNpmrc(allocator, &map, dir);
    return map;
}

/// 将 .npmrc 内容解析为 key=value 并合并进 map（同 key 后者覆盖）；只保留 registry 与 @*:registry。
fn parseInto(allocator: std.mem.Allocator, map: *std.StringArrayHashMap([]const u8), content: []const u8) !void {
    var line_start: usize = 0;
    while (line_start < content.len) {
        var i = line_start;
        while (i < content.len and content[i] != '\n') i += 1;
        const line = std.mem.trim(u8, content[line_start..i], " \t\r\n");
        line_start = i + 1;
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (key.len == 0 or value.len == 0) continue;
        const is_registry = std.mem.eql(u8, key, "registry");
        const is_scope_registry = std.mem.endsWith(u8, key, ":registry") and key.len > ":registry".len;
        if (!is_registry and !is_scope_registry) continue;
        const dup_key = allocator.dupe(u8, key) catch continue;
        const dup_val = allocator.dupe(u8, value) catch {
            allocator.free(dup_key);
            continue;
        };
        const old = map.fetchPut(dup_key, dup_val) catch |e| {
            allocator.free(dup_key);
            allocator.free(dup_val);
            return e;
        };
        if (old) |o| {
            allocator.free(o.key);
            allocator.free(o.value);
        }
    }
}

/// 从 registry URL（如 https://registry.npmjs.org/）解析出 host 部分（如 registry.npmjs.org），用于 cache key。返回的切片由调用方 free。
pub fn hostFromRegistryUrl(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    const prefix = std.mem.indexOf(u8, url, "://") orelse return allocator.dupe(u8, "registry.npmjs.org");
    var i = prefix + 3;
    while (i < url.len and url[i] != '/' and url[i] != ':') i += 1;
    return allocator.dupe(u8, url[prefix + 3 .. i]);
}

/// 根据包名得到应使用的 registry URL。@jsr/ 包固定走 JSR npm 兼容 registry（除非 .npmrc 配置 @jsr:registry）；其它 @scope/pkg 查 @scope:registry；否则查 registry；无则返回默认。返回的切片由调用方 free。
pub fn getRegistryForPackage(allocator: std.mem.Allocator, cwd: []const u8, package_name: []const u8) ![]const u8 {
    var npmrc = load(allocator, cwd) catch return allocator.dupe(u8, DEFAULT_REGISTRY_URL);
    defer {
        var it = npmrc.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        npmrc.deinit();
    }
    if (std.mem.startsWith(u8, package_name, "@")) {
        const slash = std.mem.indexOfScalar(u8, package_name, '/') orelse return allocator.dupe(u8, DEFAULT_REGISTRY_URL);
        const scope = package_name[0..slash];
        const key = try std.fmt.allocPrint(allocator, "{s}:registry", .{scope});
        defer allocator.free(key);
        if (npmrc.get(key)) |url| return allocator.dupe(u8, url);
        // @jsr/ 包未配置 @jsr:registry 时使用 JSR npm 兼容 registry
        if (std.mem.eql(u8, scope, "@jsr")) return allocator.dupe(u8, JSR_NPM_REGISTRY);
    }
    if (npmrc.get("registry")) |url| return allocator.dupe(u8, url);
    return allocator.dupe(u8, DEFAULT_REGISTRY_URL);
}
