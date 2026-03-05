//! Shu.fs：文件与目录 I/O，同步方法 + 异步 Promise（纯 Zig 延迟队列，无内联 JS）。路径均相对 process.cwd 解析为绝对路径后操作。
//!
//! ## 权限
//! - 读相关（read/readFile/readdir/stat/exists/realpath/lstat/size/isFile/isDirectory/readdirWithStats/readlink）：需 **--allow-read**
//! - 写相关（write/writeFile/mkdir/unlink/rmdir/rename/copy/append/symlink/truncate/ensureDir/ensureFile/mkdirRecursive/rmdirRecursive）：需 **--allow-write** 或 **--allow-read+--allow-write**（如 rename/copy）
//! - access：按传入 mode 检查可读/可写/可执行
//!
//! ## 提供 API（同步 + 异步，异步返回 Promise）
//!
//! ### 读/写
//! - **readSync(path [, options])** / **read(path [, options])**：读文件；options.encoding 为 null 时返回 Uint8Array（零拷贝/大文件 mmap），否则 UTF-8 字符串。别名 **readFileSync** / **readFile**
//! - **writeSync(path, content)** / **write(path, content)**：写文件（覆盖）。别名 **writeFileSync** / **writeFile**。异步 content 上限 512KB
//! - **appendSync(path, content)** / **append(path, content)**：追加写，不存在则创建。别名 **appendFileSync** / **appendFile**
//!
//! ### 目录
//! - **readdirSync(path)** / **readdir(path)**：目录项名列表 string[]
//! - **mkdirSync(path)** / **mkdir(path)**：创建单层目录
//! - **mkdirRecursiveSync(path)** / **mkdirRecursive(path)**：递归创建（mkdir -p）。别名 **ensureDirSync** / **ensureDir**
//! - **rmdirSync(path)** / **rmdir(path)**：删空目录
//! - **rmdirRecursiveSync(path)** / **rmdirRecursive(path)**：递归删除目录及内容
//!
//! ### 存在与元信息
//! - **existsSync(path)** / **exists(path)**：是否存在，返回 boolean
//! - **statSync(path)** / **stat(path)**：元数据 { isFile, isDirectory, size, mtimeMs }
//! - **lstatSync(path)** / **lstat(path)**：不跟符号链接的 stat，返回对象含 **isSymbolicLink**
//! - **realpathSync(path)** / **realpath(path)**：规范绝对路径（解析 .、.. 与符号链接）
//! - **sizeSync(path)** / **size(path)**：仅文件大小（Shu 特色）
//! - **isFileSync(path)** / **isFile(path)**、**isDirectorySync(path)** / **isDirectory(path)**：是否文件/目录（Shu 特色）
//! - **readdirWithStatsSync(path)** / **readdirWithStats(path)**：目录项 + 每项简化 stat，一次调用（Shu 特色）
//! - **isEmptyDirSync(path)** / **isEmptyDir(path)**：是否空目录（Shu 特色）
//!
//! ### 删除 / 重命名 / 复制
//! - **unlinkSync(path)** / **unlink(path)**：删文件
//! - **renameSync(oldPath, newPath)** / **rename(oldPath, newPath)**：重命名/移动
//! - **copySync(src, dest)** / **copy(src, dest)**：复制文件。大文件走 mmap。别名 **copyFileSync** / **copyFile**
//!
//! ### 链接
//! - **symlinkSync(targetPath, linkPath)** / **symlink(targetPath, linkPath)**：创建符号链接
//! - **readlinkSync(linkPath)** / **readlink(linkPath)**：读链接目标路径 string
//!
//! ### 其它
//! - **truncateSync(path [, len])** / **truncate(path [, len])**：截断到指定长度
//! - **accessSync(path [, mode])** / **access(path [, mode])**：按 R/W/X 检查可访问性
//! - **ensureFileSync(path)** / **ensureFile(path)**：不存在则创建空文件（含父目录），存在则不动（Shu 特色）
//!
//! ### 监视
//! - **watch(path [, options] [, listener])**：监视文件/目录变更，返回 FSWatcher（含 close()）；listener(eventType, filename)，eventType 为 'change' 或 'rename'；options.recursive 暂不支持；需 --allow-read；Linux(inotify)/Darwin(kqueue EVFILT_VNODE)/Windows(ReadDirectoryChangesW) 三端已实现。
//!
//! ## fs.watch 与 Node / Deno / Bun 兼容性
//! - **Node.js (node:fs)**：签名与回调 (eventType, filename) 一致；返回值为「仅含 close() 的普通对象」而非 EventEmitter。差异：① 无 listener 时本实现返回 undefined，Node 仍返回 FSWatcher（可后续 .on('change', fn)）；② 无 .on('change'|'close'|'error')，仅支持传入的 listener；③ options 仅解析 recursive（暂不支持），无 encoding/persistent。常见用法 fs.watch(dir, (ev, name) => {}) 与 watcher.close() 可直接复用，无需适配。
//! - **Bun**：实现与 Node fs.watch 对齐，故与上同；Bun 的 (event, filename) 与 shujs 的 (eventType, filename) 一致。
//! - **Deno**：Deno 使用 Deno.watchFs()（异步迭代 for await），与 node:fs.watch 非同一 API；若需在 Deno 下跑 node 风格代码，需用 npm 兼容层或自行封装 watchFs→(eventType, filename) 的适配，shujs 侧无需改。
//!
//! ## 与 Node.js (node:fs) 兼容情况
//! - readFileSync/readFile、writeFileSync/writeFile、copyFileSync/copyFile、appendFileSync/appendFile 与 readSync/read、writeSync/write、copySync/copy、appendSync/append 同实现
//! - ensureDirSync/ensureDir 与 mkdirRecursiveSync/mkdirRecursive 同实现
//! - realpath、lstat、truncate、access、readdirWithStats（对应 withFileTypes 场景）、ensureFile 等均已提供；stat/lstat 返回对象含 isSymbolicLink
//!
//! ## 性能与约定
//! - 异步：纯 Zig 实现，无内联 JS；Promise 构造时入延迟队列，在 drain（drainFileIOCompletions）中执行同步逻辑并 resolve/reject
//! - readSync(path, { encoding: null }) 返回 Buffer 时：小文件 Zig 分配 + JSC NoCopy；大文件（≥FS_MAP_THRESHOLD）走 libs_io.mapFileReadOnly，零拷贝
//! - copySync 大文件：源 mmap + 整块写，减少 OOM 与拷贝
//! - 所有需要分配内存的路径均使用调用方传入的 allocator（globals.current_allocator），谁分配谁释放
//!
//! ## §3.0 性能规则：I/O 经 io_core
//! - 文件/目录操作：openFileAbsolute、openDirAbsolute、realpath、makeDirAbsolute、deleteFileAbsolute、deleteDirAbsolute、renameAbsolute、accessAbsolute、createFileAbsolute 均经 io_core（file.zig 薄封装）。
//! - 大文件/异步：readSync(encoding:null) 大文件 → libs_io.mapFileReadOnly；copySync 大文件 → mapFileReadOnly + 整块写；异步 read/write → libs_io.AsyncFileIO。
//! - 符号链接与路径解析：readLinkAbsolute、symLinkAbsolute、pathDirname/pathBasename/pathJoin/pathResolve 等均经 io_core（file.zig 薄封装）。

const std = @import("std");
const jsc = @import("jsc");
const libs_io = @import("libs_io");
// 从 modules/shu/fs 引用 runtime 上层与 engine
const errors = @import("errors");
const libs_process = @import("libs_process");
const globals = @import("../../../globals.zig");
const common = @import("../../../common.zig");
const promise = @import("../promise.zig");
const timer_state = @import("../timers/state.zig");

/// 超过此大小的文件在 readSync(encoding:null) 时用 libs_io.mapFileReadOnly；copySync 源文件超过此值时用 mmap 读+整块写
const FS_MAP_THRESHOLD = 256 * 1024;
/// 异步 read 单次提交最大字节数，超过则回退 setTimeout+readSync
const ASYNC_READ_MAX_BYTES = 64 * 1024 * 1024;

/// 用于 readSync(..., { encoding: null }) 返回 Buffer 时：JSC 回收 ArrayBuffer 时调此回调释放 Zig 分配的 content
fn fileBufferDeallocator(bytes: *anyopaque, deallocator_context: ?*anyopaque) callconv(.c) void {
    _ = bytes;
    const ctx = @as(*FileBufferDeallocContext, @ptrCast(@alignCast(deallocator_context orelse return)));
    ctx.allocator.free(ctx.slice);
    ctx.allocator.destroy(ctx);
}
const FileBufferDeallocContext = struct {
    allocator: std.mem.Allocator,
    slice: []u8,
};

/// 大文件 readSync(encoding:null) 时用 libs_io.mapFileReadOnly；JSC 回收时调 mapped.deinit 并释放本结构
const MappedFileContext = struct {
    allocator: std.mem.Allocator,
    mapped: libs_io.MappedFile,
};
fn mappedFileDeallocator(bytes: *anyopaque, deallocator_context: ?*anyopaque) callconv(.c) void {
    _ = bytes;
    const ctx = @as(*MappedFileContext, @ptrCast(@alignCast(deallocator_context orelse return)));
    ctx.mapped.deinit();
    ctx.allocator.destroy(ctx);
}

// ---------- 异步文件 I/O 状态（libs_io.AsyncFileIO + pending 表，drain 时 resolve/reject）----------

/// 单条待完成的异步文件操作：read 或 write，完成时由 drain 根据 user_data 查表并 resolve/reject
const PendingEntry = struct {
    resolve: jsc.JSValueRef,
    reject: jsc.JSValueRef,
    file: libs_io.File,
    allocator: std.mem.Allocator,
    kind: enum { read, write },
    /// read 时：读入数据的 buffer，drain 时交 JSC 或 free
    read_buffer: ?[]u8 = null,
    /// read 时：是否以 Buffer 返回（否则 UTF-8 字符串）
    return_buffer: bool = false,
    /// write 时：写入内容的拷贝，drain 时 free
    write_data: ?[]const u8 = null,
};

/// 每线程异步 fs 状态：AsyncFileIO 实例与 pending 表；首次 Shu.fs.read/Shu.fs.write（异步）时按需创建。pending 为 Unmanaged，put 显式传 allocator（01 §1.2）
const FsAsyncState = struct {
    allocator: std.mem.Allocator,
    pending: std.AutoHashMapUnmanaged(usize, PendingEntry),
    next_id: usize,
    async_file_io: *libs_io.AsyncFileIO,
};
var fs_async_state: ?*FsAsyncState = null;

/// 单条 fs.watch 注册：句柄 + 主线程回调（listener）；drain 时用 ctx 调用 callback(eventType, filename)
const FsWatcherEntry = struct {
    handle: *libs_io.WatchHandle,
    ctx: jsc.JSGlobalContextRef,
    callback: jsc.JSValueRef,
};
/// fs.watch 活跃监视列表；首次 watch() 时按需创建并设置 globals.drain_fs_watch
/// map: watcher 对象指针 (usize) -> handle，供 close() 查找
const FsWatchersState = struct {
    list: std.ArrayListUnmanaged(FsWatcherEntry) = .{},
    /// key = @intFromPtr(watcher_obj)，value = handle，close 时据此找到 handle 并从 list 移除
    map: std.AutoHashMapUnmanaged(usize, *libs_io.WatchHandle) = .{},
    allocator: std.mem.Allocator,
};
var g_fs_watchers: ?*FsWatchersState = null;

/// 确保 g_fs_watchers 与 drain_fs_watch 已初始化；首次 watch() 时调用
fn ensureFsWatchersState() !*FsWatchersState {
    if (g_fs_watchers) |s| return s;
    const allocator = globals.current_allocator orelse return error.NoAllocator;
    const state = allocator.create(FsWatchersState) catch return error.OutOfMemory;
    state.* = .{ .allocator = allocator };
    globals.drain_fs_watch = drainFsWatch;
    g_fs_watchers = state;
    return state;
}

/// 供 Promise executor 使用：read 时传入 resolved 路径与 return_buffer，executor 内取走后清空
var fs_read_promise_args: ?struct { resolved: []const u8, return_buffer: bool } = null;
/// 供 Promise executor 使用：write 时传入 resolved 路径与 content，executor 内取走后清空
var fs_write_promise_args: ?struct { resolved: []const u8, content: []const u8 } = null;

/// 确保当前线程有 AsyncFileIO 与 FsAsyncState；创建时设置 globals.current_async_file_io 与 globals.drain_async_file_io。调用方须持有 current_allocator。
fn ensureAsyncFileIO() !*FsAsyncState {
    if (fs_async_state) |s| return s;
    const allocator = globals.current_allocator orelse return error.NoAllocator;
    var fio = allocator.create(libs_io.AsyncFileIO) catch return error.OutOfMemory;
    fio.* = libs_io.AsyncFileIO.init(allocator) catch |e| {
        allocator.destroy(fio);
        return e;
    };
    globals.current_async_file_io = fio;
    globals.drain_async_file_io = drainFileIOCompletions;
    var state = allocator.create(FsAsyncState) catch {
        fio.deinit();
        allocator.destroy(fio);
        globals.current_async_file_io = null;
        globals.drain_async_file_io = null;
        return error.OutOfMemory;
    };
    state.allocator = allocator;
    state.pending = .{};
    state.next_id = 1;
    state.async_file_io = fio;
    fs_async_state = state;
    return state;
}

// ---------- 纯 Zig 异步：延迟任务队列（无内联 JS），在 drain 中执行同步逻辑并 resolve/reject ----------

/// 延迟执行的 fs 操作类型（与 Sync 方法一一对应）
const DeferredFsOpTag = enum {
    realpath,
    lstat,
    truncate,
    access,
    isEmptyDir,
    size,
    isFile,
    isDirectory,
    readdirWithStats,
    ensureFile,
    stat,
    readdir,
    mkdir,
    exists,
    unlink,
    rmdir,
    rename,
    copy,
    append,
    write,
    readlink,
    symlink,
    readFile,
    mkdirRecursive,
    rmdirRecursive,
};

/// 单条延迟 fs 任务：path 为已解析的绝对路径；path2 用于 rename/copy/symlink；content 用于 write/append；return_buffer 仅 .readFile 时有效
const DeferredFsOp = struct {
    tag: DeferredFsOpTag,
    allocator: std.mem.Allocator,
    path: []const u8,
    path2: ?[]const u8 = null,
    content: ?[]const u8 = null,
    len: u64 = 0,
    mode: u32 = 0,
    return_buffer: bool = false,
    resolve: jsc.JSValueRef,
    reject: jsc.JSValueRef,
};

/// 当前待挂载 resolve/reject 的 op（executor 被 JSC 调用时写入并入队）；Promise 构造时 JSC 同步调用 executor，故每线程同时仅有一个 current
var deferred_fs_current_op: DeferredFsOp = undefined;
/// 当前待挂载 resolve/reject 的 op（executor 被 JSC 调用时写入并入队）
var current_deferred_fs_op: ?*DeferredFsOp = null;
/// 延迟队列；Unmanaged 不存 allocator，append/orderedRemove 显式传 allocator（01 §1.2、00 §1.5）
var deferred_fs_queue: ?std.ArrayListUnmanaged(DeferredFsOp) = null;

// ---------- read/write 回退到「微任务 + Shu.fs.xxxSync」的纯 Zig 路径（无内联 JS） ----------

/// 单参/双参 Sync 回退的 payload：微任务执行时从 global 取 Shu.fs[method_name]、JSON.parse 后调用并 resolve/reject；path_json/path2_json 为 dupeZ 所有权
const FsSyncFallbackPayload = struct {
    allocator: std.mem.Allocator,
    ctx: jsc.JSContextRef,
    resolve: jsc.JSValueRef,
    reject: jsc.JSValueRef,
    method_name: []const u8,
    path_json: []const u8,
    path2_json: ?[]const u8,
};
/// 待执行的 Sync 回退微任务队列；微任务回调每次弹出队首执行并释放 payload
var pending_fs_sync_fallback_list: ?std.ArrayListUnmanaged(*FsSyncFallbackPayload) = null;

/// 确保 pending_fs_sync_fallback_list 已初始化，便于首次 append
fn ensurePendingFsSyncFallbackList(allocator: std.mem.Allocator) void {
    if (pending_fs_sync_fallback_list == null) {
        pending_fs_sync_fallback_list = std.ArrayListUnmanaged(*FsSyncFallbackPayload).initCapacity(allocator, 8) catch return;
    }
}

