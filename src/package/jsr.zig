//! JSR（jsr.io）直接解析与安装：先拉 version_meta 得到 manifest，再并行下载所有文件（多线程），与 Deno 策略一致。
//! 参考：https://jsr.io/docs/api
//!
//! ## 性能与 Deno 对齐
//! - **文件下载**：每 worker 持有一个 std.http.Client，用 fetchUrlForJsrMetaWithClient 复用同 host 连接（Zig 路径、Keep-Alive）。
//! - **线程池**：全局 JSR 下载线程池，首次使用时初始化，任务入队由固定 worker 消费，避免每包 spawn/join。
//! - **内存**：单包下载内用 ArenaAllocator，解析与 task 列表一次 deinit，减少碎片。
//! - **流水线**：写盘与下一任务拉取由不同 worker 并行，整体上网络与磁盘重叠。

const std = @import("std");
const errors = @import("errors");
const libs_io = @import("libs_io");
const libs_process = @import("libs_process");
const cache = @import("cache.zig");
const registry = @import("registry.zig");
const resolver = @import("resolver.zig");

/// JSR 元数据缓存使用的 registry_host，与 cache.getCachedMetadata/putCachedMetadata 的 key 配合（meta/ deno/ 前缀）。
const JSR_CACHE_HOST = "jsr.io";

/// 当环境变量 SHU_DEBUG_RESOLVE_CACHE 非空时，向 stderr 打印一条缓存命中日志，便于验证「无 lock 第二次安装」是否走缓存。
fn logResolveCacheHit(allocator: std.mem.Allocator, kind: []const u8, key: []const u8) void {
    if (std.c.getenv("SHU_DEBUG_RESOLVE_CACHE")) |v| {
        if (std.mem.span(v).len > 0) {
            const msg = std.fmt.allocPrint(allocator, "[shu] jsr {s} cache hit: {s}\n", .{ kind, key }) catch return;
            defer allocator.free(msg);
            _ = std.c.write(2, msg.ptr, msg.len);
        }
    }
}

const JSR_META_BASE = "https://jsr.io";
/// 单包内文件并行下载的并发上限（静态上限）；实际 worker 数由 libs_process.getConcurrencyCap 按 CPU/内存/磁盘/网络计算（下载落盘场景）。
const JSR_DOWNLOAD_MAX_CONCURRENCY = 16;
/// meta.json / deno.json 等单次 GET 最大响应体字节数；与 registry 一致不做严限，256MB 避免大包 ResponseTooLarge。
const JSR_FETCH_MAX_BYTES = 256 * 1024 * 1024;

/// 线程池任务队列项：url/dest_path 指向提交方 arena，job 用于完成时扣减并 signal。
const JsrPoolTask = struct { url: []const u8, dest_path: []const u8, job: *JsrDownloadJob };
/// 写盘队列项：fetcher 拉取后入队，writer 线程写盘并 free body、扣减 job。
const JsrWriteItem = struct { body: []const u8, dest_path: []const u8, job: *JsrDownloadJob };
/// 单次提交的「包」：remaining 由 worker 扣减，减到 0 时 signal done_cond；任一任务失败时写 first_error，提交方 wait 后检查。
const JsrDownloadJob = struct {
    remaining: std.atomic.Value(usize),
    first_error: ?anyerror = null,
    done_mutex: std.Io.Mutex = std.Io.Mutex.init,
    done_cond: std.Io.Condition = std.Io.Condition.init,
};

var g_jsr_pool: ?*JsrDownloadPool = null;
var g_jsr_pool_mutex: std.Io.Mutex = std.Io.Mutex.init;

/// 初始化选项：io_override 指定专用 Io；http_mutex 可选，用于串行化同组内 HTTP 请求以避 EISCONN 且仅用 1 个 Io 省内存。
pub const InitOptions = struct {
    /// 若设置，worker i 使用 io_list[i]（每 worker 独立 Io，省锁但占内存）；与 io_override 二选一，io_list 优先。
    io_list: ?[]const std.Io = null,
    /// 若设置且 io_list 为 null，所有 worker 与 writer 共用此 Io；未设置则使用 libs_process.getProcessIo()。
    io_override: ?std.Io = null,
    /// 若设置，每次 HTTP 请求前 lock、请求后 unlock，使同组内仅单请求在飞，避免同一 Io 并发 connect 导致 EISCONN；配合单 io_override 可只建 1 个 Io 节省内存。
    http_mutex: ?*std.Io.Mutex = null,
};

