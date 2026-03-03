// 安装与缓存：根据 manifest 与 lockfile 将依赖从缓存解压到 node_modules；未命中则从 registry 下载后写入缓存并解压；安装完成后写回 shu.lock
// 参考：docs/PACKAGE_DESIGN.md §4、§7
// 文件/目录与路径经 io_core（§3.0）；解压 tgz 用 io_core.mapFileReadOnly

const std = @import("std");

/// 将格式化内容直接 write(2, ...) 到 stderr；前导 \\n 避免与进度条（\\r 同行刷新）挤在同一行或被覆盖。
fn logInstallFailure(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    fbs.writer().print("\n" ++ fmt, args) catch return;
    const slice = fbs.getWritten();
    _ = std.posix.write(2, slice) catch {};
}
const io_core = @import("io_core");
const manifest = @import("manifest.zig");
const lockfile = @import("lockfile.zig");
const cache = @import("cache.zig");
const registry = @import("registry.zig");
const npmrc = @import("npmrc.zig");
const resolver = @import("resolver.zig");
const jsr = @import("jsr.zig");
const shu_zlib = @import("shu_zlib");

/// 无 .npmrc 时使用的默认 registry host 与 URL（与 npmrc.DEFAULT_REGISTRY_URL 一致）
const DEFAULT_REGISTRY_HOST = "registry.npmjs.org";
const REGISTRY_BASE_URL = npmrc.DEFAULT_REGISTRY_URL;

/// 判断 URL 是否为默认 registry（含尾斜杠），用于决定是否在失败时回退到默认
fn isDefaultRegistryUrl(url: []const u8) bool {
    const t = std.mem.trim(u8, url, "/");
    return std.mem.eql(u8, t, "https://registry.npmjs.org");
}

/// 优化 C：lockfile 是否已包含 manifest 全部直接依赖及传递闭包；若 true 可跳过整段解析循环。
fn canSkipResolution(
    allocator: std.mem.Allocator,
    direct_set: std.StringArrayHashMap(void),
    resolved: std.StringArrayHashMap([]const u8),
    deps_of: std.StringArrayHashMap(std.ArrayList([]const u8)),
) bool {
    var seen = std.StringArrayHashMap(void).init(allocator);
    defer seen.deinit();
    var queue = std.ArrayList([]const u8).initCapacity(allocator, 32) catch return false;
    defer queue.deinit(allocator);
    var it = direct_set.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        if (!resolved.contains(name) or !deps_of.contains(name)) return false;
        if (!seen.contains(name)) {
            seen.put(name, {}) catch return false;
            queue.append(allocator, name) catch return false;
        }
    }
    var qidx: usize = 0;
    while (qidx < queue.items.len) {
        const name = queue.items[qidx];
        qidx += 1;
        const deps = deps_of.get(name) orelse return false;
        for (deps.items) |dep| {
            if (!resolved.contains(dep) or !deps_of.contains(dep)) return false;
            if (!seen.contains(dep)) {
                seen.put(dep, {}) catch return false;
                queue.append(allocator, dep) catch return false;
            }
        }
    }
    return true;
}

/// 解析阶段每层 JSR 并发数上限（deno.json 拉取 + version 解析）
const JSR_RESOLVE_MAX_WORKERS = 16;

/// JSR 并发解析单条结果：version/imports 由 worker 用 page_allocator 分配，主线程合并后须用 page_allocator 释放。
const JsrResolveResult = struct {
    version: []const u8 = "",
    imports: ?[]const jsr.DenoImportDep = null,
    err: ?anyerror = null,
};

/// 单条 JSR 待解析项（仅 name/spec，指针指向 to_process 内有效内存）
const JsrResolveItem = struct { name: []const u8, spec: []const u8 };

/// Worker 线程上下文：items 与 results 在 join 前有效；next_index 原子递增取任务下标。
const JsrResolveWorkerCtx = struct {
    items: []const JsrResolveItem,
    results: [*]JsrResolveResult,
    next_index: *std.atomic.Value(usize),
};

/// 每批请求数：超过后重建 Client，避免同一连接复用过多导致服务端关闭或返回非 JSON（常见于「最后一包」报 JsrMetaNoJsonObject）。
const JSR_RESOLVE_CLIENT_REUSE_LIMIT = 32;

/// npm 解析阶段每层并发 worker 数；与 JSR 对齐，避免过多连接压垮 registry。
const NPM_RESOLVE_MAX_WORKERS = 16;

/// npm 并发解析单条结果：version、tarball_url、dependencies 由 worker 用 page_allocator 分配，主线程合并后须用 page_allocator 释放。
const NpmResolveResult = struct {
    version: ?[]const u8 = null,
    tarball_url: ?[]const u8 = null,
    dependencies: ?std.StringArrayHashMap([]const u8) = null,
    err: ?anyerror = null,
};

/// 单条 npm 待解析项：name/spec/display_name 指向 to_process 内有效内存；registry_url 由主线程分配并在 join 后统一 free。
const NpmResolveItem = struct { name: []const u8, spec: []const u8, display_name: ?[]const u8, registry_url: []const u8 };

/// Worker 上下文：items 与 results 在 join 前有效；next_index 原子递增取任务下标。
const NpmResolveWorkerCtx = struct {
    items: []const NpmResolveItem,
    results: [*]NpmResolveResult,
    next_index: *std.atomic.Value(usize),
};

/// npm 解析 worker：每 worker 持有一个 Client，循环取任务并调用 resolveVersionTarballAndDeps，结果写入 results[i]（page 分配，主线程释放）。
/// 后续可考虑改为 per-worker Arena（§1.2），worker 结束时一次性 deinit，减少主线程逐项 free。
fn npmResolveWorker(ctx: *const NpmResolveWorkerCtx) void {
    const page = std.heap.page_allocator;
    var client = std.http.Client{ .allocator = page };
    defer client.deinit();
    while (true) {
        const i = ctx.next_index.fetchAdd(1, .monotonic);
        if (i >= ctx.items.len) return;
        const item = ctx.items[i];
        const r = registry.resolveVersionTarballAndDeps(page, item.registry_url, item.name, item.spec, &client) catch |e| {
            ctx.results[i] = .{ .err = e };
            continue;
        };
        ctx.results[i] = .{
            .version = r.version,
            .tarball_url = r.tarball_url,
            .dependencies = r.dependencies,
        };
    }
}

/// 优化 B：npm 安装阶段并发 worker 数；每 worker 独立 std.http.Client + 临时文件，查缓存→下载→解压一条龙。16 以压榨网络/磁盘并发，registry 限流时仍可回退为 8。
const NPM_INSTALL_MAX_WORKERS = 16;

/// JSR 安装阶段并发 worker 数；每个 worker 调用 downloadPackageToDir 向共享 JsrDownloadPool 投递一批文件任务，多包并行拉取。与 npm 对齐用 16 以压榨网络。
const JSR_INSTALL_MAX_WORKERS = 16;

/// 单条 JSR 安装任务：name/version/pkg_dest 指向 arena 或 install_order，worker 只读。
const JsrInstallTask = struct { name: []const u8, version: []const u8, pkg_dest: []const u8 };

/// 主线程与 worker 共享：最近完成的一包名，供 onProgress 第二行显示；主线程轮询时加锁读出。
const LastCompletedName = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,
    mutex: std.Thread.Mutex = .{},
};

/// JSR 安装 worker 上下文：tasks/results 在 join 前有效；next_index 原子取任务下标；pool 共享。install_completed_count 非 null 时每完成一包递增；last_completed_name 非 null 时写入最近完成包名。
const JsrInstallWorkerCtx = struct {
    tasks: []const JsrInstallTask,
    results: [*]?anyerror,
    next_index: *std.atomic.Value(usize),
    pool: *jsr.JsrDownloadPool,
    allocator: std.mem.Allocator,
    first_error: *?anyerror,
    first_error_mutex: *std.Thread.Mutex,
    error_detail: ?*InstallErrorDetail,
    main_allocator: std.mem.Allocator,
    install_completed_count: ?*std.atomic.Value(usize) = null,
    last_completed_name: ?*LastCompletedName = null,
};

/// JSR 安装 worker：循环取任务并调用 downloadPackageToDir；与 npm 一致，网络类失败（超时、HttpFailed 等）时重试
/// INSTALL_NETWORK_RETRIES 次，失败写 results[i] 并在 mutex 下写 first_error。
fn jsrInstallWorker(ctx: *const JsrInstallWorkerCtx) void {
    while (true) {
        const i = ctx.next_index.fetchAdd(1, .monotonic);
        if (i >= ctx.tasks.len) return;
        const task = ctx.tasks[i];
        var last_err: anyerror = undefined;
        var ok = false;
        for (0..INSTALL_NETWORK_RETRIES) |ri| {
            if (ri > 0) std.Thread.sleep(INSTALL_NETWORK_RETRY_DELAYS_NS[ri - 1]);
            jsr.downloadPackageToDir(ctx.allocator, ctx.pool, task.name, task.version, task.pkg_dest) catch |e| {
                last_err = e;
                continue;
            };
            ok = true;
            break;
        }
        if (!ok) {
            ctx.results[i] = last_err;
            ctx.first_error_mutex.lock();
            defer ctx.first_error_mutex.unlock();
            if (ctx.first_error.* == null) {
                ctx.first_error.* = last_err;
                if (ctx.error_detail) |ed| {
                    ed.err = last_err;
                    ed.name = ctx.main_allocator.dupe(u8, task.name) catch null;
                    ed.version = ctx.main_allocator.dupe(u8, task.version) catch null;
                }
            }
        }
        if (ctx.install_completed_count) |c| _ = c.fetchAdd(1, .monotonic);
        if (ctx.last_completed_name) |ln| setLastCompletedName(ln, task.name);
    }
}

/// 单条 npm 安装任务：name/version 指向 install_order/resolved；pkg_dest/registry_url/registry_host 由主线程分配，worker 只读，主线程在 join 后统一 free。
const NpmInstallTask = struct {
    name: []const u8,
    version: []const u8,
    pkg_dest: []const u8,
    registry_url: []const u8,
    registry_host: []const u8,
};

/// 写最近完成包名到共享缓冲，供主线程 onProgress 第二行显示；name 过长则截断。
fn setLastCompletedName(ln: *LastCompletedName, name: []const u8) void {
    ln.mutex.lock();
    defer ln.mutex.unlock();
    const n = @min(name.len, ln.buf.len - 1);
    if (n > 0) {
        @memcpy(ln.buf[0..n], name[0..n]);
        ln.buf[n] = 0;
    }
    ln.len = n;
}

/// npm 安装 worker 上下文：tasks/results 在 join 前有效；next_index 原子取任务下标；resolved_tarball_urls 只读；first_error 与 error_detail 由首次失败者写入（mutex 保护）。first_extract_failure_logged 保证首次解压失败时无条件打印一次诊断。install_completed_count 非 null 时每完成一包递增；last_completed_name 非 null 时写入最近完成包名。
const NpmInstallWorkerCtx = struct {
    tasks: []const NpmInstallTask,
    results: [*]?anyerror,
    next_index: *std.atomic.Value(usize),
    cache_root: []const u8,
    resolved_tarball_urls: *const std.StringArrayHashMap([]const u8),
    first_error: *?anyerror,
    first_error_mutex: *std.Thread.Mutex,
    first_extract_failure_logged: *std.atomic.Value(bool),
    error_detail: ?*InstallErrorDetail,
    main_allocator: std.mem.Allocator,
    worker_id: usize,
    install_completed_count: ?*std.atomic.Value(usize) = null,
    last_completed_name: ?*LastCompletedName = null,
};