/// 微任务被 runMicrotasks 调用时执行：弹出队首 payload，取 Shu.fs[method]、JSON.parse(path_json[, path2_json])，调用同步方法后 resolve(result) 或 reject(exception)
fn fsSyncFallbackMicrotaskCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    var list_opt = pending_fs_sync_fallback_list orelse return jsc.JSValueMakeUndefined(ctx);
    if (list_opt.items.len == 0) return jsc.JSValueMakeUndefined(ctx);
    const payload = list_opt.orderedRemove(0);
    pending_fs_sync_fallback_list = list_opt;
    defer {
        jsc.JSValueUnprotect(ctx, payload.resolve);
        jsc.JSValueUnprotect(ctx, payload.reject);
        allocator.free(payload.path_json);
        if (payload.path2_json) |p2| allocator.free(p2);
        allocator.destroy(payload);
    }
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_Shu = jsc.JSStringCreateWithUTF8CString("Shu");
    defer jsc.JSStringRelease(k_Shu);
    const k_fs = jsc.JSStringCreateWithUTF8CString("fs");
    defer jsc.JSStringRelease(k_fs);
    const Shu = jsc.JSObjectGetProperty(ctx, global, k_Shu, null);
    const fs_obj = jsc.JSObjectGetProperty(ctx, @ptrCast(Shu), k_fs, null);
    const method_name_str = jsc.JSStringCreateWithUTF8CString(payload.method_name.ptr);
    defer jsc.JSStringRelease(method_name_str);
    const method_val = jsc.JSObjectGetProperty(ctx, @ptrCast(fs_obj), method_name_str, null);
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(method_val))) {
        const rej_fn = jsc.JSValueToObject(ctx, payload.reject, null);
        var rej_args: [1]jsc.JSValueRef = .{jsc.JSValueMakeUndefined(ctx)};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(rej_fn), null, 1, &rej_args, null);
        return jsc.JSValueMakeUndefined(ctx);
    }
    const k_JSON = jsc.JSStringCreateWithUTF8CString("JSON");
    defer jsc.JSStringRelease(k_JSON);
    const k_parse = jsc.JSStringCreateWithUTF8CString("parse");
    defer jsc.JSStringRelease(k_parse);
    const JSON_obj = jsc.JSObjectGetProperty(ctx, global, k_JSON, null);
    const parse_fn = jsc.JSObjectGetProperty(ctx, @ptrCast(JSON_obj), k_parse, null);
    const path_str_ref = jsc.JSStringCreateWithUTF8CString(payload.path_json.ptr);
    defer jsc.JSStringRelease(path_str_ref);
    const path_js = jsc.JSValueMakeString(ctx, path_str_ref);
    var parse_args: [1]jsc.JSValueRef = .{path_js};
    var exception: ?jsc.JSValueRef = null;
    const parsed_a = jsc.JSObjectCallAsFunction(ctx, @ptrCast(parse_fn), @ptrCast(JSON_obj), 1, &parse_args, @ptrCast(&exception));
    if (exception != null) {
        const rej_fn = jsc.JSValueToObject(ctx, payload.reject, null);
        var rej_args: [1]jsc.JSValueRef = .{exception.?};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(rej_fn), null, 1, &rej_args, null);
        return jsc.JSValueMakeUndefined(ctx);
    }
    if (payload.path2_json) |b_json| {
        const b_str_ref = jsc.JSStringCreateWithUTF8CString(b_json.ptr);
        defer jsc.JSStringRelease(b_str_ref);
        const b_js = jsc.JSValueMakeString(ctx, b_str_ref);
        var parse_b_args: [1]jsc.JSValueRef = .{b_js};
        const parsed_b = jsc.JSObjectCallAsFunction(ctx, @ptrCast(parse_fn), @ptrCast(JSON_obj), 1, &parse_b_args, @ptrCast(&exception));
        if (exception != null) {
            const rej_fn = jsc.JSValueToObject(ctx, payload.reject, null);
            var rej_args: [1]jsc.JSValueRef = .{exception.?};
            _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(rej_fn), null, 1, &rej_args, null);
            return jsc.JSValueMakeUndefined(ctx);
        }
        var call_args: [2]jsc.JSValueRef = .{ parsed_a, parsed_b };
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(method_val), @ptrCast(fs_obj), 2, &call_args, @ptrCast(&exception));
        if (exception != null) {
            const resolve_fn = jsc.JSValueToObject(ctx, payload.reject, null);
            var rej_args: [1]jsc.JSValueRef = .{exception.?};
            _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(resolve_fn), null, 1, &rej_args, null);
            return jsc.JSValueMakeUndefined(ctx);
        }
        const resolve_fn = jsc.JSValueToObject(ctx, payload.resolve, null);
        var empty_args: [0]jsc.JSValueRef = .{};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(resolve_fn), null, 0, &empty_args, null);
        return jsc.JSValueMakeUndefined(ctx);
    }
    var one_arg: [1]jsc.JSValueRef = .{parsed_a};
    const result = jsc.JSObjectCallAsFunction(ctx, @ptrCast(method_val), @ptrCast(fs_obj), 1, &one_arg, @ptrCast(&exception));
    if (exception != null) {
        const rej_fn = jsc.JSValueToObject(ctx, payload.reject, null);
        var rej_args: [1]jsc.JSValueRef = .{exception.?};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(rej_fn), null, 1, &rej_args, null);
        return jsc.JSValueMakeUndefined(ctx);
    }
    const resolve_fn = jsc.JSValueToObject(ctx, payload.resolve, null);
    var res_args: [1]jsc.JSValueRef = .{result};
    _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(resolve_fn), null, 1, &res_args, null);
    return jsc.JSValueMakeUndefined(ctx);
}

/// promise.createWithExecutor 的 Zig 回调：把 resolve/reject 写入 payload，Protect 后入队并 enqueueMicrotask(__fsSyncFallbackMicrotask)
fn fsSyncFallbackOnExecutor(ctx: jsc.JSContextRef, resolve_val: jsc.JSValueRef, reject_val: jsc.JSValueRef, user_data: ?*anyopaque) void {
    const payload = @as(*FsSyncFallbackPayload, @ptrCast(@alignCast(user_data orelse return)));
    payload.resolve = resolve_val;
    payload.reject = reject_val;
    jsc.JSValueProtect(ctx, resolve_val);
    jsc.JSValueProtect(ctx, reject_val);
    const allocator = globals.current_allocator orelse return;
    ensurePendingFsSyncFallbackList(allocator);
    var list = &pending_fs_sync_fallback_list.?;
    list.append(allocator, payload) catch return;
    const state = globals.current_timer_state orelse return;
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k = jsc.JSStringCreateWithUTF8CString("__fsSyncFallbackMicrotask");
    defer jsc.JSStringRelease(k);
    const fn_val = jsc.JSObjectGetProperty(ctx, global, k, null);
    if (jsc.JSValueIsUndefined(ctx, fn_val) or jsc.JSValueIsNull(ctx, fn_val)) return;
    const fn_obj = jsc.JSValueToObject(ctx, fn_val, null) orelse return;
    if (!jsc.JSObjectIsFunction(ctx, fn_obj)) return;
    jsc.JSValueProtect(ctx, fn_val);
    state.enqueueMicrotask(@ptrCast(ctx), fn_val);
}

/// 确保延迟队列已初始化；调用方须持有 current_allocator
fn ensureDeferredFsQueue() !void {
    if (deferred_fs_queue != null) return;
    const allocator = globals.current_allocator orelse return error.NoAllocator;
    deferred_fs_queue = std.ArrayListUnmanaged(DeferredFsOp).initCapacity(allocator, 0) catch return error.NoAllocator;
}

/// promise.createWithExecutor 的 Zig 回调：将 resolve/reject 写入 op，path/path2/content 复制后入队并释放原指针
fn fsDeferredOnExecutor(ctx: jsc.JSContextRef, resolve_val: jsc.JSValueRef, reject_val: jsc.JSValueRef, user_data: ?*anyopaque) void {
    const op = @as(*DeferredFsOp, @alignCast(@ptrCast(user_data orelse return)));
    current_deferred_fs_op = null;
    const allocator = op.allocator;
    const path_dup = allocator.dupe(u8, op.path) catch return;
    allocator.free(op.path);
    const path2_dup = if (op.path2) |p| allocator.dupe(u8, p) catch null else null;
    if (op.path2) |p| allocator.free(p);
    const content_dup = if (op.content) |c| allocator.dupe(u8, c) catch null else null;
    if (op.content) |c| allocator.free(c);
    const entry = DeferredFsOp{
        .tag = op.tag,
        .allocator = allocator,
        .path = path_dup,
        .path2 = path2_dup,
        .content = content_dup,
        .len = op.len,
        .mode = op.mode,
        .return_buffer = op.return_buffer,
        .resolve = resolve_val,
        .reject = reject_val,
    };
    jsc.JSValueProtect(ctx, entry.resolve);
    jsc.JSValueProtect(ctx, entry.reject);
    if (deferred_fs_queue) |*q| {
        q.append(allocator, entry) catch {
            allocator.free(path_dup);
            if (path2_dup) |p| allocator.free(p);
            if (content_dup) |c| allocator.free(c);
        };
    }
}

/// 在 drain 中执行单条延迟任务：按 tag 跑同步逻辑，resolve(result) 或 reject(err)，释放 path/path2/content 并 Unprotect
fn runDeferredFsOp(ctx: jsc.JSContextRef, op: *const DeferredFsOp) void {
    const opts = globals.current_run_options orelse return;
    const allocator = op.allocator;
    defer allocator.free(op.path);
    defer {
        if (op.path2) |p2| allocator.free(p2);
        if (op.content) |c| allocator.free(c);
    }
    jsc.JSValueUnprotect(ctx, op.resolve);
    jsc.JSValueUnprotect(ctx, op.reject);
    const resolve_fn = jsc.JSValueToObject(ctx, op.resolve, null) orelse return;
    const reject_fn = jsc.JSValueToObject(ctx, op.reject, null) orelse return;
    const do_reject = struct {
        fn f(ctx_ref: jsc.JSContextRef, fn_obj: jsc.JSObjectRef, alloc: std.mem.Allocator, msg: []const u8) void {
            const msg_z = alloc.dupeZ(u8, msg) catch return;
            defer alloc.free(msg_z);
            const ref = jsc.JSStringCreateWithUTF8CString(msg_z.ptr);
            defer jsc.JSStringRelease(ref);
            var arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeString(ctx_ref, ref)};
            _ = jsc.JSObjectCallAsFunction(ctx_ref, fn_obj, null, 1, &arg, null);
        }
    }.f;
    const io = libs_process.getProcessIo() orelse {
        do_reject(ctx, reject_fn, allocator, "process io not set");
        return;
    };
    switch (op.tag) {
        .realpath => {
            if (!opts.permissions.allow_read) {
                do_reject(ctx, reject_fn, allocator, "Shu.fs.realpath requires --allow-read");
                return;
            }
            var buf: [libs_io.max_path_bytes]u8 = undefined;
            const canonical = libs_io.realpath(op.path, &buf) catch {
                do_reject(ctx, reject_fn, allocator, "realpath failed");
                return;
            };
            const dup = allocator.dupe(u8, canonical) catch {
                do_reject(ctx, reject_fn, allocator, "out of memory");
                return;
            };
            defer allocator.free(dup);
            const z = allocator.dupeZ(u8, dup) catch return;
            defer allocator.free(z);
            const ref = jsc.JSStringCreateWithUTF8CString(z.ptr);
            defer jsc.JSStringRelease(ref);
            var res_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeString(ctx, ref)};
            _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &res_arg, null);
        },
        .lstat => {
            if (!opts.permissions.allow_read) {
                do_reject(ctx, reject_fn, allocator, "Shu.fs.lstat requires --allow-read");
                return;
            }
            const dir_path = libs_io.pathDirname(op.path) orelse ".";
            const base = libs_io.pathBasename(op.path);
            var dir = libs_io.openDirAbsolute(dir_path, .{}) catch {
                do_reject(ctx, reject_fn, allocator, "lstat failed");
                return;
            };
            defer dir.close(io);
            const s = if (base.len == 0) dir.stat(io) catch {
                do_reject(ctx, reject_fn, allocator, "lstat failed");
                return;
            } else dir.statFile(io, base, .{}) catch {
                do_reject(ctx, reject_fn, allocator, "lstat failed");
                return;
            };
            const is_file = (s.kind == .file);
            const is_dir = (s.kind == .directory);
            const is_sym = (s.kind == .sym_link);
            const mtime_ns: i64 = @intCast(@min(s.mtime.nanoseconds, std.math.maxInt(i64)));
            const obj = makeStatObjectWithSymlink(ctx, is_file, is_dir, is_sym, s.size, mtime_ns);
            var res_arg: [1]jsc.JSValueRef = .{obj};
            _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &res_arg, null);
        },
        .truncate => {
            if (!opts.permissions.allow_write) {
                do_reject(ctx, reject_fn, allocator, "Shu.fs.truncate requires --allow-write");
                return;
            }
            const file = libs_io.openFileAbsolute(op.path, .{ .mode = .read_write }) catch {
                do_reject(ctx, reject_fn, allocator, "truncate failed");
                return;
            };
            defer file.close(io);
            if (std.c.ftruncate(file.handle, @as(std.c.off_t, @intCast(op.len))) < 0) {
                std.posix.unexpectedErrno(std.c.errno(-1)) catch {};
                do_reject(ctx, reject_fn, allocator, "ftruncate failed");
                return;
            }
            const empty: [0]jsc.JSValueRef = .{};
            _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 0, &empty, null);
        },
        .access => {
            if (!opts.permissions.allow_read) {
                var false_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeBoolean(ctx, false)};
                _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &false_arg, null);
                return;
            }
            var flags: libs_io.FileOpenFlags = .{};
            if (op.mode & 1 != 0) flags.mode = .read_only;
            if (op.mode & 2 != 0) flags.mode = if (op.mode & 1 != 0) .read_write else .write_only;
            libs_io.accessAbsolute(op.path, flags) catch {
                var false_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeBoolean(ctx, false)};
                _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &false_arg, null);
                return;
            };
            var true_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeBoolean(ctx, true)};
            _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &true_arg, null);
        },
        .isEmptyDir => {
            if (!opts.permissions.allow_read) {
                var false_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeBoolean(ctx, false)};
                _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &false_arg, null);
                return;
            }
            var dir = libs_io.openDirAbsolute(op.path, .{ .iterate = true }) catch {
                var false_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeBoolean(ctx, false)};
                _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &false_arg, null);
                return;
            };
            defer dir.close(io);
            var iter = dir.iterate();
            var has_any = false;
            while (iter.next(io) catch {
                var false_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeBoolean(ctx, false)};
                _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &false_arg, null);
                return;
            }) |_| {
                has_any = true;
                break;
            }
            var res_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeBoolean(ctx, !has_any)};
            _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &res_arg, null);
        },
        .size => {
            if (!opts.permissions.allow_read) {
                do_reject(ctx, reject_fn, allocator, "Shu.fs.size requires --allow-read");
                return;
            }
            const file = libs_io.openFileAbsolute(op.path, .{}) catch |e| {
                if (e == libs_io.FileOpenError.IsDir) {
                    var zero_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeNumber(ctx, 0)};
                    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &zero_arg, null);
                    return;
                }
                do_reject(ctx, reject_fn, allocator, "size failed");
                return;
            };
            defer file.close(io);
            const s = file.stat(io) catch {
                do_reject(ctx, reject_fn, allocator, "stat failed");
                return;
            };
            var res_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeNumber(ctx, @floatFromInt(s.size))};
            _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &res_arg, null);
        },
        .isFile => {
            if (!opts.permissions.allow_read) {
                var false_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeBoolean(ctx, false)};
                _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &false_arg, null);
                return;
            }
            const file = libs_io.openFileAbsolute(op.path, .{}) catch {
                var false_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeBoolean(ctx, false)};
                _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &false_arg, null);
                return;
            };
            defer file.close(io);
            const s = file.stat(io) catch {
                var false_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeBoolean(ctx, false)};
                _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &false_arg, null);
                return;
            };
            var res_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeBoolean(ctx, s.kind == .file)};
            _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &res_arg, null);
        },
        .isDirectory => {
            if (!opts.permissions.allow_read) {
                var false_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeBoolean(ctx, false)};
                _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &false_arg, null);
                return;
            }
            var dir = libs_io.openDirAbsolute(op.path, .{}) catch {
                var false_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeBoolean(ctx, false)};
                _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &false_arg, null);
                return;
            };
            defer dir.close(io);
            _ = dir.stat(io) catch {
                var false_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeBoolean(ctx, false)};
                _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &false_arg, null);
                return;
            };
            var res_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeBoolean(ctx, true)};
            _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &res_arg, null);
        },
        .readdirWithStats => {
            if (!opts.permissions.allow_read) {
                do_reject(ctx, reject_fn, allocator, "Shu.fs.readdirWithStats requires --allow-read");
                return;
            }
            var dir = libs_io.openDirAbsolute(op.path, .{ .iterate = true }) catch {
                do_reject(ctx, reject_fn, allocator, "readdir failed");
                return;
            };
            defer dir.close(io);
            var buf: [512]jsc.JSValueRef = undefined;
            var count: usize = 0;
            var iter = dir.iterate();
            const k_name = jsc.JSStringCreateWithUTF8CString("name");
            defer jsc.JSStringRelease(k_name);
            const k_isFile = jsc.JSStringCreateWithUTF8CString("isFile");
            defer jsc.JSStringRelease(k_isFile);
            const k_isDirectory = jsc.JSStringCreateWithUTF8CString("isDirectory");
            defer jsc.JSStringRelease(k_isDirectory);
            const k_isSymbolicLink = jsc.JSStringCreateWithUTF8CString("isSymbolicLink");
            defer jsc.JSStringRelease(k_isSymbolicLink);
            const k_size = jsc.JSStringCreateWithUTF8CString("size");
            defer jsc.JSStringRelease(k_size);
            const k_mtimeMs = jsc.JSStringCreateWithUTF8CString("mtimeMs");
            defer jsc.JSStringRelease(k_mtimeMs);
            while (iter.next(io) catch {
                do_reject(ctx, reject_fn, allocator, "readdir iterate failed");
                return;
            }) |entry| {
                if (count >= buf.len) break;
                const s = dir.statFile(io, entry.name, .{}) catch continue;
                const is_file = (s.kind == .file);
                const is_dir = (s.kind == .directory);
                const is_sym = (s.kind == .sym_link);
                const mtime_ns: i64 = @intCast(@min(s.mtime.nanoseconds, std.math.maxInt(i64)));
                const item = jsc.JSObjectMake(ctx, null, null);
                const name_z = allocator.dupeZ(u8, entry.name) catch continue;
                defer allocator.free(name_z);
                const name_ref = jsc.JSStringCreateWithUTF8CString(name_z.ptr);
                defer jsc.JSStringRelease(name_ref);
                _ = jsc.JSObjectSetProperty(ctx, item, k_name, jsc.JSValueMakeString(ctx, name_ref), jsc.kJSPropertyAttributeNone, null);
                _ = jsc.JSObjectSetProperty(ctx, item, k_isFile, jsc.JSValueMakeBoolean(ctx, is_file), jsc.kJSPropertyAttributeNone, null);
                _ = jsc.JSObjectSetProperty(ctx, item, k_isDirectory, jsc.JSValueMakeBoolean(ctx, is_dir), jsc.kJSPropertyAttributeNone, null);
                _ = jsc.JSObjectSetProperty(ctx, item, k_isSymbolicLink, jsc.JSValueMakeBoolean(ctx, is_sym), jsc.kJSPropertyAttributeNone, null);
                _ = jsc.JSObjectSetProperty(ctx, item, k_size, jsc.JSValueMakeNumber(ctx, @floatFromInt(s.size)), jsc.kJSPropertyAttributeNone, null);
                const mtime_ms: f64 = if (mtime_ns >= 0) @floatFromInt(@divTrunc(mtime_ns, 1_000_000)) else 0;
                _ = jsc.JSObjectSetProperty(ctx, item, k_mtimeMs, jsc.JSValueMakeNumber(ctx, mtime_ms), jsc.kJSPropertyAttributeNone, null);
                buf[count] = item;
                count += 1;
            }
            const arr = if (count == 0) jsc.JSObjectMakeArray(ctx, 0, undefined, null) else jsc.JSObjectMakeArray(ctx, count, &buf, null);
            var res_arg: [1]jsc.JSValueRef = .{arr};
            _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &res_arg, null);
        },
        .ensureFile => {
            if (!opts.permissions.allow_read or !opts.permissions.allow_write) {
                do_reject(ctx, reject_fn, allocator, "Shu.fs.ensureFile requires --allow-read and --allow-write");
                return;
            }
            const file = libs_io.openFileAbsolute(op.path, .{}) catch |e| {
                if (e == libs_io.FileOpenError.FileNotFound) {
                    const parent = libs_io.pathDirname(op.path) orelse return;
                    if (parent.len > 0 and parent.len < op.path.len) makeDirRecursiveAbsolute(allocator, parent);
                    var f = libs_io.createFileAbsolute(op.path, .{}) catch {
                        do_reject(ctx, reject_fn, allocator, "ensureFile create failed");
                        return;
                    };
                    f.close(io);
                    const empty: [0]jsc.JSValueRef = .{};
                    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 0, &empty, null);
                    return;
                }
                if (e == libs_io.FileOpenError.IsDir) {
                    do_reject(ctx, reject_fn, allocator, "Shu.fs.ensureFile: path is a directory");
                    return;
                }
                do_reject(ctx, reject_fn, allocator, "ensureFile failed");
                return;
            };
            file.close(io);
            const empty: [0]jsc.JSValueRef = .{};
            _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 0, &empty, null);
        },
        .stat => runDeferredFsOpStat(ctx, op, resolve_fn, reject_fn, do_reject, io),
        .readdir => runDeferredFsOpReaddir(ctx, op, resolve_fn, reject_fn, do_reject, io),
        .mkdir => runDeferredFsOpMkdir(ctx, op, resolve_fn, reject_fn, do_reject, io),
        .exists => runDeferredFsOpExists(ctx, op, resolve_fn, reject_fn, io),
        .unlink => runDeferredFsOpUnlink(ctx, op, resolve_fn, reject_fn, do_reject, io),
        .rmdir => runDeferredFsOpRmdir(ctx, op, resolve_fn, reject_fn, do_reject, io),
        .rename => runDeferredFsOpRename(ctx, op, resolve_fn, reject_fn, do_reject, io),
        .copy => runDeferredFsOpCopy(ctx, op, resolve_fn, reject_fn, do_reject, io),
        .append => runDeferredFsOpAppend(ctx, op, resolve_fn, reject_fn, do_reject, io),
        .write => runDeferredFsOpWrite(ctx, op, resolve_fn, reject_fn, do_reject, io),
        .readlink => runDeferredFsOpReadlink(ctx, op, resolve_fn, reject_fn, do_reject, io),
        .symlink => runDeferredFsOpSymlink(ctx, op, resolve_fn, reject_fn, do_reject, io),
        .readFile => runDeferredFsOpReadFile(ctx, op, resolve_fn, reject_fn, do_reject, io),
        .mkdirRecursive => runDeferredFsOpMkdirRecursive(ctx, op, resolve_fn, reject_fn, do_reject, io),
        .rmdirRecursive => runDeferredFsOpRmdirRecursive(ctx, op, resolve_fn, reject_fn, do_reject, io),
    }
}