/// 全局 JSR 下载线程池：固定 N 个 fetcher + 1 个 writer；fetcher 只拉取并入写盘队列，writer 写盘，实现网络/磁盘流水线。
/// 可由调用方创建并在适当时机 deinit 以避免 GPA 泄漏。内部 queue/threads/write_queue 使用 Unmanaged 容器（01 §1.2），减少指针占用、提升 Cache 命中。
/// io_list/io_override 非 null 时使用传入的 Io；均为 null 时与 npm 一致，各 worker 与 writer 在本线程内创建 std.Io.Threaded（每线程一个 Io 环，根除 EISCONN）。
pub const JsrDownloadPool = struct {
    allocator: std.mem.Allocator,
    io_list: ?[]const std.Io = null,
    io_override: ?std.Io = null,
    /// 非 null 时 worker 在每次 HTTP 请求前后 lock/unlock，串行化请求以避 EISCONN，可与单 io_override 配合省内存。
    http_mutex: ?*std.Io.Mutex = null,
    queue: std.ArrayListUnmanaged(JsrPoolTask),
    head: usize = 0,
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    cond: std.Io.Condition = std.Io.Condition.init,
    threads: std.ArrayListUnmanaged(std.Thread),
    write_queue: std.ArrayListUnmanaged(JsrWriteItem),
    write_head: usize = 0,
    write_mutex: std.Io.Mutex = std.Io.Mutex.init,
    write_cond: std.Io.Condition = std.Io.Condition.init,
    writer_thread: std.Thread,
    shutdown: std.atomic.Value(bool) = .{ .raw = false },

    /// 返回当前上下文使用的 Io：worker_index 非 null 时用 io_list[worker_index]（若 io_list 已设），否则用 io_list[0] 或 io_override 或 process Io。
    fn getIo(pool: *JsrDownloadPool, worker_index: ?usize) ?std.Io {
        if (pool.io_list) |list| return list[worker_index orelse 0];
        return pool.io_override orelse libs_process.getProcessIo();
    }

    /// 每 worker 持有一个 std.http.Client；io_list/io_override 已设时用 getIo，否则本线程内创建 Threaded（与 npm install worker 一致）。
    fn worker(pool: *JsrDownloadPool, worker_index: usize) void {
        var threaded: ?std.Io.Threaded = null;
        defer if (threaded) |*t| t.deinit();
        const io = pool.getIo(worker_index) orelse blk: {
            threaded = std.Io.Threaded.init(pool.allocator, .{ .environ = std.process.Environ.empty });
            break :blk threaded.?.io();
        };
        var zig_client = std.http.Client{ .allocator = pool.allocator, .io = io };
        defer zig_client.deinit();
        while (true) {
            pool.mutex.lock(io) catch return;
            while (pool.head >= pool.queue.items.len and pool.shutdown.load(.monotonic) == false) {
                pool.cond.wait(io, &pool.mutex) catch {
                    pool.mutex.unlock(io);
                    return;
                };
            }
            if (pool.shutdown.load(.monotonic)) {
                pool.mutex.unlock(io);
                break;
            }
            const task = pool.queue.items[pool.head];
            pool.head += 1;
            if (pool.head >= pool.queue.items.len) {
                pool.queue.clearRetainingCapacity(); // Unmanaged：仅清空长度，不释放内存
                pool.head = 0;
            }
            pool.mutex.unlock(io);
            if (pool.http_mutex) |m| m.lock(io) catch return;
            const content = registry.fetchUrlForJsrMetaWithClient(&zig_client, pool.allocator, task.url, JSR_FETCH_MAX_BYTES) catch |e| {
                if (pool.http_mutex) |m| m.unlock(io);
                task.job.done_mutex.lock(io) catch continue;
                if (task.job.first_error == null) task.job.first_error = e;
                _ = task.job.remaining.fetchSub(1, .monotonic);
                task.job.done_cond.signal(io);
                task.job.done_mutex.unlock(io);
                continue;
            };
            if (pool.http_mutex) |m| m.unlock(io);
            // 入写盘队列后立即继续拉取下一任务，不等待写盘（网络/磁盘流水线）
            pool.write_mutex.lock(io) catch return;
            pool.write_queue.append(pool.allocator, .{ .body = content, .dest_path = task.dest_path, .job = task.job }) catch {
                pool.allocator.free(content);
                task.job.done_mutex.lock(io) catch {};
                if (task.job.first_error == null) task.job.first_error = error.OutOfMemory;
                _ = task.job.remaining.fetchSub(1, .monotonic);
                task.job.done_cond.signal(io);
                task.job.done_mutex.unlock(io);
                pool.write_mutex.unlock(io);
                continue;
            };
            pool.write_cond.signal(io);
            pool.write_mutex.unlock(io);
        }
    }

    fn writerLoop(pool: *JsrDownloadPool) void {
        var threaded: ?std.Io.Threaded = null;
        defer if (threaded) |*t| t.deinit();
        const io = pool.getIo(null) orelse blk: {
            threaded = std.Io.Threaded.init(pool.allocator, .{ .environ = std.process.Environ.empty });
            break :blk threaded.?.io();
        };
        while (true) {
            pool.write_mutex.lock(io) catch return;
            while (pool.write_head >= pool.write_queue.items.len and pool.shutdown.load(.monotonic) == false) {
                pool.write_cond.wait(io, &pool.write_mutex) catch {
                    pool.write_mutex.unlock(io);
                    return;
                };
            }
            if (pool.shutdown.load(.monotonic)) {
                pool.write_mutex.unlock(io);
                break;
            }
            const item = pool.write_queue.items[pool.write_head];
            pool.write_head += 1;
            if (pool.write_head >= pool.write_queue.items.len) {
                pool.write_queue.clearRetainingCapacity(); // Unmanaged：仅清空长度
                pool.write_head = 0;
            }
            pool.write_mutex.unlock(io);
            defer pool.allocator.free(item.body);
            var f = libs_io.createFileAbsolute(item.dest_path, .{}) catch |e| {
                item.job.done_mutex.lock(io) catch continue;
                if (item.job.first_error == null) item.job.first_error = e;
                item.job.done_mutex.unlock(io);
                const prev = item.job.remaining.fetchSub(1, .monotonic);
                if (prev == 1) {
                    item.job.done_mutex.lock(io) catch {};
                    item.job.done_cond.signal(io);
                    item.job.done_mutex.unlock(io);
                }
                continue;
            };
            f.writeStreamingAll(io, item.body) catch |e| {
                item.job.done_mutex.lock(io) catch {};
                if (item.job.first_error == null) item.job.first_error = e;
                item.job.done_mutex.unlock(io);
            };
            f.close(io);
            const prev = item.job.remaining.fetchSub(1, .monotonic);
            if (prev == 1) {
                item.job.done_mutex.lock(io) catch {};
                item.job.done_cond.signal(io);
                item.job.done_mutex.unlock(io);
            }
        }
    }

    /// 创建并启动 worker 与 writer 线程。若 options.io_list 非 null 则 worker 数 = io_list.len，否则由 getConcurrencyCap 决定；io_list 时 worker i 使用 io_list[i]，避免并发 connect 时 EISCONN。调用方负责在适当时机 deinit(pool, allocator)。
    pub fn init(allocator: std.mem.Allocator, options: InitOptions) !*JsrDownloadPool {
        const n_workers = if (options.io_list) |list| list.len else libs_process.getConcurrencyCap(JSR_DOWNLOAD_MAX_CONCURRENCY);
        const pool = try allocator.create(JsrDownloadPool);
        pool.* = .{
            .allocator = allocator,
            .io_list = options.io_list,
            .io_override = options.io_override,
            .http_mutex = options.http_mutex,
            .queue = std.ArrayListUnmanaged(JsrPoolTask).initCapacity(allocator, 0) catch return error.OutOfMemory,
            .threads = std.ArrayListUnmanaged(std.Thread).initCapacity(allocator, n_workers) catch return error.OutOfMemory,
            .write_queue = std.ArrayListUnmanaged(JsrWriteItem).initCapacity(allocator, 0) catch return error.OutOfMemory,
            .writer_thread = undefined,
        };
        var i: usize = 0;
        while (i < n_workers) : (i += 1) {
            const th = try std.Thread.spawn(.{}, worker, .{ pool, i });
            try pool.threads.append(allocator, th);
        }
        pool.writer_thread = try std.Thread.spawn(.{}, writerLoop, .{pool});
        return pool;
    }

    /// 将一批任务入队并阻塞直到全部完成。tasks 的 url/dest_path 在返回前必须有效（通常由调用方 arena 持有）。caller_io 非 null 时用其做 mutex/cond（如 install worker 传入本线程 Io），否则用 pool.getIo(null)。
    fn submit(pool: *JsrDownloadPool, tasks: []const JsrFileTask, caller_io: ?std.Io) !void {
        if (tasks.len == 0) return;
        const io = caller_io orelse pool.getIo(null) orelse return error.ProcessIoNotSet;
        var job: JsrDownloadJob = .{ .remaining = std.atomic.Value(usize).init(tasks.len) };
        pool.mutex.lock(io) catch return error.ProcessIoNotSet;
        for (tasks) |t| {
            try pool.queue.append(pool.allocator, .{ .url = t.url, .dest_path = t.dest_path, .job = &job });
        }
        pool.cond.broadcast(io);
        pool.mutex.unlock(io);
        job.done_mutex.lock(io) catch return error.ProcessIoNotSet;
        while (job.remaining.load(.monotonic) != 0) {
            job.done_cond.wait(io, &job.done_mutex) catch |e| {
                job.done_mutex.unlock(io);
                return e;
            };
        }
        const err = job.first_error;
        job.done_mutex.unlock(io);
        if (err) |e| return e;
    }

    /// 关闭池并释放资源：置 shutdown、唤醒并 join 所有 worker 与 writer，deinit 内部 ArrayList，最后 destroy 自身。使用 pool.getIo() 与 worker 一致。调用方负责用创建池时的 allocator 调用。
    pub fn deinit(pool: *JsrDownloadPool, allocator: std.mem.Allocator) void {
        const io = pool.getIo(null) orelse return;
        pool.shutdown.store(true, .monotonic);
        pool.cond.broadcast(io);
        pool.write_cond.broadcast(io);
        for (pool.threads.items) |*th| th.join();
        pool.writer_thread.join();
        pool.queue.deinit(allocator);
        pool.threads.deinit(allocator);
        pool.write_queue.deinit(allocator);
        allocator.destroy(pool);
    }
};