/// npm 安装 worker：每 worker 持有一个 std.http.Client（Zig 路径）和独立临时文件路径；取任务后查缓存→未命中则下载（Zig client）→写缓存→解压；失败写 results[i] 并在 mutex 下写 first_error/error_detail。
fn npmInstallWorker(ctx: *const NpmInstallWorkerCtx) void {
    const page = std.heap.page_allocator;
    var zig_client = std.http.Client{ .allocator = page };
    defer zig_client.deinit();
    const temp_tgz = std.fmt.allocPrint(page, "{s}/.tmp-download-{d}.tgz", .{ ctx.cache_root, ctx.worker_id }) catch return;
    defer page.free(temp_tgz);
    while (true) {
        const i = ctx.next_index.fetchAdd(1, .monotonic);
        if (i >= ctx.tasks.len) return;
        const task = ctx.tasks[i];
        const key = cache.cacheKey(page, task.registry_host, task.name, task.version) catch |e| {
            ctx.results[i] = e;
            setFirstError(ctx, e, task.name, task.version);
            continue;
        };
        defer page.free(key);
        const cache_dir_path = cache.getCachedPackageDirPath(page, ctx.cache_root, key) catch |e| {
            ctx.results[i] = e;
            setFirstError(ctx, e, task.name, task.version);
            continue;
        };
        defer page.free(cache_dir_path);
        var invalid_gzip_retries: u32 = 0;
        retry_extract: while (invalid_gzip_retries < 2) : (invalid_gzip_retries += 1) {
            if (cache.getCachedPackageDir(page, ctx.cache_root, key)) |hit_dir| {
                defer page.free(hit_dir);
                if (io_core.pathDirname(task.pkg_dest)) |parent| io_core.makePathAbsolute(parent) catch {};
                var link_target_buf: [std.fs.max_path_bytes]u8 = undefined;
                const link_target = io_core.realpath(hit_dir, &link_target_buf) catch hit_dir;
                io_core.symLinkAbsolute(link_target, task.pkg_dest, .{}) catch |e| {
                    ctx.results[i] = e;
                    setFirstError(ctx, e, task.name, task.version);
                };
                if (ctx.install_completed_count) |c| _ = c.fetchAdd(1, .monotonic);
                if (ctx.last_completed_name) |ln| setLastCompletedName(ln, task.name);
                break :retry_extract;
            }
            const turl_opt = ctx.resolved_tarball_urls.get(task.name);
            const turl = turl_opt orelse blk: {
                const u = registry.buildTarballUrl(page, task.registry_url, task.name, task.version) catch |e| {
                    ctx.results[i] = e;
                    setFirstError(ctx, e, task.name, task.version);
                    if (ctx.install_completed_count) |c| _ = c.fetchAdd(1, .monotonic);
                    break :retry_extract;
                };
                break :blk u;
            };
            defer if (turl_opt == null) page.free(turl);
            var download_ok = false;
            var last_dl_err: anyerror = undefined;
            for (0..INSTALL_NETWORK_RETRIES) |ri| {
                if (ri > 0) std.Thread.sleep(INSTALL_NETWORK_RETRY_DELAYS_NS[ri - 1]);
                registry.downloadToPathWithClient(&zig_client, page, turl, temp_tgz) catch |e| {
                    last_dl_err = e;
                    continue;
                };
                download_ok = true;
                break;
            }
            if (!download_ok) {
                ctx.results[i] = last_dl_err;
                setFirstError(ctx, last_dl_err, task.name, task.version);
                if (ctx.install_completed_count) |c| _ = c.fetchAdd(1, .monotonic);
                if (ctx.last_completed_name) |ln| setLastCompletedName(ln, task.name);
                break :retry_extract;
            }
            // 仅一个 worker 创建缓存目录，避免多线程同时解压到同一目录导致竞态（只写出 node_modules、无 package.json）
            if (io_core.pathDirname(cache_dir_path)) |parent| io_core.makePathAbsolute(parent) catch {};
            io_core.makeDirAbsolute(cache_dir_path) catch |e| {
                if (e == error.PathAlreadyExists) {
                    // 其他 worker 已创建或正在解压；轮询等待 package.json 出现后当作缓存命中建链
                    io_core.deleteFileAbsolute(temp_tgz) catch {};
                    for (0..60) |_| {
                        if (cache.getCachedPackageDir(page, ctx.cache_root, key)) |hit_dir| {
                            defer page.free(hit_dir);
                            if (io_core.pathDirname(task.pkg_dest)) |parent_dest| io_core.makePathAbsolute(parent_dest) catch {};
                            var link_target_buf: [std.fs.max_path_bytes]u8 = undefined;
                            const link_target = io_core.realpath(hit_dir, &link_target_buf) catch hit_dir;
                            io_core.symLinkAbsolute(link_target, task.pkg_dest, .{}) catch |sym_err| {
                                ctx.results[i] = sym_err;
                                setFirstError(ctx, sym_err, task.name, task.version);
                            };
                            if (ctx.install_completed_count) |c| _ = c.fetchAdd(1, .monotonic);
                            break :retry_extract;
                        }
                        std.Thread.sleep(100_000_000); // 100ms
                    }
                    ctx.results[i] = error.CacheDirBusy;
                    setFirstError(ctx, error.CacheDirBusy, task.name, task.version);
                } else {
                    ctx.results[i] = e;
                    setFirstError(ctx, e, task.name, task.version);
                }
                break :retry_extract;
            };
            extractTarballToDir(page, temp_tgz, cache_dir_path) catch |e| {
                logFirstTarballExtractFailure(ctx, temp_tgz, e, task.name, task.version);
                debugLogTarballExtractFailed(temp_tgz, e);
                io_core.deleteFileAbsolute(temp_tgz) catch {};
                io_core.deleteTreeAbsolute(cache_dir_path) catch {};
                if (e == error.InvalidGzip and invalid_gzip_retries < 1) {
                    continue :retry_extract;
                }
                ctx.results[i] = e;
                setFirstError(ctx, if (e == error.ReadFailed) error.TarballExtractFailed else e, task.name, task.version);
                if (ctx.install_completed_count) |c| _ = c.fetchAdd(1, .monotonic);
                if (ctx.last_completed_name) |ln| setLastCompletedName(ln, task.name);
                break :retry_extract;
            };
            io_core.deleteFileAbsolute(temp_tgz) catch {};
            // 解压后必须存在 package.json，否则视为失败、不建链
            const pkg_json_path = io_core.pathJoin(page, &.{ cache_dir_path, "package.json" }) catch |e| {
                ctx.results[i] = e;
                setFirstError(ctx, e, task.name, task.version);
                break :retry_extract;
            };
            defer page.free(pkg_json_path);
            io_core.accessAbsolute(pkg_json_path, .{}) catch {
                // 解压未抛错但 package.json 不存在：打日志并列出解压出的前几项，便于判断是 tar 结构不符（无 package/）还是空解压
                logInstallFailure("[shu install] extract ok but package.json missing: {s}@{s} dir={s}\n", .{ task.name, task.version, cache_dir_path });
                var dir_opt = io_core.openDirAbsolute(cache_dir_path, .{ .iterate = true }) catch null;
                if (dir_opt) |*dir_handle| {
                    defer dir_handle.close();
                    var it = dir_handle.iterate();
                    var n: u32 = 0;
                    while (it.next() catch null) |entry| {
                        if (n >= 8) {
                            logInstallFailure("  ... (listing first 8 only)\n", .{});
                            break;
                        }
                        logInstallFailure("  entry: {s}\n", .{entry.name});
                        n += 1;
                    }
                    if (n == 0) logInstallFailure("  (no entries)\n", .{});
                } else logInstallFailure("  (could not list dir)\n", .{});
                io_core.deleteTreeAbsolute(cache_dir_path) catch {};
                ctx.results[i] = error.TarballExtractFailed;
                setFirstError(ctx, error.TarballExtractFailed, task.name, task.version);
                if (ctx.install_completed_count) |c| _ = c.fetchAdd(1, .monotonic);
                if (ctx.last_completed_name) |ln| setLastCompletedName(ln, task.name);
                break :retry_extract;
            };
            if (io_core.pathDirname(task.pkg_dest)) |parent_dest| io_core.makePathAbsolute(parent_dest) catch {};
            var link_target_buf: [std.fs.max_path_bytes]u8 = undefined;
            const link_target = io_core.realpath(cache_dir_path, &link_target_buf) catch cache_dir_path;
            io_core.symLinkAbsolute(link_target, task.pkg_dest, .{}) catch |e| {
                ctx.results[i] = e;
                setFirstError(ctx, e, task.name, task.version);
            };
            if (ctx.install_completed_count) |c| _ = c.fetchAdd(1, .monotonic);
            if (ctx.last_completed_name) |ln| setLastCompletedName(ln, task.name);
            break :retry_extract;
        }
    }
}

/// 在 mutex 下设置首次失败错误与 error_detail（仅当 first_error 尚为 null 时写入）；供 npm 安装 worker 调用。
fn setFirstError(ctx: *const NpmInstallWorkerCtx, err: anyerror, name: []const u8, version: []const u8) void {
    ctx.first_error_mutex.lock();
    defer ctx.first_error_mutex.unlock();
    if (ctx.first_error.* == null) {
        ctx.first_error.* = err;
        if (ctx.error_detail) |ed| {
            ed.err = err;
            ed.name = ctx.main_allocator.dupe(u8, name) catch null;
            ed.version = ctx.main_allocator.dupe(u8, version) catch null;
        }
    }
}

/// 安装阶段网络请求（resolve/tgz/JSR）失败时的重试次数；瞬断常见于 169/261 附近，重试可提高成功率。
const INSTALL_NETWORK_RETRIES = 3;
/// 第 2、3 次重试前等待的纳秒数（指数退避 0.5s、1s），在瞬断恢复与总耗时之间折中。
const INSTALL_NETWORK_RETRY_DELAYS_NS = [_]u64{ 500_000_000, 1_000_000_000 };

/// 解析阶段 JSR 单条 worker：每 worker 持有一个 Client 复用连接，每 JSR_RESOLVE_CLIENT_REUSE_LIMIT 次请求重建 Client 避免长连接异常；结果写入 results[i]。
/// 当前用 page_allocator，主线程合并后释放；后续可考虑 per-worker Arena（§1.2）。
fn jsrResolveWorker(ctx: *const JsrResolveWorkerCtx) void {
    const page = std.heap.page_allocator;
    while (true) {
        var client = std.http.Client{ .allocator = page };
        var count: usize = 0;
        while (count < JSR_RESOLVE_CLIENT_REUSE_LIMIT) : (count += 1) {
            const i = ctx.next_index.fetchAdd(1, .monotonic);
            if (i >= ctx.items.len) {
                client.deinit();
                return;
            }
            const item = ctx.items[i];
            const jsr_spec = std.fmt.allocPrint(page, "jsr:{s}@{s}", .{ item.name, item.spec }) catch {
                ctx.results[i].err = error.OutOfMemory;
                client.deinit();
                return;
            };
            defer page.free(jsr_spec);
            const version = jsr.resolveVersionFromMetaWithClient(&client, page, jsr_spec) catch |e| blk: {
                // 空 body 或非 JSON 常因连接被关/限流导致，用新 client 重试一次
                if (e == error.JsrMetaEmptyResponse or e == error.JsrMetaNoJsonObject) {
                    var retry_client = std.http.Client{ .allocator = page };
                    defer retry_client.deinit();
                    break :blk jsr.resolveVersionFromMetaWithClient(&retry_client, page, jsr_spec) catch |e2| {
                        ctx.results[i].err = e2;
                        client.deinit();
                        return;
                    };
                }
                ctx.results[i].err = e;
                client.deinit();
                return;
            };
            var imports_list = jsr.fetchDenoJsonImportsFromRegistryOrJsoncWithClient(&client, page, item.name, version) catch |e| {
                page.free(version);
                ctx.results[i].err = e;
                client.deinit();
                return;
            };
            if (imports_list) |*lst| {
                defer lst.deinit(page);
                const slice = page.dupe(jsr.DenoImportDep, lst.items) catch |e| {
                    page.free(version);
                    ctx.results[i].err = e;
                    client.deinit();
                    return;
                };
                ctx.results[i] = .{ .version = version, .imports = slice };
            } else {
                ctx.results[i] = .{ .version = version, .imports = null };
            }
        }
        client.deinit();
    }
}

/// 安装失败时可选填写的错误详情；name/version 由 install 用调用方传入的 allocator 分配，调用方负责 free。
pub const InstallErrorDetail = struct {
    err: anyerror = undefined,
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
};

/// 安装进度回调：onResolving 本次要解析的数量；onResolvingComplete() 解析阶段曾输出过 onResolving 时在 onStart 前调用一次，供 CLI 在 Resolving 与 Installing 间输出空行；onStart(new_count) 本次新安装数量，进度条用；onProgress(current, total, last_completed_name) 下载/解压过程中由主线程轮询调用，last_completed_name 为最近完成的一包名（可选）；onPackage(..., newly_installed)；onDone(total_count, new_count, elapsed_ms) 其中 elapsed_ms 从 install() 入口计时，含 Resolving + Installing。
/// onPackageAdded(name, version)：add 流程下 install 结束后对 added_names 中在 resolved 的包各调用一次，用于打印「+ name@version」。
/// onResolveFailure()：解析阶段某个包失败时、在写 stderr 诊断前调用一次，便于 CLI 先换行/刷新进度行，避免错误信息被后续进度覆盖。
pub const InstallReporter = struct {
    ctx: ?*anyopaque = null,
    onResolving: ?*const fn (?*anyopaque, []const u8, usize, usize) void = null,
    /// 解析阶段曾输出过 onResolving 时，在 onStart 前调用一次（跳过解析时不调用），供 CLI 在 Resolving 与 Installing 间输出空行。
    onResolvingComplete: ?*const fn (?*anyopaque) void = null,
    onResolveFailure: ?*const fn (?*anyopaque) void = null,
    onStart: ?*const fn (?*anyopaque, usize) void = null,
    /// 下载阶段主线程轮询调用，更新进度条与第二行文案；total 与 onStart 一致；last_completed_name 为最近完成的一包名（主线程从共享缓冲读出，可为 null）。
    onProgress: ?*const fn (?*anyopaque, usize, usize, ?[]const u8) void = null,
    onPackage: ?*const fn (?*anyopaque, usize, usize, []const u8, []const u8, bool) void = null,
    /// elapsed_ms 由 install 从函数入口计时到 onDone 调用前，含 Resolving + Installing，供 CLI 显示真实总耗时
    onDone: ?*const fn (?*anyopaque, usize, usize, i64) void = null,
    onPackageAdded: ?*const fn (?*anyopaque, []const u8, []const u8) void = null,
};