fn runDeferredFsOpReadFile(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef, do_reject: *const fn (jsc.JSContextRef, jsc.JSObjectRef, std.mem.Allocator, []const u8) void, io: std.Io) void {
    const opts = globals.current_run_options orelse return;
    const allocator = op.allocator;
    if (!opts.permissions.allow_read) {
        do_reject(ctx, reject_fn, allocator, "Shu.fs.read requires --allow-read");
        return;
    }
    const file = libs_io.openFileAbsolute(op.path, .{}) catch |e| {
        if (e == libs_io.FileOpenError.FileNotFound) {
            do_reject(ctx, reject_fn, allocator, "File not found");
            return;
        }
        do_reject(ctx, reject_fn, allocator, "read failed");
        return;
    };
    const stat = file.stat(io) catch {
        file.close(io);
        do_reject(ctx, reject_fn, allocator, "stat failed");
        return;
    };
    if (op.return_buffer and stat.size >= FS_MAP_THRESHOLD and stat.kind == .file) {
        file.close(io);
        var mapped = libs_io.mapFileReadOnly(op.path) catch {
            const content = allocator.alloc(u8, stat.size) catch {
                do_reject(ctx, reject_fn, allocator, "out of memory");
                return;
            };
            defer allocator.free(content);
            var f = libs_io.openFileAbsolute(op.path, .{}) catch {
                do_reject(ctx, reject_fn, allocator, "read failed");
                return;
            };
            defer f.close(io);
            var f_reader = f.reader(io, &.{});
            var read_vec = [_][]u8{content};
            _ = f_reader.interface.readVecAll(&read_vec) catch {
                do_reject(ctx, reject_fn, allocator, "read failed");
                return;
            };
            var dc = allocator.create(FileBufferDeallocContext) catch {
                do_reject(ctx, reject_fn, allocator, "out of memory");
                return;
            };
            dc.allocator = allocator;
            dc.slice = allocator.dupe(u8, content) catch {
                allocator.destroy(dc);
                do_reject(ctx, reject_fn, allocator, "out of memory");
                return;
            };
            var exc: ?jsc.JSValueRef = null;
            const out = jsc.JSObjectMakeTypedArrayWithBytesNoCopy(ctx, .Uint8Array, content.ptr, content.len, fileBufferDeallocator, dc, @ptrCast(&exc));
            if (out) |o| {
                var res_arg: [1]jsc.JSValueRef = .{o};
                _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &res_arg, null);
            } else {
                allocator.free(content);
                allocator.destroy(dc);
            }
            return;
        };
        defer mapped.deinit();
        var mc = allocator.create(MappedFileContext) catch {
            mapped.deinit();
            do_reject(ctx, reject_fn, allocator, "out of memory");
            return;
        };
        mc.allocator = allocator;
        mc.mapped = mapped;
        var exc: ?jsc.JSValueRef = null;
        const out = jsc.JSObjectMakeTypedArrayWithBytesNoCopy(ctx, .Uint8Array, @ptrCast(@constCast(mapped.slice().ptr)), mapped.slice().len, mappedFileDeallocator, mc, @ptrCast(&exc));
        if (out) |o| {
            var res_arg: [1]jsc.JSValueRef = .{o};
            _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &res_arg, null);
        } else {
            allocator.destroy(mc);
        }
        return;
    }
    file.close(io);
    const content = allocator.alloc(u8, stat.size + 1) catch {
        do_reject(ctx, reject_fn, allocator, "out of memory");
        return;
    };
    defer allocator.free(content);
    var f = libs_io.openFileAbsolute(op.path, .{}) catch {
        do_reject(ctx, reject_fn, allocator, "read failed");
        return;
    };
    defer f.close(io);
    var f_reader = f.reader(io, &.{});
    var read_vec = [_][]u8{content[0..stat.size]};
    _ = f_reader.interface.readVecAll(&read_vec) catch {
        do_reject(ctx, reject_fn, allocator, "read failed");
        return;
    };
    if (op.return_buffer) {
        var dc = allocator.create(FileBufferDeallocContext) catch return;
        dc.allocator = allocator;
        dc.slice = allocator.dupe(u8, content[0..stat.size]) catch {
            allocator.destroy(dc);
            return;
        };
        var exc: ?jsc.JSValueRef = null;
        const out = jsc.JSObjectMakeTypedArrayWithBytesNoCopy(ctx, .Uint8Array, dc.slice.ptr, dc.slice.len, fileBufferDeallocator, dc, @ptrCast(&exc));
        if (out) |o| {
            var res_arg: [1]jsc.JSValueRef = .{o};
            _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &res_arg, null);
        } else {
            allocator.free(dc.slice);
            allocator.destroy(dc);
        }
        return;
    }
    content[stat.size] = 0;
    const ref = jsc.JSStringCreateWithUTF8CString(content.ptr);
    defer jsc.JSStringRelease(ref);
    var res_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeString(ctx, ref)};
    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &res_arg, null);
}

fn runDeferredFsOpSymlink(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef, do_reject: *const fn (jsc.JSContextRef, jsc.JSObjectRef, std.mem.Allocator, []const u8) void, io: std.Io) void {
    _ = io;
    const opts = globals.current_run_options orelse return;
    const allocator = op.allocator;
    const path2 = op.path2 orelse return;
    if (!opts.permissions.allow_write) {
        do_reject(ctx, reject_fn, allocator, "Shu.fs.symlink requires --allow-write");
        return;
    }
    libs_io.symLinkAbsolute(op.path, path2, .{}) catch {
        do_reject(ctx, reject_fn, allocator, "symlink failed");
        return;
    };
    const empty: [0]jsc.JSValueRef = .{};
    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 0, &empty, null);
}

fn runDeferredFsOpStat(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef, do_reject: *const fn (jsc.JSContextRef, jsc.JSObjectRef, std.mem.Allocator, []const u8) void, io: std.Io) void {
    const opts = globals.current_run_options orelse return;
    const allocator = op.allocator;
    if (!opts.permissions.allow_read) {
        do_reject(ctx, reject_fn, allocator, "Shu.fs.stat requires --allow-read");
        return;
    }
    const file = libs_io.openFileAbsolute(op.path, .{}) catch |e| {
        if (e == libs_io.FileOpenError.IsDir) {
            var dir = libs_io.openDirAbsolute(op.path, .{}) catch return;
            defer dir.close(io);
            const s = dir.stat(io) catch return;
            const mtime_ns: i64 = @intCast(@min(s.mtime.nanoseconds, std.math.maxInt(i64)));
            const obj = makeStatObject(ctx, false, s.size, mtime_ns);
            var res_arg: [1]jsc.JSValueRef = .{obj};
            _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &res_arg, null);
            return;
        }
        do_reject(ctx, reject_fn, allocator, "stat failed");
        return;
    };
    defer file.close(io);
    const s = file.stat(io) catch {
        do_reject(ctx, reject_fn, allocator, "stat failed");
        return;
    };
    const mtime_ns: i64 = @intCast(@min(s.mtime.nanoseconds, std.math.maxInt(i64)));
    const obj = makeStatObject(ctx, true, s.size, mtime_ns);
    var res_arg: [1]jsc.JSValueRef = .{obj};
    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &res_arg, null);
}

fn runDeferredFsOpReaddir(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef, do_reject: *const fn (jsc.JSContextRef, jsc.JSObjectRef, std.mem.Allocator, []const u8) void, io: std.Io) void {
    const opts = globals.current_run_options orelse return;
    const allocator = op.allocator;
    if (!opts.permissions.allow_read) {
        do_reject(ctx, reject_fn, allocator, "Shu.fs.readdir requires --allow-read");
        return;
    }
    var dir = libs_io.openDirAbsolute(op.path, .{ .iterate = true }) catch {
        do_reject(ctx, reject_fn, allocator, "readdir failed");
        return;
    };
    defer dir.close(io);
    var buf: [512]jsc.JSValueRef = undefined;
    var count: usize = 0;
    var iter = dir.iterate();
    while (iter.next(io) catch {
        do_reject(ctx, reject_fn, allocator, "readdir iterate failed");
        return;
    }) |entry| {
        if (count >= buf.len) break;
        const name_z = op.allocator.dupeZ(u8, entry.name) catch return;
        defer op.allocator.free(name_z);
        const name_ref = jsc.JSStringCreateWithUTF8CString(name_z.ptr);
        defer jsc.JSStringRelease(name_ref);
        buf[count] = jsc.JSValueMakeString(ctx, name_ref);
        count += 1;
    }
    const arr = if (count == 0) jsc.JSObjectMakeArray(ctx, 0, undefined, null) else jsc.JSObjectMakeArray(ctx, count, &buf, null);
    var res_arg: [1]jsc.JSValueRef = .{arr};
    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &res_arg, null);
}

fn runDeferredFsOpMkdir(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef, do_reject: *const fn (jsc.JSContextRef, jsc.JSObjectRef, std.mem.Allocator, []const u8) void, io: std.Io) void {
    _ = io;
    const opts = globals.current_run_options orelse return;
    const allocator = op.allocator;
    if (!opts.permissions.allow_write) {
        do_reject(ctx, reject_fn, allocator, "Shu.fs.mkdir requires --allow-write");
        return;
    }
    libs_io.makeDirAbsolute(op.path) catch {
        do_reject(ctx, reject_fn, allocator, "mkdir failed");
        return;
    };
    const empty: [0]jsc.JSValueRef = .{};
    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 0, &empty, null);
}

fn runDeferredFsOpExists(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef, io: std.Io) void {
    _ = .{ reject_fn, io };
    const opts = globals.current_run_options orelse return;
    if (!opts.permissions.allow_read) {
        var false_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeBoolean(ctx, false)};
        _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &false_arg, null);
        return;
    }
    libs_io.accessAbsolute(op.path, .{}) catch {
        var false_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeBoolean(ctx, false)};
        _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &false_arg, null);
        return;
    };
    var true_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeBoolean(ctx, true)};
    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &true_arg, null);
}

fn runDeferredFsOpUnlink(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef, do_reject: *const fn (jsc.JSContextRef, jsc.JSObjectRef, std.mem.Allocator, []const u8) void, io: std.Io) void {
    _ = io;
    const opts = globals.current_run_options orelse return;
    const allocator = op.allocator;
    if (!opts.permissions.allow_write) {
        do_reject(ctx, reject_fn, allocator, "Shu.fs.unlink requires --allow-write");
        return;
    }
    libs_io.deleteFileAbsolute(op.path) catch {
        do_reject(ctx, reject_fn, allocator, "unlink failed");
        return;
    };
    const empty: [0]jsc.JSValueRef = .{};
    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 0, &empty, null);
}

fn runDeferredFsOpRmdir(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef, do_reject: *const fn (jsc.JSContextRef, jsc.JSObjectRef, std.mem.Allocator, []const u8) void, io: std.Io) void {
    _ = io;
    const opts = globals.current_run_options orelse return;
    const allocator = op.allocator;
    if (!opts.permissions.allow_write) {
        do_reject(ctx, reject_fn, allocator, "Shu.fs.rmdir requires --allow-write");
        return;
    }
    libs_io.deleteDirAbsolute(op.path) catch {
        do_reject(ctx, reject_fn, allocator, "rmdir failed");
        return;
    };
    const empty: [0]jsc.JSValueRef = .{};
    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 0, &empty, null);
}

fn runDeferredFsOpRename(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef, do_reject: *const fn (jsc.JSContextRef, jsc.JSObjectRef, std.mem.Allocator, []const u8) void, io: std.Io) void {
    _ = io;
    const opts = globals.current_run_options orelse return;
    const allocator = op.allocator;
    const path2 = op.path2 orelse return;
    if (!opts.permissions.allow_read or !opts.permissions.allow_write) {
        do_reject(ctx, reject_fn, allocator, "Shu.fs.rename requires --allow-read and --allow-write");
        return;
    }
    libs_io.renameAbsolute(op.path, path2) catch {
        do_reject(ctx, reject_fn, allocator, "rename failed");
        return;
    };
    const empty: [0]jsc.JSValueRef = .{};
    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 0, &empty, null);
}