/// 获取或创建全局 JSR 下载线程池（首次调用时用传入的 allocator 创建，进程内复用）。
fn getOrCreatePool(allocator: std.mem.Allocator) !*JsrDownloadPool {
    const io = libs_process.getProcessIo() orelse return error.ProcessIoNotSet;
    g_jsr_pool_mutex.lock(io) catch return error.ProcessIoNotSet;
    defer g_jsr_pool_mutex.unlock(io);
    if (g_jsr_pool) |p| return p;
    const pool = try JsrDownloadPool.init(allocator, .{});
    g_jsr_pool = pool;
    return pool;
}

/// 发生 JsrMetaNoJsonObject 时始终向 stderr 打印失败 URL 与短 body 预览，便于用户定位是哪个包/请求。Zig 0.16 使用 std.Io.File.stderr() + Writer。
fn logJsrMetaNoJson(url: []const u8, body_trimmed: []const u8) void {
    const io = libs_process.getProcessIo() orelse return;
    var buf: [512]u8 = undefined;
    var w = std.Io.File.Writer.init(std.Io.File.stderr(), io, &buf);
    w.interface.print("JSR meta not JSON for: {s}\n", .{url}) catch return;
    const preview_len = @min(120, body_trimmed.len);
    if (preview_len > 0) {
        w.interface.print("  body preview: {s}\n", .{body_trimmed[0..preview_len]}) catch return;
    } else {
        w.interface.print("  body: (empty)\n", .{}) catch return;
    }
    w.flush() catch return;
}

