// 安装与缓存：根据 manifest 与 lockfile 将依赖从缓存解压到 node_modules；未命中则从 registry 下载后写入缓存并解压；安装完成后写回 shu.lock
// 参考：docs/PACKAGE_DESIGN.md §4、§7
// 文件/目录与路径经 io_core（§3.0）；解压 tgz 用 libs_io.mapFileReadOnly

const std = @import("std");
const errors = @import("errors");
const libs_process = @import("libs_process");

/// 将格式化内容直接 write(2, ...) 到 stderr；前导 \\n 避免与进度条（\\r 同行刷新）挤在同一行或被覆盖。Zig 0.16 用 std.fmt.bufPrint + std.c.write。
fn logInstallFailure(comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, "\n" ++ fmt, args) catch return;
    _ = std.c.write(2, slice.ptr, slice.len);
}
const libs_io = @import("libs_io");
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

/// 优化 C：lockfile 是否已包含 manifest 全部直接依赖及传递闭包；若 true 可跳过整段解析循环。deps_of 为 Unmanaged（01 §1.2）。
fn canSkipResolution(
    allocator: std.mem.Allocator,
    direct_set: std.StringArrayHashMap(void),
    resolved: std.StringArrayHashMap([]const u8),
    deps_of: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)),
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
        const deps = deps_of.getPtr(name) orelse return false;
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

/// 解析/安装阶段 worker 或并发数的**静态上限**；实际使用上限在运行时由 getPackageConcurrencyCap()
/// 根据 CPU 核心数计算（见下），避免单核机开过多线程。网络速度、当前 I/O 状态暂无自动探测，可后续通过环境变量或配置扩展。
/// 解析阶段 JSR 并发 worker 数；与 npm 对齐，提高以压榨网络（解析为纯 I/O，32 可更好饱和带宽）
const JSR_RESOLVE_MAX_WORKERS = 32;

/// 每批请求数：超过后重建 Client，避免同一连接复用过多导致服务端关闭或返回非 JSON（常见于「最后一包」报 JsrMetaNoJsonObject）。与 CPU 无关，保持常量。
const JSR_RESOLVE_CLIENT_REUSE_LIMIT = 32;

/// 解析阶段 JSR 仅对「可能瞬断」的错误重试，避免永久性错误（404、解析失败等）上白等；重试次数与退避时间从简以不拖慢正常安装。
const JSR_RESOLVE_RETRIES = 2;
/// 第 2 次重试前等待的纳秒数（0.2s），仅对空响应/非 JSON 等瞬断错误重试时用。
const JSR_RESOLVE_RETRY_DELAY_NS: u64 = 200_000_000;

/// npm 解析阶段每层并发 worker 数；与 JSR 对齐，解析为纯 I/O 故用 32 更好饱和网络，实际上限由 getConcurrencyCapForRequests 决定。
const NPM_RESOLVE_MAX_WORKERS = 32;

/// JSR 并发解析单条结果：version/imports 由 worker 用本批 Arena 分配，主线程合并后 Arena deinit 统一释放（00 §1.2）。
const JsrResolveResult = struct {
    version: []const u8 = "",
    imports: ?[]const jsr.DenoImportDep = null,
    err: ?anyerror = null,
};

/// 单条 JSR 待解析项（仅 name/spec，指针指向 to_process 内有效内存）
const JsrResolveItem = struct { name: []const u8, spec: []const u8 };

/// Worker 线程上下文：items 与 results 在 join 前有效；next_index 原子递增取任务下标。allocator 为 per-batch Arena，join 后主线程 deinit（00 §1.2）。
/// resolving_progress 非 null 时 worker 每完成一个包即更新 count/name，与 Installing 一致。
const JsrResolveWorkerCtx = struct {
    items: []const JsrResolveItem,
    results: [*]JsrResolveResult,
    next_index: *std.atomic.Value(usize),
    allocator: std.mem.Allocator,
    resolving_progress: ?*ResolvingProgress = null,
};

/// npm 并发解析单条结果：version、tarball_url、dependencies 由 worker 用本批 Arena 分配，主线程合并后 Arena deinit 统一释放（00 §1.2）。
const NpmResolveResult = struct {
    version: ?[]const u8 = null,
    tarball_url: ?[]const u8 = null,
    dependencies: ?std.StringArrayHashMap([]const u8) = null,
    err: ?anyerror = null,
};

/// 单条 npm 待解析项：name/spec/display_name 指向 to_process 内有效内存；registry_url 由主线程分配并在 join 后统一 free。
const NpmResolveItem = struct { name: []const u8, spec: []const u8, display_name: ?[]const u8, registry_url: []const u8 };

/// Worker 上下文：items 与 results 在 join 前有效；next_index 原子递增取任务下标。allocator 为 per-batch Arena，join 后主线程 deinit（00 §1.2）。
/// resolving_progress 非 null 时 worker 每完成一个包即更新 count/name，供 CLI 进度线程轮询（与 Installing 一致）。
const NpmResolveWorkerCtx = struct {
    items: []const NpmResolveItem,
    results: [*]NpmResolveResult,
    next_index: *std.atomic.Value(usize),
    allocator: std.mem.Allocator,
    resolving_progress: ?*ResolvingProgress = null,
};