fn runDeferredFsOpCopy(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef, do_reject: *const fn (jsc.JSContextRef, jsc.JSObjectRef, std.mem.Allocator, []const u8) void, io: std.Io) void {
    const opts = globals.current_run_options orelse return;
    const allocator = op.allocator;
    const dest = op.path2 orelse return;
    if (!opts.permissions.allow_read or !opts.permissions.allow_write) {
        do_reject(ctx, reject_fn, allocator, "Shu.fs.copy requires --allow-read and --allow-write");
        return;
    }
    const src_file = libs_io.openFileAbsolute(op.path, .{}) catch |e| {
        if (e == libs_io.FileOpenError.FileNotFound) {
            do_reject(ctx, reject_fn, allocator, "File not found");
            return;
        }
        do_reject(ctx, reject_fn, allocator, "copy open src failed");
        return;
    };
    defer src_file.close(io);
    const src_stat = src_file.stat(io) catch {
        do_reject(ctx, reject_fn, allocator, "copy stat failed");
        return;
    };
    const dest_file = libs_io.createFileAbsolute(dest, .{}) catch {
        do_reject(ctx, reject_fn, allocator, "copy create dest failed");
        return;
    };
    defer dest_file.close(io);
    if (src_stat.size >= FS_MAP_THRESHOLD and src_stat.kind == .file) {
        var mapped = libs_io.mapFileReadOnly(op.path) catch {
            do_reject(ctx, reject_fn, allocator, "copy mmap failed");
            return;
        };
        defer mapped.deinit();
        dest_file.writeStreamingAll(io, mapped.slice()) catch {
            do_reject(ctx, reject_fn, allocator, "copy write failed");
            return;
        };
    } else {
        const content = op.allocator.alloc(u8, src_stat.size) catch {
            do_reject(ctx, reject_fn, allocator, "copy read failed");
            return;
        };
        defer op.allocator.free(content);
        var src_reader = src_file.reader(io, &.{});
        var read_vec = [_][]u8{content};
        _ = src_reader.interface.readVecAll(&read_vec) catch {
            do_reject(ctx, reject_fn, allocator, "copy read failed");
            return;
        };
        dest_file.writeStreamingAll(io, content) catch {
            do_reject(ctx, reject_fn, allocator, "copy write failed");
            return;
        };
    }
    const empty: [0]jsc.JSValueRef = .{};
    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 0, &empty, null);
}

fn runDeferredFsOpAppend(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef, do_reject: *const fn (jsc.JSContextRef, jsc.JSObjectRef, std.mem.Allocator, []const u8) void, io: std.Io) void {
    const opts = globals.current_run_options orelse return;
    const allocator = op.allocator;
    const content = op.content orelse return;
    if (!opts.permissions.allow_write) {
        do_reject(ctx, reject_fn, allocator, "Shu.fs.append requires --allow-write");
        return;
    }
    const file = libs_io.openFileAbsolute(op.path, .{ .mode = .read_write }) catch {
        do_reject(ctx, reject_fn, allocator, "append open failed");
        return;
    };
    defer file.close(io);
    const end_pos = file.length(io) catch {
        do_reject(ctx, reject_fn, allocator, "append length failed");
        return;
    };
    file.writePositionalAll(io, content, end_pos) catch {
        do_reject(ctx, reject_fn, allocator, "append write failed");
        return;
    };
    const empty: [0]jsc.JSValueRef = .{};
    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 0, &empty, null);
}

fn runDeferredFsOpWrite(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef, do_reject: *const fn (jsc.JSContextRef, jsc.JSObjectRef, std.mem.Allocator, []const u8) void, io: std.Io) void {
    const opts = globals.current_run_options orelse return;
    const allocator = op.allocator;
    const content = op.content orelse return;
    if (!opts.permissions.allow_write) {
        do_reject(ctx, reject_fn, allocator, "Shu.fs.write requires --allow-write");
        return;
    }
    const file = libs_io.createFileAbsolute(op.path, .{}) catch {
        do_reject(ctx, reject_fn, allocator, "write create failed");
        return;
    };
    defer file.close(io);
    file.writeStreamingAll(io, content) catch {
        do_reject(ctx, reject_fn, allocator, "write failed");
        return;
    };
    const empty: [0]jsc.JSValueRef = .{};
    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 0, &empty, null);
}

fn runDeferredFsOpReadlink(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef, do_reject: *const fn (jsc.JSContextRef, jsc.JSObjectRef, std.mem.Allocator, []const u8) void, io: std.Io) void {
    _ = io;
    const opts = globals.current_run_options orelse return;
    const allocator = op.allocator;
    if (!opts.permissions.allow_read) {
        do_reject(ctx, reject_fn, allocator, "Shu.fs.readlink requires --allow-read");
        return;
    }
    var buf: [libs_io.max_path_bytes]u8 = undefined;
    const target = libs_io.readLinkAbsolute(op.path, &buf) catch {
        do_reject(ctx, reject_fn, allocator, "readlink failed");
        return;
    };
    const dup = op.allocator.dupe(u8, target) catch {
        do_reject(ctx, reject_fn, allocator, "out of memory");
        return;
    };
    defer op.allocator.free(dup);
    const z = op.allocator.dupeZ(u8, dup) catch return;
    defer op.allocator.free(z);
    const ref = jsc.JSStringCreateWithUTF8CString(z.ptr);
    defer jsc.JSStringRelease(ref);
    var res_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeString(ctx, ref)};
    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &res_arg, null);
}

fn runDeferredFsOpMkdirRecursive(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef, do_reject: *const fn (jsc.JSContextRef, jsc.JSObjectRef, std.mem.Allocator, []const u8) void, io: std.Io) void {
    _ = io;
    const opts = globals.current_run_options orelse return;
    const allocator = op.allocator;
    if (!opts.permissions.allow_write) {
        do_reject(ctx, reject_fn, allocator, "Shu.fs.mkdirRecursive requires --allow-write");
        return;
    }
    makeDirRecursiveAbsolute(op.allocator, op.path);
    const empty: [0]jsc.JSValueRef = .{};
    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 0, &empty, null);
}

/// 递归删除目录（仅 Zig 内部使用）；失败时返回 error，由调用方 reject。io 用于 dir.close/iter.next（0.16）。
fn deleteDirRecursiveAbsolute(allocator: std.mem.Allocator, path: []const u8, io: std.Io) !void {
    var dir = libs_io.openDirAbsolute(path, .{ .iterate = true }) catch return error.OpenFailed;
    defer dir.close(io);
    var iter = dir.iterate();
    while (iter.next(io) catch return error.IterateFailed) |entry| {
        const full = libs_io.pathJoin(allocator, &.{ path, entry.name }) catch return error.OutOfMemory;
        defer allocator.free(full);
        var d = libs_io.openDirAbsolute(full, .{ .iterate = true }) catch {
            libs_io.deleteFileAbsolute(full) catch {};
            continue;
        };
        d.close(io);
        try deleteDirRecursiveAbsolute(allocator, full, io);
    }
    libs_io.deleteDirAbsolute(path) catch return error.DeleteFailed;
}

fn runDeferredFsOpRmdirRecursive(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef, do_reject: *const fn (jsc.JSContextRef, jsc.JSObjectRef, std.mem.Allocator, []const u8) void, io: std.Io) void {
    const opts = globals.current_run_options orelse return;
    const allocator = op.allocator;
    if (!opts.permissions.allow_write) {
        do_reject(ctx, reject_fn, allocator, "Shu.fs.rmdirRecursive requires --allow-write");
        return;
    }
    deleteDirRecursiveAbsolute(op.allocator, op.path, io) catch {
        do_reject(ctx, reject_fn, allocator, "rmdirRecursive failed");
        return;
    };
    const empty: [0]jsc.JSValueRef = .{};
    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 0, &empty, null);
}

/// 每轮事件循环调用：收割 AsyncFileIO 完成项并处理延迟 fs 队列（纯 Zig，无内联 JS）。Zig 0.16：pollCompletions/close 需传入 io。
pub fn drainFileIOCompletions(ctx: jsc.JSContextRef) void {
    const fio = globals.current_async_file_io orelse return;
    const state = fs_async_state orelse return;
    const io = libs_process.getProcessIo() orelse return;
    const comps = fio.pollCompletions(io, 0);
    for (comps) |*c| {
        if (c.tag != .file_read and c.tag != .file_write) continue;
        const entry = state.pending.fetchRemove(c.user_data) orelse continue;
        const e = entry.value;
        const file_err = c.file_err;
        jsc.JSValueUnprotect(ctx, e.resolve);
        jsc.JSValueUnprotect(ctx, e.reject);
        defer e.file.close(io);
        if (e.kind == .read) {
            if (file_err) |err| {
                if (e.read_buffer) |buf| e.allocator.free(buf);
                const err_ref = jsc.JSStringCreateWithUTF8CString(@errorName(err).ptr);
                defer jsc.JSStringRelease(err_ref);
                var err_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeString(ctx, err_ref)};
                _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(jsc.JSValueToObject(ctx, e.reject, null)), null, 1, &err_arg, null);
            } else if (e.read_buffer) |buf| {
                const slice = c.buffer_ptr[0..c.len];
                if (e.return_buffer) {
                    var dc = e.allocator.create(FileBufferDeallocContext) catch {
                        e.allocator.free(buf);
                        continue;
                    };
                    dc.allocator = e.allocator;
                    dc.slice = e.allocator.dupe(u8, slice) catch {
                        e.allocator.destroy(dc);
                        e.allocator.free(buf);
                        continue;
                    };
                    var exc: ?jsc.JSValueRef = null;
                    const out = jsc.JSObjectMakeTypedArrayWithBytesNoCopy(ctx, .Uint8Array, dc.slice.ptr, dc.slice.len, fileBufferDeallocator, dc, @ptrCast(&exc));
                    if (out) |o| {
                        var res_arg: [1]jsc.JSValueRef = .{o};
                        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(jsc.JSValueToObject(ctx, e.resolve, null)), null, 1, &res_arg, null);
                    } else {
                        e.allocator.free(dc.slice);
                        e.allocator.destroy(dc);
                    }
                } else {
                    const content_z = e.allocator.dupeZ(u8, slice) catch {
                        e.allocator.free(buf);
                        continue;
                    };
                    defer e.allocator.free(content_z);
                    const ref = jsc.JSStringCreateWithUTF8CString(content_z.ptr);
                    defer jsc.JSStringRelease(ref);
                    var str_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeString(ctx, ref)};
                    _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(jsc.JSValueToObject(ctx, e.resolve, null)), null, 1, &str_arg, null);
                }
                e.allocator.free(buf);
            }
        } else {
            if (e.write_data) |d| e.allocator.free(d);
            if (file_err) |err| {
                const err_ref = jsc.JSStringCreateWithUTF8CString(@errorName(err).ptr);
                defer jsc.JSStringRelease(err_ref);
                var err_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeString(ctx, err_ref)};
                _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(jsc.JSValueToObject(ctx, e.reject, null)), null, 1, &err_arg, null);
            } else {
                const empty: [0]jsc.JSValueRef = .{};
                _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(jsc.JSValueToObject(ctx, e.resolve, null)), null, 0, &empty, null);
            }
        }
    }
    // 处理延迟 fs 队列（纯 Zig 实现，无内联 JS）
    if (deferred_fs_queue) |*q| {
        while (q.items.len > 0) {
            var op = q.orderedRemove(0);
            runDeferredFsOp(ctx, &op);
        }
    }
}

/// 每轮事件循环调用：收割 fs.watch 事件并回调 JS listener(eventType, filename)；仅主线程、有 watchers 时执行
pub fn drainFsWatch(ctx: jsc.JSContextRef) void {
    const state = g_fs_watchers orelse return;
    const allocator = state.allocator;
    var i: usize = 0;
    while (i < state.list.items.len) {
        const entry = &state.list.items[i];
        while (libs_io.drainWatchEvents(entry.handle)) |ev| {
            defer if (ev.filename.len > 0) allocator.free(ev.filename);
            const event_str = switch (ev.event_type) {
                .change => "change",
                .rename => "rename",
            };
            const event_ref = jsc.JSStringCreateWithUTF8CString(event_str);
            defer jsc.JSStringRelease(event_ref);
            const name_ref = if (ev.filename.len > 0)
                jsc.JSStringCreateWithUTF8CString(ev.filename.ptr)
            else
                jsc.JSStringCreateWithUTF8CString("");
            defer jsc.JSStringRelease(name_ref);
            var args: [2]jsc.JSValueRef = .{
                jsc.JSValueMakeString(ctx, event_ref),
                jsc.JSValueMakeString(ctx, name_ref),
            };
            _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(jsc.JSValueToObject(ctx, entry.callback, null)), null, 2, &args, null);
        }
        i += 1;
    }
}

/// 核心逻辑：用已解析路径提交一次异步读，resolve/reject 由 drain 或本函数内同步 resolve（空文件等）时调用；不检查权限（由调用方在构造 Promise 前完成）
fn doSubmitRead(
    ctx: jsc.JSContextRef,
    resolved: []const u8,
    return_buffer: bool,
    resolve_fn: jsc.JSValueRef,
    reject_fn: jsc.JSValueRef,
) void {
    const allocator = globals.current_allocator orelse return;
    const io = libs_process.getProcessIo() orelse return;
    var file = libs_io.openFileAbsolute(resolved, .{}) catch |e| {
        if (e == libs_io.FileOpenError.FileNotFound) {
            const msg = std.fmt.allocPrint(allocator, "File not found: {s}", .{resolved}) catch resolved;
            errors.reportToStderr(.{ .code = .file_not_found, .message = msg }) catch {};
            if (msg.ptr != resolved.ptr) allocator.free(msg);
        }
        return;
    };
    const stat = file.stat(io) catch {
        file.close(io);
        return;
    };
    const size = @min(stat.size, ASYNC_READ_MAX_BYTES);
    if (size == 0) {
        file.close(io);
        if (return_buffer) {
            var dc = allocator.create(FileBufferDeallocContext) catch return;
            dc.allocator = allocator;
            dc.slice = allocator.alloc(u8, 0) catch {
                allocator.destroy(dc);
                return;
            };
            var exc: ?jsc.JSValueRef = null;
            const out = jsc.JSObjectMakeTypedArrayWithBytesNoCopy(ctx, .Uint8Array, dc.slice.ptr, 0, fileBufferDeallocator, dc, @ptrCast(&exc));
            if (out) |o| {
                var arg: [1]jsc.JSValueRef = .{o};
                _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(jsc.JSValueToObject(ctx, resolve_fn, null)), null, 1, &arg, null);
            } else allocator.free(dc.slice);
            allocator.destroy(dc);
        } else {
            const ref = jsc.JSStringCreateWithUTF8CString("");
            defer jsc.JSStringRelease(ref);
            var arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeString(ctx, ref)};
            _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(jsc.JSValueToObject(ctx, resolve_fn, null)), null, 1, &arg, null);
        }
        return;
    }
    var state = ensureAsyncFileIO() catch {
        file.close(io);
        return;
    };
    const buffer = state.allocator.alloc(u8, size) catch {
        file.close(io);
        return;
    };
    const user_data = state.next_id;
    state.next_id +%= 1;
    state.async_file_io.submitReadFile(io, file.handle, buffer.ptr, buffer.len, 0, user_data) catch |e| {
        state.allocator.free(buffer);
        file.close(io);
        const err_ref = jsc.JSStringCreateWithUTF8CString(@errorName(e).ptr);
        defer jsc.JSStringRelease(err_ref);
        var err_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeString(ctx, err_ref)};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(jsc.JSValueToObject(ctx, reject_fn, null)), null, 1, &err_arg, null);
        return;
    };
    jsc.JSValueProtect(ctx, resolve_fn);
    jsc.JSValueProtect(ctx, reject_fn);
    state.pending.put(state.allocator, user_data, .{
        .resolve = resolve_fn,
        .reject = reject_fn,
        .file = file,
        .allocator = state.allocator,
        .kind = .read,
        .read_buffer = buffer,
        .return_buffer = return_buffer,
    }) catch {
        jsc.JSValueUnprotect(ctx, resolve_fn);
        jsc.JSValueUnprotect(ctx, reject_fn);
        state.allocator.free(buffer);
        file.close(io);
    };
}