/// 当 SHU_DEBUG_HTTP 非空时向 stderr 打印 JSR 请求的 URL 与完整 body 预览，用于排查 JsrMetaNoJsonObject。
fn debugLogJsrResponse(url: []const u8, body_trimmed: []const u8) void {
    const env = std.c.getenv("SHU_DEBUG_HTTP") orelse return;
    if (std.mem.span(env).len == 0) return;
    const io = libs_process.getProcessIo() orelse return;
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.Writer.init(std.Io.File.stderr(), io, &buf);
    w.interface.print("[shu jsr debug] url={s}\n", .{url}) catch return;
    w.interface.print("[shu jsr debug] body_len={d}\n", .{body_trimmed.len}) catch return;
    const preview_len = @min(512, body_trimmed.len);
    if (preview_len > 0) {
        w.interface.print("[shu jsr debug] body_preview (first {d} bytes):\n{s}\n", .{ preview_len, body_trimmed[0..preview_len] }) catch return;
    } else {
        w.interface.print("[shu jsr debug] body_preview: (empty)\n", .{}) catch return;
    }
    w.flush() catch return;
}

/// [Allocates] 从 jsr.io 的 meta.json 解析版本。jsr_spec 为 jsr:@scope/name 或 jsr:@scope/name@version；version_spec 为 "latest" 时用 meta 的 "latest" 字段。返回的切片由调用方 free。
pub fn resolveVersionFromMeta(allocator: std.mem.Allocator, jsr_spec: []const u8) ![]const u8 {
    return resolveVersionFromMetaWithClient(null, allocator, jsr_spec);
}