/// 根据 manifest 与 lockfile 安装依赖到 cwd/node_modules。若 added_names 非 null（add 流程），install 结束后对其中在 resolved 的包调用 reporter.onPackageAdded。
/// 若 error_detail 非 null，安装失败时会填入最后一次失败的 err 及包 name/version（由 allocator 分配，调用方 free name/version）。
/// §1.2：整次 install 用 Arena 分配临时路径与 key，仅 resolved map 的 key/value 用主 allocator（供 save 后释放），减少 alloc/free 与碎片。
/// 耗时统计：从本函数入口计时，onDone 时传入 elapsed_ms（含 Resolving + Installing），避免 CLI 只统计安装阶段造成虚假时间。
pub fn install(allocator: std.mem.Allocator, cwd: []const u8, reporter: ?*const InstallReporter, added_names: ?[]const []const u8, error_detail: ?*InstallErrorDetail) !void {
    const install_start_ms = std.time.milliTimestamp();
    var loaded = manifest.Manifest.load(allocator, cwd) catch |e| {
        if (e == error.ManifestNotFound) return error.NoManifest;
        return e;
    };
    defer loaded.arena.deinit();
    const m = &loaded.manifest;

    var task_arena = std.heap.ArenaAllocator.init(allocator);
    defer task_arena.deinit();
    const a = task_arena.allocator();

    // 将 cwd 解析为绝对路径，供 lock_path/nm_dir/pkg_dest 使用，确保 *Absolute 系 API 收到绝对路径
    var cwd_realpath_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_cwd = blk: {
        const resolved = io_core.realpath(cwd, &cwd_realpath_buf) catch break :blk cwd;
        break :blk try a.dupe(u8, resolved);
    };
    const lock_path = try io_core.pathJoin(a, &.{ abs_cwd, lockfile.lock_file_name });
    var locked_result = lockfile.loadWithDeps(allocator, lock_path) catch return error.OutOfMemory;
    defer {
        var it = locked_result.packages.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            for (e.value_ptr.*.items) |p| allocator.free(p);
            e.value_ptr.*.deinit(allocator);
        }
        locked_result.packages.deinit();
        for (locked_result.root_dependencies.items) |p| allocator.free(p);
        locked_result.root_dependencies.deinit(allocator);
        for (locked_result.jsr_packages.items) |p| allocator.free(p);
        locked_result.jsr_packages.deinit(allocator);
    }

    const cache_root = try cache.getCacheRoot(a);
    // 解析为规范绝对路径，确保软链接目标为绝对路径，从任意 cwd 打开 node_modules 时都能正确解析
    var cache_root_real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache_root_abs = io_core.realpath(cache_root, &cache_root_real_buf) catch cache_root;
    const cache_root_abs_owned = try a.dupe(u8, cache_root_abs);
    // 安装前确保缓存根与 content 目录存在，避免解压到缓存目录时 FileNotFound
    try io_core.makePathAbsolute(cache_root_abs_owned);
    const cache_content_dir = try io_core.pathJoin(a, &.{ cache_root_abs_owned, "content" });
    try io_core.makePathAbsolute(cache_content_dir);
    const nm_dir = try io_core.pathJoin(a, &.{ abs_cwd, "node_modules" });
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
    // 每个包名 -> 其 dependencies 的包名列表（用于在包内建 node_modules/<dep> 符号链接；直接依赖在 node_modules，传递依赖在 .shu）
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
    // 解析阶段得到的 name -> tarball_url，供安装阶段未命中缓存时直接下载，避免重复解析（优化 D）
    var resolved_tarball_urls = std.StringArrayHashMap([]const u8).init(allocator);
    defer {
        var it_tb = resolved_tarball_urls.iterator();
        while (it_tb.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        resolved_tarball_urls.deinit();
    }
    // 从 lockfile 新格式（packages name@version -> deps、root_dependencies）预填 resolved 与 deps_of；多版本时每 name 保留一版（先 root 再 packages）
    for (locked_result.root_dependencies.items) |name_at_ver| {
        const parsed = lockfile.parseNameAtVersion(allocator, name_at_ver) catch continue;
        defer allocator.free(parsed.name);
        defer allocator.free(parsed.version);
        try resolved.put(try allocator.dupe(u8, parsed.name), try allocator.dupe(u8, parsed.version));
    }
    var pkg_it = locked_result.packages.iterator();
    while (pkg_it.next()) |e| {
        const parsed = lockfile.parseNameAtVersion(allocator, e.key_ptr.*) catch continue;
        defer allocator.free(parsed.name);
        defer allocator.free(parsed.version);
        if (!resolved.contains(parsed.name)) try resolved.put(try allocator.dupe(u8, parsed.name), try allocator.dupe(u8, parsed.version));
        var list = std.ArrayList([]const u8).initCapacity(allocator, e.value_ptr.*.items.len) catch return error.OutOfMemory;
        for (e.value_ptr.*.items) |dep_at_ver| {
            const dp = lockfile.parseNameAtVersion(allocator, dep_at_ver) catch continue;
            defer allocator.free(dp.name);
            defer allocator.free(dp.version);
            try list.append(allocator, try allocator.dupe(u8, dp.name));
        }
        const name_dup = try allocator.dupe(u8, parsed.name);
        const gop = try deps_of.getOrPut(name_dup);
        if (gop.found_existing) {
            allocator.free(name_dup);
            for (gop.value_ptr.*.items) |p| allocator.free(p);
            gop.value_ptr.*.deinit(allocator);
        }
        gop.value_ptr.* = list;
    }

    // 优化 B：npm 下载临时文件改为各 worker 内 .tmp-download-<worker_id>.tgz，主线程不再使用单一 temp_tgz
    // 传递依赖统一放在 node_modules/.shu/<name>@<version>，不再使用 .shu/store 子目录
    // Windows：创建符号链接需「开发者模式」或管理员权限，否则会 AccessDenied；失败时见 CLI 的 Hint
    const shu_dir = try io_core.pathJoin(a, &.{ nm_dir, ".shu" });
    io_core.makePathAbsolute(shu_dir) catch {};

    // 直接依赖名集合：dependencies + dev_dependencies + imports 中的 jsr:/npm:（三者都装到 node_modules）
    var direct_set = std.StringArrayHashMap(void).init(a);
    defer direct_set.deinit();
    var dep_it = m.dependencies.iterator();
    while (dep_it.next()) |e| _ = direct_set.put(try a.dupe(u8, e.key_ptr.*), {}) catch {};
    var dev_it = m.dev_dependencies.iterator();
    while (dev_it.next()) |e| _ = direct_set.put(try a.dupe(u8, e.key_ptr.*), {}) catch {};
    var imports_for_direct = m.imports.iterator();
    while (imports_for_direct.next()) |entry| {
        const value = entry.value_ptr.*;
        if (std.mem.startsWith(u8, value, "jsr:")) {
            const scope_name = resolver.jsrSpecToScopeName(a, value) catch continue;
            _ = direct_set.put(try a.dupe(u8, scope_name), {}) catch {};
        } else if (std.mem.startsWith(u8, value, "npm:")) {
            const rest = value["npm:".len..];
            // scoped 包如 npm:@tailwindcss/postcss@4.2.0 第一个 @ 属于 scope，用最后一个 @ 分割包名与版本
            const last_at = std.mem.lastIndexOfScalar(u8, rest, '@') orelse continue;
            const npm_name = rest[0..last_at];
            _ = direct_set.put(try a.dupe(u8, npm_name), {}) catch {};
        }
    }

    // 待解析队列：name 为包名（npm 为 registry 名，JSR 为 @scope/name 与 Deno 一致）；is_jsr 时走 jsr.io 原生 API，不经过 npm 兼容层。
    var to_process = std.ArrayList(struct { name: []const u8, spec: []const u8, display_name: ?[]const u8, is_jsr: bool }).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer {
        for (to_process.items) |item| {
            allocator.free(item.name);
            allocator.free(item.spec);
            if (item.display_name) |d| allocator.free(d);
        }
        to_process.deinit(allocator);
    }
    var first_error: ?anyerror = null;
    // 将 HTTP ReadFailed 转为 HttpFailed，避免 CLI 显示 ReadFailed（底层已 Zig 重试，仍失败则按网络错误提示重试）
    const map_install_err = struct {
        fn call(err: anyerror) anyerror {
            if (err == error.ReadFailed) return error.HttpFailed;
            return err;
        }
    }.call;
    // 解析阶段只记 JSR 包名，安装阶段再按「先传递依赖、再直接依赖」顺序统一下载；跳过解析时为空
    var jsr_packages = std.StringArrayHashMap(void).init(a);
    defer jsr_packages.deinit();
    // 从 lockfile 恢复 JSR 包集合（新格式为 name@version，只取 name），有 lock 跳过解析时据此走 jsr_tasks
    for (locked_result.jsr_packages.items) |name_at_ver| {
        const parsed = lockfile.parseNameAtVersion(allocator, name_at_ver) catch continue;
        defer allocator.free(parsed.name);
        defer allocator.free(parsed.version);
        _ = jsr_packages.put(try a.dupe(u8, parsed.name), {}) catch {};
    }
    var resolution_idx: usize = 0;
    var resolving_emitted = false; // 本轮是否输出过 onResolving，用于 onResolvingComplete 仅在有 Resolving 输出时调用
    var npm_resolve_client = std.http.Client{ .allocator = allocator };
    defer npm_resolve_client.deinit();
    // 优化 C：lockfile 已包含全部直接依赖及传递闭包时跳过整段解析
    if (!canSkipResolution(allocator, direct_set, resolved, deps_of)) {
        var queue_it = m.dependencies.iterator();
        while (queue_it.next()) |entry| {
            const name = entry.key_ptr.*;
            if (resolved.get(name) != null and deps_of.contains(name)) continue;
            const raw_spec = resolved.get(name) orelse entry.value_ptr.*;
            const is_jsr_spec = std.mem.startsWith(u8, raw_spec, "jsr:");
            const spec = if (is_jsr_spec) blk: {
                const last_at = std.mem.lastIndexOf(u8, raw_spec, "@");
                break :blk if (last_at) |idx| if (idx > "jsr:".len) raw_spec[idx + 1 ..] else "latest" else "latest";
            } else raw_spec;
            const spec_owned = try allocator.dupe(u8, spec);
            try to_process.append(allocator, .{ .name = try allocator.dupe(u8, name), .spec = spec_owned, .display_name = null, .is_jsr = is_jsr_spec });
        }
        var queue_dev = m.dev_dependencies.iterator();
        while (queue_dev.next()) |entry| {
            const name = entry.key_ptr.*;
            if (resolved.get(name) != null and deps_of.contains(name)) continue;
            const raw_spec = resolved.get(name) orelse entry.value_ptr.*;
            const is_jsr_spec = std.mem.startsWith(u8, raw_spec, "jsr:");
            const spec = if (is_jsr_spec) blk: {
                const last_at = std.mem.lastIndexOf(u8, raw_spec, "@");
                break :blk if (last_at) |idx| if (idx > "jsr:".len) raw_spec[idx + 1 ..] else "latest" else "latest";
            } else raw_spec;
            const spec_owned = try allocator.dupe(u8, spec);
            try to_process.append(allocator, .{ .name = try allocator.dupe(u8, name), .spec = spec_owned, .display_name = null, .is_jsr = is_jsr_spec });
        }
        // 兼容 Deno 项目：deno.json 的 imports 中 jsr: 与 npm: 说明符也参与安装；JSR 用 @scope/name 走 jsr.io 原生 API，不转 @jsr/xxx
        var imports_it = m.imports.iterator();
        while (imports_it.next()) |entry| {
            const value = entry.value_ptr.*;
            const import_key = entry.key_ptr.*;
            if (std.mem.startsWith(u8, value, "jsr:")) {
                const scope_name = resolver.jsrSpecToScopeName(a, value) catch continue;
                if (m.dependencies.contains(scope_name) or m.dev_dependencies.contains(scope_name)) continue;
                if (resolved.get(scope_name) != null and deps_of.contains(scope_name)) continue;
                const spec_from_jsr = blk: {
                    const last_at = std.mem.lastIndexOf(u8, value, "@");
                    if (last_at) |idx| {
                        if (idx > "jsr:".len) break :blk value[idx + 1 ..];
                    }
                    break :blk "latest";
                };
                try to_process.append(allocator, .{
                    .name = try allocator.dupe(u8, scope_name),
                    .spec = try allocator.dupe(u8, spec_from_jsr),
                    .display_name = try allocator.dupe(u8, import_key),
                    .is_jsr = true,
                });
            } else if (std.mem.startsWith(u8, value, "npm:")) {
                const rest = value["npm:".len..];
                // scoped 包如 npm:@tailwindcss/postcss@4.2.0 第一个 @ 属于 scope，用最后一个 @ 分割包名与版本
                const last_at = std.mem.lastIndexOfScalar(u8, rest, '@') orelse continue;
                const npm_name = rest[0..last_at];
                const spec_from_npm = if (last_at + 1 < rest.len) rest[last_at + 1 ..] else "latest";
                if (m.dependencies.contains(npm_name) or m.dev_dependencies.contains(npm_name)) continue;
                if (resolved.get(npm_name) != null and deps_of.contains(npm_name)) continue;
                try to_process.append(allocator, .{
                    .name = try allocator.dupe(u8, npm_name),
                    .spec = try allocator.dupe(u8, spec_from_npm),
                    .display_name = null,
                    .is_jsr = false,
                });
            }
        }

        const page = std.heap.page_allocator;
        // 按层（wave）处理：每层先收集待处理项，npm 并行、JSR 并发拉 version + deno.json，再合并结果并扩展 to_process
        while (resolution_idx < to_process.items.len) {
            const wave_end = to_process.items.len;
            var npm_indices = std.ArrayList(usize).initCapacity(allocator, 0) catch return error.OutOfMemory;
            defer npm_indices.deinit(allocator);
            var jsr_indices = std.ArrayList(usize).initCapacity(allocator, 0) catch return error.OutOfMemory;
            defer jsr_indices.deinit(allocator);
            var i = resolution_idx;
            while (i < wave_end) : (i += 1) {
                const item = to_process.items[i];
                const already_has_deps = deps_of.contains(item.name);
                const must_ensure_jsr_direct = item.is_jsr and direct_set.contains(item.name);
                if (resolved.contains(item.name) and already_has_deps and !must_ensure_jsr_direct) continue;
                if (item.is_jsr) {
                    jsr_indices.append(allocator, i) catch return error.OutOfMemory;
                } else {
                    npm_indices.append(allocator, i) catch return error.OutOfMemory;
                }
            }
            resolution_idx = wave_end;

            // 无镜像缓存时先完成默认 registry 探测并写入 ~/.shu/registry，再发后续包请求，避免对不可达镜像发请求
            var first_npm_probe_result: ?registry.TarballAndDepsResult = null;
            const had_cache = registry.getCachedRegistry(allocator);
            if (had_cache) |url| allocator.free(url);
            if (had_cache == null and npm_indices.items.len > 0) {
                const first_pi = npm_indices.items[0];
                const first_item = to_process.items[first_pi];
                const first_reg = npmrc.getRegistryForPackage(a, cwd, first_item.name) catch try a.dupe(u8, REGISTRY_BASE_URL);
                if (isDefaultRegistryUrl(first_reg)) {
                    first_npm_probe_result = registry.probeRegistriesWithPingThenResolvePackage(allocator, first_item.name, first_item.spec) catch null;
                }
            }

            // 本层 npm：并行解析（优化 A）；首包在无缓存且默认 registry 时已由 probe 解析，合并时优先用 first_npm_probe_result
            if (npm_indices.items.len > 0) {
                const work_items = allocator.alloc(NpmResolveItem, npm_indices.items.len) catch |e| {
                    if (first_error == null) first_error = map_install_err(e);
                    continue;
                };
                defer allocator.free(work_items);
                for (npm_indices.items, work_items) |pi, *wi| {
                    const it = to_process.items[pi];
                    const reg_url_src = npmrc.getRegistryForPackage(a, cwd, it.name) catch try a.dupe(u8, REGISTRY_BASE_URL);
                    // 始终用 allocator 复制一份存入 wi.registry_url，避免 reg_url_src 来自 arena 导致最后 allocator.free 非法
                    const reg_url = if (registry.getCachedRegistry(allocator)) |cached| blk: {
                        const url = try allocator.dupe(u8, cached);
                        allocator.free(cached);
                        break :blk url;
                    } else try allocator.dupe(u8, reg_url_src);
                    wi.* = .{ .name = it.name, .spec = it.spec, .display_name = it.display_name, .registry_url = reg_url };
                }
                const npm_results = allocator.alloc(NpmResolveResult, npm_indices.items.len) catch |e| {
                    if (first_error == null) first_error = map_install_err(e);
                    for (work_items) |wi| allocator.free(wi.registry_url);
                    continue;
                };
                defer allocator.free(npm_results);
                const n_workers = @min(npm_indices.items.len, NPM_RESOLVE_MAX_WORKERS);
                var npm_threads = std.ArrayList(std.Thread).initCapacity(allocator, n_workers) catch |e| {
                    if (first_error == null) first_error = map_install_err(e);
                    for (work_items) |wi| allocator.free(wi.registry_url);
                    continue;
                };
                defer npm_threads.deinit(allocator);
                var npm_next = std.atomic.Value(usize).init(0);
                const npm_ctx = NpmResolveWorkerCtx{ .items = work_items, .results = npm_results.ptr, .next_index = &npm_next };
                for (0..n_workers) |_| {
                    npm_threads.append(allocator, std.Thread.spawn(.{}, npmResolveWorker, .{&npm_ctx}) catch |e2| {
                        if (first_error == null) first_error = map_install_err(e2);
                        for (npm_threads.items) |t| t.join();
                        for (work_items) |wi| allocator.free(wi.registry_url);
                        break;
                    }) catch |e2| {
                        if (first_error == null) first_error = map_install_err(e2);
                        for (npm_threads.items) |t| t.join();
                        for (work_items) |wi| allocator.free(wi.registry_url);
                        break;
                    };
                }
                for (npm_threads.items) |t| t.join();

                var first_probe_consumed = false;
                for (npm_indices.items, npm_results, 0..) |pi, res, ni| {
                    const item = to_process.items[pi];
                    if (reporter) |r| {
                        if (r.onResolving) |cb| {
                            resolving_emitted = true;
                            cb(r.ctx, item.display_name orelse item.name, pi + 1, to_process.items.len);
                        }
                    }
                    var from_probe = false;
                    const res_opt: ?registry.TarballAndDepsResult = if (pi == npm_indices.items[0] and first_npm_probe_result != null and !first_probe_consumed) blk: {
                        first_probe_consumed = true;
                        from_probe = true;
                        const r = first_npm_probe_result.?;
                        first_npm_probe_result = null;
                        break :blk r;
                    } else if (res.err) |e| blk: {
                        if (reporter) |r| if (r.onResolveFailure) |cb| cb(r.ctx);
                        const base = std.mem.trim(u8, work_items[ni].registry_url, "/");
                        logInstallFailure("[shu install] failed: {s}@{s} (npm resolve): {s}\n  url: {s}/{s}\n", .{ item.name, item.spec, @errorName(e), base, item.name });
                        if (first_error == null) {
                            first_error = map_install_err(e);
                            if (error_detail) |ed| {
                                ed.err = e;
                                ed.name = allocator.dupe(u8, item.name) catch null;
                                ed.version = allocator.dupe(u8, item.spec) catch null;
                            }
                        }
                        break :blk null;
                    } else blk: {
                        break :blk .{
                            .version = res.version.?,
                            .tarball_url = res.tarball_url.?,
                            .dependencies = res.dependencies.?,
                        };
                    };
                    const res_val = res_opt orelse continue;
                    const version = res_val.version;
                    const tarball_url = res_val.tarball_url;
                    const deps = res_val.dependencies;
                    if (resolved.getPtr(item.name)) |vptr| {
                        allocator.free(vptr.*);
                        vptr.* = try allocator.dupe(u8, version);
                    } else {
                        try resolved.put(try allocator.dupe(u8, item.name), try allocator.dupe(u8, version));
                    }
                    const name_dup = try allocator.dupe(u8, item.name);
                    const turl_dup = try allocator.dupe(u8, tarball_url);
                    const put_old = try resolved_tarball_urls.fetchPut(name_dup, turl_dup);
                    if (put_old) |old| {
                        allocator.free(old.value);
                        allocator.free(name_dup);
                    }
                    var dep_names = std.ArrayList([]const u8).initCapacity(allocator, deps.count()) catch {
                        if (first_error == null) first_error = error.OutOfMemory;
                        if (from_probe) {
                            allocator.free(version);
                            allocator.free(tarball_url);
                            var dit = deps.iterator();
                            while (dit.next()) |e| {
                                allocator.free(e.key_ptr.*);
                                allocator.free(e.value_ptr.*);
                            }
                            @constCast(&deps).deinit();
                        } else {
                            page.free(version);
                            page.free(tarball_url);
                            var dit = deps.iterator();
                            while (dit.next()) |e| {
                                page.free(e.key_ptr.*);
                                page.free(e.value_ptr.*);
                            }
                            @constCast(&deps).deinit();
                        }
                        continue;
                    };
                    var dep_iter = deps.iterator();
                    while (dep_iter.next()) |e| {
                        const dname = e.key_ptr.*;
                        const dspec = e.value_ptr.*;
                        const dname_dup = allocator.dupe(u8, dname) catch {
                            for (dep_names.items) |p| allocator.free(p);
                            dep_names.deinit(allocator);
                            if (from_probe) {
                                allocator.free(version);
                                allocator.free(tarball_url);
                                var dit = deps.iterator();
                                while (dit.next()) |e2| {
                                    allocator.free(e2.key_ptr.*);
                                    allocator.free(e2.value_ptr.*);
                                }
                                @constCast(&deps).deinit();
                            } else {
                                page.free(version);
                                page.free(tarball_url);
                                var dit = deps.iterator();
                                while (dit.next()) |e2| {
                                    page.free(e2.key_ptr.*);
                                    page.free(e2.value_ptr.*);
                                }
                                @constCast(&deps).deinit();
                            }
                            if (first_error == null) first_error = error.OutOfMemory;
                            continue;
                        };
                        dep_names.append(allocator, dname_dup) catch {
                            allocator.free(dname_dup);
                            for (dep_names.items) |p| allocator.free(p);
                            dep_names.deinit(allocator);
                            if (from_probe) {
                                allocator.free(version);
                                allocator.free(tarball_url);
                                var dit = deps.iterator();
                                while (dit.next()) |e2| {
                                    allocator.free(e2.key_ptr.*);
                                    allocator.free(e2.value_ptr.*);
                                }
                                @constCast(&deps).deinit();
                            } else {
                                page.free(version);
                                page.free(tarball_url);
                                var dit = deps.iterator();
                                while (dit.next()) |e2| {
                                    page.free(e2.key_ptr.*);
                                    page.free(e2.value_ptr.*);
                                }
                                @constCast(&deps).deinit();
                            }
                            if (first_error == null) first_error = error.OutOfMemory;
                            continue;
                        };
                        if (!resolved.contains(dname)) {
                            to_process.append(allocator, .{ .name = try allocator.dupe(u8, dname), .spec = try allocator.dupe(u8, dspec), .display_name = null, .is_jsr = false }) catch {
                                for (dep_names.items) |p| allocator.free(p);
                                dep_names.deinit(allocator);
                                if (from_probe) {
                                    allocator.free(version);
                                    allocator.free(tarball_url);
                                    var dit = deps.iterator();
                                    while (dit.next()) |e2| {
                                        allocator.free(e2.key_ptr.*);
                                        allocator.free(e2.value_ptr.*);
                                    }
                                    @constCast(&deps).deinit();
                                } else {
                                    page.free(version);
                                    page.free(tarball_url);
                                    var dit = deps.iterator();
                                    while (dit.next()) |e2| {
                                        page.free(e2.key_ptr.*);
                                        page.free(e2.value_ptr.*);
                                    }
                                    @constCast(&deps).deinit();
                                }
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
                        const name_key = try allocator.dupe(u8, item.name);
                        deps_of.put(name_key, dep_names) catch {
                            allocator.free(name_key);
                            for (dep_names.items) |p| allocator.free(p);
                            dep_names.deinit(allocator);
                            if (from_probe) {
                                allocator.free(version);
                                allocator.free(tarball_url);
                                var dit = deps.iterator();
                                while (dit.next()) |e2| {
                                    allocator.free(e2.key_ptr.*);
                                    allocator.free(e2.value_ptr.*);
                                }
                                @constCast(&deps).deinit();
                            } else {
                                page.free(version);
                                page.free(tarball_url);
                                var dit = deps.iterator();
                                while (dit.next()) |e2| {
                                    page.free(e2.key_ptr.*);
                                    page.free(e2.value_ptr.*);
                                }
                                @constCast(&deps).deinit();
                            }
                            if (first_error == null) first_error = error.OutOfMemory;
                            continue;
                        };
                    }
                    if (from_probe) {
                        allocator.free(version);
                        allocator.free(tarball_url);
                        var dit = deps.iterator();
                        while (dit.next()) |e| {
                            allocator.free(e.key_ptr.*);
                            allocator.free(e.value_ptr.*);
                        }
                        @constCast(&deps).deinit();
                        // 首包用了 probe 结果，worker 仍写入了 results[ni]，须释放避免泄漏
                        if (npm_results[ni].version) |v| page.free(v);
                        if (npm_results[ni].tarball_url) |tb| page.free(tb);
                        if (npm_results[ni].dependencies) |*d| {
                            var dit2 = d.iterator();
                            while (dit2.next()) |e| {
                                page.free(e.key_ptr.*);
                                page.free(e.value_ptr.*);
                            }
                            d.deinit();
                        }
                    } else {
                        page.free(version);
                        page.free(tarball_url);
                        var dit = deps.iterator();
                        while (dit.next()) |e| {
                            page.free(e.key_ptr.*);
                            page.free(e.value_ptr.*);
                        }
                        @constCast(&deps).deinit();
                    }
                }
                for (work_items) |wi| allocator.free(wi.registry_url);
            }

            // 本层 JSR：并发解析 version + 拉 deno.json
            if (jsr_indices.items.len > 0) {
                var jsr_items_buf_opt: ?[]JsrResolveItem = null;
                if (allocator.alloc(JsrResolveItem, jsr_indices.items.len)) |buf| {
                    jsr_items_buf_opt = buf;
                } else |_| {
                    if (first_error == null) first_error = error.OutOfMemory;
                }
                if (jsr_items_buf_opt) |jsr_items_buf| {
                    defer allocator.free(jsr_items_buf);
                    for (jsr_indices.items, jsr_items_buf) |pi, *out| {
                        const it = to_process.items[pi];
                        out.* = .{ .name = it.name, .spec = it.spec };
                    }
                    var jsr_results_opt: ?[]JsrResolveResult = null;
                    if (allocator.alloc(JsrResolveResult, jsr_indices.items.len)) |slice| {
                        jsr_results_opt = slice;
                    } else |_| {
                        if (first_error == null) first_error = error.OutOfMemory;
                    }
                    if (jsr_results_opt) |jsr_results| {
                        defer allocator.free(jsr_results);
                        const n_workers = @min(jsr_indices.items.len, JSR_RESOLVE_MAX_WORKERS);
                        jsr_parallel: {
                            var threads = std.ArrayList(std.Thread).initCapacity(allocator, n_workers) catch |e| {
                                if (first_error == null) first_error = map_install_err(e);
                                break :jsr_parallel;
                            };
                            defer threads.deinit(allocator);
                            var next_atomic = std.atomic.Value(usize).init(0);
                            const ctx = JsrResolveWorkerCtx{
                                .items = jsr_items_buf,
                                .results = jsr_results.ptr,
                                .next_index = &next_atomic,
                            };
                            var t: usize = 0;
                            while (t < n_workers) : (t += 1) {
                                threads.append(allocator, std.Thread.spawn(.{}, jsrResolveWorker, .{&ctx}) catch |e2| {
                                    if (first_error == null) first_error = map_install_err(e2);
                                    for (threads.items) |th| th.join();
                                    break :jsr_parallel;
                                }) catch |e2| {
                                    if (first_error == null) first_error = map_install_err(e2);
                                    for (threads.items) |th| th.join();
                                    break :jsr_parallel;
                                };
                            }
                            for (threads.items) |th| th.join();

                            // 主线程合并 JSR 结果到 resolved/deps_of/to_process，并释放 worker 用 page 分配的内存
                            for (jsr_indices.items, jsr_results) |pi, res| {
                                const item = to_process.items[pi];
                                if (res.err) |e| {
                                    if (reporter) |r| if (r.onResolveFailure) |cb| cb(r.ctx);
                                    logInstallFailure("[shu install] failed: {s}@{s} (JSR resolve): {s}\n", .{ item.name, item.spec, @errorName(e) });
                                    if (first_error == null) {
                                        first_error = map_install_err(e);
                                        if (error_detail) |ed| {
                                            ed.err = e;
                                            ed.name = allocator.dupe(u8, item.name) catch null;
                                            ed.version = allocator.dupe(u8, item.spec) catch null;
                                        }
                                    }
                                    continue;
                                }
                                const version_owned = if (resolved.get(item.name)) |ver|
                                    try allocator.dupe(u8, ver)
                                else
                                    try allocator.dupe(u8, res.version);
                                page.free(res.version);
                                if (resolved.getPtr(item.name)) |vptr| {
                                    allocator.free(vptr.*);
                                    vptr.* = version_owned;
                                } else {
                                    const resolved_key = allocator.dupe(u8, item.name) catch {
                                        allocator.free(version_owned);
                                        if (first_error == null) first_error = error.OutOfMemory;
                                        continue;
                                    };
                                    resolved.put(resolved_key, version_owned) catch {
                                        allocator.free(resolved_key);
                                        allocator.free(version_owned);
                                        if (first_error == null) first_error = error.OutOfMemory;
                                        continue;
                                    };
                                }
                                var dep_names = std.ArrayList([]const u8).initCapacity(allocator, 0) catch {
                                    if (first_error == null) first_error = error.OutOfMemory;
                                    continue;
                                };
                                // 若本迭代因 try 返回或异常路径离开且未并入 deps_of，errdefer 统一释放，避免 GPA 泄漏；break :merge_jsr 时已在 catch 里释放，用 freed_in_catch 避免重复释放
                                var merged_into_deps = false;
                                var freed_in_catch = false;
                                errdefer if (!merged_into_deps and !freed_in_catch) {
                                    for (dep_names.items) |p| allocator.free(p);
                                    dep_names.deinit(allocator);
                                };
                                // 用块与 break :merge_jsr 保证：内层 catch 里 deinit dep_names 后必须跳过当前项的 name_key/deps_of.put，否则下一轮 dep_entry 会 use-after-free 且本项分配会泄漏
                                merge_jsr: {
                                    if (res.imports) |imports| {
                                        for (imports) |dep_entry| {
                                            const dep_name_dup = allocator.dupe(u8, dep_entry.name) catch {
                                                page.free(dep_entry.name);
                                                page.free(dep_entry.spec);
                                                for (dep_names.items) |p| allocator.free(p);
                                                dep_names.deinit(allocator);
                                                freed_in_catch = true;
                                                if (first_error == null) first_error = error.OutOfMemory;
                                                break :merge_jsr;
                                            };
                                            dep_names.append(allocator, dep_name_dup) catch {
                                                allocator.free(dep_name_dup);
                                                page.free(dep_entry.name);
                                                page.free(dep_entry.spec);
                                                for (dep_names.items) |p| allocator.free(p);
                                                dep_names.deinit(allocator);
                                                freed_in_catch = true;
                                                if (first_error == null) first_error = error.OutOfMemory;
                                                break :merge_jsr;
                                            };
                                            if (!resolved.contains(dep_entry.name)) {
                                                const tp_name = allocator.dupe(u8, dep_entry.name) catch {
                                                    page.free(dep_entry.name);
                                                    page.free(dep_entry.spec);
                                                    for (dep_names.items) |p| allocator.free(p);
                                                    dep_names.deinit(allocator);
                                                    freed_in_catch = true;
                                                    if (first_error == null) first_error = error.OutOfMemory;
                                                    break :merge_jsr;
                                                };
                                                const tp_spec = allocator.dupe(u8, dep_entry.spec) catch {
                                                    allocator.free(tp_name);
                                                    page.free(dep_entry.name);
                                                    page.free(dep_entry.spec);
                                                    for (dep_names.items) |p| allocator.free(p);
                                                    dep_names.deinit(allocator);
                                                    freed_in_catch = true;
                                                    if (first_error == null) first_error = error.OutOfMemory;
                                                    break :merge_jsr;
                                                };
                                                to_process.append(allocator, .{
                                                    .name = tp_name,
                                                    .spec = tp_spec,
                                                    .display_name = null,
                                                    .is_jsr = dep_entry.is_jsr,
                                                }) catch {
                                                    allocator.free(tp_name);
                                                    allocator.free(tp_spec);
                                                    page.free(dep_entry.name);
                                                    page.free(dep_entry.spec);
                                                    for (dep_names.items) |p| allocator.free(p);
                                                    dep_names.deinit(allocator);
                                                    freed_in_catch = true;
                                                    if (first_error == null) first_error = error.OutOfMemory;
                                                    break :merge_jsr;
                                                };
                                            }
                                            page.free(dep_entry.name);
                                            page.free(dep_entry.spec);
                                        }
                                        page.free(imports);
                                    }
                                    const name_key = allocator.dupe(u8, item.name) catch {
                                        for (dep_names.items) |p| allocator.free(p);
                                        dep_names.deinit(allocator);
                                        freed_in_catch = true;
                                        if (first_error == null) first_error = error.OutOfMemory;
                                        break :merge_jsr;
                                    };
                                    // 同一包名可能多轮出现，fetchPut 只更新 value 不替换 key，返回的旧 key 仍在 map 中，不能 free
                                    const old_kv = deps_of.fetchPut(name_key, dep_names) catch {
                                        allocator.free(name_key);
                                        for (dep_names.items) |p| allocator.free(p);
                                        dep_names.deinit(allocator);
                                        freed_in_catch = true;
                                        if (first_error == null) first_error = error.OutOfMemory;
                                        break :merge_jsr;
                                    };
                                    if (old_kv) |kv| {
                                        allocator.free(name_key); // map 保留旧 key，本次 dupe 的 key 未写入，须释放防泄漏
                                        var old_list = kv.value;
                                        for (old_list.items) |p| allocator.free(p);
                                        old_list.deinit(allocator);
                                        // 不释放 kv.key：fetchPut 仅更新 value，key 仍由 map 持有，defer 中会统一 free
                                    }
                                    merged_into_deps = true;
                                    if (a.dupe(u8, item.name)) |jsr_key| {
                                        _ = jsr_packages.put(jsr_key, {}) catch a.free(jsr_key);
                                    } else |_| {}
                                    if (reporter) |r| {
                                        if (r.onResolving) |cb| {
                                            resolving_emitted = true;
                                            cb(r.ctx, item.display_name orelse item.name, wave_end, to_process.items.len);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    } // 优化 C：end !canSkipResolution
    if (first_error) |e| {
        // 无条件写 fd 2，确认是此路径返回且诊断可见（若仍无输出则可能未用当前构建的二进制）
        logInstallFailure("[shu install] returning error (after resolve): {s}\n", .{@errorName(e)});
        return e;
    }

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
    // 仅通过 imports 添加的 JSR/npm（未出现在 dependencies/devDependencies）也加入安装顺序，否则第二遍不会 onPackage，进度条与 "+ 包名" 不显示
    var add_imp = m.imports.iterator();
    while (add_imp.next()) |entry| {
        const value = entry.value_ptr.*;
        if (!std.mem.startsWith(u8, value, "jsr:") and !std.mem.startsWith(u8, value, "npm:")) continue;
        const name = if (std.mem.startsWith(u8, value, "jsr:"))
            resolver.jsrSpecToScopeName(a, value) catch continue
        else blk: {
            const rest = value["npm:".len..];
            const last_at = std.mem.lastIndexOfScalar(u8, rest, '@') orelse continue;
            break :blk rest[0..last_at];
        };
        if (m.dependencies.contains(name) or m.dev_dependencies.contains(name)) continue;
        if (resolved.contains(name)) install_order.append(allocator, name) catch return error.OutOfMemory;
    }

    const total_count = install_order.items.len;
    // 本次需要新安装的数量：目标目录尚不存在的包（npm 与 JSR 均在安装阶段统一下载）
    var new_count: usize = 0;
    for (install_order.items) |name| {
        const version = resolved.get(name).?;
        const pkg_dest = if (direct_set.contains(name))
            io_core.pathJoin(a, &.{ nm_dir, name }) catch continue
        else
            storePkgDir(a, shu_dir, name, version) catch continue;
        var d = io_core.openDirAbsolute(pkg_dest, .{}) catch {
            new_count += 1;
            continue;
        };
        d.close();
    }
    if (resolving_emitted) if (reporter) |r| if (r.onResolvingComplete) |cb| cb(r.ctx);
    if (reporter) |r| {
        if (r.onStart) |cb| {
            // add 流程：进度条与统计只按「本次添加的包」数量，不按全量依赖数
            const start_total = if (added_names) |names| names.len else new_count;
            cb(r.ctx, start_total);
        }
    }

    first_error = null;
    // 本次 install 内创建并持有的 JSR 下载池，结束时 deinit 避免 GPA 泄漏（不再使用全局 getOrCreatePool 的池）
    var jsr_pool: ?*jsr.JsrDownloadPool = null;
    defer if (jsr_pool) |p| p.deinit(allocator);
    var new_index: usize = 0;
    // add 流程下仅对 added 包报告进度，用 reported_index 作进度条 current，避免出现 326/1
    var reported_index: usize = 0;
    // 优化 B：第一遍收集「已安装 / JSR / npm 任务」；npm 任务投递到 worker 池并行下载+解压，第二遍按 install_order 报告进度。
    const n_install = install_order.items.len;
    const already_installed_arr = allocator.alloc(bool, n_install) catch return error.OutOfMemory;
    defer allocator.free(already_installed_arr);
    @memset(already_installed_arr, false);
    const npm_task_idx_arr = allocator.alloc(?usize, n_install) catch return error.OutOfMemory;
    defer allocator.free(npm_task_idx_arr);
    for (npm_task_idx_arr) |*v| v.* = null;
    const jsr_task_idx_arr = allocator.alloc(?usize, n_install) catch return error.OutOfMemory;
    defer allocator.free(jsr_task_idx_arr);
    for (jsr_task_idx_arr) |*v| v.* = null;
    var jsr_tasks = std.ArrayList(JsrInstallTask).initCapacity(allocator, n_install) catch return error.OutOfMemory;
    defer jsr_tasks.deinit(allocator);
    var npm_tasks = std.ArrayList(NpmInstallTask).initCapacity(allocator, n_install) catch return error.OutOfMemory;
    defer npm_tasks.deinit(allocator);
    // 同一 pkg_dest 只解压一次，避免 install_order 中同一包出现两次（deps+devDeps）时重复解压导致后一次覆盖或报错
    var pkg_dest_to_npm_idx = std.StringArrayHashMap(usize).init(a);
    defer pkg_dest_to_npm_idx.deinit();
    // pkg_dest/registry_url/registry_host 均由 arena (a) 分配，不在此 free，由 task_arena.deinit() 统一回收
    // 第一遍：已安装跳过；JSR 只收集任务（优化：并行阶段再下载）；npm 收集任务。
    for (install_order.items, already_installed_arr, jsr_task_idx_arr, npm_task_idx_arr) |name, *already_installed, *jsr_task_idx, *npm_task_idx| {
        const version = resolved.get(name).?;
        const pkg_dest = if (direct_set.contains(name))
            io_core.pathJoin(a, &.{ nm_dir, name }) catch |e| {
                logInstallFailure("[shu install] failed: {s}@{s} (path): {s}\n", .{ name, version, @errorName(e) });
                if (first_error == null) {
                    first_error = map_install_err(e);
                    if (error_detail) |ed| {
                        ed.err = e;
                        ed.name = allocator.dupe(u8, name) catch null;
                        ed.version = allocator.dupe(u8, version) catch null;
                    }
                }
                continue;
            }
        else
            storePkgDir(a, shu_dir, name, version) catch |e| {
                logInstallFailure("[shu install] failed: {s}@{s} (store path): {s}\n", .{ name, version, @errorName(e) });
                if (first_error == null) {
                    first_error = map_install_err(e);
                    if (error_detail) |ed| {
                        ed.err = e;
                        ed.name = allocator.dupe(u8, name) catch null;
                        ed.version = allocator.dupe(u8, version) catch null;
                    }
                }
                continue;
            };
        if (io_core.pathDirname(pkg_dest)) |parent| io_core.makePathAbsolute(parent) catch {};
        // 已安装判断：JSR 包看目录存在即可（用 deno.json）；npm 包须目录存在且含 package.json，避免空目录被误判
        already_installed.* = blk: {
            var d = io_core.openDirAbsolute(pkg_dest, .{}) catch break :blk false;
            d.close();
            if (jsr_packages.contains(name)) break :blk true;
            const pkg_json = io_core.pathJoin(a, &.{ pkg_dest, "package.json" }) catch break :blk false;
            defer a.free(pkg_json);
            var f = io_core.openFileAbsolute(pkg_json, .{}) catch break :blk false;
            f.close();
            break :blk true;
        };
        if (already_installed.*) {
            continue;
        }
        if (jsr_packages.contains(name)) {
            if (jsr_pool == null) jsr_pool = try jsr.JsrDownloadPool.init(allocator);
            jsr_tasks.append(allocator, .{ .name = name, .version = version, .pkg_dest = pkg_dest }) catch |e| {
                if (first_error == null) first_error = map_install_err(e);
                continue;
            };
            jsr_task_idx.* = jsr_tasks.items.len - 1;
            continue;
        }
        if (pkg_dest_to_npm_idx.get(pkg_dest)) |existing_idx| {
            npm_task_idx.* = existing_idx;
            continue;
        }
        const registry_url = npmrc.getRegistryForPackage(a, cwd, name) catch try a.dupe(u8, REGISTRY_BASE_URL);
        const registry_host = npmrc.hostFromRegistryUrl(a, registry_url) catch try a.dupe(u8, DEFAULT_REGISTRY_HOST);
        npm_tasks.append(allocator, .{
            .name = name,
            .version = version,
            .pkg_dest = pkg_dest,
            .registry_url = registry_url,
            .registry_host = registry_host,
        }) catch |e| {
            if (first_error == null) first_error = map_install_err(e);
            continue;
        };
        npm_task_idx.* = npm_tasks.items.len - 1;
        pkg_dest_to_npm_idx.put(pkg_dest, npm_tasks.items.len - 1) catch {};
    }
    // 下载阶段进度：主线程轮询 install_completed_count 并调用 onProgress；last_completed_name 由 worker 写入、主线程读出传 onProgress 第二行显示。
    const total_work_items = jsr_tasks.items.len + npm_tasks.items.len;
    var install_completed_count = std.atomic.Value(usize).init(0);
    var last_completed_name = LastCompletedName{};
    const want_progress = total_work_items > 0 and reporter != null and reporter.?.onProgress != null;

    // JSR 任务并行执行（多 worker 向共享 JsrDownloadPool 投递，池内并发拉取+写盘）
    const jsr_results = allocator.alloc(?anyerror, jsr_tasks.items.len) catch return error.OutOfMemory;
    defer allocator.free(jsr_results);
    if (jsr_tasks.items.len > 0 and jsr_pool != null) {
        const pool = jsr_pool.?;
        for (jsr_results) |*v| v.* = null;
        var jsr_first_err: ?anyerror = null;
        var jsr_err_mutex = std.Thread.Mutex{};
        const n_jsr_workers = @min(jsr_tasks.items.len, JSR_INSTALL_MAX_WORKERS);
        var jsr_threads = std.ArrayList(std.Thread).initCapacity(allocator, n_jsr_workers) catch return error.OutOfMemory;
        defer jsr_threads.deinit(allocator);
        var jsr_next = std.atomic.Value(usize).init(0);
        const jsr_ctx = JsrInstallWorkerCtx{
            .tasks = jsr_tasks.items,
            .results = jsr_results.ptr,
            .next_index = &jsr_next,
            .pool = pool,
            .allocator = allocator,
            .first_error = &jsr_first_err,
            .first_error_mutex = &jsr_err_mutex,
            .error_detail = error_detail,
            .main_allocator = allocator,
            .install_completed_count = if (want_progress) &install_completed_count else null,
            .last_completed_name = if (want_progress) &last_completed_name else null,
        };
        var j: usize = 0;
        while (j < n_jsr_workers) : (j += 1) {
            jsr_threads.append(allocator, std.Thread.spawn(.{}, jsrInstallWorker, .{&jsr_ctx}) catch |e| {
                for (jsr_threads.items) |th| th.join();
                return e;
            }) catch |e| {
                for (jsr_threads.items) |th| th.join();
                return e;
            };
        }
        while (want_progress and install_completed_count.load(.monotonic) < jsr_tasks.items.len) {
            const cur = install_completed_count.load(.monotonic);
            var name_buf: [64]u8 = undefined;
            var name_slice: ?[]const u8 = null;
            last_completed_name.mutex.lock();
            if (last_completed_name.len > 0) {
                @memcpy(name_buf[0..last_completed_name.len], last_completed_name.buf[0..last_completed_name.len]);
                name_slice = name_buf[0..last_completed_name.len];
            }
            last_completed_name.mutex.unlock();
            if (reporter.?.onProgress) |onProg| onProg(reporter.?.ctx, cur, total_work_items, name_slice);
            std.Thread.sleep(80_000_000); // 80ms
        }
        for (jsr_threads.items) |th| th.join();
        if (jsr_first_err) |e| first_error = map_install_err(e);
    }
    // 优化 B：npm 任务并行执行（worker 池）
    const npm_results = allocator.alloc(?anyerror, npm_tasks.items.len) catch return error.OutOfMemory;
    defer allocator.free(npm_results);
    if (npm_tasks.items.len > 0) {
        for (npm_results) |*v| v.* = null;
        var npm_first_err: ?anyerror = null;
        var npm_err_mutex = std.Thread.Mutex{};
        var npm_first_extract_logged = std.atomic.Value(bool).init(false);
        const n_workers = @min(npm_tasks.items.len, NPM_INSTALL_MAX_WORKERS);
        var threads = std.ArrayList(std.Thread).initCapacity(allocator, n_workers) catch return error.OutOfMemory;
        defer threads.deinit(allocator);
        var next_atomic = std.atomic.Value(usize).init(0);
        // 每个 worker 必须使用独立的 ctx 副本与唯一的 worker_id，否则多线程会共享同一栈上 worker_ctx，最终都读到最后一个 worker_id，共用同一临时文件导致覆盖与 TarballExtractFailed。
        var worker_ctxs = allocator.alloc(NpmInstallWorkerCtx, n_workers) catch return error.OutOfMemory;
        defer allocator.free(worker_ctxs);
        const base_ctx = NpmInstallWorkerCtx{
            .tasks = npm_tasks.items,
            .results = npm_results.ptr,
            .next_index = &next_atomic,
            .cache_root = cache_root_abs_owned,
            .resolved_tarball_urls = &resolved_tarball_urls,
            .first_error = &npm_first_err,
            .first_error_mutex = &npm_err_mutex,
            .first_extract_failure_logged = &npm_first_extract_logged,
            .error_detail = error_detail,
            .main_allocator = allocator,
            .worker_id = 0,
            .install_completed_count = if (want_progress) &install_completed_count else null,
            .last_completed_name = if (want_progress) &last_completed_name else null,
        };
        for (0..n_workers) |t| {
            worker_ctxs[t] = base_ctx;
            worker_ctxs[t].worker_id = t;
            threads.append(allocator, std.Thread.spawn(.{}, npmInstallWorker, .{&worker_ctxs[t]}) catch |e| {
                for (threads.items) |th| th.join();
                return e;
            }) catch |e| {
                for (threads.items) |th| th.join();
                return e;
            };
        }
        while (want_progress and install_completed_count.load(.monotonic) < total_work_items) {
            const cur = install_completed_count.load(.monotonic);
            var name_buf: [64]u8 = undefined;
            var name_slice: ?[]const u8 = null;
            last_completed_name.mutex.lock();
            if (last_completed_name.len > 0) {
                @memcpy(name_buf[0..last_completed_name.len], last_completed_name.buf[0..last_completed_name.len]);
                name_slice = name_buf[0..last_completed_name.len];
            }
            last_completed_name.mutex.unlock();
            if (reporter.?.onProgress) |onProg| onProg(reporter.?.ctx, cur, total_work_items, name_slice);
            std.Thread.sleep(80_000_000); // 80ms
        }
        for (threads.items) |th| th.join();
        if (npm_first_err) |e| first_error = map_install_err(e);
    }
    // 第二遍：按 install_order 报告进度（已安装 / JSR 与 npm 按 results 决定 onPackage 或记错）。
    // add 流程（added_names 非 null）时仅对用户添加的包调用 onPackage 打印，不打印全部传递依赖。
    const shouldReportPackage = struct {
        fn call(added: ?[]const []const u8, pkg_name: []const u8) bool {
            const names = added orelse return true;
            for (names) |n| if (std.mem.eql(u8, n, pkg_name)) return true;
            return false;
        }
    }.call;
    for (install_order.items, already_installed_arr, jsr_task_idx_arr, npm_task_idx_arr) |name, already_installed, jsr_task_idx, npm_task_idx| {
        const version = resolved.get(name).?;
        if (already_installed) {
            if (reporter) |r| {
                if (r.onPackage) |cb| {
                    if (shouldReportPackage(added_names, name)) {
                        const total = if (added_names) |names| names.len else new_count;
                        cb(r.ctx, reported_index, total, name, version, true);
                        reported_index += 1;
                    }
                }
            }
            new_index += 1;
            continue;
        }
        if (jsr_task_idx) |idx| {
            if (jsr_results[idx]) |e| {
                logInstallFailure("[shu install] failed: {s}@{s} (JSR download): {s}\n", .{ name, version, @errorName(e) });
                if (first_error == null) first_error = e;
            } else {
                if (reporter) |r| {
                    if (r.onPackage) |cb| {
                        if (shouldReportPackage(added_names, name)) {
                            const total = if (added_names) |names| names.len else new_count;
                            cb(r.ctx, reported_index, total, name, version, true);
                            reported_index += 1;
                        }
                    }
                }
                new_index += 1;
            }
            continue;
        }
        const idx = npm_task_idx orelse continue;
        if (npm_results[idx]) |e| {
            logInstallFailure("[shu install] failed: {s}@{s} (npm): {s}\n", .{ name, version, @errorName(e) });
            if (first_error == null) first_error = e;
        } else {
            if (reporter) |r| {
                if (r.onPackage) |cb| {
                    if (shouldReportPackage(added_names, name)) {
                        const total = if (added_names) |names| names.len else new_count;
                        cb(r.ctx, reported_index, total, name, version, true);
                        reported_index += 1;
                    }
                }
            }
            new_index += 1;
        }
    }

    if (first_error) |e| {
        // 无条件写 fd 2；若有 error_detail 则打出首败包，便于定位未出现「failed: pkg@ver」时的根因
        logInstallFailure("[shu install] returning error (after install): {s}\n", .{@errorName(e)});
        if (error_detail) |ed| {
            if (ed.name) |n| if (ed.version) |v|
                logInstallFailure("  first failure: {s}@{s}\n", .{ n, v });
        }
        return e;
    }

    // 直接依赖已安装在 node_modules/<name>，无需再建顶层符号链接

    // node_modules/.bin：为每个直接依赖的 package.json "bin" 在 .bin 下创建符号链接，供 npx/CLI 解析
    const bin_dir = io_core.pathJoin(a, &.{ nm_dir, ".bin" }) catch return error.OutOfMemory;
    io_core.makePathAbsolute(bin_dir) catch {};
    var direct_it = direct_set.iterator();
    while (direct_it.next()) |e| {
        const pkg_name = e.key_ptr.*;
        const pkg_dir = io_core.pathJoin(a, &.{ nm_dir, pkg_name }) catch continue;
        linkPackageBins(a, bin_dir, pkg_name, pkg_dir);
    }

    // 每个包（直接依赖在 node_modules，传递依赖在 .shu）内建 node_modules/<dep>，供 require 解析
    // 目标：传递依赖在 .shu/<name>@<version>；直接依赖在 node_modules/<name>
    var deps_it = deps_of.iterator();
    while (deps_it.next()) |entry| {
        const pkg_name = entry.key_ptr.*;
        const deps_list = entry.value_ptr.*;
        const version = resolved.get(pkg_name) orelse {
            logInstallFailure("[shu install] skip symlink: no resolved version for package {s}\n", .{pkg_name});
            continue;
        };
        const pkg_dir = if (direct_set.contains(pkg_name))
            io_core.pathJoin(a, &.{ nm_dir, pkg_name }) catch continue
        else
            storePkgDir(a, shu_dir, pkg_name, version) catch continue;
        const nm_inside = io_core.pathJoin(a, &.{ pkg_dir, "node_modules" }) catch continue;
        io_core.makePathAbsolute(nm_inside) catch {};
        for (deps_list.items) |dep_name| {
            const dep_ver = resolved.get(dep_name) orelse {
                logInstallFailure("[shu install] skip symlink: no resolved version for dep {s} of {s}\n", .{ dep_name, pkg_name });
                continue;
            };
            // 传递依赖指向 node_modules/.shu/<name>@<ver>，直接依赖指向 node_modules/<name>；用绝对路径指向 .shu，避免相对路径 ../../.shu 依赖 cwd 或解析歧义
            const target_path = blk: {
                if (direct_set.contains(dep_name)) {
                    break :blk if (direct_set.contains(pkg_name))
                        std.fmt.allocPrint(a, "../../{s}", .{dep_name}) catch continue
                    else
                        std.fmt.allocPrint(a, "../../../{s}", .{dep_name}) catch continue;
                } else {
                    const name_at_ver = std.fmt.allocPrint(a, "{s}@{s}", .{ dep_name, dep_ver }) catch continue;
                    if (direct_set.contains(pkg_name)) {
                        // 从「直接依赖包」的 node_modules 链到项目 node_modules/.shu/<name>@<ver>：用绝对路径，确保任意 cwd 下都能解析
                        break :blk io_core.pathJoin(a, &.{ shu_dir, name_at_ver }) catch continue;
                    } else break :blk std.fmt.allocPrint(a, "../{s}", .{name_at_ver}) catch continue;
                }
            };
            const dep_link_path = io_core.pathJoin(a, &.{ nm_inside, dep_name }) catch continue;
            io_core.deleteFileAbsolute(dep_link_path) catch |err| if (err == error.IsDir) io_core.deleteTreeAbsolute(dep_link_path) catch {};
            const parent = io_core.pathDirname(dep_link_path) orelse continue;
            const link_name = io_core.pathBasename(dep_link_path);
            io_core.makePathAbsolute(parent) catch {};
            var dep_dir = io_core.openDirAbsolute(parent, .{}) catch continue;
            dep_dir.symLink(target_path, link_name, .{ .is_directory = true }) catch |e| {
                if (@import("builtin").os.tag == .windows) {
                    logInstallFailure("[shu install] symlink failed (Windows): enable Developer Mode or run as Administrator. dep={s} error={s}\n", .{ dep_name, @errorName(e) });
                }
            };
            dep_dir.close();
        }
    }

    if (reporter) |r| {
        // add 流程下仅当本次无新安装（already up to date）时才调用 onPackageAdded，避免与 onPackage 已打印的重复且导致多出一空行
        if (added_names) |names| {
            if (r.onPackageAdded) |cb| {
                if (new_index == 0) {
                    for (names) |name| {
                        if (resolved.get(name)) |ver| cb(r.ctx, name, ver);
                    }
                }
            }
        }
        if (r.onDone) |cb| {
            // add 流程：统计只显示本次添加的包数，如 "1 package installed"
            const done_total = if (added_names) |names| names.len else total_count;
            const done_new = if (added_names) |names| names.len else new_index;
            const elapsed_ms = std.time.milliTimestamp() - install_start_ms;
            cb(r.ctx, done_total, done_new, elapsed_ms);
        }
    }
    try lockfile.saveFromResolved(allocator, lock_path, resolved, &deps_of, &jsr_packages);
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

/// 返回 .shu 下某传递依赖包的目录路径：shu_dir/<name>@<version>（如 @scope/pkg 则 shu_dir/@scope/pkg@1.0.0）。调用方 free。
fn storePkgDir(allocator: std.mem.Allocator, shu_dir: []const u8, name: []const u8, version: []const u8) ![]const u8 {
    return io_core.pathJoin(allocator, &.{ shu_dir, try std.fmt.allocPrint(allocator, "{s}@{s}", .{ name, version }) });
}

/// 从包目录 pkg_dir 的 package.json 解析 "bin" 字段，为每个 bin 在 node_modules/.bin 下创建符号链接。
/// bin 为字符串时视为单一条目，命令名为 pkg_name；为对象时键为命令名、值为相对路径。
/// 使用相对目标（../<pkg_name>/<path>），与 npm 一致。失败仅打日志，不中断 install。
fn linkPackageBins(
    allocator: std.mem.Allocator,
    bin_dir: []const u8,
    pkg_name: []const u8,
    pkg_dir: []const u8,
) void {
    const pkg_json_path = io_core.pathJoin(allocator, &.{ pkg_dir, "package.json" }) catch return;
    defer allocator.free(pkg_json_path);
    var f = io_core.openFileAbsolute(pkg_json_path, .{}) catch return;
    defer f.close();
    const raw = f.readToEndAlloc(allocator, std.math.maxInt(usize)) catch return;
    defer allocator.free(raw);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{ .allocate = .alloc_always }) catch return;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return;
    const bin_value = root.object.get("bin") orelse return;
    var bin_name: []const u8 = undefined;
    var rel_path: []const u8 = undefined;
    switch (bin_value) {
        .string => |s| {
            bin_name = pkg_name;
            rel_path = s;
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                bin_name = entry.key_ptr.*;
                const val = entry.value_ptr.*;
                if (val != .string) continue;
                rel_path = val.string;
                linkOneBin(allocator, bin_dir, pkg_dir, bin_name, rel_path) catch |e| {
                    if (@import("builtin").os.tag == .windows) {
                        logInstallFailure("[shu install] .bin link failed (Windows): {s} -> {s} error={s}\n", .{ bin_name, rel_path, @errorName(e) });
                    }
                };
            }
            return;
        },
        else => return,
    }
    linkOneBin(allocator, bin_dir, pkg_dir, bin_name, rel_path) catch |e| {
        if (@import("builtin").os.tag == .windows) {
            logInstallFailure("[shu install] .bin link failed (Windows): {s} -> {s} error={s}\n", .{ bin_name, rel_path, @errorName(e) });
        }
    };
}

/// 在 bin_dir 下创建一条 bin 链接：bin_dir/<bin_name> -> pkg_dir/<normalized_path>。
/// target 须为绝对路径，否则 io_core.symLinkAbsolute 会断言失败。
/// Unix：创建后对目标脚本 fchmod +x，使 exec .bin/<name> 时 shebang 能执行。
/// Windows：无「可执行位」概念，不需 chmod；额外写 .bin/<bin_name>.cmd 包装脚本（@node "target" %*），
/// 以便在 cmd 中直接运行 <name> 时能正确执行。
fn linkOneBin(
    allocator: std.mem.Allocator,
    bin_dir: []const u8,
    pkg_dir: []const u8,
    bin_name: []const u8,
    rel_path: []const u8,
) !void {
    const normalized = std.mem.trim(u8, rel_path, "./");
    const target_absolute = io_core.pathJoin(allocator, &.{ pkg_dir, normalized }) catch return error.OutOfMemory;
    defer allocator.free(target_absolute);
    const link_path = io_core.pathJoin(allocator, &.{ bin_dir, bin_name }) catch return error.OutOfMemory;
    defer allocator.free(link_path);
    io_core.deleteFileAbsolute(link_path) catch |err| if (err == error.IsDir) io_core.deleteTreeAbsolute(link_path) catch {};
    io_core.symLinkAbsolute(target_absolute, link_path, .{}) catch return;
    const is_windows = @import("builtin").os.tag == .windows;
    if (is_windows) {
        // Windows：写 .cmd 包装，使 cmd 中运行 <name> 时执行 node target %*
        const cmd_path = std.fmt.allocPrint(allocator, "{s}.cmd", .{link_path}) catch return;
        defer allocator.free(cmd_path);
        io_core.deleteFileAbsolute(cmd_path) catch {};
        var f = io_core.createFileAbsolute(cmd_path, .{}) catch return;
        defer f.close();
        // @echo off & node "target_absolute" %*
        var buf: [4096]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "@echo off\r\nnode \"{s}\" %*\r\n", .{target_absolute}) catch return;
        f.writeAll(line) catch return;
    } else {
        // Unix：对目标脚本加可执行权限
        var f = io_core.openFileAbsolute(target_absolute, .{}) catch return;
        defer f.close();
        std.posix.fchmod(f.handle, 0o755) catch {};
    }
}

/// 首次解压失败时无条件打印一次：包名、错误、路径、文件大小、前 16 字节（hex）。便于自动定位 tgz 是否为 gzip（1f 8b）或误写为 br 等。用原子标记保证只打印一次（与 first_error 谁先无关）。
fn logFirstTarballExtractFailure(ctx: *const NpmInstallWorkerCtx, tgz_path: []const u8, err: anyerror, name: []const u8, version: []const u8) void {
    if (ctx.first_extract_failure_logged.swap(true, .monotonic)) return;
    logInstallFailure("[shu install] first tarball extract failure: {s}@{s} error={s}\n", .{ name, version, @errorName(err) });
    var f = io_core.openFileAbsolute(tgz_path, .{}) catch {
        logInstallFailure("[shu install] first tarball extract failure: {s}@{s} error={s} path={s} (file not openable)\n", .{ name, version, @errorName(err), tgz_path });
        return;
    };
    defer f.close();
    var buf: [16]u8 = undefined;
    const n = f.read(buf[0..]) catch 0;
    var hex: [64]u8 = undefined;
    for (buf[0..n], 0..) |b, i| {
        _ = std.fmt.bufPrint(hex[i * 3 ..][0..3], "{x:0>2} ", .{b}) catch break;
    }
    const stat = f.stat() catch return;
    logInstallFailure("[shu install] first tarball extract failure: {s}@{s} error={s} path={s} size={d} first_bytes=[{s}]\n", .{
        name,
        version,
        @errorName(err),
        tgz_path,
        stat.size,
        hex[0..@min(n * 3, 48)],
    });
}

/// 当 SHU_DEBUG_TGZ 非空时，在 extractRawTarFromSlice 返回 InvalidGzip 前调用，打印解压后 content 长度与首个 tar 条目的名字，用于区分「截断」与「无 package/」。
fn logInvalidTarContent(tgz_path: []const u8, content: []const u8, reason: []const u8) void {
    if (std.posix.getenv("SHU_DEBUG_TGZ")) |_| {} else return;
    var name_buf: [120]u8 = undefined;
    var name_slice: []const u8 = "?";
    if (content.len >= 512) {
        const name_end = std.mem.indexOfScalar(u8, content[0..100], 0) orelse 100;
        if (name_end > 0) {
            name_slice = content[0..name_end];
        }
        const ustar = content[257..262];
        if (ustar.len >= 5 and ustar[0] == 'u' and ustar[1] == 's' and ustar[2] == 't' and ustar[3] == 'a' and ustar[4] == 'r') {
            const prefix_end = std.mem.indexOfScalar(u8, content[345..500], 0) orelse 155;
            const prefix_slice = content[345..][0..prefix_end];
            var fbs = std.io.fixedBufferStream(&name_buf);
            if (prefix_slice.len > 0) {
                fbs.writer().print("{s}/{s}", .{ prefix_slice, name_slice }) catch {};
            } else {
                fbs.writer().print("{s}", .{name_slice}) catch {};
            }
            name_slice = fbs.getWritten();
        }
    }
    logInstallFailure("[shu tgz debug] InvalidGzip reason={s} path={s} decompressed_len={d} first_entry={s}\n", .{
        reason,
        tgz_path,
        content.len,
        name_slice,
    });
}

/// 当 SHU_DEBUG_TGZ 非空时，解压某步骤失败则向 stderr 打印步骤、路径与错误，便于定位 TarballExtractFailed 等。
fn logExtractFailureStep(tgz_path: []const u8, step: []const u8, path_or_rel: []const u8, err: anyerror) void {
    if (std.posix.getenv("SHU_DEBUG_TGZ")) |_| {} else return;
    logInstallFailure("[shu tgz debug] step={s} path={s} target={s} error={s}\n", .{
        step,
        tgz_path,
        path_or_rel,
        @errorName(err),
    });
}

/// 当 SHU_DEBUG_TGZ 非空时，解压失败则向 stderr 打印 tgz 路径、错误、文件大小及前 16 字节（hex）。
fn debugLogTarballExtractFailed(tgz_path: []const u8, err: anyerror) void {
    if (std.posix.getenv("SHU_DEBUG_TGZ")) |_| {} else return;
    var f = io_core.openFileAbsolute(tgz_path, .{}) catch {
        logInstallFailure("[shu tgz debug] path={s} error={s} (could not open file)\n", .{ tgz_path, @errorName(err) });
        return;
    };
    defer f.close();
    var buf: [16]u8 = undefined;
    const n = f.read(buf[0..]) catch 0;
    var hex: [64]u8 = undefined;
    for (buf[0..n], 0..) |b, i| {
        _ = std.fmt.bufPrint(hex[i * 3 ..][0..3], "{x:0>2} ", .{b}) catch break;
    }
    const stat = f.stat() catch return;
    logInstallFailure("[shu tgz debug] path={s} error={s} size={d} first_bytes={s}\n", .{
        tgz_path,
        @errorName(err),
        stat.size,
        hex[0..@min(n * 3, 48)],
    });
}

/// 从内存中的 raw tar 切片解析并解出「单层顶层目录」下内容到 dest_dir。与 extractTarballToDir 的 tar 解析逻辑一致，用于服务端返回未压缩 tar（Accept-Encoding: identity）时。
/// 兼容任意单层顶层目录：从第一条条目的路径推断前缀（如 package/、ws/、foo/ 等），只解压该前缀下的文件到 dest_dir。
fn extractRawTarFromSlice(tgz_path: []const u8, content: []const u8, dest_dir: []const u8) !void {
    try io_core.makePathAbsolute(dest_dir);
    // §3.0: 目录打开经 io_core，与模块约定一致
    var dest_dir_handle = io_core.openDirAbsolute(dest_dir, .{}) catch |e| {
        logExtractFailureStep(tgz_path, "open_dest_dir", dest_dir, e);
        return error.TarballExtractFailed;
    };
    defer dest_dir_handle.close();
    var wrote_any_file = false;
    var offset: usize = 0;
    var prefix_buf: [256]u8 = undefined;
    var prefix: []const u8 = "";
    var prefix_len: usize = 0;
    while (offset + 512 <= content.len) {
        const header_buf = content[offset..][0..512];
        offset += 512;
        const name_end = std.mem.indexOfScalar(u8, header_buf[0..100], 0) orelse 100;
        const name_slice = header_buf[0..name_end];
        if (name_slice.len == 0) {
            if (!wrote_any_file) {
                logInvalidTarContent(tgz_path, content, "empty_block_no_package");
                return error.InvalidGzip;
            }
            break;
        }
        const full_name = blk: {
            const ustar_magic = header_buf[257..262];
            if (ustar_magic[0] == 'u' and ustar_magic[1] == 's' and ustar_magic[2] == 't' and ustar_magic[3] == 'a' and ustar_magic[4] == 'r') {
                const prefix_end = std.mem.indexOfScalar(u8, header_buf[345..500], 0) orelse 155;
                const prefix_slice = header_buf[345..][0..prefix_end];
                if (prefix_slice.len > 0) {
                    var buf: [256]u8 = undefined;
                    var fbs = std.io.fixedBufferStream(&buf);
                    fbs.writer().print("{s}/{s}", .{ prefix_slice, name_slice }) catch break :blk name_slice;
                    break :blk fbs.getWritten();
                }
            }
            break :blk name_slice;
        };
        var size: usize = 0;
        for (header_buf[124..136]) |c| {
            if (c >= '0' and c <= '7') size = size * 8 + (c - '0');
        }
        const typeflag = if (header_buf.len > 156) header_buf[156] else '0';
        const block_rounded = (size + 511) / 512 * 512;
        if (offset + block_rounded > content.len) {
            logInvalidTarContent(tgz_path, content, "truncated");
            return error.InvalidGzip;
        }
        // 从第一条条目推断顶层目录前缀（package/、ws/、任意单层目录），后续只接受此前缀下的条目
        if (prefix_len == 0) {
            const slash = std.mem.indexOfScalar(u8, full_name, '/');
            if (slash) |s| {
                if (s + 1 <= prefix_buf.len) {
                    @memcpy(prefix_buf[0..s], full_name[0..s]);
                    prefix_buf[s] = '/';
                    prefix = prefix_buf[0 .. s + 1];
                    prefix_len = s + 1;
                }
            } else if (full_name.len + 1 <= prefix_buf.len) {
                @memcpy(prefix_buf[0..full_name.len], full_name);
                prefix_buf[full_name.len] = '/';
                prefix = prefix_buf[0 .. full_name.len + 1];
                prefix_len = full_name.len + 1;
            }
        }
        const under_prefix = prefix_len > 0 and std.mem.startsWith(u8, full_name, prefix);
        if (!under_prefix) {
            offset += block_rounded;
            continue;
        }
        var rel_full = full_name[prefix_len..];
        // 兼容 USTAR 双层 package（如 prefix=package/package、name=package.json → package/package/package.json）：再剥掉一层 package/
        if (std.mem.startsWith(u8, rel_full, "package/")) rel_full = rel_full["package/".len..];
        const rel_null = std.mem.indexOfScalar(u8, rel_full, 0) orelse rel_full.len;
        const rel = rel_full[0..rel_null];
        if (rel.len == 0) {
            offset += block_rounded;
            continue;
        }
        if (typeflag == '5') {
            dest_dir_handle.makePath(rel) catch {};
            offset += block_rounded;
        } else {
            if (std.mem.indexOf(u8, rel, "..")) |_| {
                offset += block_rounded;
                continue;
            }
            if (io_core.pathDirname(rel)) |rel_dir| if (rel_dir.len > 0) dest_dir_handle.makePath(rel_dir) catch {};
            const out_file = dest_dir_handle.createFile(rel, .{}) catch |e| {
                logExtractFailureStep(tgz_path, "create_file", rel, e);
                offset += block_rounded;
                return e;
            };
            defer out_file.close();
            wrote_any_file = true;
            if (size > 0) {
                try out_file.writeAll(content[offset..][0..size]);
            }
            offset += block_rounded;
        }
    }
    if (!wrote_any_file) {
        logInvalidTarContent(tgz_path, content, "no_package_entry");
        return error.InvalidGzip;
    }
}

/// 将 .tgz 解压到指定目录 dest_dir（tgz 内 package/ 前缀下的内容写入 dest_dir）。使用 io_core.mapFileReadOnly 映射 tgz，gzip 解压后流式解析 tar。
/// 通过 io_core.openDirAbsolute(dest_dir) + Dir.createFile/makePath 写文件。
/// allocator 用于 gzip 一次性解压的临时缓冲；若由安装 worker 调用，建议传入该 worker 的 Arena 或独立 allocator。
fn extractTarballToDir(allocator: std.mem.Allocator, tgz_path: []const u8, dest_dir: []const u8) !void {
    var mapped = io_core.mapFileReadOnly(tgz_path) catch |e| {
        debugLogTarballExtractFailed(tgz_path, e);
        return e;
    };
    defer mapped.deinit();
    const tgz_content = mapped.slice();
    if (tgz_content.len < 10) {
        debugLogTarballExtractFailed(tgz_path, error.InvalidGzip);
        return error.InvalidGzip;
    }
    // 若非 gzip magic：视为未压缩 tar（如 Accept-Encoding: identity 时服务端返回的 body），直接按 raw tar 解析
    if (tgz_content[0] != 0x1f or tgz_content[1] != 0x8b) {
        return extractRawTarFromSlice(tgz_path, tgz_content, dest_dir);
    }

    // 先尝试一次性 gzip 解压再按 raw tar 解析，兼容部分镜像（如 npmmirror）的 gzip 与 std.compress.flate 流式解压不兼容导致 InvalidGzip 的情况
    if (shu_zlib.decompressGzip(allocator, tgz_content)) |tar_bytes| {
        defer allocator.free(tar_bytes);
        if (tar_bytes.len > 0) {
            return extractRawTarFromSlice(tgz_path, tar_bytes, dest_dir);
        }
    } else |_| {}

    // 回退：进程内流式 gzip 解压（decode.zig 已支持多 member，此处仅作流式兜底）
    var in_reader = std.Io.Reader.fixed(tgz_content);
    var dec = std.compress.flate.Decompress.init(&in_reader, .gzip, &[0]u8{});

    try io_core.makePathAbsolute(dest_dir);
    // §3.0: 目录打开经 io_core
    var dest_dir_handle = io_core.openDirAbsolute(dest_dir, .{}) catch |e| {
        logExtractFailureStep(tgz_path, "open_dest_dir(stream)", dest_dir, e);
        return error.TarballExtractFailed;
    };
    defer dest_dir_handle.close();

    var header_buf: [512]u8 = undefined;
    var chunk: [8192]u8 = undefined;
    var wrote_any_file = false;
    var stream_prefix_buf: [256]u8 = undefined;
    var stream_prefix: []const u8 = "";
    var stream_prefix_len: usize = 0;

    while (true) {
        streamReadExactlyToBuffer(&dec, header_buf[0..512], &chunk) catch |e| {
            if (e == error.UnexpectedEof) break;
            logExtractFailureStep(tgz_path, "stream_read_header", dest_dir, e);
            return e;
        };
        const name_end = std.mem.indexOfScalar(u8, header_buf[0..100], 0) orelse 100;
        const name_slice = header_buf[0..name_end];
        if (name_slice.len == 0) {
            if (!wrote_any_file) {
                debugLogTarballExtractFailed(tgz_path, error.InvalidGzip);
                return error.InvalidGzip;
            }
            break;
        }

        // USTAR 格式（magic "ustar" 在 257-262）：完整路径 = prefix(345-499) + "/" + name(0-99)，否则仅 name
        const full_name = blk: {
            const ustar_magic = header_buf[257..262]; // "ustar\0"
            if (ustar_magic[0] == 'u' and ustar_magic[1] == 's' and ustar_magic[2] == 't' and ustar_magic[3] == 'a' and ustar_magic[4] == 'r') {
                const prefix_end = std.mem.indexOfScalar(u8, header_buf[345..500], 0) orelse 155;
                const prefix_slice = header_buf[345..][0..prefix_end];
                if (prefix_slice.len > 0) {
                    var buf: [256]u8 = undefined;
                    var fbs = std.io.fixedBufferStream(&buf);
                    fbs.writer().print("{s}/{s}", .{ prefix_slice, name_slice }) catch break :blk name_slice;
                    const written = fbs.getWritten();
                    break :blk written;
                }
            }
            break :blk name_slice;
        };

        var size: usize = 0;
        for (header_buf[124..136]) |c| {
            if (c >= '0' and c <= '7') size = size * 8 + (c - '0');
        }
        const typeflag = if (header_buf.len > 156) header_buf[156] else '0';

        const block_rounded = (size + 511) / 512 * 512;

        // 从第一条条目推断顶层目录前缀，与 extractRawTarFromSlice 一致，兼容任意单层顶层目录
        if (stream_prefix_len == 0) {
            const slash = std.mem.indexOfScalar(u8, full_name, '/');
            if (slash) |s| {
                if (s + 1 <= stream_prefix_buf.len) {
                    @memcpy(stream_prefix_buf[0..s], full_name[0..s]);
                    stream_prefix_buf[s] = '/';
                    stream_prefix = stream_prefix_buf[0 .. s + 1];
                    stream_prefix_len = s + 1;
                }
            } else if (full_name.len + 1 <= stream_prefix_buf.len) {
                @memcpy(stream_prefix_buf[0..full_name.len], full_name);
                stream_prefix_buf[full_name.len] = '/';
                stream_prefix = stream_prefix_buf[0 .. full_name.len + 1];
                stream_prefix_len = full_name.len + 1;
            }
        }
        const under_prefix = stream_prefix_len > 0 and std.mem.startsWith(u8, full_name, stream_prefix);
        if (!under_prefix) {
            try streamSkipExactly(&dec, block_rounded, &chunk);
            continue;
        }
        // 截断到首个 null，避免 name 域未以 0 结尾时产生错误文件名（如 package.json\x00...）
        var rel_full = full_name[stream_prefix_len..];
        // 兼容 USTAR 双层 package（同 extractRawTarFromSlice）：再剥掉一层 package/
        if (std.mem.startsWith(u8, rel_full, "package/")) rel_full = rel_full["package/".len..];
        const rel_null = std.mem.indexOfScalar(u8, rel_full, 0) orelse rel_full.len;
        const rel = rel_full[0..rel_null];
        if (rel.len == 0) {
            try streamSkipExactly(&dec, block_rounded, &chunk);
            continue;
        }

        if (typeflag == '5') {
            dest_dir_handle.makePath(rel) catch {};
            try streamSkipExactly(&dec, block_rounded, &chunk);
        } else {
            if (std.mem.indexOf(u8, rel, "..")) |_| {
                try streamSkipExactly(&dec, block_rounded, &chunk);
                continue;
            }
            if (io_core.pathDirname(rel)) |rel_dir| if (rel_dir.len > 0) dest_dir_handle.makePath(rel_dir) catch {};
            const out_file = dest_dir_handle.createFile(rel, .{}) catch |e| {
                logExtractFailureStep(tgz_path, "create_file(stream)", rel, e);
                try streamSkipExactly(&dec, block_rounded, &chunk);
                return e;
            };
            defer out_file.close();
            wrote_any_file = true;
            // 必须完整读出文件内容；失败则直接返回，避免流位置错位导致后续条目（如 package.json）解析错乱
            if (size > 0) {
                streamReadExactlyToFile(&dec, out_file, size, &chunk) catch |e| {
                    logExtractFailureStep(tgz_path, "stream_read_file", rel, e);
                    return e;
                };
            }
            const padding = block_rounded - size;
            if (padding > 0) {
                streamSkipExactly(&dec, padding, &chunk) catch |e| {
                    logExtractFailureStep(tgz_path, "stream_skip_padding", rel, e);
                    return e;
                };
            }
        }
    }
    if (!wrote_any_file) {
        debugLogTarballExtractFailed(tgz_path, error.InvalidGzip);
        return error.InvalidGzip;
    }
}

// -----------------------------------------------------------------------------
// 单元测试：最小 tgz 解压后须存在 package.json
// -----------------------------------------------------------------------------
test "extractTarballToDir: minimal tgz produces package.json" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dest_dir_path = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dest_dir_path);
    // 最小 tgz：仅含 package/package.json 内容 "{}"，由 tar -cvf - package | gzip -n 生成后 base64
    const minimal_tgz_b64 =
        "H4sIAAAAAAAAA+3RMQ6CMBiG4c6eoifQllI4T2MQVILEShyId7cRGDSEwdA4+D4dvpA07Vf+1u3Prix2IiKlVG6tfGU2ZDDl8KFtWCYxOtdSaZNbI6SNWWrS+Zu7hiq+6uqja8pDN7/vXhVFvXDO+6NkjKoxtOP8x9ye/KVZ+47wP7I0XZq/+Zh/lphESLV2kTl/Pv/+sfl1BQAAAAAAAAAAAAAAAABfegKFU2cHACgAAA==";
    var tgz_bytes = try std.base64.standard.Decoder.calcSizeForSlice(minimal_tgz_b64);
    const decoded = try a.alloc(u8, tgz_bytes);
    defer a.free(decoded);
    tgz_bytes = try std.base64.standard.Decoder.decode(decoded, minimal_tgz_b64);
    const tgz_path = try std.fmt.allocPrint(a, "{s}/minimal.tgz", .{dest_dir_path});
    defer a.free(tgz_path);
    try tmp.dir.writeFile("minimal.tgz", decoded[0..tgz_bytes]);
    const extract_dest = try io_core.pathJoin(a, &.{ dest_dir_path, "out" });
    defer a.free(extract_dest);
    try io_core.makePathAbsolute(extract_dest);
    try extractTarballToDir(a, tgz_path, extract_dest);
    const pkg_json = try io_core.pathJoin(a, &.{ extract_dest, "package.json" });
    defer a.free(pkg_json);
    try std.testing.expect(io_core.accessAbsolute(pkg_json, .{}) == .ok);
    const content = try tmp.dir.readFileAlloc(a, "out/package.json", 64);
    defer a.free(content);
    try std.testing.expect(std.mem.eql(u8, std.mem.trim(u8, content, " \n"), "{}"));
}

// 可选：若环境变量 SHU_TGZ_PATH 指向某 .tgz 文件，解压并断言存在 package.json（用于调试真实 npm tgz）。
test "extractTarballToDir: real tgz when SHU_TGZ_PATH set" {
    const path = std.posix.getenv("SHU_TGZ_PATH") orelse return;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dest = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dest);
    const out_dir = try io_core.pathJoin(a, &.{ dest, "out" });
    defer a.free(out_dir);
    try io_core.makePathAbsolute(out_dir);
    try extractTarballToDir(a, path, out_dir);
    const pkg_json = try io_core.pathJoin(a, &.{ out_dir, "package.json" });
    defer a.free(pkg_json);
    try std.testing.expect(io_core.accessAbsolute(pkg_json, .{}) == .ok);
}