/// 核心逻辑：用已解析路径与内容提交一次异步写，resolve/reject 由 drain 或本函数内同步调用；不检查权限（由调用方在构造 Promise 前完成）
fn doSubmitWrite(
    ctx: jsc.JSContextRef,
    resolved: []const u8,
    content: []const u8,
    resolve_fn: jsc.JSValueRef,
    reject_fn: jsc.JSValueRef,
) void {
    const allocator = globals.current_allocator orelse return;
    const io = libs_process.getProcessIo() orelse return;
    var file = libs_io.createFileAbsolute(resolved, .{}) catch {
        allocator.free(content);
        return;
    };
    var state = ensureAsyncFileIO() catch {
        file.close(io);
        allocator.free(content);
        return;
    };
    const user_data = state.next_id;
    state.next_id +%= 1;
    state.async_file_io.submitWriteFile(io, file.handle, content.ptr, content.len, 0, user_data) catch |e| {
        file.close(io);
        allocator.free(content);
        const err_ref = jsc.JSStringCreateWithUTF8CString(@errorName(e).ptr);
        defer jsc.JSStringRelease(err_ref);
        var err_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeString(ctx, err_ref)};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(jsc.JSValueToObject(ctx, reject_fn, null)), null, 1, &err_arg, null);
        return;
    };
    jsc.JSValueProtect(ctx, resolve_fn);
    jsc.JSValueProtect(ctx, reject_fn);
    state.pending.put(state.allocator, user_data, .{
        .resolve = resolve_fn,
        .reject = reject_fn,
        .file = file,
        .allocator = state.allocator,
        .kind = .write,
        .write_data = content,
    }) catch {
        jsc.JSValueUnprotect(ctx, resolve_fn);
        jsc.JSValueUnprotect(ctx, reject_fn);
        file.close(io);
        allocator.free(content);
    };
}

/// Promise executor 的 C 回调：从 thread-local 取 read 参数，调用 doSubmitRead 后释放并清空
fn fsReadExecutorCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const args = fs_read_promise_args orelse return jsc.JSValueMakeUndefined(ctx);
    fs_read_promise_args = null;
    defer globals.current_allocator.?.free(args.resolved);
    doSubmitRead(ctx, args.resolved, args.return_buffer, arguments[0], arguments[1]);
    return jsc.JSValueMakeUndefined(ctx);
}

/// Promise executor 的 C 回调：从 thread-local 取 write 参数，调用 doSubmitWrite 后释放并清空
fn fsWriteExecutorCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const args = fs_write_promise_args orelse return jsc.JSValueMakeUndefined(ctx);
    fs_write_promise_args = null;
    defer globals.current_allocator.?.free(args.resolved);
    defer globals.current_allocator.?.free(args.content);
    doSubmitWrite(ctx, args.resolved, args.content, arguments[0], arguments[1]);
    return jsc.JSValueMakeUndefined(ctx);
}

/// C 回调：fs.watch(path [, options] [, listener])。path 必填；listener 为 (eventType, filename) => {}；options.recursive 暂不支持。
/// 返回带 close() 的 FSWatcher 对象；需 --allow-read。
fn watchCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    if (!opts.permissions.allow_read) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.fs.watch requires --allow-read" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);

    var recursive = false;
    var listener: ?jsc.JSValueRef = null;
    if (argumentCount >= 2 and jsc.JSObjectIsFunction(ctx, @ptrCast(arguments[1]))) {
        listener = arguments[1];
    } else if (argumentCount >= 2 and jsc.JSValueToObject(ctx, arguments[1], null) != null) {
        if (argumentCount >= 3 and jsc.JSObjectIsFunction(ctx, @ptrCast(arguments[2])))
            listener = arguments[2];
        const rec_str = jsc.JSStringCreateWithUTF8CString("recursive");
        defer jsc.JSStringRelease(rec_str);
        const rec_val = jsc.JSObjectGetProperty(ctx, @ptrCast(jsc.JSValueToObject(ctx, arguments[1], null)), rec_str, null);
        if (jsc.JSValueToBoolean(ctx, rec_val)) recursive = true;
    }

    const state = ensureFsWatchersState() catch return jsc.JSValueMakeUndefined(ctx);
    const handle = libs_io.startWatch(allocator, resolved, recursive) catch |e| {
        const msg = std.fmt.allocPrint(allocator, "Shu.fs.watch failed: {s}", .{@errorName(e)}) catch return jsc.JSValueMakeUndefined(ctx);
        defer allocator.free(msg);
        errors.reportToStderr(.{ .code = .unknown, .message = msg }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    };
    const callback = listener orelse {
        handle.deinit();
        allocator.destroy(handle);
        return jsc.JSValueMakeUndefined(ctx);
    };
    jsc.JSValueProtect(ctx, callback);
    state.list.append(state.allocator, .{ .handle = handle, .ctx = @ptrCast(ctx), .callback = callback }) catch {
        jsc.JSValueUnprotect(ctx, callback);
        handle.deinit();
        allocator.destroy(handle);
        return jsc.JSValueMakeUndefined(ctx);
    };
    const watcher_obj = jsc.JSObjectMake(ctx, null, null);
    state.map.put(state.allocator, @intFromPtr(watcher_obj), handle) catch {
        _ = state.list.pop();
        jsc.JSValueUnprotect(ctx, callback);
        handle.deinit();
        allocator.destroy(handle);
        return jsc.JSValueMakeUndefined(ctx);
    };

    const close_str = jsc.JSStringCreateWithUTF8CString("close");
    defer jsc.JSStringRelease(close_str);
    const close_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, close_str, watchCloseCallback);
    _ = jsc.JSObjectSetProperty(ctx, watcher_obj, close_str, close_fn, jsc.kJSPropertyAttributeNone, null);
    return watcher_obj;
}

/// C 回调：FSWatcher.close()；从 map/list 移除、Unprotect、deinit handle
fn watchCloseCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    _ = argumentCount;
    const state = g_fs_watchers orelse return jsc.JSValueMakeUndefined(ctx);
    const key = @intFromPtr(this);
    const handle = state.map.fetchRemove(key) orelse return jsc.JSValueMakeUndefined(ctx);
    var i: usize = 0;
    while (i < state.list.items.len) : (i += 1) {
        if (state.list.items[i].handle == handle.value) {
            const entry = state.list.swapRemove(i);
            jsc.JSValueUnprotect(ctx, entry.callback);
            break;
        }
    }
    handle.value.deinit();
    state.allocator.destroy(handle.value);
    return jsc.JSValueMakeUndefined(ctx);
}

/// 内部 C 回调：供 JS 侧 Shu.__fsSubmitRead(path, returnBuffer, resolve, reject) 调用；解析路径、检查权限后调用 doSubmitRead
fn fsSubmitReadCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    if (argumentCount < 4) return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    if (!opts.permissions.allow_read) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.fs.read requires --allow-read" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    const n = jsc.JSValueToNumber(ctx, arguments[1], null);
    const return_buffer = argumentCount >= 2 and !std.math.isNan(n) and n != 0;
    doSubmitRead(ctx, resolved, return_buffer, arguments[2], arguments[3]);
    return jsc.JSValueMakeUndefined(ctx);
}

/// 内部 C 回调：供 JS 侧 Shu.__fsSubmitWrite(path, content, resolve, reject) 调用；解析路径、检查权限后调用 doSubmitWrite
fn fsSubmitWriteCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    if (argumentCount < 4) return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    if (!opts.permissions.allow_write) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.fs.write requires --allow-write" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    const content_js = jsc.JSValueToStringCopy(ctx, arguments[1], null);
    defer jsc.JSStringRelease(content_js);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(content_js);
    if (max_sz == 0 or max_sz > 1024 * 1024 * 16) return jsc.JSValueMakeUndefined(ctx);
    const content_buf = allocator.alloc(u8, max_sz) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(content_buf);
    const n = jsc.JSStringGetUTF8CString(content_js, content_buf.ptr, max_sz);
    const content_len = if (n > 0) n - 1 else 0;
    const content = allocator.dupe(u8, content_buf[0..content_len]) catch return jsc.JSValueMakeUndefined(ctx);
    doSubmitWrite(ctx, resolved, content, arguments[2], arguments[3]);
    return jsc.JSValueMakeUndefined(ctx);
}

/// 返回 Shu.fs 的 exports 对象（供 shu:fs 内置与引擎挂载）；allocator 预留
pub fn getExports(ctx: jsc.JSContextRef, _: std.mem.Allocator) jsc.JSValueRef {
    const file_obj = jsc.JSObjectMake(ctx, null, null);
    attachMethods(ctx, file_obj);
    return file_obj;
}

/// 向 shu_obj 上注册 Shu.fs 子对象（委托 getExports），与 node:fs/deno:fs 命名统一；并注册内部 __fsSubmitRead/__fsSubmitWrite 与全局 __fsSyncFallbackMicrotask 供异步 read/write 回退微任务使用
pub fn register(ctx: jsc.JSGlobalContextRef, shu_obj: jsc.JSObjectRef) void {
    const allocator = globals.current_allocator orelse return;
    const name_fs = jsc.JSStringCreateWithUTF8CString("fs");
    defer jsc.JSStringRelease(name_fs);
    _ = jsc.JSObjectSetProperty(ctx, shu_obj, name_fs, getExports(ctx, allocator), jsc.kJSPropertyAttributeNone, null);
    common.setMethod(ctx, shu_obj, "__fsSubmitRead", fsSubmitReadCallback);
    common.setMethod(ctx, shu_obj, "__fsSubmitWrite", fsSubmitWriteCallback);
    const global = jsc.JSContextGetGlobalObject(ctx);
    common.setMethod(ctx, @ptrCast(global), "__fsSyncFallbackMicrotask", fsSyncFallbackMicrotaskCallback);
}

/// 在 file_obj 上挂载所有方法（getExports / register 共用）；含 node:fs 兼容命名（readFileSync/writeFileSync/readFile/writeFile/copyFileSync/appendFileSync）
fn attachMethods(ctx: jsc.JSGlobalContextRef, file_obj: jsc.JSObjectRef) void {
    // 同步方法：readSync、writeSync、readdirSync、mkdirSync、existsSync、statSync、unlinkSync、rmdirSync、renameSync、copySync、appendSync
    common.setMethod(ctx, file_obj, "readSync", readFileSyncCallback);
    common.setMethod(ctx, file_obj, "writeSync", writeFileSyncCallback);
    common.setMethod(ctx, file_obj, "readdirSync", readdirSyncCallback);
    common.setMethod(ctx, file_obj, "mkdirSync", mkdirSyncCallback);
    common.setMethod(ctx, file_obj, "existsSync", existsSyncCallback);
    common.setMethod(ctx, file_obj, "statSync", statSyncCallback);
    common.setMethod(ctx, file_obj, "realpathSync", realpathSyncCallback);
    common.setMethod(ctx, file_obj, "lstatSync", lstatSyncCallback);
    common.setMethod(ctx, file_obj, "truncateSync", truncateSyncCallback);
    common.setMethod(ctx, file_obj, "accessSync", accessSyncCallback);
    common.setMethod(ctx, file_obj, "isEmptyDirSync", isEmptyDirSyncCallback);
    common.setMethod(ctx, file_obj, "sizeSync", sizeSyncCallback);
    common.setMethod(ctx, file_obj, "isFileSync", isFileSyncCallback);
    common.setMethod(ctx, file_obj, "isDirectorySync", isDirectorySyncCallback);
    common.setMethod(ctx, file_obj, "readdirWithStatsSync", readdirWithStatsSyncCallback);
    common.setMethod(ctx, file_obj, "ensureFileSync", ensureFileSyncCallback);
    common.setMethod(ctx, file_obj, "unlinkSync", unlinkSyncCallback);
    common.setMethod(ctx, file_obj, "rmdirSync", rmdirSyncCallback);
    common.setMethod(ctx, file_obj, "renameSync", renameSyncCallback);
    common.setMethod(ctx, file_obj, "copySync", copySyncCallback);
    common.setMethod(ctx, file_obj, "appendSync", appendSyncCallback);
    common.setMethod(ctx, file_obj, "symlinkSync", symlinkSyncCallback);
    common.setMethod(ctx, file_obj, "readlinkSync", readlinkSyncCallback);
    common.setMethod(ctx, file_obj, "mkdirRecursiveSync", mkdirRecursiveSyncCallback);
    common.setMethod(ctx, file_obj, "rmdirRecursiveSync", rmdirRecursiveSyncCallback);
    // 检查目录是否存在，不存在则创建（含父目录），存在则不做任何操作；与 mkdirRecursiveSync 同实现
    common.setMethod(ctx, file_obj, "ensureDirSync", mkdirRecursiveSyncCallback);
    // 文件/目录监视：返回 FSWatcher（含 close()）；与 node:fs watch 对齐，需 --allow-read
    common.setMethod(ctx, file_obj, "watch", watchCallback);
    // node:fs 兼容命名：与上同实现，便于 Node 迁移
    common.setMethod(ctx, file_obj, "readFileSync", readFileSyncCallback);
    common.setMethod(ctx, file_obj, "writeFileSync", writeFileSyncCallback);
    common.setMethod(ctx, file_obj, "copyFileSync", copySyncCallback);
    common.setMethod(ctx, file_obj, "appendFileSync", appendSyncCallback);
    // 异步方法：read、write、readdir、mkdir、exists、stat、unlink、rmdir、rename、copy、append、symlink、readlink、mkdirRecursive、rmdirRecursive
    common.setMethod(ctx, file_obj, "read", readFileAsyncCallback);
    common.setMethod(ctx, file_obj, "write", writeFileAsyncCallback);
    common.setMethod(ctx, file_obj, "readdir", readdirAsyncCallback);
    common.setMethod(ctx, file_obj, "mkdir", mkdirAsyncCallback);
    common.setMethod(ctx, file_obj, "exists", existsAsyncCallback);
    common.setMethod(ctx, file_obj, "stat", statAsyncCallback);
    common.setMethod(ctx, file_obj, "realpath", realpathAsyncCallback);
    common.setMethod(ctx, file_obj, "lstat", lstatAsyncCallback);
    common.setMethod(ctx, file_obj, "truncate", truncateAsyncCallback);
    common.setMethod(ctx, file_obj, "access", accessAsyncCallback);
    common.setMethod(ctx, file_obj, "isEmptyDir", isEmptyDirAsyncCallback);
    common.setMethod(ctx, file_obj, "size", sizeAsyncCallback);
    common.setMethod(ctx, file_obj, "isFile", isFileAsyncCallback);
    common.setMethod(ctx, file_obj, "isDirectory", isDirectoryAsyncCallback);
    common.setMethod(ctx, file_obj, "readdirWithStats", readdirWithStatsAsyncCallback);
    common.setMethod(ctx, file_obj, "ensureFile", ensureFileAsyncCallback);
    common.setMethod(ctx, file_obj, "unlink", unlinkAsyncCallback);
    common.setMethod(ctx, file_obj, "rmdir", rmdirAsyncCallback);
    common.setMethod(ctx, file_obj, "rename", renameAsyncCallback);
    common.setMethod(ctx, file_obj, "copy", copyAsyncCallback);
    common.setMethod(ctx, file_obj, "append", appendAsyncCallback);
    common.setMethod(ctx, file_obj, "symlink", symlinkAsyncCallback);
    common.setMethod(ctx, file_obj, "readlink", readlinkAsyncCallback);
    common.setMethod(ctx, file_obj, "mkdirRecursive", mkdirRecursiveAsyncCallback);
    common.setMethod(ctx, file_obj, "rmdirRecursive", rmdirRecursiveAsyncCallback);
    // 检查目录是否存在，不存在则创建，存在则不做任何操作；与 mkdirRecursive 同实现
    common.setMethod(ctx, file_obj, "ensureDir", mkdirRecursiveAsyncCallback);
    // node:fs 兼容命名
    common.setMethod(ctx, file_obj, "readFile", readFileAsyncCallback);
    common.setMethod(ctx, file_obj, "writeFile", writeFileAsyncCallback);
    common.setMethod(ctx, file_obj, "copyFile", copyAsyncCallback);
    common.setMethod(ctx, file_obj, "appendFile", appendAsyncCallback);
}

// ---------- 内部辅助 ----------

/// 将字符串转成 JSON 字面量（带引号），用于拼接到 JS 脚本中；返回的切片需由调用方 free
fn jsonEscapeString(allocator: std.mem.Allocator, str: []const u8) ?[]const u8 {
    const max = str.len * 2 + 2 + 1;
    const buf = allocator.alloc(u8, max) catch return null;
    var i: usize = 0;
    buf[i] = '"';
    i += 1;
    for (str) |c| {
        switch (c) {
            '\\' => {
                buf[i] = '\\';
                buf[i + 1] = '\\';
                i += 2;
            },
            '"' => {
                buf[i] = '\\';
                buf[i + 1] = '"';
                i += 2;
            },
            '\n' => {
                buf[i] = '\\';
                buf[i + 1] = 'n';
                i += 2;
            },
            '\r' => {
                buf[i] = '\\';
                buf[i + 1] = 'r';
                i += 2;
            },
            '\t' => {
                buf[i] = '\\';
                buf[i + 1] = 't';
                i += 2;
            },
            else => {
                buf[i] = c;
                i += 1;
            },
        }
        if (i + 2 > max) break;
    }
    buf[i] = '"';
    i += 1;
    const out = allocator.dupe(u8, buf[0..i]) catch {
        allocator.free(buf);
        return null;
    };
    allocator.free(buf);
    return out;
}

/// 从 JS 参数取第 idx 个参数的 UTF-8 字符串（不解析路径），返回的切片需由调用方 free
fn getArgString(allocator: std.mem.Allocator, ctx: jsc.JSContextRef, arguments: [*]const jsc.JSValueRef, argumentCount: usize, idx: usize) ?[]const u8 {
    if (argumentCount <= idx) return null;
    const path_js = jsc.JSValueToStringCopy(ctx, arguments[idx], null);
    defer jsc.JSStringRelease(path_js);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(path_js);
    if (max_sz == 0 or max_sz > 65536) return null;
    const path_buf = allocator.alloc(u8, max_sz) catch return null;
    defer allocator.free(path_buf);
    const n = jsc.JSStringGetUTF8CString(path_js, path_buf.ptr, max_sz);
    if (n == 0) return null;
    return allocator.dupe(u8, path_buf[0 .. n - 1]) catch null;
}