/// [Allocates] 与 resolveVersionFromMeta 相同；JSR meta 优先读 .shu/cache 下 jsr.io 元数据缓存，未命中再请求 jsr.io，避免无 lockfile 时重复拉 meta.json。
/// 当 client 非 null 时用 fetchUrlForJsrMetaWithClient 复用连接，避免每请求新建 Client 导致多线程下 Zig Client 内部 proxy 等状态异常（如 connect 时 proxy.host 野指针 segfault）。返回的切片由调用方 free。
pub fn resolveVersionFromMetaWithClient(client: ?*std.http.Client, allocator: std.mem.Allocator, jsr_spec: []const u8) ![]const u8 {
    const scope_name = try jsrSpecToScopeAndName(allocator, jsr_spec);
    defer allocator.free(scope_name.scope);
    defer allocator.free(scope_name.name);
    const cache_key = try std.fmt.allocPrint(allocator, "meta/@{s}/{s}", .{ scope_name.scope, scope_name.name });
    defer allocator.free(cache_key);
    const cache_root = cache.getCacheRoot(allocator) catch null;
    defer if (cache_root) |r| allocator.free(r);
    if (cache_root) |root| {
        if (cache.getCachedMetadata(allocator, root, JSR_CACHE_HOST, cache_key)) |cached| {
            defer allocator.free(cached);
            logResolveCacheHit(allocator, "meta", cache_key);
            return parseLatestFromMeta(allocator, cached);
        }
    }
    const meta_url = try buildMetaUrl(allocator, scope_name.scope, scope_name.name);
    defer allocator.free(meta_url);
    const body = if (client) |c|
        registry.fetchUrlForJsrMetaWithClient(c, allocator, meta_url, JSR_FETCH_MAX_BYTES) catch |e| return e
    else
        registry.fetchUrlForJsrMeta(allocator, meta_url, JSR_FETCH_MAX_BYTES) catch |e| return e;
    defer allocator.free(body);
    // 若响应明显是 HTML 或非 JSON，先报明确错误便于排查；空 body 单独报错便于上层重试（连接被关等）
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) {
        logJsrMetaNoJson(meta_url, trimmed);
        debugLogJsrResponse(meta_url, trimmed);
        return error.JsrMetaEmptyResponse;
    }
    if (trimmed.len >= 5 and (std.mem.startsWith(u8, trimmed, "<!DOC") or std.mem.startsWith(u8, trimmed, "<html") or std.mem.startsWith(u8, trimmed, "<HTML")))
        return error.JsrReturnedHtml;
    if (trimmed.len >= 2 and trimmed[0] == 0x1f and trimmed[1] == 0x8b)
        return error.JsrResponseNotDecompressed;
    if (std.mem.indexOfScalar(u8, trimmed, '{') == null) {
        logJsrMetaNoJson(meta_url, trimmed);
        debugLogJsrResponse(meta_url, trimmed);
        return error.JsrMetaNoJsonObject;
    }
    if (cache_root) |root| cache.putCachedMetadata(allocator, root, JSR_CACHE_HOST, cache_key, body) catch {};
    return parseLatestFromMeta(allocator, body);
}

/// jsr:@scope/name 或 jsr:@scope/name@x.y.z 解析为 scope 与 name（不含版本）。返回的 scope/name 由调用方 free。
fn jsrSpecToScopeAndName(allocator: std.mem.Allocator, jsr_spec: []const u8) !struct { scope: []const u8, name: []const u8 } {
    if (!std.mem.startsWith(u8, jsr_spec, "jsr:")) return error.InvalidJsrSpecifier;
    var rest = jsr_spec["jsr:".len..];
    if (rest.len == 0 or rest[0] != '@') return error.InvalidJsrSpecifier;
    rest = rest["@".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidJsrSpecifier;
    const scope = try allocator.dupe(u8, rest[0..slash]);
    var name_part = rest[slash + 1 ..];
    if (std.mem.indexOfScalar(u8, name_part, '@')) |at_pos| name_part = name_part[0..at_pos];
    const name = try allocator.dupe(u8, name_part);
    return .{ .scope = scope, .name = name };
}

/// 构建 jsr.io meta.json URL：https://jsr.io/@scope/name/meta.json
fn buildMetaUrl(allocator: std.mem.Allocator, scope: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/@{s}/{s}/meta.json", .{ JSR_META_BASE, scope, name });
}

/// 从 meta.json 响应体中解析 "latest" 字段作为版本；无 latest 时取 versions 中第一个非 yanked。返回的切片由调用方 free。
/// 响应体可能带前导非 JSON（如 jsr.io 返回的数字前缀），从第一个 '{' 开始解析。
fn parseLatestFromMeta(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    const json_start = std.mem.indexOfScalar(u8, trimmed, '{') orelse return error.JsrMetaNoJsonObject;
    const json_slice = trimmed[json_start..];
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_slice, .{ .allocate = .alloc_always }) catch return error.JsrMetaParseError;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.JsrMetaNotObject;
    if (root.object.get("latest")) |v| {
        if (v == .string and v.string.len > 0) return allocator.dupe(u8, v.string);
    }
    if (root.object.get("versions")) |ver_obj| {
        if (ver_obj == .object) {
            var it = ver_obj.object.iterator();
            if (it.next()) |entry| {
                const ver_str = entry.key_ptr.*;
                if (entry.value_ptr.* == .object) {
                    if (entry.value_ptr.*.object.get("yanked")) |y| {
                        if (y == .bool and y.bool) return error.JsrMetaAllVersionsYanked;
                    }
                }
                return allocator.dupe(u8, ver_str);
            }
        }
    }
    return error.JsrMetaNoLatestOrVersions;
}