/// npm 解析 worker：每 worker 持有一个 Client，循环取任务并调用 resolveVersionTarballAndDeps，结果写入 results[i]。领到任务后立即更新 resolving_progress.count（claim 时计数），保证 count 与 total 一致不缺口。
fn npmResolveWorker(ctx: *const NpmResolveWorkerCtx) void {
    const a = ctx.allocator;
    const io = libs_process.getProcessIo() orelse return;
    var client = std.http.Client{ .allocator = a, .io = io };
    defer client.deinit();
    while (true) {
        const i = ctx.next_index.fetchAdd(1, .monotonic);
        if (i >= ctx.items.len) return;
        const item = ctx.items[i];
        if (ctx.resolving_progress) |p| {
            _ = p.count.fetchAdd(1, .monotonic);
            p.name_mutex.lock(io) catch {};
            const name_slice = item.display_name orelse item.name;
            const copy_len = @min(name_slice.len, 63);
            @memcpy(p.name_buf[0..copy_len], name_slice[0..copy_len]);
            p.name_buf[copy_len] = 0;
            p.name_len.store(copy_len, .monotonic);
            p.name_mutex.unlock(io);
        }
        const r = registry.resolveVersionTarballAndDeps(a, item.registry_url, item.name, item.spec, &client) catch |e| {
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
    mutex: std.Io.Mutex = std.Io.Mutex.init,
};

/// JSR 安装 worker 上下文：tasks/results 在 join 前有效；pool 共享。io 由主进程创建并传入（每 worker 一个），供 downloadPackageToDir 与 mutex/sleep。
const JsrInstallWorkerCtx = struct {
    tasks: []const JsrInstallTask,
    results: [*]?anyerror,
    next_index: *std.atomic.Value(usize),
    pool: *jsr.JsrDownloadPool,
    allocator: std.mem.Allocator,
    first_error: *?anyerror,
    first_error_mutex: *std.Io.Mutex,
    error_detail: ?*InstallErrorDetail,
    main_allocator: std.mem.Allocator,
    io: std.Io,
    install_completed_count: ?*std.atomic.Value(usize) = null,
    last_completed_name: ?*LastCompletedName = null,
};

/// JSR 安装 worker：使用主进程传入的 ctx.io，循环取任务并调用 downloadPackageToDir。
fn jsrInstallWorker(ctx: *const JsrInstallWorkerCtx) void {
    const io = ctx.io;
    while (true) {
        const i = ctx.next_index.fetchAdd(1, .monotonic);
        if (i >= ctx.tasks.len) return;
        const task = ctx.tasks[i];
        var last_err: anyerror = undefined;
        var ok = false;
        for (0..INSTALL_NETWORK_RETRIES) |ri| {
            if (ri > 0) std.Io.sleep(io, std.Io.Duration.fromNanoseconds(INSTALL_NETWORK_RETRY_DELAYS_NS[ri - 1]), .awake) catch {};
            jsr.downloadPackageToDir(ctx.allocator, ctx.pool, task.name, task.version, task.pkg_dest, io) catch |e| {
                last_err = e;
                continue;
            };
            ok = true;
            break;
        }
        if (!ok) {
            ctx.results[i] = last_err;
            ctx.first_error_mutex.lock(io) catch return;
            defer ctx.first_error_mutex.unlock(io);
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
    const io = libs_process.getProcessIo() orelse return;
    ln.mutex.lock(io) catch return;
    defer ln.mutex.unlock(io);
    const n = @min(name.len, ln.buf.len - 1);
    if (n > 0) {
        @memcpy(ln.buf[0..n], name[0..n]);
        ln.buf[n] = 0;
    }
    ln.len = n;
}

/// npm 安装 worker 上下文：tasks/results 在 join 前有效；next_index 原子取任务下标；resolved_tarball_urls 只读。io 由主进程创建并传入（每 worker 一个）。
const NpmInstallWorkerCtx = struct {
    tasks: []const NpmInstallTask,
    results: [*]?anyerror,
    next_index: *std.atomic.Value(usize),
    cache_root: []const u8,
    resolved_tarball_urls: *const std.StringArrayHashMap([]const u8),
    first_error: *?anyerror,
    first_error_mutex: *std.Io.Mutex,
    first_extract_failure_logged: *std.atomic.Value(bool),
    error_detail: ?*InstallErrorDetail,
    main_allocator: std.mem.Allocator,
    worker_id: usize,
    allocator: std.mem.Allocator,
    io: std.Io,
    install_completed_count: ?*std.atomic.Value(usize) = null,
    last_completed_name: ?*LastCompletedName = null,
};

/// npm 安装 worker：使用主进程传入的 ctx.io，持有一个 std.http.Client 和独立临时文件路径；取任务后查缓存→未命中则下载→写缓存→解压。
fn npmInstallWorker(ctx: *const NpmInstallWorkerCtx) void {
    const a = ctx.allocator;
    const io = ctx.io;
    var zig_client = std.http.Client{ .allocator = a, .io = io };
    defer zig_client.deinit();
    const temp_tgz = std.fmt.allocPrint(a, "{s}/.tmp-download-{d}.tgz", .{ ctx.cache_root, ctx.worker_id }) catch return;
    // Arena：不在此处 free，主线程 deinit 时统一释放
    while (true) {
        const i = ctx.next_index.fetchAdd(1, .monotonic);
        if (i >= ctx.tasks.len) return;
        const task = ctx.tasks[i];
        const key = cache.cacheKey(a, task.registry_host, task.name, task.version) catch |e| {
            ctx.results[i] = e;
            setFirstError(ctx, e, task.name, task.version);
            continue;
        };
        const cache_dir_path = cache.getCachedPackageDirPath(a, ctx.cache_root, key) catch |e| {
            ctx.results[i] = e;
            setFirstError(ctx, e, task.name, task.version);
            continue;
        };
        var invalid_gzip_retries: u32 = 0;
        retry_extract: while (invalid_gzip_retries < 2) : (invalid_gzip_retries += 1) {
            if (cache.getCachedPackageDir(a, ctx.cache_root, key)) |hit_dir| {
                if (libs_io.pathDirname(task.pkg_dest)) |parent| libs_io.makePathAbsolute(parent) catch {};
                var link_target_buf: [libs_io.max_path_bytes]u8 = undefined;
                const link_target = libs_io.realpath(hit_dir, &link_target_buf) catch hit_dir;
                libs_io.symLinkAbsolute(link_target, task.pkg_dest, .{}) catch |e| {
                    ctx.results[i] = e;
                    setFirstError(ctx, e, task.name, task.version);
                };
                if (ctx.install_completed_count) |c| _ = c.fetchAdd(1, .monotonic);
                if (ctx.last_completed_name) |ln| setLastCompletedName(ln, task.name);
                break :retry_extract;
            }
            const turl_opt = ctx.resolved_tarball_urls.get(task.name);
            const turl = turl_opt orelse blk: {
                const u = registry.buildTarballUrl(a, task.registry_url, task.name, task.version) catch |e| {
                    ctx.results[i] = e;
                    setFirstError(ctx, e, task.name, task.version);
                    if (ctx.install_completed_count) |c| _ = c.fetchAdd(1, .monotonic);
                    break :retry_extract;
                };
                break :blk u;
            };
            var download_ok = false;
            var last_dl_err: anyerror = undefined;
            for (0..INSTALL_NETWORK_RETRIES) |ri| {
                if (ri > 0) std.Io.sleep(io, std.Io.Duration.fromNanoseconds(INSTALL_NETWORK_RETRY_DELAYS_NS[ri - 1]), .awake) catch {};
                registry.downloadToPathWithClient(&zig_client, a, turl, temp_tgz) catch |e| {
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
            if (libs_io.pathDirname(cache_dir_path)) |parent| libs_io.makePathAbsolute(parent) catch {};
            libs_io.makeDirAbsolute(cache_dir_path) catch |e| {
                if (e == error.PathAlreadyExists) {
                    // 其他 worker 已创建或正在解压；轮询等待 package.json 出现后当作缓存命中建链
                    libs_io.deleteFileAbsolute(temp_tgz) catch {};
                    for (0..60) |_| {
                        if (cache.getCachedPackageDir(a, ctx.cache_root, key)) |hit_dir| {
                            if (libs_io.pathDirname(task.pkg_dest)) |parent_dest| libs_io.makePathAbsolute(parent_dest) catch {};
                            var link_target_buf: [libs_io.max_path_bytes]u8 = undefined;
                            const link_target = libs_io.realpath(hit_dir, &link_target_buf) catch hit_dir;
                            libs_io.symLinkAbsolute(link_target, task.pkg_dest, .{}) catch |sym_err| {
                                ctx.results[i] = sym_err;
                                setFirstError(ctx, sym_err, task.name, task.version);
                            };
                            if (ctx.install_completed_count) |c| _ = c.fetchAdd(1, .monotonic);
                            break :retry_extract;
                        }
                        std.Io.sleep(io, std.Io.Duration.fromNanoseconds(100_000_000), .awake) catch {}; // 100ms
                    }
                    ctx.results[i] = error.CacheDirBusy;
                    setFirstError(ctx, error.CacheDirBusy, task.name, task.version);
                } else {
                    ctx.results[i] = e;
                    setFirstError(ctx, e, task.name, task.version);
                }
                break :retry_extract;
            };
            extractTarballToDir(a, temp_tgz, cache_dir_path) catch |e| {
                logFirstTarballExtractFailure(ctx, temp_tgz, e, task.name, task.version);
                debugLogTarballExtractFailed(temp_tgz, e);
                libs_io.deleteFileAbsolute(temp_tgz) catch {};
                libs_io.deleteTreeAbsolute(a, cache_dir_path) catch {};
                if (e == error.InvalidGzip and invalid_gzip_retries < 1) {
                    continue :retry_extract;
                }
                ctx.results[i] = e;
                setFirstError(ctx, if (e == error.ReadFailed) error.TarballExtractFailed else e, task.name, task.version);
                if (ctx.install_completed_count) |c| _ = c.fetchAdd(1, .monotonic);
                if (ctx.last_completed_name) |ln| setLastCompletedName(ln, task.name);
                break :retry_extract;
            };
            libs_io.deleteFileAbsolute(temp_tgz) catch {};
            // 解压后必须存在 package.json，否则视为失败、不建链
            const pkg_json_path = libs_io.pathJoin(a, &.{ cache_dir_path, "package.json" }) catch |e| {
                ctx.results[i] = e;
                setFirstError(ctx, e, task.name, task.version);
                break :retry_extract;
            };
            libs_io.accessAbsolute(pkg_json_path, .{}) catch {
                // 解压未抛错但 package.json 不存在：打日志并列出解压出的前几项，便于判断是 tar 结构不符（无 package/）还是空解压
                logInstallFailure("[shu install] extract ok but package.json missing: {s}@{s} dir={s}\n", .{ task.name, task.version, cache_dir_path });
                var dir_opt = libs_io.openDirAbsolute(cache_dir_path, .{ .iterate = true }) catch null;
                if (dir_opt) |*dir_handle| {
                    const proc_io = libs_process.getProcessIo();
                    defer if (proc_io) |pi| dir_handle.close(pi);
                    var it = dir_handle.iterate();
                    var n: u32 = 0;
                    while (if (proc_io) |pi| it.next(pi) catch null else null) |entry| {
                        if (n >= 8) {
                            logInstallFailure("  ... (listing first 8 only)\n", .{});
                            break;
                        }
                        logInstallFailure("  entry: {s}\n", .{entry.name});
                        n += 1;
                    }
                    if (n == 0) logInstallFailure("  (no entries)\n", .{});
                } else logInstallFailure("  (could not list dir)\n", .{});
                libs_io.deleteTreeAbsolute(a, cache_dir_path) catch {};
                ctx.results[i] = error.TarballExtractFailed;
                setFirstError(ctx, error.TarballExtractFailed, task.name, task.version);
                if (ctx.install_completed_count) |c| _ = c.fetchAdd(1, .monotonic);
                if (ctx.last_completed_name) |ln| setLastCompletedName(ln, task.name);
                break :retry_extract;
            };
            if (libs_io.pathDirname(task.pkg_dest)) |parent_dest| libs_io.makePathAbsolute(parent_dest) catch {};
            var link_target_buf: [libs_io.max_path_bytes]u8 = undefined;
            const link_target = libs_io.realpath(cache_dir_path, &link_target_buf) catch cache_dir_path;
            libs_io.symLinkAbsolute(link_target, task.pkg_dest, .{}) catch |e| {
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
    const io = libs_process.getProcessIo() orelse return;
    ctx.first_error_mutex.lock(io) catch return;
    defer ctx.first_error_mutex.unlock(io);
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

/// 解析阶段 JSR 单条 worker：每 worker 持有一个 Client 复用连接，每 JSR_RESOLVE_CLIENT_REUSE_LIMIT 次请求重建 Client 避免长连接异常；结果写入 results[i]。使用 ctx.allocator（Arena），join 后主线程 deinit（00 §1.2）。
fn jsrResolveWorker(ctx: *const JsrResolveWorkerCtx) void {
    const a = ctx.allocator;
    const io = libs_process.getProcessIo() orelse return;
    while (true) {
        var client = std.http.Client{ .allocator = a, .io = io };
        var count: usize = 0;
        while (count < JSR_RESOLVE_CLIENT_REUSE_LIMIT) : (count += 1) {
            const i = ctx.next_index.fetchAdd(1, .monotonic);
            if (i >= ctx.items.len) {
                client.deinit();
                return;
            }
            const item = ctx.items[i];
            if (ctx.resolving_progress) |p| {
                _ = p.count.fetchAdd(1, .monotonic);
                p.name_mutex.lock(io) catch {};
                const copy_len = @min(item.name.len, 63);
                @memcpy(p.name_buf[0..copy_len], item.name[0..copy_len]);
                p.name_buf[copy_len] = 0;
                p.name_len.store(copy_len, .monotonic);
                p.name_mutex.unlock(io);
            }
            const jsr_spec = std.fmt.allocPrint(a, "jsr:{s}@{s}", .{ item.name, item.spec }) catch {
                ctx.results[i].err = error.OutOfMemory;
                client.deinit();
                return;
            };
            // 仅对可能瞬断的错误（空响应、非 JSON）重试一次，永久性错误不重试不等待，避免拖慢安装
            var last_err: anyerror = undefined;
            var version: []const u8 = undefined;
            var imports_list: ?std.ArrayList(jsr.DenoImportDep) = null;
            var resolved_ok = false;
            // 首轮用外层 client 复用连接（Keep-Alive），减少多包×2 请求的建连开销；重试时用新 client 避免坏连接
            var attempt: u32 = 0;
            var retry_client: ?std.http.Client = null;
            while (attempt < JSR_RESOLVE_RETRIES) : (attempt += 1) {
                if (attempt > 0) {
                    std.Io.sleep(io, std.Io.Duration.fromNanoseconds(JSR_RESOLVE_RETRY_DELAY_NS), .awake) catch {};
                    retry_client = std.http.Client{ .allocator = a, .io = io };
                }
                const req_client = if (retry_client) |*rc| rc else &client;
                const ver = jsr.resolveVersionFromMetaWithClient(req_client, a, jsr_spec) catch |e| {
                    last_err = e;
                    if (e != error.JsrMetaEmptyResponse and e != error.JsrMetaNoJsonObject) break;
                    continue;
                };
                const imports = jsr.fetchDenoJsonImportsFromRegistryOrJsoncWithClient(req_client, a, item.name, ver) catch |e| {
                    last_err = e;
                    continue;
                };
                version = ver;
                imports_list = imports;
                resolved_ok = true;
                break;
            }
            if (retry_client) |*rc| rc.deinit();
            if (!resolved_ok) {
                ctx.results[i].err = last_err;
                client.deinit();
                return;
            }
            if (imports_list) |*lst| {
                defer lst.deinit(a);
                const slice = a.dupe(jsr.DenoImportDep, lst.items) catch |e| {
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

/// 解析阶段可轮询进度：与 Installing 一致，由 worker 每完成一个包就更新 count/name，CLI 用独立线程每 80ms 轮询并重绘。
/// 若 reporter.resolving_progress 非 null，resolve worker 在完成时更新该结构，主线程不再在合并循环里调 onResolving。
pub const ResolvingProgress = struct {
    count: std.atomic.Value(usize) = .{ .raw = 0 },
    total: std.atomic.Value(usize) = .{ .raw = 0 },
    name_buf: [64]u8 = [_]u8{0} ** 64,
    name_len: std.atomic.Value(usize) = .{ .raw = 0 },
    name_mutex: std.Io.Mutex = std.Io.Mutex.init,
    resolving_done: std.atomic.Value(bool) = .{ .raw = false },
};

/// 安装进度回调：onResolving；onResolvingComplete；onStart；onProgress(current, total, last_completed_name) 由主线程每 80ms 轮询 install_completed_count 调用；onPackage；onDone。
/// resolving_progress 非 null 时由 resolve worker 更新、CLI 进度线程轮询绘制（与 Installing 同逻辑）。
pub const InstallReporter = struct {
    ctx: ?*anyopaque = null,
    resolving_progress: ?*ResolvingProgress = null,
    onResolving: ?*const fn (?*anyopaque, []const u8, usize, usize) void = null,
    /// 解析阶段曾输出过 onResolving 时，在 onStart 前调用一次；resolving_elapsed_ms 为解析阶段耗时（毫秒），供 CLI 在「Resolving (N) name」下输出 Resolving Xms。
    onResolvingComplete: ?*const fn (?*anyopaque, i64) void = null,
    onResolveFailure: ?*const fn (?*anyopaque) void = null,
    onStart: ?*const fn (?*anyopaque, usize) void = null,
    /// 下载阶段主线程轮询调用，更新进度条与第二行文案；total 与 onStart 一致；last_completed_name 为最近完成的一包名（主线程从共享缓冲读出，可为 null）。
    onProgress: ?*const fn (?*anyopaque, usize, usize, ?[]const u8) void = null,
    onPackage: ?*const fn (?*anyopaque, usize, usize, []const u8, []const u8, bool) void = null,
    /// elapsed_ms 由 install 从函数入口计时到 onDone 调用前，含 Resolving + Installing，供 CLI 显示真实总耗时
    onDone: ?*const fn (?*anyopaque, usize, usize, i64) void = null,
    /// 若非 null，install 在 onDone 前写入解析阶段耗时（毫秒），供 CLI 显示 Resolving/Installing 分段
    resolving_elapsed_ms: ?*i64 = null,
    /// 若非 null，install 在 onDone 前写入安装阶段耗时（毫秒）
    installing_elapsed_ms: ?*i64 = null,
    onPackageAdded: ?*const fn (?*anyopaque, []const u8, []const u8) void = null,
};

/// 根据 manifest 与 lockfile 安装依赖到 cwd/node_modules。若 added_names 非 null（add 流程），install 结束后对其中在 resolved 的包调用 reporter.onPackageAdded。
/// 内部使用 allocator 做临时分配，不向调用方返回需 free 的切片；reporter/error_detail 由调用方管理。
/// 若 error_detail 非 null，安装失败时会填入最后一次失败的 err 及包 name/version（由 allocator 分配，调用方 free name/version）。
/// §1.2：整次 install 用 Arena 分配临时路径与 key，仅 resolved map 的 key/value 用主 allocator（供 save 后释放），减少 alloc/free 与碎片。
/// 耗时统计：从本函数入口计时，onDone 时传入 elapsed_ms（含 Resolving + Installing），避免 CLI 只统计安装阶段造成虚假时间。
pub fn install(allocator: std.mem.Allocator, cwd: []const u8, reporter: ?*const InstallReporter, added_names: ?[]const []const u8, error_detail: ?*InstallErrorDetail) !void {
    // Zig 0.16：nanoTimestamp 已移除，用 std.Io.Clock.monotonic + untilNow 得 elapsed ns，再换算毫秒
    // Zig 0.16：Clock 用 .awake（单调、不含休眠时间）计量耗时
    const install_start_ts: ?std.Io.Clock.Timestamp = if (libs_process.getProcessIo()) |io|
        std.Io.Clock.Timestamp.now(io, .awake)
    else
        null;
    // 解析阶段耗时（纳秒）与是否记录；仅当本轮曾输出 onResolving 时在 onResolvingComplete 前写入，供 onDone 前填 reporter
    var resolving_elapsed_ns: i64 = 0;
    var resolving_phase_recorded: bool = false;
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
    var cwd_realpath_buf: [libs_io.max_path_bytes]u8 = undefined;
    const abs_cwd = blk: {
        const resolved = libs_io.realpath(cwd, &cwd_realpath_buf) catch break :blk cwd;
        break :blk try a.dupe(u8, resolved);
    };
    const lock_path = try libs_io.pathJoin(a, &.{ abs_cwd, lockfile.lock_file_name });
    var locked_result = lockfile.loadWithDeps(allocator, lock_path) catch return error.OutOfMemory;
    defer {
        var it = locked_result.packages.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            for (e.value_ptr.*.items) |p| allocator.free(p);
            e.value_ptr.*.deinit(allocator);
        }
        locked_result.packages.deinit(allocator);
        for (locked_result.root_dependencies.items) |p| allocator.free(p);
        locked_result.root_dependencies.deinit(allocator);
        for (locked_result.jsr_packages.items) |p| allocator.free(p);
        locked_result.jsr_packages.deinit(allocator);
    }

    const cache_root = try cache.getCacheRoot(a);
    // 解析为规范绝对路径，确保软链接目标为绝对路径，从任意 cwd 打开 node_modules 时都能正确解析
    var cache_root_real_buf: [libs_io.max_path_bytes]u8 = undefined;
    const cache_root_abs = libs_io.realpath(cache_root, &cache_root_real_buf) catch cache_root;
    const cache_root_abs_owned = try a.dupe(u8, cache_root_abs);
    // 安装前确保缓存根与 content 目录存在，避免解压到缓存目录时 FileNotFound
    try libs_io.makePathAbsolute(cache_root_abs_owned);
    const cache_content_dir = try libs_io.pathJoin(a, &.{ cache_root_abs_owned, "content" });
    try libs_io.makePathAbsolute(cache_content_dir);
    const nm_dir = try libs_io.pathJoin(a, &.{ abs_cwd, "node_modules" });
    libs_io.makePathAbsolute(nm_dir) catch {};

    var resolved = std.StringArrayHashMap([]const u8).init(allocator);
    defer {
        var free_it = resolved.iterator();
        while (free_it.next()) |e| {
            allocator.free(e.key_ptr.*);
            allocator.free(e.value_ptr.*);
        }
        resolved.deinit();
    }
    // 每个包名 -> 其 dependencies 的包名列表（用于在包内建 node_modules/<dep> 符号链接；直接依赖在 node_modules，传递依赖在 .shu）。Unmanaged（01 §1.2）。
    var deps_of = std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)){};
    defer {
        var it = deps_of.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            for (e.value_ptr.*.items) |p| allocator.free(p);
            e.value_ptr.*.deinit(allocator);
        }
        deps_of.deinit(allocator);
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
        var list = std.ArrayListUnmanaged([]const u8).initCapacity(allocator, e.value_ptr.*.items.len) catch return error.OutOfMemory;
        for (e.value_ptr.*.items) |dep_at_ver| {
            const dp = lockfile.parseNameAtVersion(allocator, dep_at_ver) catch continue;
            defer allocator.free(dp.name);
            defer allocator.free(dp.version);
            try list.append(allocator, try allocator.dupe(u8, dp.name));
        }
        const name_dup = try allocator.dupe(u8, parsed.name);
        const gop = try deps_of.getOrPut(allocator, name_dup);
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
    const shu_dir = try libs_io.pathJoin(a, &.{ nm_dir, ".shu" });
    libs_io.makePathAbsolute(shu_dir) catch {};

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
    var resolved_count: usize = 0; // 全局已解析包数，每完成一个（npm 或 JSR）加 1，供 onResolving 显示顺滑递增的进度
    var resolving_emitted = false; // 本轮是否输出过 onResolving，用于 onResolvingComplete 仅在有 Resolving 输出时调用
    const io = libs_process.getProcessIo() orelse return error.ProcessIoNotSet;
    var npm_resolve_client = std.http.Client{ .allocator = allocator, .io = io };
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

        // 按层（wave）处理：每层先收集待处理项，npm 并行、JSR 并发拉 version + deno.json，再合并结果并扩展 to_process
        // total_resolve_tasks 累加每波实际派发的解析任务数，与 worker 的 count 一致，结束时显示 521/521 而非 465/521。
        var total_resolve_tasks: usize = 0;
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

            // 本波任务数一次性写入 total，使 CLI 进度条尽快显示 40/50 等，不必等 count 追到 44 才看到 total 增加（各跑各的）
            const wave_tasks = npm_indices.items.len + jsr_indices.items.len;
            if (reporter) |r| if (r.resolving_progress) |p| {
                p.total.store(total_resolve_tasks + wave_tasks, .monotonic);
            };

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

            // 本波 npm + JSR 并行：先同时 spawn 两路，再统一 join、merge，避免「跑完 npm 再跑 JSR」的串行等待
            wave_parallel: {
                var npm_work_items: ?[]NpmResolveItem = null;
                var npm_results_slice: ?[]NpmResolveResult = null;
                var npm_threads = std.ArrayList(std.Thread).initCapacity(allocator, 0) catch |e| {
                    if (first_error == null) first_error = map_install_err(e);
                    break :wave_parallel;
                };
                defer npm_threads.deinit(allocator);
                var npm_arena = std.heap.ArenaAllocator.init(allocator);
                defer npm_arena.deinit();
                var npm_next = std.atomic.Value(usize).init(0);

                if (npm_indices.items.len > 0) {
                    const work_items = allocator.alloc(NpmResolveItem, npm_indices.items.len) catch |e| {
                        if (first_error == null) first_error = map_install_err(e);
                        break :wave_parallel;
                    };
                    npm_work_items = work_items;
                    for (npm_indices.items, work_items) |pi, *wi| {
                        const it = to_process.items[pi];
                        const reg_url_src = npmrc.getRegistryForPackage(a, cwd, it.name) catch try a.dupe(u8, REGISTRY_BASE_URL);
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
                        break :wave_parallel;
                    };
                    npm_results_slice = npm_results;
                    const n_workers = @min(npm_indices.items.len, libs_process.getConcurrencyCapForRequests(NPM_RESOLVE_MAX_WORKERS));
                    npm_threads.ensureTotalCapacity(allocator, n_workers) catch |e| {
                        if (first_error == null) first_error = map_install_err(e);
                        for (work_items) |wi| allocator.free(wi.registry_url);
                        allocator.free(npm_results);
                        break :wave_parallel;
                    };
                    const npm_ctx = NpmResolveWorkerCtx{
                        .items = work_items,
                        .results = npm_results.ptr,
                        .next_index = &npm_next,
                        .allocator = npm_arena.allocator(),
                        .resolving_progress = if (reporter) |r| r.resolving_progress else null,
                    };
                    for (0..n_workers) |_| {
                        npm_threads.append(allocator, std.Thread.spawn(.{}, npmResolveWorker, .{&npm_ctx}) catch |e2| {
                            if (first_error == null) first_error = map_install_err(e2);
                            for (npm_threads.items) |t| t.join();
                            for (work_items) |wi| allocator.free(wi.registry_url);
                            break :wave_parallel;
                        }) catch |e2| {
                            if (first_error == null) first_error = map_install_err(e2);
                            for (npm_threads.items) |t| t.join();
                            for (work_items) |wi| allocator.free(wi.registry_url);
                            break :wave_parallel;
                        };
                    }
                    total_resolve_tasks += npm_indices.items.len;
                }

                // JSR 状态与 spawn（与 npm 同时跑，join 在下方统一做）
                var jsr_items_buf_wave: ?[]JsrResolveItem = null;
                var jsr_results_wave: ?[]JsrResolveResult = null;
                var jsr_threads = std.ArrayList(std.Thread).initCapacity(allocator, 0) catch |e| {
                    if (first_error == null) first_error = map_install_err(e);
                    break :wave_parallel;
                };
                defer jsr_threads.deinit(allocator);
                var jsr_arena = std.heap.ArenaAllocator.init(allocator);
                defer jsr_arena.deinit();
                var jsr_next = std.atomic.Value(usize).init(0);
                if (jsr_indices.items.len > 0) {
                    if (allocator.alloc(JsrResolveItem, jsr_indices.items.len)) |buf| {
                        jsr_items_buf_wave = buf;
                        for (jsr_indices.items, buf) |pi, *out| {
                            const it = to_process.items[pi];
                            out.* = .{ .name = it.name, .spec = it.spec };
                        }
                    } else |_| {
                        if (first_error == null) first_error = error.OutOfMemory;
                    }
                    if (jsr_items_buf_wave) |jsr_items_buf| {
                        if (allocator.alloc(JsrResolveResult, jsr_indices.items.len)) |slice| {
                            jsr_results_wave = slice;
                            const n_workers = @min(jsr_indices.items.len, libs_process.getConcurrencyCapForRequests(JSR_RESOLVE_MAX_WORKERS));
                            jsr_threads.ensureTotalCapacity(allocator, n_workers) catch |e| {
                                if (first_error == null) first_error = map_install_err(e);
                                allocator.free(jsr_items_buf_wave.?);
                                break :wave_parallel;
                            };
                            var ctx = JsrResolveWorkerCtx{
                                .items = jsr_items_buf,
                                .results = slice.ptr,
                                .next_index = &jsr_next,
                                .allocator = jsr_arena.allocator(),
                                .resolving_progress = if (reporter) |r| r.resolving_progress else null,
                            };
                            var t: usize = 0;
                            while (t < n_workers) : (t += 1) {
                                jsr_threads.append(allocator, std.Thread.spawn(.{}, jsrResolveWorker, .{&ctx}) catch |e2| {
                                    if (first_error == null) first_error = map_install_err(e2);
                                    for (jsr_threads.items) |th| th.join();
                                    break :wave_parallel;
                                }) catch |e2| {
                                    if (first_error == null) first_error = map_install_err(e2);
                                    for (jsr_threads.items) |th| th.join();
                                    break :wave_parallel;
                                };
                            }
                            total_resolve_tasks += jsr_indices.items.len;
                        } else |_| {
                            if (first_error == null) first_error = error.OutOfMemory;
                            allocator.free(jsr_items_buf_wave.?);
                        }
                    }
                }

                for (npm_threads.items) |t| t.join();
                for (jsr_threads.items) |th| th.join();

                // 合并 npm 结果（首包在无缓存且默认 registry 时优先用 first_npm_probe_result）
                if (npm_work_items) |work_items| {
                    const npm_results = npm_results_slice.?;
                    var first_probe_consumed = false;
                    for (npm_indices.items, npm_results, 0..) |pi, res, ni| {
                        const item = to_process.items[pi];
                        if (reporter) |r| {
                            if (r.resolving_progress != null) {
                                resolving_emitted = true;
                            } else if (r.onResolving) |cb| {
                                resolving_emitted = true;
                                resolved_count += 1;
                                cb(r.ctx, item.display_name orelse item.name, resolved_count, to_process.items.len);
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
                        var dep_names = std.ArrayListUnmanaged([]const u8).initCapacity(allocator, deps.count()) catch {
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
                            deps_of.put(allocator, name_key, dep_names) catch {
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
                            if (npm_results[ni].dependencies) |*d| d.deinit();
                        } else {
                            @constCast(&deps).deinit();
                        }
                    }
                    for (work_items) |wi| allocator.free(wi.registry_url);
                    allocator.free(work_items);
                    allocator.free(npm_results);
                }

                // 合并 JSR 结果到 resolved/deps_of/to_process；worker 分配由 jsr_arena.deinit 统一释放（00 §1.2）
                if (jsr_results_wave) |jsr_results| {
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
                                var dep_names = std.ArrayListUnmanaged([]const u8).initCapacity(allocator, 0) catch {
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
                                                for (dep_names.items) |p| allocator.free(p);
                                                dep_names.deinit(allocator);
                                                freed_in_catch = true;
                                                if (first_error == null) first_error = error.OutOfMemory;
                                                break :merge_jsr;
                                            };
                                            dep_names.append(allocator, dep_name_dup) catch {
                                                allocator.free(dep_name_dup);
                                                for (dep_names.items) |p| allocator.free(p);
                                                dep_names.deinit(allocator);
                                                freed_in_catch = true;
                                                if (first_error == null) first_error = error.OutOfMemory;
                                                break :merge_jsr;
                                            };
                                            if (!resolved.contains(dep_entry.name)) {
                                                const tp_name = allocator.dupe(u8, dep_entry.name) catch {
                                                    for (dep_names.items) |p| allocator.free(p);
                                                    dep_names.deinit(allocator);
                                                    freed_in_catch = true;
                                                    if (first_error == null) first_error = error.OutOfMemory;
                                                    break :merge_jsr;
                                                };
                                                const tp_spec = allocator.dupe(u8, dep_entry.spec) catch {
                                                    allocator.free(tp_name);
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
                                                    for (dep_names.items) |p| allocator.free(p);
                                                    dep_names.deinit(allocator);
                                                    freed_in_catch = true;
                                                    if (first_error == null) first_error = error.OutOfMemory;
                                                    break :merge_jsr;
                                                };
                                            }
                                        }
                                    }
                                    const name_key = allocator.dupe(u8, item.name) catch {
                                        for (dep_names.items) |p| allocator.free(p);
                                        dep_names.deinit(allocator);
                                        freed_in_catch = true;
                                        if (first_error == null) first_error = error.OutOfMemory;
                                        break :merge_jsr;
                                    };
                                    // 同一包名可能多轮出现，fetchPut 只更新 value 不替换 key，返回的旧 key 仍在 map 中，不能 free
                                    const old_kv = deps_of.fetchPut(allocator, name_key, dep_names) catch {
                                        allocator.free(name_key);
                                        for (dep_names.items) |p| allocator.free(p);
                                        dep_names.deinit(allocator);
                                        freed_in_catch = true;
                                        if (first_error == null) first_error = error.OutOfMemory;
                                        break :merge_jsr;
                                    };
                                    if (old_kv) |kv| {
                                        allocator.free(name_key); // map 保留旧 key，本次 dupe 的 key 未写入，须释放防泄漏
                                        var old_list = kv.value; // 拷贝出 value 以便 deinit（fetchPut 返回 const）
                                        for (old_list.items) |p| allocator.free(p);
                                        old_list.deinit(allocator);
                                        // 不释放 kv.key：fetchPut 仅更新 value，key 仍由 map 持有，defer 中会统一 free
                                    }
                                    merged_into_deps = true;
                                    if (a.dupe(u8, item.name)) |jsr_key| {
                                        _ = jsr_packages.put(jsr_key, {}) catch a.free(jsr_key);
                                    } else |_| {}
                                    if (reporter) |r| {
                                        if (r.resolving_progress != null) {
                                            resolving_emitted = true;
                                        } else if (r.onResolving) |cb| {
                                            resolving_emitted = true;
                                            resolved_count += 1;
                                            cb(r.ctx, item.display_name orelse item.name, resolved_count, to_process.items.len);
                                        }
                                    }
                                }
                            }
                    allocator.free(jsr_items_buf_wave.?);
                    allocator.free(jsr_results);
                }
            } // wave_parallel
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
            libs_io.pathJoin(a, &.{ nm_dir, name }) catch continue
        else
            storePkgDir(a, shu_dir, name, version) catch continue;
        var d = libs_io.openDirAbsolute(pkg_dest, .{}) catch {
            new_count += 1;
            continue;
        };
        d.close(io);
    }
    if (resolving_emitted and install_start_ts != null) {
        if (libs_process.getProcessIo()) |prog_io| {
            const dur = install_start_ts.?.untilNow(prog_io);
            resolving_elapsed_ns = @intCast(dur.raw.nanoseconds);
            resolving_phase_recorded = true;
        }
    }
    if (reporter) |r| if (r.resolving_progress) |p| p.resolving_done.store(true, .monotonic);
    if (resolving_emitted) if (reporter) |r| if (r.onResolvingComplete) |cb| {
        const resolving_ms: i64 = if (resolving_phase_recorded) @intCast(@divTrunc(if (resolving_elapsed_ns < 0) 0 else resolving_elapsed_ns, 1_000_000)) else -1;
        cb(r.ctx, resolving_ms);
    };
    if (reporter) |r| {
        if (r.onStart) |cb| {
            // add 流程：进度条与统计只按「本次添加的包」数量，不按全量依赖数
            const start_total = if (added_names) |names| names.len else new_count;
            cb(r.ctx, start_total);
        }
    }

    first_error = null;
    // 本次 install 内创建并持有的 JSR 下载池；主进程创建 Io 传入 pool 与 install worker（与之前一致，先试效果）。
    var jsr_pool: ?*jsr.JsrDownloadPool = null;
    var jsr_io_list_owned: ?[]std.Io = null;
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
    // 同一 pkg_dest 只解压/下载一次，避免 install_order 中同一包出现两次（多包依赖同一包）时多 worker 争抢同一路径导致 PathAlreadyExists
    var pkg_dest_to_npm_idx = std.StringArrayHashMap(usize).init(a);
    defer pkg_dest_to_npm_idx.deinit();
    var pkg_dest_to_jsr_idx = std.StringArrayHashMap(usize).init(a);
    defer pkg_dest_to_jsr_idx.deinit();
    // pkg_dest/registry_url/registry_host 均由 arena (a) 分配，不在此 free，由 task_arena.deinit() 统一回收
    // 第一遍：已安装跳过；JSR 只收集任务（优化：并行阶段再下载）；npm 收集任务。
    for (install_order.items, already_installed_arr, jsr_task_idx_arr, npm_task_idx_arr) |name, *already_installed, *jsr_task_idx, *npm_task_idx| {
        const version = resolved.get(name).?;
        const pkg_dest = if (direct_set.contains(name))
            libs_io.pathJoin(a, &.{ nm_dir, name }) catch |e| {
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
        if (libs_io.pathDirname(pkg_dest)) |parent| libs_io.makePathAbsolute(parent) catch {};
        // 已安装判断：JSR 包看目录存在即可（用 deno.json）；npm 包须目录存在且含 package.json，避免空目录被误判
        already_installed.* = blk: {
            const proc_io = libs_process.getProcessIo() orelse break :blk false;
            var d = libs_io.openDirAbsolute(pkg_dest, .{}) catch break :blk false;
            d.close(proc_io);
            if (jsr_packages.contains(name)) break :blk true;
            const pkg_json = libs_io.pathJoin(a, &.{ pkg_dest, "package.json" }) catch break :blk false;
            defer a.free(pkg_json);
            var f = libs_io.openFileAbsolute(pkg_json, .{}) catch break :blk false;
            f.close(proc_io);
            break :blk true;
        };
        if (already_installed.*) {
            continue;
        }
        if (jsr_packages.contains(name)) {
            if (pkg_dest_to_jsr_idx.get(pkg_dest)) |existing_idx| {
                jsr_task_idx.* = existing_idx;
                continue;
            }
            jsr_tasks.append(allocator, .{ .name = name, .version = version, .pkg_dest = pkg_dest }) catch |e| {
                if (first_error == null) first_error = map_install_err(e);
                continue;
            };
            jsr_task_idx.* = jsr_tasks.items.len - 1;
            pkg_dest_to_jsr_idx.put(pkg_dest, jsr_tasks.items.len - 1) catch {};
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

    // 结果数组：第二遍按 install_order 报告时按 jsr_task_idx_arr/npm_task_idx_arr 索引，无任务时长度 0 即可。
    const jsr_results = allocator.alloc(?anyerror, jsr_tasks.items.len) catch return error.OutOfMemory;
    defer allocator.free(jsr_results);
    for (jsr_results) |*v| v.* = null;
    const npm_results = allocator.alloc(?anyerror, npm_tasks.items.len) catch return error.OutOfMemory;
    defer allocator.free(npm_results);
    for (npm_results) |*v| v.* = null;

    const have_jsr = jsr_tasks.items.len > 0;
    const have_npm = npm_tasks.items.len > 0;
    const n_jsr_workers: usize = if (have_jsr) @min(jsr_tasks.items.len, libs_process.getConcurrencyCap(JSR_INSTALL_MAX_WORKERS)) else 0;
    const n_npm_workers: usize = if (have_npm) @min(npm_tasks.items.len, libs_process.getConcurrencyCap(NPM_INSTALL_MAX_WORKERS)) else 0;
    // 主进程创建 Io，传入 pool 与各 install worker（先试效果：之前偶尔报错，线程内创建则直接崩）。
    var threaded_jsr_arr: []std.Io.Threaded = &.{};
    var threaded_npm_arr: []std.Io.Threaded = &.{};
    var threaded_jsr_install_arr: []std.Io.Threaded = &.{};
    var jsr_install_io_list_owned: ?[]std.Io = null;
    defer {
        if (jsr_pool) |p| p.deinit(allocator);
        if (jsr_io_list_owned) |s| allocator.free(s);
        for (threaded_jsr_arr) |*t| t.deinit();
        for (threaded_npm_arr) |*t| t.deinit();
        for (threaded_jsr_install_arr) |*t| t.deinit();
        if (threaded_jsr_arr.len > 0) allocator.free(threaded_jsr_arr);
        if (threaded_npm_arr.len > 0) allocator.free(threaded_npm_arr);
        if (threaded_jsr_install_arr.len > 0) allocator.free(threaded_jsr_install_arr);
        if (jsr_install_io_list_owned) |s| allocator.free(s);
    }
    if (have_jsr and n_jsr_workers > 0) {
        threaded_jsr_arr = allocator.alloc(std.Io.Threaded, n_jsr_workers) catch return error.OutOfMemory;
        for (threaded_jsr_arr) |*t| t.* = std.Io.Threaded.init(allocator, .{ .environ = std.process.Environ.empty });
        const jsr_io_list = allocator.alloc(std.Io, n_jsr_workers) catch return error.OutOfMemory;
        jsr_io_list_owned = jsr_io_list;
        for (threaded_jsr_arr, jsr_io_list) |*t, *slot| slot.* = t.io();
        jsr_pool = try jsr.JsrDownloadPool.init(allocator, .{ .io_list = jsr_io_list });
    }
    if (have_jsr and n_jsr_workers > 0) {
        threaded_jsr_install_arr = allocator.alloc(std.Io.Threaded, n_jsr_workers) catch return error.OutOfMemory;
        for (threaded_jsr_install_arr) |*t| t.* = std.Io.Threaded.init(allocator, .{ .environ = std.process.Environ.empty });
        const jsr_install_io_list = allocator.alloc(std.Io, n_jsr_workers) catch return error.OutOfMemory;
        jsr_install_io_list_owned = jsr_install_io_list;
        for (threaded_jsr_install_arr, jsr_install_io_list) |*t, *slot| slot.* = t.io();
    }
    if (have_npm and n_npm_workers > 0) {
        threaded_npm_arr = allocator.alloc(std.Io.Threaded, n_npm_workers) catch return error.OutOfMemory;
        for (threaded_npm_arr) |*t| t.* = std.Io.Threaded.init(allocator, .{ .environ = std.process.Environ.empty });
    }
    // JSR 与 npm 安装并行：先 spawn 两组 worker，再统一进度轮询，最后一起 join。
    var jsr_first_err: ?anyerror = null;
    var jsr_err_mutex = std.Io.Mutex.init;
    var jsr_threads = std.ArrayList(std.Thread).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer jsr_threads.deinit(allocator);
    var jsr_worker_ctxs: []JsrInstallWorkerCtx = &.{};
    defer if (jsr_worker_ctxs.len > 0) allocator.free(jsr_worker_ctxs);
    if (have_jsr and jsr_pool != null and jsr_install_io_list_owned != null) {
        const pool = jsr_pool.?;
        const jsr_install_io_list = jsr_install_io_list_owned.?;
        jsr_worker_ctxs = allocator.alloc(JsrInstallWorkerCtx, n_jsr_workers) catch return error.OutOfMemory;
        var jsr_next = std.atomic.Value(usize).init(0);
        for (jsr_worker_ctxs, jsr_install_io_list) |*wc, io_slot| {
            wc.* = .{
                .tasks = jsr_tasks.items,
                .results = jsr_results.ptr,
                .next_index = &jsr_next,
                .pool = pool,
                .allocator = allocator,
                .first_error = &jsr_first_err,
                .first_error_mutex = &jsr_err_mutex,
                .error_detail = error_detail,
                .main_allocator = allocator,
                .io = io_slot,
                .install_completed_count = if (want_progress) &install_completed_count else null,
                .last_completed_name = if (want_progress) &last_completed_name else null,
            };
        }
        var j: usize = 0;
        while (j < n_jsr_workers) : (j += 1) {
            jsr_threads.append(allocator, std.Thread.spawn(.{}, jsrInstallWorker, .{&jsr_worker_ctxs[j]}) catch |e| {
                for (jsr_threads.items) |th| th.join();
                return e;
            }) catch |e| {
                for (jsr_threads.items) |th| th.join();
                return e;
            };
        }
    }
    var npm_first_err: ?anyerror = null;
    var npm_err_mutex = std.Io.Mutex.init;
    var npm_first_extract_logged = std.atomic.Value(bool).init(false);
    var npm_threads = std.ArrayList(std.Thread).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer npm_threads.deinit(allocator);
    // npm worker 的 Arena 与 ctx 需在 join 之后才释放，故不在此块内 defer，改在 join 后统一释放
    var npm_install_arenas: []std.heap.ArenaAllocator = &.{};
    var npm_worker_ctxs: []NpmInstallWorkerCtx = &.{};
    if (have_npm) {
        const n_workers = n_npm_workers;
        try npm_threads.ensureTotalCapacity(allocator, n_workers);
        var next_atomic = std.atomic.Value(usize).init(0);
        npm_install_arenas = allocator.alloc(std.heap.ArenaAllocator, n_workers) catch return error.OutOfMemory;
        for (npm_install_arenas) |*arena| arena.* = std.heap.ArenaAllocator.init(allocator);
        npm_worker_ctxs = allocator.alloc(NpmInstallWorkerCtx, n_workers) catch return error.OutOfMemory;
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
            .allocator = undefined,
            .io = undefined,
            .install_completed_count = if (want_progress) &install_completed_count else null,
            .last_completed_name = if (want_progress) &last_completed_name else null,
        };
        for (0..n_workers) |t| {
            npm_worker_ctxs[t] = base_ctx;
            npm_worker_ctxs[t].worker_id = t;
            npm_worker_ctxs[t].allocator = npm_install_arenas[t].allocator();
            npm_worker_ctxs[t].io = threaded_npm_arr[t].io();
            npm_threads.append(allocator, std.Thread.spawn(.{}, npmInstallWorker, .{&npm_worker_ctxs[t]}) catch |e| {
                for (npm_threads.items) |th| th.join();
                if (have_jsr) for (jsr_threads.items) |th| th.join();
                return e;
            }) catch |e| {
                for (npm_threads.items) |th| th.join();
                if (have_jsr) for (jsr_threads.items) |th| th.join();
                return e;
            };
        }
    }
    // 统一进度轮询：JSR 与 npm 并行进行，主线程只等总完成数。若长时间无进展（如最后一包 HTTP 无超时导致卡住），提示一次。
    const install_stall_iters: usize = 40; // 40 * 80ms ≈ 3.2s 无进展则视为卡住
    var prev_install_cur: usize = 0;
    var same_cur_iters: usize = 0;
    var install_stall_warned: bool = false;
    while (want_progress and install_completed_count.load(.monotonic) < total_work_items) {
        const cur = install_completed_count.load(.monotonic);
        if (cur == prev_install_cur) {
            same_cur_iters += 1;
            if (same_cur_iters >= install_stall_iters and !install_stall_warned) {
                install_stall_warned = true;
                const remaining = total_work_items - cur;
                logInstallFailure("[shu install] still waiting for {d} package(s) (network may be slow). Press Ctrl+C to cancel.\n", .{remaining});
            }
        } else {
            prev_install_cur = cur;
            same_cur_iters = 0;
            install_stall_warned = false;
        }
        var name_buf: [64]u8 = undefined;
        var name_slice: ?[]const u8 = null;
        const prog_io = libs_process.getProcessIo() orelse break;
        last_completed_name.mutex.lock(prog_io) catch break;
        if (last_completed_name.len > 0) {
            @memcpy(name_buf[0..last_completed_name.len], last_completed_name.buf[0..last_completed_name.len]);
            name_slice = name_buf[0..last_completed_name.len];
        }
        last_completed_name.mutex.unlock(prog_io);
        if (reporter.?.onProgress) |onProg| onProg(reporter.?.ctx, cur, total_work_items, name_slice);
        std.Io.sleep(prog_io, std.Io.Duration.fromNanoseconds(80_000_000), .awake) catch {}; // 80ms
    }
    if (have_jsr) {
        for (jsr_threads.items) |th| th.join();
        if (jsr_first_err) |e| first_error = map_install_err(e);
    }
    if (have_npm) {
        for (npm_threads.items) |th| th.join();
        if (npm_first_err) |e| first_error = map_install_err(e);
        for (npm_install_arenas) |*arena| arena.deinit();
        allocator.free(npm_install_arenas);
        allocator.free(npm_worker_ctxs);
    }
    // threaded_* 与 jsr_install_io_list_owned 由上方 defer 统一 deinit/free
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
    const bin_dir = libs_io.pathJoin(a, &.{ nm_dir, ".bin" }) catch return error.OutOfMemory;
    libs_io.makePathAbsolute(bin_dir) catch {};
    var direct_it = direct_set.iterator();
    while (direct_it.next()) |e| {
        const pkg_name = e.key_ptr.*;
        const pkg_dir = libs_io.pathJoin(a, &.{ nm_dir, pkg_name }) catch continue;
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
            libs_io.pathJoin(a, &.{ nm_dir, pkg_name }) catch continue
        else
            storePkgDir(a, shu_dir, pkg_name, version) catch continue;
        const nm_inside = libs_io.pathJoin(a, &.{ pkg_dir, "node_modules" }) catch continue;
        libs_io.makePathAbsolute(nm_inside) catch {};
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
                        break :blk libs_io.pathJoin(a, &.{ shu_dir, name_at_ver }) catch continue;
                    } else break :blk std.fmt.allocPrint(a, "../{s}", .{name_at_ver}) catch continue;
                }
            };
            const dep_link_path = libs_io.pathJoin(a, &.{ nm_inside, dep_name }) catch continue;
            libs_io.deleteFileAbsolute(dep_link_path) catch |err| if (err == error.IsDir) libs_io.deleteTreeAbsolute(allocator, dep_link_path) catch {};
            const parent = libs_io.pathDirname(dep_link_path) orelse continue;
            const link_name = libs_io.pathBasename(dep_link_path);
            libs_io.makePathAbsolute(parent) catch {};
            const proc_io = libs_process.getProcessIo() orelse continue;
            var dep_dir = libs_io.openDirAbsolute(parent, .{}) catch continue;
            dep_dir.symLink(proc_io, target_path, link_name, .{ .is_directory = true }) catch |e| {
                if (@import("builtin").os.tag == .windows) {
                    logInstallFailure("[shu install] symlink failed (Windows): enable Developer Mode or run as Administrator. dep={s} error={s}\n", .{ dep_name, @errorName(e) });
                }
            };
            dep_dir.close(proc_io);
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
            const elapsed_ms: u64 = if (install_start_ts) |start_ts| blk: {
                const dur = start_ts.untilNow(io);
                const ns = dur.raw.nanoseconds;
                break :blk @intCast(@divTrunc(if (ns < 0) 0 else ns, 1_000_000));
            } else 0;
            if (r.resolving_elapsed_ms) |ptr| {
                if (resolving_phase_recorded) {
                    ptr.* = @intCast(@divTrunc(if (resolving_elapsed_ns < 0) 0 else resolving_elapsed_ns, 1_000_000));
                }
                // 未解析时保持调用方初始值（如 -1），便于 CLI 不显示分段
            }
            if (r.installing_elapsed_ms) |ptr| {
                if (resolving_phase_recorded) {
                    const resolving_ms: i64 = @intCast(@divTrunc(if (resolving_elapsed_ns < 0) 0 else resolving_elapsed_ns, 1_000_000));
                    ptr.* = @as(i64, @intCast(elapsed_ms)) - resolving_ms;
                    if (ptr.* < 0) ptr.* = 0;
                }
            }
            cb(r.ctx, done_total, done_new, @as(i64, @intCast(elapsed_ms)));
        }
    }
    try lockfile.saveFromResolved(allocator, lock_path, resolved, &deps_of, &jsr_packages);
}

/// 从解压流 dec 中读取恰好 buf.len 字节写入 buf，用 work 作为读缓冲。用于 tar 头等定长块。
fn streamReadExactlyToBuffer(dec: anytype, buf: []u8, work: []u8) !void {
    var pos: usize = 0;
    while (pos < buf.len) {
        const to_read = @min(work.len, buf.len - pos);
        var w = std.Io.Writer.fixed(work[0..to_read]);
        const n = dec.reader.stream(&w, .limited(to_read)) catch |e| {
            if (e == error.EndOfStream) return error.UnexpectedEof;
            return e;
        };
        if (n == 0) return error.UnexpectedEof;
        @memcpy(buf[pos..][0..n], work[0..n]);
        pos += n;
    }
}

/// 从解压流 dec 中读取恰好 need 字节并写入 file，用 chunk 作为读缓冲。用于 tar 文件条目内容。Zig 0.16 使用 std.Io.File.writeStreamingAll(io, slice)。
fn streamReadExactlyToFile(dec: anytype, file: std.Io.File, io: std.Io, need: usize, chunk: []u8) !void {
    var pos: usize = 0;
    while (pos < need) {
        const to_read = @min(chunk.len, need - pos);
        var w = std.Io.Writer.fixed(chunk[0..to_read]);
        const n = dec.reader.stream(&w, .limited(to_read)) catch |e| {
            if (e == error.EndOfStream) return error.UnexpectedEof;
            return e;
        };
        if (n == 0) return error.UnexpectedEof;
        try file.writeStreamingAll(io, chunk[0..n]);
        pos += n;
    }
}

/// 从解压流 dec 中跳过恰好 need 字节（读入 chunk 后丢弃），用于跳过非 package/ 条目或 padding。
fn streamSkipExactly(dec: anytype, need: usize, chunk: []u8) !void {
    var pos: usize = 0;
    while (pos < need) {
        const to_read = @min(chunk.len, need - pos);
        var w = std.Io.Writer.fixed(chunk[0..to_read]);
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
    return libs_io.pathJoin(allocator, &.{ shu_dir, try std.fmt.allocPrint(allocator, "{s}@{s}", .{ name, version }) });
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
    const pkg_json_path = libs_io.pathJoin(allocator, &.{ pkg_dir, "package.json" }) catch return;
    defer allocator.free(pkg_json_path);
    const io = libs_process.getProcessIo() orelse return;
    var f = libs_io.openFileAbsolute(pkg_json_path, .{}) catch return;
    defer f.close(io);
    var file_reader = f.reader(io, &.{});
    const raw = file_reader.interface.allocRemaining(allocator, std.Io.Limit.unlimited) catch return;
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
/// target 须为绝对路径，否则 libs_io.symLinkAbsolute 会断言失败。
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
    const target_absolute = libs_io.pathJoin(allocator, &.{ pkg_dir, normalized }) catch return error.OutOfMemory;
    defer allocator.free(target_absolute);
    const link_path = libs_io.pathJoin(allocator, &.{ bin_dir, bin_name }) catch return error.OutOfMemory;
    defer allocator.free(link_path);
    libs_io.deleteFileAbsolute(link_path) catch |err| if (err == error.IsDir) libs_io.deleteTreeAbsolute(allocator, link_path) catch {};
    libs_io.symLinkAbsolute(target_absolute, link_path, .{}) catch return;
    const io = libs_process.getProcessIo() orelse return;
    const is_windows = @import("builtin").os.tag == .windows;
    if (is_windows) {
        // Windows：写 .cmd 包装，使 cmd 中运行 <name> 时执行 node target %*
        const cmd_path = std.fmt.allocPrint(allocator, "{s}.cmd", .{link_path}) catch return;
        defer allocator.free(cmd_path);
        libs_io.deleteFileAbsolute(cmd_path) catch {};
        var f = libs_io.createFileAbsolute(cmd_path, .{}) catch return;
        defer f.close(io);
        // @echo off & node "target_absolute" %*
        var buf: [4096]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "@echo off\r\nnode \"{s}\" %*\r\n", .{target_absolute}) catch return;
        f.writeStreamingAll(io, line) catch return;
    } else {
        // Unix：对目标脚本加可执行权限。Zig 0.16 使用 std.c.fchmod，File.close 需传 io。
        var f = libs_io.openFileAbsolute(target_absolute, .{}) catch return;
        defer f.close(io);
        _ = std.c.fchmod(f.handle, 0o755);
    }
}

/// 首次解压失败时无条件打印一次：包名、错误、路径、文件大小、前 16 字节（hex）。便于自动定位 tgz 是否为 gzip（1f 8b）或误写为 br 等。用原子标记保证只打印一次（与 first_error 谁先无关）。
fn logFirstTarballExtractFailure(ctx: *const NpmInstallWorkerCtx, tgz_path: []const u8, err: anyerror, name: []const u8, version: []const u8) void {
    if (ctx.first_extract_failure_logged.swap(true, .monotonic)) return;
    logInstallFailure("[shu install] first tarball extract failure: {s}@{s} error={s}\n", .{ name, version, @errorName(err) });
    const proc_io = libs_process.getProcessIo() orelse return;
    var f = libs_io.openFileAbsolute(tgz_path, .{}) catch {
        logInstallFailure("[shu install] first tarball extract failure: {s}@{s} error={s} path={s} (file not openable)\n", .{ name, version, @errorName(err), tgz_path });
        return;
    };
    defer f.close(proc_io);
    var buf: [16]u8 = undefined;
    const n = f.readStreaming(proc_io, &.{buf[0..]}) catch 0;
    var hex: [64]u8 = undefined;
    for (buf[0..n], 0..) |b, i| {
        _ = std.fmt.bufPrint(hex[i * 3 ..][0..3], "{x:0>2} ", .{b}) catch break;
    }
    const stat = f.stat(proc_io) catch return;
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
    if (std.c.getenv("SHU_DEBUG_TGZ")) |_| {} else return;
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
            var w = std.Io.Writer.fixed(&name_buf);
            if (prefix_slice.len > 0) {
                w.print("{s}/{s}", .{ prefix_slice, name_slice }) catch {};
            } else {
                w.print("{s}", .{name_slice}) catch {};
            }
            name_slice = std.Io.Writer.buffered(&w);
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
    if (std.c.getenv("SHU_DEBUG_TGZ")) |_| {} else return;
    logInstallFailure("[shu tgz debug] step={s} path={s} target={s} error={s}\n", .{
        step,
        tgz_path,
        path_or_rel,
        @errorName(err),
    });
}

/// 当 SHU_DEBUG_TGZ 非空时，解压失败则向 stderr 打印 tgz 路径、错误、文件大小及前 16 字节（hex）。
fn debugLogTarballExtractFailed(tgz_path: []const u8, err: anyerror) void {
    if (std.c.getenv("SHU_DEBUG_TGZ")) |_| {} else return;
    const proc_io = libs_process.getProcessIo() orelse return;
    var f = libs_io.openFileAbsolute(tgz_path, .{}) catch {
        logInstallFailure("[shu tgz debug] path={s} error={s} (could not open file)\n", .{ tgz_path, @errorName(err) });
        return;
    };
    defer f.close(proc_io);
    var buf: [16]u8 = undefined;
    const n = f.readStreaming(proc_io, &.{buf[0..]}) catch 0;
    var hex: [64]u8 = undefined;
    for (buf[0..n], 0..) |b, i| {
        _ = std.fmt.bufPrint(hex[i * 3 ..][0..3], "{x:0>2} ", .{b}) catch break;
    }
    const stat = f.stat(proc_io) catch return;
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
    const proc_io = libs_process.getProcessIo() orelse return error.ProcessIoNotSet;
    try libs_io.makePathAbsolute(dest_dir);
    // §3.0: 目录打开经 io_core，与模块约定一致
    var dest_dir_handle = libs_io.openDirAbsolute(dest_dir, .{}) catch |e| {
        logExtractFailureStep(tgz_path, "open_dest_dir", dest_dir, e);
        return error.TarballExtractFailed;
    };
    defer dest_dir_handle.close(proc_io);
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
                    var w = std.Io.Writer.fixed(&buf);
                    w.print("{s}/{s}", .{ prefix_slice, name_slice }) catch break :blk name_slice;
                    break :blk std.Io.Writer.buffered(&w);
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
            dest_dir_handle.createDirPath(proc_io, rel) catch {};
            offset += block_rounded;
        } else {
            if (std.mem.indexOf(u8, rel, "..")) |_| {
                offset += block_rounded;
                continue;
            }
            if (libs_io.pathDirname(rel)) |rel_dir| if (rel_dir.len > 0) dest_dir_handle.createDirPath(proc_io, rel_dir) catch {};
            const out_file = dest_dir_handle.createFile(proc_io, rel, .{}) catch |e| {
                logExtractFailureStep(tgz_path, "create_file", rel, e);
                offset += block_rounded;
                return e;
            };
            defer out_file.close(proc_io);
            wrote_any_file = true;
            if (size > 0) {
                try out_file.writeStreamingAll(proc_io, content[offset..][0..size]);
            }
            offset += block_rounded;
        }
    }
    if (!wrote_any_file) {
        logInvalidTarContent(tgz_path, content, "no_package_entry");
        return error.InvalidGzip;
    }
}

/// 将 .tgz 解压到指定目录 dest_dir（tgz 内 package/ 前缀下的内容写入 dest_dir）。使用 libs_io.mapFileReadOnly 映射 tgz，gzip 解压后流式解析 tar。
/// 通过 libs_io.openDirAbsolute(dest_dir) + Dir.createFile/makePath 写文件。
/// allocator 用于 gzip 一次性解压的临时缓冲；若由安装 worker 调用，建议传入该 worker 的 Arena 或独立 allocator。
fn extractTarballToDir(allocator: std.mem.Allocator, tgz_path: []const u8, dest_dir: []const u8) !void {
    var mapped = libs_io.mapFileReadOnly(tgz_path) catch |e| {
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

    const proc_io = libs_process.getProcessIo() orelse return error.ProcessIoNotSet;
    try libs_io.makePathAbsolute(dest_dir);
    // §3.0: 目录打开经 io_core
    var dest_dir_handle = libs_io.openDirAbsolute(dest_dir, .{}) catch |e| {
        logExtractFailureStep(tgz_path, "open_dest_dir(stream)", dest_dir, e);
        return error.TarballExtractFailed;
    };
    defer dest_dir_handle.close(proc_io);

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
                    var w = std.Io.Writer.fixed(&buf);
                    w.print("{s}/{s}", .{ prefix_slice, name_slice }) catch break :blk name_slice;
                    break :blk std.Io.Writer.buffered(&w);
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
            dest_dir_handle.createDirPath(proc_io, rel) catch {};
            try streamSkipExactly(&dec, block_rounded, &chunk);
        } else {
            if (std.mem.indexOf(u8, rel, "..")) |_| {
                try streamSkipExactly(&dec, block_rounded, &chunk);
                continue;
            }
            if (libs_io.pathDirname(rel)) |rel_dir| if (rel_dir.len > 0) dest_dir_handle.createDirPath(proc_io, rel_dir) catch {};
            const out_file = dest_dir_handle.createFile(proc_io, rel, .{}) catch |e| {
                logExtractFailureStep(tgz_path, "create_file(stream)", rel, e);
                try streamSkipExactly(&dec, block_rounded, &chunk);
                return e;
            };
            defer out_file.close(proc_io);
            wrote_any_file = true;
            // 必须完整读出文件内容；失败则直接返回，避免流位置错位导致后续条目（如 package.json）解析错乱
            if (size > 0) {
                streamReadExactlyToFile(&dec, out_file, proc_io, size, &chunk) catch |e| {
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
    const extract_dest = try libs_io.pathJoin(a, &.{ dest_dir_path, "out" });
    defer a.free(extract_dest);
    try libs_io.makePathAbsolute(extract_dest);
    try extractTarballToDir(a, tgz_path, extract_dest);
    const pkg_json = try libs_io.pathJoin(a, &.{ extract_dest, "package.json" });
    defer a.free(pkg_json);
    try std.testing.expect(libs_io.accessAbsolute(pkg_json, .{}) == .ok);
    const content = try tmp.dir.readFileAlloc(a, "out/package.json", 64);
    defer a.free(content);
    try std.testing.expect(std.mem.eql(u8, std.mem.trim(u8, content, " \n"), "{}"));
}

// 可选：若环境变量 SHU_TGZ_PATH 指向某 .tgz 文件，解压并断言存在 package.json（用于调试真实 npm tgz）。
test "extractTarballToDir: real tgz when SHU_TGZ_PATH set" {
    const path = std.c.getenv("SHU_TGZ_PATH") orelse return;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dest = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(dest);
    const out_dir = try libs_io.pathJoin(a, &.{ dest, "out" });
    defer a.free(out_dir);
    try libs_io.makePathAbsolute(out_dir);
    try extractTarballToDir(a, path, out_dir);
    const pkg_json = try libs_io.pathJoin(a, &.{ out_dir, "package.json" });
    defer a.free(pkg_json);
    try std.testing.expect(libs_io.accessAbsolute(pkg_json, .{}) == .ok);
}