/// 从 JS 参数取第 idx 个字符串，解析为路径并相对 cwd 解析为绝对路径；返回的切片需由调用方 free
fn getResolvedPath(allocator: std.mem.Allocator, cwd: []const u8, ctx: jsc.JSContextRef, arguments: [*]const jsc.JSValueRef, argumentCount: usize, idx: usize) ?[]const u8 {
    if (argumentCount <= idx) return null;
    const path_js = jsc.JSValueToStringCopy(ctx, arguments[idx], null);
    defer jsc.JSStringRelease(path_js);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(path_js);
    if (max_sz == 0 or max_sz > 65536) return null;
    const path_buf = allocator.alloc(u8, max_sz) catch return null;
    const n = jsc.JSStringGetUTF8CString(path_js, path_buf.ptr, max_sz);
    if (n == 0) {
        allocator.free(path_buf);
        return null;
    }
    const path = path_buf[0 .. n - 1];
    const resolved = libs_io.pathResolve(allocator, &.{ cwd, path }) catch {
        allocator.free(path_buf);
        return null;
    };
    allocator.free(path_buf);
    return resolved;
}

/// 在 ctx 中创建并返回 { isFile, isDirectory, size, mtimeMs } 对象
fn makeStatObject(ctx: jsc.JSContextRef, is_file: bool, size: u64, mtime_ns: i64) jsc.JSValueRef {
    return makeStatObjectWithSymlink(ctx, is_file, !is_file, false, size, mtime_ns);
}

/// 在 ctx 中创建并返回 { isFile, isDirectory, isSymbolicLink, size, mtimeMs } 对象；lstat/readdirWithStats 使用
fn makeStatObjectWithSymlink(ctx: jsc.JSContextRef, is_file: bool, is_dir: bool, is_symlink: bool, size: u64, mtime_ns: i64) jsc.JSValueRef {
    const obj = jsc.JSObjectMake(ctx, null, null);
    const k_isFile = jsc.JSStringCreateWithUTF8CString("isFile");
    defer jsc.JSStringRelease(k_isFile);
    const k_isDirectory = jsc.JSStringCreateWithUTF8CString("isDirectory");
    defer jsc.JSStringRelease(k_isDirectory);
    const k_isSymbolicLink = jsc.JSStringCreateWithUTF8CString("isSymbolicLink");
    defer jsc.JSStringRelease(k_isSymbolicLink);
    const k_size = jsc.JSStringCreateWithUTF8CString("size");
    defer jsc.JSStringRelease(k_size);
    const k_mtimeMs = jsc.JSStringCreateWithUTF8CString("mtimeMs");
    defer jsc.JSStringRelease(k_mtimeMs);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_isFile, jsc.JSValueMakeBoolean(ctx, is_file), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_isDirectory, jsc.JSValueMakeBoolean(ctx, is_dir), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_isSymbolicLink, jsc.JSValueMakeBoolean(ctx, is_symlink), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_size, jsc.JSValueMakeNumber(ctx, @floatFromInt(size)), jsc.kJSPropertyAttributeNone, null);
    const mtime_ms: f64 = if (mtime_ns >= 0) @floatFromInt(@divTrunc(mtime_ns, 1_000_000)) else 0;
    _ = jsc.JSObjectSetProperty(ctx, obj, k_mtimeMs, jsc.JSValueMakeNumber(ctx, mtime_ms), jsc.kJSPropertyAttributeNone, null);
    return obj;
}

/// read/write 在内存不足等 fallback 时用微任务 + Shu.fs.xxxSync 纯 Zig 路径（无内联 JS）；path_json 由调用方提供，本函数 dupeZ 后由 payload 持有
fn makeDeferredPromiseOne(ctx: jsc.JSContextRef, allocator: std.mem.Allocator, syncMethod: []const u8, path_json: []const u8) jsc.JSValueRef {
    const path_z = allocator.dupeZ(u8, path_json) catch return jsc.JSValueMakeUndefined(ctx);
    const payload = allocator.create(FsSyncFallbackPayload) catch {
        allocator.free(path_z);
        return jsc.JSValueMakeUndefined(ctx);
    };
    payload.* = .{
        .allocator = allocator,
        .ctx = ctx,
        .resolve = undefined,
        .reject = undefined,
        .method_name = syncMethod,
        .path_json = path_z,
        .path2_json = null,
    };
    return promise.createWithExecutor(ctx, fsSyncFallbackOnExecutor, payload);
}
/// 双参 Sync 回退（如 writeSync(path, content)）：a_json/b_json 由调用方提供，本函数 dupeZ 后由 payload 持有
fn makeDeferredPromiseTwo(ctx: jsc.JSContextRef, allocator: std.mem.Allocator, syncMethod: []const u8, a_json: []const u8, b_json: []const u8) jsc.JSValueRef {
    const a_z = allocator.dupeZ(u8, a_json) catch return jsc.JSValueMakeUndefined(ctx);
    const b_z = allocator.dupeZ(u8, b_json) catch {
        allocator.free(a_z);
        return jsc.JSValueMakeUndefined(ctx);
    };
    const payload = allocator.create(FsSyncFallbackPayload) catch {
        allocator.free(a_z);
        allocator.free(b_z);
        return jsc.JSValueMakeUndefined(ctx);
    };
    payload.* = .{
        .allocator = allocator,
        .ctx = ctx,
        .resolve = undefined,
        .reject = undefined,
        .method_name = syncMethod,
        .path_json = a_z,
        .path2_json = b_z,
    };
    return promise.createWithExecutor(ctx, fsSyncFallbackOnExecutor, payload);
}

/// 纯 Zig 创建 Promise：将 op 挂到 current_deferred_fs_op，用 Zig 回调作为 executor，drain 时执行同步逻辑并 resolve/reject；path/path2/content 所有权转入队列
fn createDeferredFsPromise(
    ctx: jsc.JSContextRef,
    allocator: std.mem.Allocator,
    tag: DeferredFsOpTag,
    path: []const u8,
    path2: ?[]const u8,
    content: ?[]const u8,
    len: u64,
    mode: u32,
    return_buffer: bool,
) jsc.JSValueRef {
    ensureDeferredFsQueue() catch return jsc.JSValueMakeUndefined(ctx);
    deferred_fs_current_op = .{
        .tag = tag,
        .allocator = allocator,
        .path = path,
        .path2 = path2,
        .content = content,
        .len = len,
        .mode = mode,
        .return_buffer = return_buffer,
        .resolve = undefined,
        .reject = undefined,
    };
    current_deferred_fs_op = &deferred_fs_current_op;
    return promise.createWithExecutor(ctx, fsDeferredOnExecutor, current_deferred_fs_op);
}

// ---------- 同步回调 ----------

/// [Allocates] 从 options 对象读取 encoding：'utf8' 或未传则返回 string（Zig 分配后交 JSC）；null/'buffer' 则返回 Buffer（零拷贝或 mmap，生命周期见 NoCopy/映射约定）。大文件且 encoding 为 null 时用 libs_io.mapFileReadOnly。
fn readFileSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    if (!opts.permissions.allow_read) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.fs.read requires --allow-read" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    const io = libs_process.getProcessIo() orelse return jsc.JSValueMakeUndefined(ctx);
    const file = libs_io.openFileAbsolute(resolved, .{}) catch |e| {
        if (e == libs_io.FileOpenError.FileNotFound) {
            const msg = std.fmt.allocPrint(allocator, "File not found: {s}", .{resolved}) catch resolved;
            errors.reportToStderr(.{ .code = .file_not_found, .message = msg }) catch {};
            if (msg.ptr != resolved.ptr) allocator.free(msg);
        }
        return jsc.JSValueMakeUndefined(ctx);
    };
    const stat = file.stat(io) catch {
        file.close(io);
        return jsc.JSValueMakeUndefined(ctx);
    };
    const return_buffer = blk: {
        if (argumentCount < 2) break :blk false;
        const options = jsc.JSValueToObject(ctx, arguments[1], null) orelse break :blk false;
        const k_enc = jsc.JSStringCreateWithUTF8CString("encoding");
        defer jsc.JSStringRelease(k_enc);
        const enc_val = jsc.JSObjectGetProperty(ctx, options, k_enc, null);
        if (jsc.JSValueIsUndefined(ctx, enc_val) or jsc.JSValueIsNull(ctx, enc_val)) break :blk true;
        const enc_str = jsc.JSValueToStringCopy(ctx, enc_val, null);
        defer jsc.JSStringRelease(enc_str);
        const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(enc_str);
        if (max_sz <= 1 or max_sz > 32) break :blk false;
        var buf: [32]u8 = undefined;
        const n = jsc.JSStringGetUTF8CString(enc_str, &buf, max_sz);
        const enc = buf[0..if (n > 0) n - 1 else 0];
        if (enc.len == 0) break :blk true;
        if (enc.len == 6) {
            var pad: [8]u8 = [_]u8{0} ** 8;
            @memcpy(pad[0..6], enc[0..6]);
            const q = @as(u64, @bitCast(pad));
            if (q == @as(u64, @bitCast([8]u8{ 'b', 'u', 'f', 'f', 'e', 'r', 0, 0 })) or q == @as(u64, @bitCast([8]u8{ 'b', 'i', 'n', 'a', 'r', 'y', 0, 0 }))) break :blk true;
        }
        break :blk false;
    };
    // 大文件且返回 Buffer 时走 libs_io.mapFileReadOnly，减少整文件读入与 OOM
    if (return_buffer and stat.size >= FS_MAP_THRESHOLD and stat.kind == .file) {
        file.close(io);
        var mapped = libs_io.mapFileReadOnly(resolved) catch {
            var fallback_file = libs_io.openFileAbsolute(resolved, .{}) catch return jsc.JSValueMakeUndefined(ctx);
            defer fallback_file.close(io);
            var fallback_reader = fallback_file.reader(io, &.{});
            const content = fallback_reader.interface.allocRemaining(allocator, std.Io.Limit.unlimited) catch {
                return jsc.JSValueMakeUndefined(ctx);
            };
            var dc = allocator.create(FileBufferDeallocContext) catch {
                allocator.free(content);
                return jsc.JSValueMakeUndefined(ctx);
            };
            dc.allocator = allocator;
            dc.slice = content;
            var exc: ?jsc.JSValueRef = null;
            const out = jsc.JSObjectMakeTypedArrayWithBytesNoCopy(ctx, .Uint8Array, content.ptr, content.len, fileBufferDeallocator, dc, @ptrCast(&exc));
            if (out == null) {
                allocator.free(content);
                allocator.destroy(dc);
                if (exc) |e| exception[0] = e;
                return jsc.JSValueMakeUndefined(ctx);
            }
            return out.?;
        };
        var map_ctx = allocator.create(MappedFileContext) catch {
            mapped.deinit();
            return jsc.JSValueMakeUndefined(ctx);
        };
        map_ctx.allocator = allocator;
        map_ctx.mapped = mapped;
        const slice = map_ctx.mapped.slice();
        var exc: ?jsc.JSValueRef = null;
        const out = jsc.JSObjectMakeTypedArrayWithBytesNoCopy(ctx, .Uint8Array, @ptrCast(@constCast(slice.ptr)), slice.len, mappedFileDeallocator, map_ctx, @ptrCast(&exc));
        if (out == null) {
            map_ctx.mapped.deinit();
            allocator.destroy(map_ctx);
            if (exc) |e| exception[0] = e;
            return jsc.JSValueMakeUndefined(ctx);
        }
        return out.?;
    }
    var file_reader = file.reader(io, &.{});
    const raw = file_reader.interface.allocRemaining(allocator, std.Io.Limit.unlimited) catch {
        file.close(io);
        return jsc.JSValueMakeUndefined(ctx);
    };
    defer allocator.free(raw);
    defer file.close(io);
    if (return_buffer) {
        var dc = allocator.create(FileBufferDeallocContext) catch {
            allocator.free(raw);
            return jsc.JSValueMakeUndefined(ctx);
        };
        dc.allocator = allocator;
        dc.slice = allocator.dupe(u8, raw) catch {
            allocator.destroy(dc);
            return jsc.JSValueMakeUndefined(ctx);
        };
        var exc: ?jsc.JSValueRef = null;
        const out = jsc.JSObjectMakeTypedArrayWithBytesNoCopy(
            ctx,
            .Uint8Array,
            dc.slice.ptr,
            dc.slice.len,
            fileBufferDeallocator,
            dc,
            @ptrCast(&exc),
        );
        if (out == null) {
            allocator.free(dc.slice);
            allocator.destroy(dc);
            if (exc) |e| exception[0] = e;
            return jsc.JSValueMakeUndefined(ctx);
        }
        return out.?;
    }
    const content_z = allocator.dupeZ(u8, raw) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(content_z);
    const content_ref = jsc.JSStringCreateWithUTF8CString(content_z.ptr);
    defer jsc.JSStringRelease(content_ref);
    return jsc.JSValueMakeString(ctx, content_ref);
}

fn writeFileSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    if (!opts.permissions.allow_write) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.fs.write requires --allow-write" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    const content_js = jsc.JSValueToStringCopy(ctx, arguments[1], null);
    defer jsc.JSStringRelease(content_js);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(content_js);
    if (max_sz == 0 or max_sz > 1024 * 1024 * 16) return jsc.JSValueMakeUndefined(ctx);
    const content_buf = allocator.alloc(u8, max_sz) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(content_buf);
    const n = jsc.JSStringGetUTF8CString(content_js, content_buf.ptr, max_sz);
    const content = content_buf[0..if (n > 0) n - 1 else 0];
    const io = libs_process.getProcessIo() orelse return jsc.JSValueMakeUndefined(ctx);
    const file = libs_io.createFileAbsolute(resolved, .{}) catch return jsc.JSValueMakeUndefined(ctx);
    defer file.close(io);
    file.writeStreamingAll(io, content) catch return jsc.JSValueMakeUndefined(ctx);
    return jsc.JSValueMakeUndefined(ctx);
}

fn readdirSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    if (!opts.permissions.allow_read) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.fs.readdir requires --allow-read" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    const io = libs_process.getProcessIo() orelse return jsc.JSValueMakeUndefined(ctx);
    var dir = libs_io.openDirAbsolute(resolved, .{ .iterate = true }) catch return jsc.JSValueMakeUndefined(ctx);
    defer dir.close(io);
    var buf: [512]jsc.JSValueRef = undefined;
    var count: usize = 0;
    var iter = dir.iterate();
    while (iter.next(io) catch return jsc.JSValueMakeUndefined(ctx)) |entry| {
        if (count >= buf.len) break;
        const name_z = allocator.dupeZ(u8, entry.name) catch return jsc.JSValueMakeUndefined(ctx);
        defer allocator.free(name_z);
        const name_ref = jsc.JSStringCreateWithUTF8CString(name_z.ptr);
        defer jsc.JSStringRelease(name_ref);
        buf[count] = jsc.JSValueMakeString(ctx, name_ref);
        count += 1;
    }
    if (count == 0) return jsc.JSObjectMakeArray(ctx, 0, undefined, null);
    return jsc.JSObjectMakeArray(ctx, count, &buf, null);
}

fn mkdirSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    if (!opts.permissions.allow_write) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.fs.mkdir requires --allow-write" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    libs_io.makeDirAbsolute(resolved) catch return jsc.JSValueMakeUndefined(ctx);
    return jsc.JSValueMakeUndefined(ctx);
}

fn existsSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeBoolean(ctx, false);
    defer allocator.free(resolved);
    if (!opts.permissions.allow_read) {
        return jsc.JSValueMakeBoolean(ctx, false);
    }
    libs_io.accessAbsolute(resolved, .{}) catch return jsc.JSValueMakeBoolean(ctx, false);
    return jsc.JSValueMakeBoolean(ctx, true);
}

fn statSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    if (!opts.permissions.allow_read) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.fs.stat requires --allow-read" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    const io = libs_process.getProcessIo() orelse return jsc.JSValueMakeUndefined(ctx);
    const file = libs_io.openFileAbsolute(resolved, .{}) catch |e| {
        if (e == libs_io.FileOpenError.IsDir) {
            var dir = libs_io.openDirAbsolute(resolved, .{}) catch return jsc.JSValueMakeUndefined(ctx);
            defer dir.close(io);
            const s = dir.stat(io) catch return jsc.JSValueMakeUndefined(ctx);
            const mtime_ns: i64 = @intCast(@min(s.mtime.nanoseconds, std.math.maxInt(i64)));
            return makeStatObject(ctx, false, s.size, mtime_ns);
        }
        return jsc.JSValueMakeUndefined(ctx);
    };
    defer file.close(io);
    const s = file.stat(io) catch return jsc.JSValueMakeUndefined(ctx);
    const mtime_ns: i64 = @intCast(@min(s.mtime.nanoseconds, std.math.maxInt(i64)));
    return makeStatObject(ctx, true, s.size, mtime_ns);
}