/// 从 @scope/name 解析出 scope 与 name（不含前导 @）。用于构建 jsr.io URL。
fn scopeNameFromAtScopeName(allocator: std.mem.Allocator, at_scope_name: []const u8) !struct { scope: []const u8, name: []const u8 } {
    if (at_scope_name.len == 0 or at_scope_name[0] != '@') return error.InvalidJsrSpecifier;
    const rest = at_scope_name[1..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidJsrSpecifier;
    return .{
        .scope = try allocator.dupe(u8, rest[0..slash]),
        .name = try allocator.dupe(u8, rest[slash + 1 ..]),
    };
}

/// 从 jsr: 或 npm: 说明符中截取版本 spec（最后一个 @ 之后）。用于 deno.json imports 解析。
fn specFromImportValue(value: []const u8) []const u8 {
    if (std.mem.lastIndexOf(u8, value, "@")) |idx| {
        if (idx + 1 < value.len) return value[idx + 1 ..];
    }
    return "latest";
}

/// deno.json imports 中的一条依赖：name 为包名（@scope/name 或 npm 名），spec 为版本范围，is_jsr 表示是否走 JSR。name/spec 由调用方 free。
pub const DenoImportDep = struct { name: []const u8, spec: []const u8, is_jsr: bool };

/// [Allocates] 在解析阶段从 jsr.io 直接 GET deno.json（不下载整包），解析 imports。优先读 .shu/cache 下 jsr.io 元数据缓存，未命中再走 fetchUrlForJsrMeta 并写入缓存。返回的列表及项内 name/spec 由调用方 free 并 deinit。
pub fn fetchDenoJsonImportsFromRegistryWithClient(client: ?*std.http.Client, allocator: std.mem.Allocator, scope_name: []const u8, version: []const u8) !?std.ArrayList(DenoImportDep) {
    _ = client;
    const cache_key = try std.fmt.allocPrint(allocator, "deno/{s}/{s}", .{ scope_name, version });
    defer allocator.free(cache_key);
    const cache_root = cache.getCacheRoot(allocator) catch null;
    defer if (cache_root) |r| allocator.free(r);
    if (cache_root) |root| {
        if (cache.getCachedMetadata(allocator, root, JSR_CACHE_HOST, cache_key)) |cached| {
            defer allocator.free(cached);
            logResolveCacheHit(allocator, "deno", cache_key);
            return parseImportsFromContent(allocator, cached) catch return null;
        }
    }
    const sn = scopeNameFromAtScopeName(allocator, scope_name) catch return null;
    defer allocator.free(sn.scope);
    defer allocator.free(sn.name);
    const deno_json_url = try std.fmt.allocPrint(allocator, "{s}/@{s}/{s}/{s}/deno.json", .{ JSR_META_BASE, sn.scope, sn.name, version });
    defer allocator.free(deno_json_url);
    const content = registry.fetchUrlForJsrMeta(allocator, deno_json_url, JSR_FETCH_MAX_BYTES) catch |e| {
        if (e == error.BadStatus) return null;
        return e;
    };
    defer allocator.free(content);
    if (cache_root) |root| cache.putCachedMetadata(allocator, root, JSR_CACHE_HOST, cache_key, content) catch {};
    const list = parseImportsFromContent(allocator, content) catch return null;
    return list;
}

/// [Allocates] 同上，若 deno.json 不存在则尝试 deno.jsonc；deno.json 路径已带缓存，deno.jsonc 拉取前也先查同一 cache key，拉取成功后写入缓存。返回的列表及项内 name/spec 由调用方 free 并 deinit。
pub fn fetchDenoJsonImportsFromRegistryOrJsoncWithClient(client: ?*std.http.Client, allocator: std.mem.Allocator, scope_name: []const u8, version: []const u8) !?std.ArrayList(DenoImportDep) {
    const from_json = fetchDenoJsonImportsFromRegistryWithClient(client, allocator, scope_name, version) catch null;
    if (from_json) |list| return list;
    const cache_key = std.fmt.allocPrint(allocator, "deno/{s}/{s}", .{ scope_name, version }) catch return null;
    defer allocator.free(cache_key);
    const cache_root = cache.getCacheRoot(allocator) catch null;
    defer if (cache_root) |r| allocator.free(r);
    if (cache_root) |root| {
        if (cache.getCachedMetadata(allocator, root, JSR_CACHE_HOST, cache_key)) |cached| {
            defer allocator.free(cached);
            logResolveCacheHit(allocator, "deno", cache_key);
            return parseImportsFromContent(allocator, cached) catch null;
        }
    }
    const sn = scopeNameFromAtScopeName(allocator, scope_name) catch return null;
    defer allocator.free(sn.scope);
    defer allocator.free(sn.name);
    const deno_jsonc_url = try std.fmt.allocPrint(allocator, "{s}/@{s}/{s}/{s}/deno.jsonc", .{ JSR_META_BASE, sn.scope, sn.name, version });
    defer allocator.free(deno_jsonc_url);
    const content = registry.fetchUrlForJsrMeta(allocator, deno_jsonc_url, JSR_FETCH_MAX_BYTES) catch return null;
    defer allocator.free(content);
    if (cache_root) |root| cache.putCachedMetadata(allocator, root, JSR_CACHE_HOST, cache_key, content) catch {};
    return parseImportsFromContent(allocator, content) catch null;
}

/// [Allocates] 读取已安装 JSR 包目录下的 deno.json（或 deno.jsonc）的 imports，解析出 jsr: 与 npm: 依赖列表。（兜底用，优先用 fetchDenoJsonImportsFromRegistry）
/// 返回的列表中每项的 name、spec 由 allocator 分配，调用方负责 free 并 deinit 列表。
pub fn getDenoJsonImports(allocator: std.mem.Allocator, pkg_dir: []const u8) !std.ArrayList(DenoImportDep) {
    const deno_path = try libs_io.pathJoin(allocator, &.{ pkg_dir, "deno.json" });
    defer allocator.free(deno_path);
    var f = libs_io.openFileAbsolute(deno_path, .{}) catch |e| {
        if (e == error.FileNotFound) {
            const deno_jsonc = try libs_io.pathJoin(allocator, &.{ pkg_dir, "deno.jsonc" });
            defer allocator.free(deno_jsonc);
            var fc = libs_io.openFileAbsolute(deno_jsonc, .{}) catch return error.ManifestNotFound;
            defer fc.close();
            const content = try readFileAll(allocator, fc);
            defer allocator.free(content);
            return parseImportsFromContent(allocator, content);
        }
        return e;
    };
    defer f.close();
    const content = try readFileAll(allocator, f);
    defer allocator.free(content);
    return parseImportsFromContent(allocator, content);
}

/// 将文件读入内存（按 getEndPos 分配后 readAll）。调用方 free 返回切片。
fn readFileAll(allocator: std.mem.Allocator, file: std.fs.File) ![]const u8 {
    const size = try file.getEndPos();
    if (size > 1024 * 1024) return error.JsrDenoJsonTooLarge;
    try file.seekTo(0);
    const buf = try allocator.alloc(u8, size);
    _ = try file.readAll(buf);
    return buf;
}

/// 从 deno.json 内容字符串解析 imports 对象，收集 jsr: 与 npm: 依赖。
fn parseImportsFromContent(allocator: std.mem.Allocator, content: []const u8) !std.ArrayList(DenoImportDep) {
    var list = std.ArrayList(DenoImportDep).initCapacity(allocator, 0) catch return error.OutOfMemory;
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    const json_start = std.mem.indexOfScalar(u8, trimmed, '{') orelse return error.JsrDenoJsonNoObject;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed[json_start..], .{ .allocate = .alloc_always }) catch return error.JsrDenoJsonParseError;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.JsrDenoJsonNoObject;
    const imports_ptr = root.object.get("imports") orelse return list;
    if (imports_ptr != .object) return list;
    var it = imports_ptr.object.iterator();
    while (it.next()) |entry| {
        const val = entry.value_ptr.*;
        if (val != .string or val.string.len == 0) continue;
        const value = val.string;
        if (std.mem.startsWith(u8, value, "jsr:")) {
            const name = resolver.jsrSpecToScopeName(allocator, value) catch continue;
            const spec = specFromImportValue(value);
            list.append(allocator, .{
                .name = name,
                .spec = try allocator.dupe(u8, spec),
                .is_jsr = true,
            }) catch continue;
        } else if (std.mem.startsWith(u8, value, "npm:")) {
            const rest = value["npm:".len..];
            // scoped 包如 npm:@tailwindcss/postcss@4.2.0 第一个 @ 属于 scope，用最后一个 @ 分割包名与版本
            const last_at = std.mem.lastIndexOfScalar(u8, rest, '@') orelse continue;
            const name = try allocator.dupe(u8, rest[0..last_at]);
            const spec = if (last_at + 1 < rest.len) rest[last_at + 1 ..] else "latest";
            list.append(allocator, .{
                .name = name,
                .spec = try allocator.dupe(u8, spec),
                .is_jsr = false,
            }) catch {
                allocator.free(name);
                continue;
            };
        }
    }
    return list;
}