/// [Allocates] 解析符号链接与 . / .. 得到规范绝对路径；返回的 JS 字符串对应 Zig 侧 dupe 的路径，由本函数 defer 释放后交 JSC。realpathSync(path)，需要 --allow-read。
fn realpathSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    if (!opts.permissions.allow_read) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.fs.realpath requires --allow-read" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    var buf: [libs_io.max_path_bytes]u8 = undefined;
    const canonical = libs_io.realpath(resolved, &buf) catch return jsc.JSValueMakeUndefined(ctx);
    const dup = allocator.dupe(u8, canonical) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(dup);
    const z = allocator.dupeZ(u8, dup) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(z);
    const ref = jsc.JSStringCreateWithUTF8CString(z.ptr);
    defer jsc.JSStringRelease(ref);
    return jsc.JSValueMakeString(ctx, ref);
}

/// 对路径做 stat 但不跟符号链接，返回 isFile/isDirectory/isSymbolicLink/size/mtimeMs；lstatSync(path)，需要 --allow-read
fn lstatSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    if (!opts.permissions.allow_read) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.fs.lstat requires --allow-read" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    const io = libs_process.getProcessIo() orelse return jsc.JSValueMakeUndefined(ctx);
    const dir_path = libs_io.pathDirname(resolved) orelse ".";
    const base = libs_io.pathBasename(resolved);
    var dir = libs_io.openDirAbsolute(dir_path, .{}) catch return jsc.JSValueMakeUndefined(ctx);
    defer dir.close(io);
    const s = if (base.len == 0)
        dir.stat(io) catch return jsc.JSValueMakeUndefined(ctx)
    else
        dir.statFile(io, base, .{}) catch return jsc.JSValueMakeUndefined(ctx);
    const is_file = (s.kind == .file);
    const is_dir = (s.kind == .directory);
    const is_sym = (s.kind == .sym_link);
    const mtime_ns: i64 = @intCast(@min(s.mtime.nanoseconds, std.math.maxInt(i64)));
    return makeStatObjectWithSymlink(ctx, is_file, is_dir, is_sym, s.size, mtime_ns);
}

/// 将文件截断到指定长度（默认 0）；truncateSync(path [, len])，需要 --allow-write
fn truncateSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    if (!opts.permissions.allow_write) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.fs.truncate requires --allow-write" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    var len: u64 = 0;
    if (argumentCount >= 2) {
        const n = jsc.JSValueToNumber(ctx, arguments[1], null);
        if (n == n and n >= 0) len = @min(@as(u64, @intFromFloat(n)), std.math.maxInt(u64));
    }
    const io = libs_process.getProcessIo() orelse return jsc.JSValueMakeUndefined(ctx);
    const file = libs_io.openFileAbsolute(resolved, .{ .mode = .read_write }) catch return jsc.JSValueMakeUndefined(ctx);
    defer file.close(io);
    if (std.c.ftruncate(file.handle, @as(std.c.off_t, @intCast(len))) < 0) {
        std.posix.unexpectedErrno(std.c.errno(-1)) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// 按 R/W/X 检查路径可访问性；accessSync(path [, mode])，mode 为数字时 1=R 2=W 4=X，未传则仅检查存在，需要 --allow-read
fn accessSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeBoolean(ctx, false);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeBoolean(ctx, false);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeBoolean(ctx, false);
    defer allocator.free(resolved);
    if (!opts.permissions.allow_read) {
        return jsc.JSValueMakeBoolean(ctx, false);
    }
    var flags: libs_io.FileOpenFlags = .{};
    if (argumentCount >= 2) {
        const m = jsc.JSValueToNumber(ctx, arguments[1], null);
        if (m == m) {
            const mode = @as(u32, @intFromFloat(m));
            if (mode & 2 != 0)
                flags.mode = if (mode & 1 != 0) .read_write else .write_only
            else if (mode & 1 != 0)
                flags.mode = .read_only;
            // mode & 4 (X_OK) 无对应 Zig OpenMode，保留默认 .read_only 做存在性检查
        }
    }
    libs_io.accessAbsolute(resolved, flags) catch return jsc.JSValueMakeBoolean(ctx, false);
    return jsc.JSValueMakeBoolean(ctx, true);
}

/// 判断目录是否为空（无任何条目）；isEmptyDirSync(path)，需要 --allow-read
fn isEmptyDirSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeBoolean(ctx, false);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeBoolean(ctx, false);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeBoolean(ctx, false);
    defer allocator.free(resolved);
    if (!opts.permissions.allow_read) {
        return jsc.JSValueMakeBoolean(ctx, false);
    }
    const io = libs_process.getProcessIo() orelse return jsc.JSValueMakeBoolean(ctx, false);
    var dir = libs_io.openDirAbsolute(resolved, .{ .iterate = true }) catch return jsc.JSValueMakeBoolean(ctx, false);
    defer dir.close(io);
    var iter = dir.iterate();
    var has_any = false;
    while (iter.next(io) catch return jsc.JSValueMakeBoolean(ctx, false)) |_| {
        has_any = true;
        break;
    }
    return jsc.JSValueMakeBoolean(ctx, !has_any);
}

/// 仅返回文件大小（字节），目录返回 0；sizeSync(path)，需要 --allow-read
fn sizeSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    if (!opts.permissions.allow_read) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.fs.size requires --allow-read" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    const io = libs_process.getProcessIo() orelse return jsc.JSValueMakeUndefined(ctx);
    const file = libs_io.openFileAbsolute(resolved, .{}) catch |e| {
        if (e == libs_io.FileOpenError.IsDir) {
            return jsc.JSValueMakeNumber(ctx, 0);
        }
        return jsc.JSValueMakeUndefined(ctx);
    };
    defer file.close(io);
    const s = file.stat(io) catch return jsc.JSValueMakeUndefined(ctx);
    return jsc.JSValueMakeNumber(ctx, @floatFromInt(s.size));
}

/// 仅判断是否为文件，不存在或错误返回 false；isFileSync(path)，需要 --allow-read
fn isFileSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeBoolean(ctx, false);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeBoolean(ctx, false);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeBoolean(ctx, false);
    defer allocator.free(resolved);
    if (!opts.permissions.allow_read) return jsc.JSValueMakeBoolean(ctx, false);
    const io = libs_process.getProcessIo() orelse return jsc.JSValueMakeBoolean(ctx, false);
    const file = libs_io.openFileAbsolute(resolved, .{}) catch return jsc.JSValueMakeBoolean(ctx, false);
    defer file.close(io);
    const s = file.stat(io) catch return jsc.JSValueMakeBoolean(ctx, false);
    return jsc.JSValueMakeBoolean(ctx, s.kind == .file);
}

/// 仅判断是否为目录，不存在或错误返回 false；isDirectorySync(path)，需要 --allow-read
fn isDirectorySyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeBoolean(ctx, false);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeBoolean(ctx, false);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeBoolean(ctx, false);
    defer allocator.free(resolved);
    if (!opts.permissions.allow_read) return jsc.JSValueMakeBoolean(ctx, false);
    const io = libs_process.getProcessIo() orelse return jsc.JSValueMakeBoolean(ctx, false);
    var dir = libs_io.openDirAbsolute(resolved, .{}) catch return jsc.JSValueMakeBoolean(ctx, false);
    defer dir.close(io);
    _ = dir.stat(io) catch return jsc.JSValueMakeBoolean(ctx, false);
    return jsc.JSValueMakeBoolean(ctx, true);
}

/// 列出目录项且每项带 stat（name + isFile/isDirectory/isSymbolicLink/size/mtimeMs），避免 N+1 次 stat；readdirWithStatsSync(path)，需要 --allow-read
fn readdirWithStatsSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    if (!opts.permissions.allow_read) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.fs.readdirWithStats requires --allow-read" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    const io = libs_process.getProcessIo() orelse return jsc.JSValueMakeUndefined(ctx);
    var dir = libs_io.openDirAbsolute(resolved, .{ .iterate = true }) catch return jsc.JSValueMakeUndefined(ctx);
    defer dir.close(io);
    var buf: [512]jsc.JSValueRef = undefined;
    var count: usize = 0;
    var iter = dir.iterate();
    const k_name = jsc.JSStringCreateWithUTF8CString("name");
    defer jsc.JSStringRelease(k_name);
    const k_isFile = jsc.JSStringCreateWithUTF8CString("isFile");
    defer jsc.JSStringRelease(k_isFile);
    const k_isDirectory = jsc.JSStringCreateWithUTF8CString("isDirectory");
    defer jsc.JSStringRelease(k_isDirectory);
    const k_isSymbolicLink = jsc.JSStringCreateWithUTF8CString("isSymbolicLink");
    defer jsc.JSStringRelease(k_isSymbolicLink);
    const k_size = jsc.JSStringCreateWithUTF8CString("size");
    defer jsc.JSStringRelease(k_size);
    const k_mtimeMs = jsc.JSStringCreateWithUTF8CString("mtimeMs");
    defer jsc.JSStringRelease(k_mtimeMs);
    while (iter.next(io) catch return jsc.JSValueMakeUndefined(ctx)) |entry| {
        if (count >= buf.len) break;
        const s = dir.statFile(io, entry.name, .{}) catch continue;
        const is_file = (s.kind == .file);
        const is_dir = (s.kind == .directory);
        const is_sym = (s.kind == .sym_link);
        const mtime_ns: i64 = @intCast(@min(s.mtime.nanoseconds, std.math.maxInt(i64)));
        const item = jsc.JSObjectMake(ctx, null, null);
        const name_z = allocator.dupeZ(u8, entry.name) catch continue;
        defer allocator.free(name_z);
        const name_ref = jsc.JSStringCreateWithUTF8CString(name_z.ptr);
        defer jsc.JSStringRelease(name_ref);
        _ = jsc.JSObjectSetProperty(ctx, item, k_name, jsc.JSValueMakeString(ctx, name_ref), jsc.kJSPropertyAttributeNone, null);
        _ = jsc.JSObjectSetProperty(ctx, item, k_isFile, jsc.JSValueMakeBoolean(ctx, is_file), jsc.kJSPropertyAttributeNone, null);
        _ = jsc.JSObjectSetProperty(ctx, item, k_isDirectory, jsc.JSValueMakeBoolean(ctx, is_dir), jsc.kJSPropertyAttributeNone, null);
        _ = jsc.JSObjectSetProperty(ctx, item, k_isSymbolicLink, jsc.JSValueMakeBoolean(ctx, is_sym), jsc.kJSPropertyAttributeNone, null);
        _ = jsc.JSObjectSetProperty(ctx, item, k_size, jsc.JSValueMakeNumber(ctx, @floatFromInt(s.size)), jsc.kJSPropertyAttributeNone, null);
        const mtime_ms: f64 = if (mtime_ns >= 0) @floatFromInt(@divTrunc(mtime_ns, 1_000_000)) else 0;
        _ = jsc.JSObjectSetProperty(ctx, item, k_mtimeMs, jsc.JSValueMakeNumber(ctx, mtime_ms), jsc.kJSPropertyAttributeNone, null);
        buf[count] = item;
        count += 1;
    }
    if (count == 0) return jsc.JSObjectMakeArray(ctx, 0, undefined, null);
    return jsc.JSObjectMakeArray(ctx, count, &buf, null);
}

/// 路径不存在则创建空文件（含父目录），已存在为文件则 no-op，已存在为目录则报错；ensureFileSync(path)，需要 --allow-read 与 --allow-write
fn ensureFileSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    if (!opts.permissions.allow_read or !opts.permissions.allow_write) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.fs.ensureFile requires --allow-read and --allow-write" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    const io = libs_process.getProcessIo() orelse return jsc.JSValueMakeUndefined(ctx);
    const file = libs_io.openFileAbsolute(resolved, .{}) catch |e| {
        if (e == libs_io.FileOpenError.FileNotFound) {
            const parent = libs_io.pathDirname(resolved) orelse return jsc.JSValueMakeUndefined(ctx);
            if (parent.len > 0 and parent.len < resolved.len) {
                makeDirRecursiveAbsolute(allocator, parent);
            }
            var f = libs_io.createFileAbsolute(resolved, .{}) catch return jsc.JSValueMakeUndefined(ctx);
            f.close(io);
            return jsc.JSValueMakeUndefined(ctx);
        }
        if (e == libs_io.FileOpenError.IsDir) {
            errors.reportToStderr(.{ .code = .file_not_found, .message = "Shu.fs.ensureFile: path is a directory" }) catch {};
        }
        return jsc.JSValueMakeUndefined(ctx);
    };
    file.close(io);
    return jsc.JSValueMakeUndefined(ctx);
}

fn unlinkSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    if (!opts.permissions.allow_write) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.fs.unlink requires --allow-write" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    libs_io.deleteFileAbsolute(resolved) catch return jsc.JSValueMakeUndefined(ctx);
    return jsc.JSValueMakeUndefined(ctx);
}

fn rmdirSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    if (!opts.permissions.allow_write) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.fs.rmdir requires --allow-write" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    libs_io.deleteDirAbsolute(resolved) catch return jsc.JSValueMakeUndefined(ctx);
    return jsc.JSValueMakeUndefined(ctx);
}

fn renameSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const old_resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(old_resolved);
    const new_resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 1) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(new_resolved);
    if (!opts.permissions.allow_read or !opts.permissions.allow_write) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.fs.rename requires --allow-read and --allow-write" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    libs_io.renameAbsolute(old_resolved, new_resolved) catch return jsc.JSValueMakeUndefined(ctx);
    return jsc.JSValueMakeUndefined(ctx);
}

/// 同步复制文件：copySync(srcPath, destPath)，需要源可读、目标可写；大文件走 libs_io.mapFileReadOnly 减少拷贝与 OOM
fn copySyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const src_resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(src_resolved);
    const dest_resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 1) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(dest_resolved);
    if (!opts.permissions.allow_read or !opts.permissions.allow_write) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.fs.copy requires --allow-read and --allow-write" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    const io = libs_process.getProcessIo() orelse return jsc.JSValueMakeUndefined(ctx);
    const src_file = libs_io.openFileAbsolute(src_resolved, .{}) catch |e| {
        if (e == libs_io.FileOpenError.FileNotFound) {
            const msg = std.fmt.allocPrint(allocator, "File not found: {s}", .{src_resolved}) catch src_resolved;
            errors.reportToStderr(.{ .code = .file_not_found, .message = msg }) catch {};
            if (msg.ptr != src_resolved.ptr) allocator.free(msg);
        }
        return jsc.JSValueMakeUndefined(ctx);
    };
    const src_stat = src_file.stat(io) catch {
        src_file.close(io);
        return jsc.JSValueMakeUndefined(ctx);
    };
    if (src_stat.size >= FS_MAP_THRESHOLD and src_stat.kind == .file) {
        src_file.close(io);
        var mapped = libs_io.mapFileReadOnly(src_resolved) catch {
            var fallback_src = libs_io.openFileAbsolute(src_resolved, .{}) catch return jsc.JSValueMakeUndefined(ctx);
            defer fallback_src.close(io);
            const content = allocator.alloc(u8, src_stat.size) catch return jsc.JSValueMakeUndefined(ctx);
            defer allocator.free(content);
            var fallback_src_reader = fallback_src.reader(io, &.{});
            var read_vec = [_][]u8{content};
            _ = fallback_src_reader.interface.readVecAll(&read_vec) catch return jsc.JSValueMakeUndefined(ctx);
            const dest_file = libs_io.createFileAbsolute(dest_resolved, .{}) catch return jsc.JSValueMakeUndefined(ctx);
            defer dest_file.close(io);
            dest_file.writeStreamingAll(io, content) catch return jsc.JSValueMakeUndefined(ctx);
            return jsc.JSValueMakeUndefined(ctx);
        };
        defer mapped.deinit();
        const dest_file = libs_io.createFileAbsolute(dest_resolved, .{}) catch return jsc.JSValueMakeUndefined(ctx);
        defer dest_file.close(io);
        dest_file.writeStreamingAll(io, mapped.slice()) catch return jsc.JSValueMakeUndefined(ctx);
        return jsc.JSValueMakeUndefined(ctx);
    }
    src_file.close(io);
    // §3.1/§5 小文件用 libs_io.copyFileAbsolute，由内核 copy_file_range/sendfile 等实现，避免 readToEndAlloc+writeAll 用户态拷贝
    libs_io.copyFileAbsolute(src_resolved, dest_resolved, .{}) catch return jsc.JSValueMakeUndefined(ctx);
    return jsc.JSValueMakeUndefined(ctx);
}

/// 同步追加写入：appendSync(path, content)，需要 --allow-write；文件不存在则创建
fn appendSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    if (!opts.permissions.allow_write) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.fs.append requires --allow-write" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    const content_js = jsc.JSValueToStringCopy(ctx, arguments[1], null);
    defer jsc.JSStringRelease(content_js);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(content_js);
    if (max_sz == 0 or max_sz > 1024 * 1024 * 16) return jsc.JSValueMakeUndefined(ctx);
    const content_buf = allocator.alloc(u8, max_sz) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(content_buf);
    const n = jsc.JSStringGetUTF8CString(content_js, content_buf.ptr, max_sz);
    const content = content_buf[0..if (n > 0) n - 1 else 0];
    const io = libs_process.getProcessIo() orelse return jsc.JSValueMakeUndefined(ctx);
    var file = libs_io.openFileAbsolute(resolved, .{ .mode = .write_only }) catch |e| {
        if (e == libs_io.FileOpenError.FileNotFound) {
            var new_file = libs_io.createFileAbsolute(resolved, .{}) catch return jsc.JSValueMakeUndefined(ctx);
            defer new_file.close(io);
            new_file.writeStreamingAll(io, content) catch return jsc.JSValueMakeUndefined(ctx);
            return jsc.JSValueMakeUndefined(ctx);
        }
        return jsc.JSValueMakeUndefined(ctx);
    };
    defer file.close(io);
    const end_pos = file.length(io) catch return jsc.JSValueMakeUndefined(ctx);
    file.writePositionalAll(io, content, end_pos) catch return jsc.JSValueMakeUndefined(ctx);
    return jsc.JSValueMakeUndefined(ctx);
}