/// 单个文件下载任务：url 与 dest_path 由调用方分配，生命周期覆盖并行下载全程
const JsrFileTask = struct { url: []const u8, dest_path: []const u8 };

/// 将指定版本的 JSR 包按 jsr.io 原生 API 下载到 dest_dir：先查 ~/.shu/cache 是否已有该包，命中则直接软链；未命中则拉 version_meta.json、并行下载到缓存目录再软链到 dest_dir。
/// pool 非 null 时使用传入的池（调用方负责在适当时机 deinit）；为 null 时使用全局 getOrCreatePool(allocator)。
/// fetch_io 非 null 时用其拉取 _meta.json，避免多线程共享 process Io 导致 EISCONN；为 null 时使用 libs_process.getProcessIo()（单线程或兼容旧调用方）。
/// 单包内解析与 task 列表使用 ArenaAllocator，结束时一次 deinit，减少碎片化分配。首包 version_meta 用 std.http.Client（Zig 路径）拉取。
pub fn downloadPackageToDir(allocator: std.mem.Allocator, pool: ?*JsrDownloadPool, scope_name: []const u8, version: []const u8, dest_dir: []const u8, fetch_io: ?std.Io) !void {
    libs_io.makePathAbsolute(dest_dir) catch {};
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sn = try scopeNameFromAtScopeName(a, scope_name);
    const cache_root = cache.getCacheRoot(a) catch null;
    if (cache_root) |cr| {
        const key = try std.fmt.allocPrint(a, "jsr/{s}/{s}/{s}", .{ sn.scope, sn.name, version });
        if (cache.getCachedJsrPackageDir(a, cr, key)) |cached_dir| {
            if (libs_io.pathDirname(dest_dir)) |parent| libs_io.makePathAbsolute(parent) catch {};
            var link_target_buf: [libs_io.max_path_bytes]u8 = undefined;
            const link_target = libs_io.realpath(cached_dir, &link_target_buf) catch cached_dir;
            libs_io.symLinkAbsolute(link_target, dest_dir, .{}) catch |e| return e;
            return;
        }
    }

    const version_meta_url = try std.fmt.allocPrint(a, "{s}/@{s}/{s}/{s}_meta.json", .{ JSR_META_BASE, sn.scope, sn.name, version });
    const io = fetch_io orelse libs_process.getProcessIo() orelse return error.ProcessIoNotSet;
    var zig_client = std.http.Client{ .allocator = a, .io = io };
    defer zig_client.deinit();
    const body = registry.fetchUrlForJsrMetaWithClient(&zig_client, a, version_meta_url, JSR_FETCH_MAX_BYTES) catch |e| return e;
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    const json_start = std.mem.indexOfScalar(u8, trimmed, '{') orelse {
        debugLogJsrResponse(version_meta_url, trimmed);
        return error.JsrMetaNoJsonObject;
    };
    var parsed = std.json.parseFromSlice(std.json.Value, a, trimmed[json_start..], .{ .allocate = .alloc_always }) catch return error.JsrMetaParseError;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.JsrMetaNotObject;
    const manifest_ptr = root.object.get("manifest") orelse return error.JsrMetaNoManifest;
    if (manifest_ptr != .object) return error.JsrMetaNoManifest;
    const base_url = try std.fmt.allocPrint(a, "{s}/@{s}/{s}/{s}", .{ JSR_META_BASE, sn.scope, sn.name, version });

    // 有缓存根则下载到缓存目录，再软链到 dest_dir；无则直接下载到 dest_dir（兼容旧行为）
    const base_dir: []const u8 = blk: {
        if (cache_root) |cr| {
            const key = try std.fmt.allocPrint(a, "jsr/{s}/{s}/{s}", .{ sn.scope, sn.name, version });
            const cache_dir_path = try cache.getCachedPackageDirPath(a, cr, key);
            libs_io.makePathAbsolute(cache_dir_path) catch {};
            break :blk cache_dir_path;
        }
        break :blk dest_dir;
    };

    var tasks = std.ArrayList(JsrFileTask).initCapacity(a, 64) catch return error.OutOfMemory;
    defer tasks.deinit(a);
    var it = manifest_ptr.object.iterator();
    while (it.next()) |entry| {
        const path_key = entry.key_ptr.*;
        if (path_key.len == 0 or path_key[0] != '/') continue;
        const rel = path_key[1..];
        const file_url = if (rel.len == 0) base_url else try std.fmt.allocPrint(a, "{s}/{s}", .{ base_url, rel });
        const dest_path = try libs_io.pathJoin(a, &.{ base_dir, rel });
        if (libs_io.pathDirname(dest_path)) |parent| {
            libs_io.makePathAbsolute(parent) catch {};
        }
        try tasks.append(a, .{ .url = file_url, .dest_path = dest_path });
    }
    if (tasks.items.len == 0) return;

    const p = if (pool) |pp| pp else try getOrCreatePool(allocator);
    try p.submit(tasks.items, fetch_io);

    if (cache_root != null and base_dir.ptr != dest_dir.ptr) {
        if (libs_io.pathDirname(dest_dir)) |parent| libs_io.makePathAbsolute(parent) catch {};
        var link_target_buf: [libs_io.max_path_bytes]u8 = undefined;
        const link_target = libs_io.realpath(base_dir, &link_target_buf) catch base_dir;
        libs_io.symLinkAbsolute(link_target, dest_dir, .{}) catch |e| return e;
    }
    // task 的 url/dest_path 均在 arena 内，由 defer arena.deinit() 统一释放
}