/// 递归创建目录（mkdir -p）：先创建父目录再创建当前路径
fn makeDirRecursiveAbsolute(allocator: std.mem.Allocator, absolute_path: []const u8) void {
    libs_io.makeDirAbsolute(absolute_path) catch |e| {
        switch (e) {
            error.PathAlreadyExists => return,
            else => {
                const parent = libs_io.pathDirname(absolute_path) orelse return;
                if (parent.len == 0 or parent.len >= absolute_path.len) return;
                makeDirRecursiveAbsolute(allocator, parent);
                libs_io.makeDirAbsolute(absolute_path) catch return;
            },
        }
    };
}

/// 同步创建符号链接：symlinkSync(targetPath, linkPath)，需要 --allow-write
fn symlinkSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const target_resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(target_resolved);
    const link_resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 1) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(link_resolved);
    if (!opts.permissions.allow_write) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.fs.symlink requires --allow-write" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    libs_io.symLinkAbsolute(target_resolved, link_resolved, .{}) catch return jsc.JSValueMakeUndefined(ctx);
    return jsc.JSValueMakeUndefined(ctx);
}

/// 同步读取符号链接目标：readlinkSync(linkPath) 返回目标路径字符串，需要 --allow-read
fn readlinkSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    if (!opts.permissions.allow_read) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.fs.readlink requires --allow-read" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    var buf: [libs_io.max_path_bytes]u8 = undefined;
    const target = libs_io.readLinkAbsolute(resolved, &buf) catch return jsc.JSValueMakeUndefined(ctx);
    const target_dup = allocator.dupe(u8, target) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(target_dup);
    const target_z = allocator.dupeZ(u8, target_dup) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(target_z);
    const ref = jsc.JSStringCreateWithUTF8CString(target_z.ptr);
    defer jsc.JSStringRelease(ref);
    return jsc.JSValueMakeString(ctx, ref);
}

/// 同步递归创建目录（mkdir -p 风格）：mkdirRecursiveSync(path)，需要 --allow-write
fn mkdirRecursiveSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    if (!opts.permissions.allow_write) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.fs.mkdir requires --allow-write" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    makeDirRecursiveAbsolute(allocator, resolved);
    return jsc.JSValueMakeUndefined(ctx);
}

/// 同步递归删除目录及内容（rm -rf 风格）：rmdirRecursiveSync(path)，需要 --allow-write
fn rmdirRecursiveSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    if (!opts.permissions.allow_write) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.fs.rmdir requires --allow-write" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    libs_io.deleteTreeAbsolute(allocator, resolved) catch return jsc.JSValueMakeUndefined(ctx);
    return jsc.JSValueMakeUndefined(ctx);
}

// ---------- 异步回调 ----------

/// Shu.fs.read(path [, options])：异步读文件，走 libs_io.AsyncFileIO；Zig 侧直接 new Promise(executor) 无脚本解析；options.encoding 为 null/'buffer' 时返回 Buffer，否则 UTF-8 字符串；失败时回退 setTimeout+readSync
fn readFileAsyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const path = getArgString(allocator, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(path);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    if (!opts.permissions.allow_read) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.fs.read requires --allow-read" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    const return_buffer = blk: {
        if (argumentCount < 2) break :blk false;
        const options = jsc.JSValueToObject(ctx, arguments[1], null) orelse break :blk false;
        const k_enc = jsc.JSStringCreateWithUTF8CString("encoding");
        defer jsc.JSStringRelease(k_enc);
        const enc_val = jsc.JSObjectGetProperty(ctx, options, k_enc, null);
        if (jsc.JSValueIsUndefined(ctx, enc_val) or jsc.JSValueIsNull(ctx, enc_val)) break :blk true;
        const enc_str = jsc.JSValueToStringCopy(ctx, enc_val, null);
        defer jsc.JSStringRelease(enc_str);
        const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(enc_str);
        if (max_sz <= 1 or max_sz > 32) break :blk false;
        var buf: [32]u8 = undefined;
        const n = jsc.JSStringGetUTF8CString(enc_str, &buf, max_sz);
        const enc = buf[0..if (n > 0) n - 1 else 0];
        if (enc.len == 0) break :blk true;
        if (enc.len == 6) {
            var pad: [8]u8 = [_]u8{0} ** 8;
            @memcpy(pad[0..6], enc[0..6]);
            const q = @as(u64, @bitCast(pad));
            if (q == @as(u64, @bitCast([8]u8{ 'b', 'u', 'f', 'f', 'e', 'r', 0, 0 })) or q == @as(u64, @bitCast([8]u8{ 'b', 'i', 'n', 'a', 'r', 'y', 0, 0 }))) break :blk true;
        }
        break :blk false;
    };
    const resolved_owned = allocator.dupe(u8, resolved) catch {
        const path_json = jsonEscapeString(allocator, path) orelse return jsc.JSValueMakeUndefined(ctx);
        defer allocator.free(path_json);
        return makeDeferredPromiseOne(ctx, allocator, "readSync", path_json);
    };
    fs_read_promise_args = .{ .resolved = resolved_owned, .return_buffer = return_buffer };
    const Promise_ctor = promise.getPromiseConstructor(ctx) orelse {
        fs_read_promise_args = null;
        allocator.free(resolved_owned);
        const path_json = jsonEscapeString(allocator, path) orelse return jsc.JSValueMakeUndefined(ctx);
        defer allocator.free(path_json);
        return makeDeferredPromiseOne(ctx, allocator, "readSync", path_json);
    };
    const executor_name = jsc.JSStringCreateWithUTF8CString("executor");
    defer jsc.JSStringRelease(executor_name);
    const executor_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, executor_name, fsReadExecutorCallback);
    var executor_arg: [1]jsc.JSValueRef = .{executor_fn};
    return jsc.JSObjectCallAsConstructor(ctx, Promise_ctor, 1, &executor_arg, null);
}

/// Shu.fs.write(path, content)：异步写文件，走 libs_io.AsyncFileIO；Zig 侧直接 new Promise(executor) 无脚本解析；init 失败或 content 超 512KB 时回退 setTimeout+writeSync
fn writeFileAsyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    if (!opts.permissions.allow_write) {
        allocator.free(resolved);
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.fs.write requires --allow-write" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    const content = getArgString(allocator, ctx, arguments, argumentCount, 1) orelse {
        allocator.free(resolved);
        return jsc.JSValueMakeUndefined(ctx);
    };
    if (content.len > 512 * 1024) {
        const path_json = jsonEscapeString(allocator, resolved) orelse {
            allocator.free(resolved);
            allocator.free(content);
            return jsc.JSValueMakeUndefined(ctx);
        };
        defer allocator.free(path_json);
        const content_json = jsonEscapeString(allocator, content) orelse {
            allocator.free(resolved);
            allocator.free(content);
            return jsc.JSValueMakeUndefined(ctx);
        };
        defer allocator.free(content_json);
        allocator.free(resolved);
        allocator.free(content);
        return makeDeferredPromiseTwo(ctx, allocator, "writeSync", path_json, content_json);
    }
    const content_owned = allocator.dupe(u8, content) catch {
        allocator.free(resolved);
        allocator.free(content);
        return jsc.JSValueMakeUndefined(ctx);
    };
    allocator.free(content); // getArgString 返回的切片，dupe 后不再需要
    fs_write_promise_args = .{ .resolved = resolved, .content = content_owned };
    const Promise_ctor = promise.getPromiseConstructor(ctx) orelse {
        fs_write_promise_args = null;
        const path_json = jsonEscapeString(allocator, resolved) orelse {
            allocator.free(resolved);
            allocator.free(content_owned);
            return jsc.JSValueMakeUndefined(ctx);
        };
        defer allocator.free(path_json);
        const content_json = jsonEscapeString(allocator, content_owned) orelse {
            allocator.free(resolved);
            allocator.free(content_owned);
            return jsc.JSValueMakeUndefined(ctx);
        };
        defer allocator.free(content_json);
        allocator.free(resolved);
        allocator.free(content_owned);
        return makeDeferredPromiseTwo(ctx, allocator, "writeSync", path_json, content_json);
    };
    const executor_name = jsc.JSStringCreateWithUTF8CString("executor");
    defer jsc.JSStringRelease(executor_name);
    const executor_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, executor_name, fsWriteExecutorCallback);
    var one: [1]jsc.JSValueRef = .{executor_fn};
    const result = jsc.JSObjectCallAsConstructor(ctx, Promise_ctor, 1, &one, null);
    if (jsc.JSValueIsUndefined(ctx, result)) {
        fs_write_promise_args = null;
        allocator.free(resolved);
        allocator.free(content_owned);
    }
    return result;
}

fn readdirAsyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    const path_dup = allocator.dupe(u8, resolved) catch return jsc.JSValueMakeUndefined(ctx);
    return createDeferredFsPromise(ctx, allocator, .readdir, path_dup, null, null, 0, 0, false);
}

fn mkdirAsyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    const path_dup = allocator.dupe(u8, resolved) catch return jsc.JSValueMakeUndefined(ctx);
    return createDeferredFsPromise(ctx, allocator, .mkdir, path_dup, null, null, 0, 0, false);
}

fn existsAsyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    const path_dup = allocator.dupe(u8, resolved) catch return jsc.JSValueMakeUndefined(ctx);
    return createDeferredFsPromise(ctx, allocator, .exists, path_dup, null, null, 0, 0, false);
}

fn statAsyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    const path_dup = allocator.dupe(u8, resolved) catch return jsc.JSValueMakeUndefined(ctx);
    return createDeferredFsPromise(ctx, allocator, .stat, path_dup, null, null, 0, 0, false);
}

fn realpathAsyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    const path_dup = allocator.dupe(u8, resolved) catch return jsc.JSValueMakeUndefined(ctx);
    return createDeferredFsPromise(ctx, allocator, .realpath, path_dup, null, null, 0, 0, false);
}

fn lstatAsyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    const path_dup = allocator.dupe(u8, resolved) catch return jsc.JSValueMakeUndefined(ctx);
    return createDeferredFsPromise(ctx, allocator, .lstat, path_dup, null, null, 0, 0, false);
}

fn truncateAsyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    var len: u64 = 0;
    if (argumentCount >= 2) {
        const n = jsc.JSValueToNumber(ctx, arguments[1], null);
        if (n == n and n >= 0) len = @min(@as(u64, @intFromFloat(n)), std.math.maxInt(u64));
    }
    const path_dup = allocator.dupe(u8, resolved) catch return jsc.JSValueMakeUndefined(ctx);
    return createDeferredFsPromise(ctx, allocator, .truncate, path_dup, null, null, len, 0, false);
}

fn accessAsyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    var mode: u32 = 0;
    if (argumentCount >= 2) {
        const m = jsc.JSValueToNumber(ctx, arguments[1], null);
        if (m == m) mode = @as(u32, @intFromFloat(m));
    }
    const path_dup = allocator.dupe(u8, resolved) catch return jsc.JSValueMakeUndefined(ctx);
    return createDeferredFsPromise(ctx, allocator, .access, path_dup, null, null, 0, mode, false);
}

fn isEmptyDirAsyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    const path_dup = allocator.dupe(u8, resolved) catch return jsc.JSValueMakeUndefined(ctx);
    return createDeferredFsPromise(ctx, allocator, .isEmptyDir, path_dup, null, null, 0, 0, false);
}

fn sizeAsyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    const path_dup = allocator.dupe(u8, resolved) catch return jsc.JSValueMakeUndefined(ctx);
    return createDeferredFsPromise(ctx, allocator, .size, path_dup, null, null, 0, 0, false);
}

fn isFileAsyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    const path_dup = allocator.dupe(u8, resolved) catch return jsc.JSValueMakeUndefined(ctx);
    return createDeferredFsPromise(ctx, allocator, .isFile, path_dup, null, null, 0, 0, false);
}

fn isDirectoryAsyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    const path_dup = allocator.dupe(u8, resolved) catch return jsc.JSValueMakeUndefined(ctx);
    return createDeferredFsPromise(ctx, allocator, .isDirectory, path_dup, null, null, 0, 0, false);
}

fn readdirWithStatsAsyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    const path_dup = allocator.dupe(u8, resolved) catch return jsc.JSValueMakeUndefined(ctx);
    return createDeferredFsPromise(ctx, allocator, .readdirWithStats, path_dup, null, null, 0, 0, false);
}

fn ensureFileAsyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    const path_dup = allocator.dupe(u8, resolved) catch return jsc.JSValueMakeUndefined(ctx);
    return createDeferredFsPromise(ctx, allocator, .ensureFile, path_dup, null, null, 0, 0, false);
}

fn unlinkAsyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    const path_dup = allocator.dupe(u8, resolved) catch return jsc.JSValueMakeUndefined(ctx);
    return createDeferredFsPromise(ctx, allocator, .unlink, path_dup, null, null, 0, 0, false);
}

fn rmdirAsyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    const path_dup = allocator.dupe(u8, resolved) catch return jsc.JSValueMakeUndefined(ctx);
    return createDeferredFsPromise(ctx, allocator, .rmdir, path_dup, null, null, 0, 0, false);
}

fn renameAsyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const old_resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(old_resolved);
    const new_resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 1) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(new_resolved);
    const path_dup = allocator.dupe(u8, old_resolved) catch return jsc.JSValueMakeUndefined(ctx);
    const path2_dup = allocator.dupe(u8, new_resolved) catch {
        allocator.free(path_dup);
        return jsc.JSValueMakeUndefined(ctx);
    };
    return createDeferredFsPromise(ctx, allocator, .rename, path_dup, path2_dup, null, 0, 0, false);
}

/// 异步复制文件：copy(srcPath, destPath) 返回 Promise<void>
fn copyAsyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const src_resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(src_resolved);
    const dest_resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 1) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(dest_resolved);
    const path_dup = allocator.dupe(u8, src_resolved) catch return jsc.JSValueMakeUndefined(ctx);
    const path2_dup = allocator.dupe(u8, dest_resolved) catch {
        allocator.free(path_dup);
        return jsc.JSValueMakeUndefined(ctx);
    };
    return createDeferredFsPromise(ctx, allocator, .copy, path_dup, path2_dup, null, 0, 0, false);
}

/// 异步追加写入：append(path, content) 返回 Promise<void>，content 上限 512KB
fn appendAsyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    const content = getArgString(allocator, ctx, arguments, argumentCount, 1) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(content);
    if (content.len > 512 * 1024) return jsc.JSValueMakeUndefined(ctx);
    const path_dup = allocator.dupe(u8, resolved) catch return jsc.JSValueMakeUndefined(ctx);
    const content_dup = allocator.dupe(u8, content) catch {
        allocator.free(path_dup);
        return jsc.JSValueMakeUndefined(ctx);
    };
    return createDeferredFsPromise(ctx, allocator, .append, path_dup, null, content_dup, 0, 0, false);
}

/// 异步创建符号链接：symlink(targetPath, linkPath) 返回 Promise<void>
fn symlinkAsyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const target_resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(target_resolved);
    const link_resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 1) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(link_resolved);
    const path_dup = allocator.dupe(u8, target_resolved) catch return jsc.JSValueMakeUndefined(ctx);
    const path2_dup = allocator.dupe(u8, link_resolved) catch {
        allocator.free(path_dup);
        return jsc.JSValueMakeUndefined(ctx);
    };
    return createDeferredFsPromise(ctx, allocator, .symlink, path_dup, path2_dup, null, 0, 0, false);
}

/// 异步读取符号链接目标：readlink(linkPath) 返回 Promise<string>
fn readlinkAsyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    const path_dup = allocator.dupe(u8, resolved) catch return jsc.JSValueMakeUndefined(ctx);
    return createDeferredFsPromise(ctx, allocator, .readlink, path_dup, null, null, 0, 0, false);
}

/// 异步递归创建目录：mkdirRecursive(path) 返回 Promise<void>
fn mkdirRecursiveAsyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    const path_dup = allocator.dupe(u8, resolved) catch return jsc.JSValueMakeUndefined(ctx);
    return createDeferredFsPromise(ctx, allocator, .mkdirRecursive, path_dup, null, null, 0, 0, false);
}

/// 异步递归删除目录及内容：rmdirRecursive(path) 返回 Promise<void>
fn rmdirRecursiveAsyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const resolved = getResolvedPath(allocator, opts.cwd, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(resolved);
    const path_dup = allocator.dupe(u8, resolved) catch return jsc.JSValueMakeUndefined(ctx);
    return createDeferredFsPromise(ctx, allocator, .rmdirRecursive, path_dup, null, null, 0, 0, false);
}
