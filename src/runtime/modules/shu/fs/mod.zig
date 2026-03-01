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
//! ## 与 Node.js (node:fs) 兼容情况
//! - readFileSync/readFile、writeFileSync/writeFile、copyFileSync/copyFile、appendFileSync/appendFile 与 readSync/read、writeSync/write、copySync/copy、appendSync/append 同实现
//! - ensureDirSync/ensureDir 与 mkdirRecursiveSync/mkdirRecursive 同实现
//! - realpath、lstat、truncate、access、readdirWithStats（对应 withFileTypes 场景）、ensureFile 等均已提供；stat/lstat 返回对象含 isSymbolicLink
//!
//! ## 性能与约定
//! - 异步：纯 Zig 实现，无内联 JS；Promise 构造时入延迟队列，在 drain（drainFileIOCompletions）中执行同步逻辑并 resolve/reject
//! - readSync(path, { encoding: null }) 返回 Buffer 时：小文件 Zig 分配 + JSC NoCopy；大文件（≥FS_MAP_THRESHOLD）走 io_core.mapFileReadOnly，零拷贝
//! - copySync 大文件：源 mmap + 整块写，减少 OOM 与拷贝
//! - 所有需要分配内存的路径均使用调用方传入的 allocator（globals.current_allocator），谁分配谁释放

const std = @import("std");
const jsc = @import("jsc");
const io_core = @import("io_core");
// 从 modules/shu/fs 引用 runtime 上层与 engine
const errors = @import("../../../../errors.zig");
const globals = @import("../../../globals.zig");
const common = @import("../../../common.zig");

/// 超过此大小的文件在 readSync(encoding:null) 时用 io_core.mapFileReadOnly；copySync 源文件超过此值时用 mmap 读+整块写
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

/// 大文件 readSync(encoding:null) 时用 io_core.mapFileReadOnly；JSC 回收时调 mapped.deinit 并释放本结构
const MappedFileContext = struct {
    allocator: std.mem.Allocator,
    mapped: io_core.MappedFile,
};
fn mappedFileDeallocator(bytes: *anyopaque, deallocator_context: ?*anyopaque) callconv(.c) void {
    _ = bytes;
    const ctx = @as(*MappedFileContext, @ptrCast(@alignCast(deallocator_context orelse return)));
    ctx.mapped.deinit();
    ctx.allocator.destroy(ctx);
}

// ---------- 异步文件 I/O 状态（io_core.AsyncFileIO + pending 表，drain 时 resolve/reject）----------

/// 单条待完成的异步文件操作：read 或 write，完成时由 drain 根据 user_data 查表并 resolve/reject
const PendingEntry = struct {
    resolve: jsc.JSValueRef,
    reject: jsc.JSValueRef,
    file: std.fs.File,
    allocator: std.mem.Allocator,
    kind: enum { read, write },
    /// read 时：读入数据的 buffer，drain 时交 JSC 或 free
    read_buffer: ?[]u8 = null,
    /// read 时：是否以 Buffer 返回（否则 UTF-8 字符串）
    return_buffer: bool = false,
    /// write 时：写入内容的拷贝，drain 时 free
    write_data: ?[]const u8 = null,
};

/// 每线程异步 fs 状态：AsyncFileIO 实例与 pending 表；首次 Shu.fs.read/Shu.fs.write（异步）时按需创建
const FsAsyncState = struct {
    allocator: std.mem.Allocator,
    pending: std.AutoHashMap(usize, PendingEntry),
    next_id: usize,
    async_file_io: *io_core.AsyncFileIO,
};
var fs_async_state: ?*FsAsyncState = null;

/// 供 Promise executor 使用：read 时传入 resolved 路径与 return_buffer，executor 内取走后清空
var fs_read_promise_args: ?struct { resolved: []const u8, return_buffer: bool } = null;
/// 供 Promise executor 使用：write 时传入 resolved 路径与 content，executor 内取走后清空
var fs_write_promise_args: ?struct { resolved: []const u8, content: []const u8 } = null;

/// 确保当前线程有 AsyncFileIO 与 FsAsyncState；创建时设置 globals.current_async_file_io 与 globals.drain_async_file_io。调用方须持有 current_allocator。
fn ensureAsyncFileIO() !*FsAsyncState {
    if (fs_async_state) |s| return s;
    const allocator = globals.current_allocator orelse return error.NoAllocator;
    var fio = allocator.create(io_core.AsyncFileIO) catch return error.OutOfMemory;
    fio.* = io_core.AsyncFileIO.init(allocator) catch |e| {
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
    state.pending = std.AutoHashMap(usize, PendingEntry).init(allocator);
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
/// 延迟队列；首次使用时用 current_allocator 初始化
var deferred_fs_queue: ?std.ArrayList(DeferredFsOp) = null;

/// 确保延迟队列已初始化；调用方须持有 current_allocator
fn ensureDeferredFsQueue() !void {
    if (deferred_fs_queue != null) return;
    const allocator = globals.current_allocator orelse return error.NoAllocator;
    deferred_fs_queue = std.ArrayList(DeferredFsOp).initCapacity(allocator, 0) catch return error.NoAllocator;
}

/// Promise executor 的 C 回调：JSC 调用时传入 (resolve, reject)，将当前 op 的 resolve/reject 写入，path/path2/content 复制后入队并释放原指针，返回 undefined
fn deferredFsExecutor(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const op = current_deferred_fs_op orelse return jsc.JSValueMakeUndefined(ctx);
    current_deferred_fs_op = null;
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const allocator = op.allocator;
    const path_dup = allocator.dupe(u8, op.path) catch return jsc.JSValueMakeUndefined(ctx);
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
        .resolve = arguments[0],
        .reject = arguments[1],
    };
    jsc.JSValueProtect(ctx, entry.resolve);
    jsc.JSValueProtect(ctx, entry.reject);
    if (deferred_fs_queue) |*q| {
        q.append(allocator, entry) catch {
            allocator.free(path_dup);
            if (path2_dup) |p| allocator.free(p);
            if (content_dup) |c| allocator.free(c);
            return jsc.JSValueMakeUndefined(ctx);
        };
    } else {
        return jsc.JSValueMakeUndefined(ctx);
    }
    return jsc.JSValueMakeUndefined(ctx);
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
    switch (op.tag) {
        .realpath => {
            if (!opts.permissions.allow_read) {
                do_reject(ctx, reject_fn, allocator, "Shu.fs.realpath requires --allow-read");
                return;
            }
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const canonical = std.fs.realpath(op.path, &buf) catch {
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
            const dir_path = std.fs.path.dirname(op.path) orelse ".";
            const base = std.fs.path.basename(op.path);
            var dir = std.fs.openDirAbsolute(dir_path, .{}) catch {
                do_reject(ctx, reject_fn, allocator, "lstat failed");
                return;
            };
            defer dir.close();
            const s = if (base.len == 0) dir.stat() catch {
                do_reject(ctx, reject_fn, allocator, "lstat failed");
                return;
            } else dir.statFile(base) catch {
                do_reject(ctx, reject_fn, allocator, "lstat failed");
                return;
            };
            const is_file = (s.kind == .file);
            const is_dir = (s.kind == .directory);
            const is_sym = (s.kind == .sym_link);
            const mtime_ns: i64 = @intCast(@min(s.mtime, std.math.maxInt(i64)));
            const obj = makeStatObjectWithSymlink(ctx, is_file, is_dir, is_sym, s.size, mtime_ns);
            var res_arg: [1]jsc.JSValueRef = .{obj};
            _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &res_arg, null);
        },
        .truncate => {
            if (!opts.permissions.allow_write) {
                do_reject(ctx, reject_fn, allocator, "Shu.fs.truncate requires --allow-write");
                return;
            }
            const file = std.fs.openFileAbsolute(op.path, .{ .mode = .read_write }) catch {
                do_reject(ctx, reject_fn, allocator, "truncate failed");
                return;
            };
            defer file.close();
            std.posix.ftruncate(file.handle, op.len) catch {
                do_reject(ctx, reject_fn, allocator, "ftruncate failed");
                return;
            };
            const empty: [0]jsc.JSValueRef = .{};
            _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 0, &empty, null);
        },
        .access => {
            if (!opts.permissions.allow_read) {
                var false_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeBoolean(ctx, false)};
                _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &false_arg, null);
                return;
            }
            var flags: std.fs.File.OpenFlags = .{};
            if (op.mode & 1 != 0) flags.mode = .read_only;
            if (op.mode & 2 != 0) flags.mode = if (op.mode & 1 != 0) .read_write else .write_only;
            std.fs.accessAbsolute(op.path, flags) catch {
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
            var dir = std.fs.openDirAbsolute(op.path, .{ .iterate = true }) catch {
                var false_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeBoolean(ctx, false)};
                _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &false_arg, null);
                return;
            };
            defer dir.close();
            var iter = dir.iterate();
            var has_any = false;
            while (iter.next() catch {
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
            const file = std.fs.openFileAbsolute(op.path, .{}) catch |e| {
                if (e == std.fs.File.OpenError.IsDir) {
                    var zero_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeNumber(ctx, 0)};
                    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &zero_arg, null);
                    return;
                }
                do_reject(ctx, reject_fn, allocator, "size failed");
                return;
            };
            defer file.close();
            const s = file.stat() catch {
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
            const file = std.fs.openFileAbsolute(op.path, .{}) catch {
                var false_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeBoolean(ctx, false)};
                _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &false_arg, null);
                return;
            };
            defer file.close();
            const s = file.stat() catch {
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
            var dir = std.fs.openDirAbsolute(op.path, .{}) catch {
                var false_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeBoolean(ctx, false)};
                _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &false_arg, null);
                return;
            };
            defer dir.close();
            _ = dir.stat() catch {
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
            var dir = std.fs.openDirAbsolute(op.path, .{ .iterate = true }) catch {
                do_reject(ctx, reject_fn, allocator, "readdir failed");
                return;
            };
            defer dir.close();
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
            while (iter.next() catch {
                do_reject(ctx, reject_fn, allocator, "readdir iterate failed");
                return;
            }) |entry| {
                if (count >= buf.len) break;
                const s = dir.statFile(entry.name) catch continue;
                const is_file = (s.kind == .file);
                const is_dir = (s.kind == .directory);
                const is_sym = (s.kind == .sym_link);
                const mtime_ns: i64 = @intCast(@min(s.mtime, std.math.maxInt(i64)));
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
            const file = std.fs.openFileAbsolute(op.path, .{}) catch |e| {
                if (e == std.fs.File.OpenError.FileNotFound) {
                    const parent = std.fs.path.dirname(op.path) orelse return;
                    if (parent.len > 0 and parent.len < op.path.len) makeDirRecursiveAbsolute(allocator, parent);
                    var f = std.fs.createFileAbsolute(op.path, .{}) catch {
                        do_reject(ctx, reject_fn, allocator, "ensureFile create failed");
                        return;
                    };
                    f.close();
                    const empty: [0]jsc.JSValueRef = .{};
                    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 0, &empty, null);
                    return;
                }
                if (e == std.fs.File.OpenError.IsDir) {
                    do_reject(ctx, reject_fn, allocator, "Shu.fs.ensureFile: path is a directory");
                    return;
                }
                do_reject(ctx, reject_fn, allocator, "ensureFile failed");
                return;
            };
            file.close();
            const empty: [0]jsc.JSValueRef = .{};
            _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 0, &empty, null);
        },
        .stat => runDeferredFsOpStat(ctx, op, resolve_fn, reject_fn, do_reject),
        .readdir => runDeferredFsOpReaddir(ctx, op, resolve_fn, reject_fn, do_reject),
        .mkdir => runDeferredFsOpMkdir(ctx, op, resolve_fn, reject_fn, do_reject),
        .exists => runDeferredFsOpExists(ctx, op, resolve_fn, reject_fn),
        .unlink => runDeferredFsOpUnlink(ctx, op, resolve_fn, reject_fn, do_reject),
        .rmdir => runDeferredFsOpRmdir(ctx, op, resolve_fn, reject_fn, do_reject),
        .rename => runDeferredFsOpRename(ctx, op, resolve_fn, reject_fn, do_reject),
        .copy => runDeferredFsOpCopy(ctx, op, resolve_fn, reject_fn, do_reject),
        .append => runDeferredFsOpAppend(ctx, op, resolve_fn, reject_fn, do_reject),
        .write => runDeferredFsOpWrite(ctx, op, resolve_fn, reject_fn, do_reject),
        .readlink => runDeferredFsOpReadlink(ctx, op, resolve_fn, reject_fn, do_reject),
        .symlink => runDeferredFsOpSymlink(ctx, op, resolve_fn, reject_fn, do_reject),
        .readFile => runDeferredFsOpReadFile(ctx, op, resolve_fn, reject_fn, do_reject),
        .mkdirRecursive => runDeferredFsOpMkdirRecursive(ctx, op, resolve_fn, reject_fn, do_reject),
        .rmdirRecursive => runDeferredFsOpRmdirRecursive(ctx, op, resolve_fn, reject_fn, do_reject),
    }
}

fn runDeferredFsOpReadFile(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef, do_reject: *const fn (jsc.JSContextRef, jsc.JSObjectRef, std.mem.Allocator, []const u8) void) void {
    const opts = globals.current_run_options orelse return;
    const allocator = op.allocator;
    if (!opts.permissions.allow_read) {
        do_reject(ctx, reject_fn, allocator, "Shu.fs.read requires --allow-read");
        return;
    }
    const file = std.fs.openFileAbsolute(op.path, .{}) catch |e| {
        if (e == std.fs.File.OpenError.FileNotFound) {
            do_reject(ctx, reject_fn, allocator, "File not found");
            return;
        }
        do_reject(ctx, reject_fn, allocator, "read failed");
        return;
    };
    const stat = file.stat() catch {
        file.close();
        do_reject(ctx, reject_fn, allocator, "stat failed");
        return;
    };
    if (op.return_buffer and stat.size >= FS_MAP_THRESHOLD and stat.kind == .file) {
        file.close();
        var mapped = io_core.mapFileReadOnly(op.path) catch {
            const content = allocator.alloc(u8, stat.size) catch {
                do_reject(ctx, reject_fn, allocator, "out of memory");
                return;
            };
            defer allocator.free(content);
            var f = std.fs.openFileAbsolute(op.path, .{}) catch {
                do_reject(ctx, reject_fn, allocator, "read failed");
                return;
            };
            defer f.close();
            _ = f.readAll(content) catch {
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
    file.close();
    const content = allocator.alloc(u8, stat.size + 1) catch {
        do_reject(ctx, reject_fn, allocator, "out of memory");
        return;
    };
    defer allocator.free(content);
    var f = std.fs.openFileAbsolute(op.path, .{}) catch {
        do_reject(ctx, reject_fn, allocator, "read failed");
        return;
    };
    defer f.close();
    _ = f.readAll(content[0..stat.size]) catch {
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

fn runDeferredFsOpSymlink(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef, do_reject: *const fn (jsc.JSContextRef, jsc.JSObjectRef, std.mem.Allocator, []const u8) void) void {
    const opts = globals.current_run_options orelse return;
    const allocator = op.allocator;
    const path2 = op.path2 orelse return;
    if (!opts.permissions.allow_write) {
        do_reject(ctx, reject_fn, allocator, "Shu.fs.symlink requires --allow-write");
        return;
    }
    std.fs.symLinkAbsolute(op.path, path2, .{}) catch {
        do_reject(ctx, reject_fn, allocator, "symlink failed");
        return;
    };
    const empty: [0]jsc.JSValueRef = .{};
    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 0, &empty, null);
}

fn runDeferredFsOpStat(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef, do_reject: *const fn (jsc.JSContextRef, jsc.JSObjectRef, std.mem.Allocator, []const u8) void) void {
    const opts = globals.current_run_options orelse return;
    const allocator = op.allocator;
    if (!opts.permissions.allow_read) {
        do_reject(ctx, reject_fn, allocator, "Shu.fs.stat requires --allow-read");
        return;
    }
    const file = std.fs.openFileAbsolute(op.path, .{}) catch |e| {
        if (e == std.fs.File.OpenError.IsDir) {
            var dir = std.fs.openDirAbsolute(op.path, .{}) catch return;
            defer dir.close();
            const s = dir.stat() catch return;
            const mtime_ns: i64 = @intCast(@min(s.mtime, std.math.maxInt(i64)));
            const obj = makeStatObject(ctx, false, s.size, mtime_ns);
            var res_arg: [1]jsc.JSValueRef = .{obj};
            _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &res_arg, null);
            return;
        }
        do_reject(ctx, reject_fn, allocator, "stat failed");
        return;
    };
    defer file.close();
    const s = file.stat() catch {
        do_reject(ctx, reject_fn, allocator, "stat failed");
        return;
    };
    const mtime_ns: i64 = @intCast(@min(s.mtime, std.math.maxInt(i64)));
    const obj = makeStatObject(ctx, true, s.size, mtime_ns);
    var res_arg: [1]jsc.JSValueRef = .{obj};
    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &res_arg, null);
}

fn runDeferredFsOpReaddir(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef, do_reject: *const fn (jsc.JSContextRef, jsc.JSObjectRef, std.mem.Allocator, []const u8) void) void {
    const opts = globals.current_run_options orelse return;
    const allocator = op.allocator;
    if (!opts.permissions.allow_read) {
        do_reject(ctx, reject_fn, allocator, "Shu.fs.readdir requires --allow-read");
        return;
    }
    var dir = std.fs.openDirAbsolute(op.path, .{ .iterate = true }) catch {
        do_reject(ctx, reject_fn, allocator, "readdir failed");
        return;
    };
    defer dir.close();
    var buf: [512]jsc.JSValueRef = undefined;
    var count: usize = 0;
    var iter = dir.iterate();
    while (iter.next() catch {
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

fn runDeferredFsOpMkdir(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef, do_reject: *const fn (jsc.JSContextRef, jsc.JSObjectRef, std.mem.Allocator, []const u8) void) void {
    const opts = globals.current_run_options orelse return;
    const allocator = op.allocator;
    if (!opts.permissions.allow_write) {
        do_reject(ctx, reject_fn, allocator, "Shu.fs.mkdir requires --allow-write");
        return;
    }
    std.fs.makeDirAbsolute(op.path) catch {
        do_reject(ctx, reject_fn, allocator, "mkdir failed");
        return;
    };
    const empty: [0]jsc.JSValueRef = .{};
    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 0, &empty, null);
}

fn runDeferredFsOpExists(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef) void {
    _ = reject_fn;
    const opts = globals.current_run_options orelse return;
    if (!opts.permissions.allow_read) {
        var false_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeBoolean(ctx, false)};
        _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &false_arg, null);
        return;
    }
    std.fs.accessAbsolute(op.path, .{}) catch {
        var false_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeBoolean(ctx, false)};
        _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &false_arg, null);
        return;
    };
    var true_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeBoolean(ctx, true)};
    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &true_arg, null);
}

fn runDeferredFsOpUnlink(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef, do_reject: *const fn (jsc.JSContextRef, jsc.JSObjectRef, std.mem.Allocator, []const u8) void) void {
    const opts = globals.current_run_options orelse return;
    const allocator = op.allocator;
    if (!opts.permissions.allow_write) {
        do_reject(ctx, reject_fn, allocator, "Shu.fs.unlink requires --allow-write");
        return;
    }
    std.fs.deleteFileAbsolute(op.path) catch {
        do_reject(ctx, reject_fn, allocator, "unlink failed");
        return;
    };
    const empty: [0]jsc.JSValueRef = .{};
    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 0, &empty, null);
}

fn runDeferredFsOpRmdir(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef, do_reject: *const fn (jsc.JSContextRef, jsc.JSObjectRef, std.mem.Allocator, []const u8) void) void {
    const opts = globals.current_run_options orelse return;
    const allocator = op.allocator;
    if (!opts.permissions.allow_write) {
        do_reject(ctx, reject_fn, allocator, "Shu.fs.rmdir requires --allow-write");
        return;
    }
    std.fs.deleteDirAbsolute(op.path) catch {
        do_reject(ctx, reject_fn, allocator, "rmdir failed");
        return;
    };
    const empty: [0]jsc.JSValueRef = .{};
    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 0, &empty, null);
}

fn runDeferredFsOpRename(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef, do_reject: *const fn (jsc.JSContextRef, jsc.JSObjectRef, std.mem.Allocator, []const u8) void) void {
    const opts = globals.current_run_options orelse return;
    const allocator = op.allocator;
    const path2 = op.path2 orelse return;
    if (!opts.permissions.allow_read or !opts.permissions.allow_write) {
        do_reject(ctx, reject_fn, allocator, "Shu.fs.rename requires --allow-read and --allow-write");
        return;
    }
    std.fs.renameAbsolute(op.path, path2) catch {
        do_reject(ctx, reject_fn, allocator, "rename failed");
        return;
    };
    const empty: [0]jsc.JSValueRef = .{};
    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 0, &empty, null);
}

fn runDeferredFsOpCopy(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef, do_reject: *const fn (jsc.JSContextRef, jsc.JSObjectRef, std.mem.Allocator, []const u8) void) void {
    const opts = globals.current_run_options orelse return;
    const allocator = op.allocator;
    const dest = op.path2 orelse return;
    if (!opts.permissions.allow_read or !opts.permissions.allow_write) {
        do_reject(ctx, reject_fn, allocator, "Shu.fs.copy requires --allow-read and --allow-write");
        return;
    }
    const src_file = std.fs.openFileAbsolute(op.path, .{}) catch |e| {
        if (e == std.fs.File.OpenError.FileNotFound) {
            do_reject(ctx, reject_fn, allocator, "File not found");
            return;
        }
        do_reject(ctx, reject_fn, allocator, "copy open src failed");
        return;
    };
    defer src_file.close();
    const src_stat = src_file.stat() catch {
        do_reject(ctx, reject_fn, allocator, "copy stat failed");
        return;
    };
    const dest_file = std.fs.createFileAbsolute(dest, .{}) catch {
        do_reject(ctx, reject_fn, allocator, "copy create dest failed");
        return;
    };
    defer dest_file.close();
    if (src_stat.size >= FS_MAP_THRESHOLD and src_stat.kind == .file) {
        var mapped = io_core.mapFileReadOnly(op.path) catch {
            do_reject(ctx, reject_fn, allocator, "copy mmap failed");
            return;
        };
        defer mapped.deinit();
        dest_file.writeAll(mapped.slice()) catch {
            do_reject(ctx, reject_fn, allocator, "copy write failed");
            return;
        };
    } else {
        const content = src_file.readToEndAlloc(op.allocator, std.math.maxInt(usize)) catch {
            do_reject(ctx, reject_fn, allocator, "copy read failed");
            return;
        };
        defer op.allocator.free(content);
        dest_file.writeAll(content) catch {
            do_reject(ctx, reject_fn, allocator, "copy write failed");
            return;
        };
    }
    const empty: [0]jsc.JSValueRef = .{};
    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 0, &empty, null);
}

fn runDeferredFsOpAppend(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef, do_reject: *const fn (jsc.JSContextRef, jsc.JSObjectRef, std.mem.Allocator, []const u8) void) void {
    const opts = globals.current_run_options orelse return;
    const allocator = op.allocator;
    const content = op.content orelse return;
    if (!opts.permissions.allow_write) {
        do_reject(ctx, reject_fn, allocator, "Shu.fs.append requires --allow-write");
        return;
    }
    const file = std.fs.openFileAbsolute(op.path, .{ .mode = .read_write }) catch {
        do_reject(ctx, reject_fn, allocator, "append open failed");
        return;
    };
    defer file.close();
    file.seekFromEnd(0) catch {
        do_reject(ctx, reject_fn, allocator, "append seek failed");
        return;
    };
    file.writeAll(content) catch {
        do_reject(ctx, reject_fn, allocator, "append write failed");
        return;
    };
    const empty: [0]jsc.JSValueRef = .{};
    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 0, &empty, null);
}

fn runDeferredFsOpWrite(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef, do_reject: *const fn (jsc.JSContextRef, jsc.JSObjectRef, std.mem.Allocator, []const u8) void) void {
    const opts = globals.current_run_options orelse return;
    const allocator = op.allocator;
    const content = op.content orelse return;
    if (!opts.permissions.allow_write) {
        do_reject(ctx, reject_fn, allocator, "Shu.fs.write requires --allow-write");
        return;
    }
    const file = std.fs.createFileAbsolute(op.path, .{}) catch {
        do_reject(ctx, reject_fn, allocator, "write create failed");
        return;
    };
    defer file.close();
    file.writeAll(content) catch {
        do_reject(ctx, reject_fn, allocator, "write failed");
        return;
    };
    const empty: [0]jsc.JSValueRef = .{};
    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 0, &empty, null);
}

fn runDeferredFsOpReadlink(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef, do_reject: *const fn (jsc.JSContextRef, jsc.JSObjectRef, std.mem.Allocator, []const u8) void) void {
    const opts = globals.current_run_options orelse return;
    const allocator = op.allocator;
    if (!opts.permissions.allow_read) {
        do_reject(ctx, reject_fn, allocator, "Shu.fs.readlink requires --allow-read");
        return;
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = std.fs.readLinkAbsolute(op.path, &buf) catch {
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

fn runDeferredFsOpMkdirRecursive(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef, do_reject: *const fn (jsc.JSContextRef, jsc.JSObjectRef, std.mem.Allocator, []const u8) void) void {
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

/// 递归删除目录（仅 Zig 内部使用）；失败时返回 error，由调用方 reject
fn deleteDirRecursiveAbsolute(allocator: std.mem.Allocator, path: []const u8) !void {
    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch return error.OpenFailed;
    defer dir.close();
    var iter = dir.iterate();
    while (iter.next() catch return error.IterateFailed) |entry| {
        const full = std.fs.path.join(allocator, &.{ path, entry.name }) catch return error.OutOfMemory;
        defer allocator.free(full);
        var d = std.fs.openDirAbsolute(full, .{ .iterate = true }) catch {
            std.fs.deleteFileAbsolute(full) catch {};
            continue;
        };
        d.close();
        try deleteDirRecursiveAbsolute(allocator, full);
    }
    std.fs.deleteDirAbsolute(path) catch return error.DeleteFailed;
}

fn runDeferredFsOpRmdirRecursive(ctx: jsc.JSContextRef, op: *const DeferredFsOp, resolve_fn: jsc.JSObjectRef, reject_fn: jsc.JSObjectRef, do_reject: *const fn (jsc.JSContextRef, jsc.JSObjectRef, std.mem.Allocator, []const u8) void) void {
    const opts = globals.current_run_options orelse return;
    const allocator = op.allocator;
    if (!opts.permissions.allow_write) {
        do_reject(ctx, reject_fn, allocator, "Shu.fs.rmdirRecursive requires --allow-write");
        return;
    }
    deleteDirRecursiveAbsolute(op.allocator, op.path) catch {
        do_reject(ctx, reject_fn, allocator, "rmdirRecursive failed");
        return;
    };
    const empty: [0]jsc.JSValueRef = .{};
    _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 0, &empty, null);
}

/// 每轮事件循环调用：收割 AsyncFileIO 完成项并处理延迟 fs 队列（纯 Zig，无内联 JS）
pub fn drainFileIOCompletions(ctx: jsc.JSContextRef) void {
    const fio = globals.current_async_file_io orelse return;
    const state = fs_async_state orelse return;
    const comps = fio.pollCompletions(0);
    for (comps) |*c| {
        if (c.tag != .file_read and c.tag != .file_write) continue;
        const entry = state.pending.fetchRemove(c.user_data) orelse continue;
        const e = entry.value;
        const file_err = c.file_err;
        jsc.JSValueUnprotect(ctx, e.resolve);
        jsc.JSValueUnprotect(ctx, e.reject);
        defer e.file.close();
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

/// 核心逻辑：用已解析路径提交一次异步读，resolve/reject 由 drain 或本函数内同步 resolve（空文件等）时调用；不检查权限（由调用方在构造 Promise 前完成）
fn doSubmitRead(
    ctx: jsc.JSContextRef,
    resolved: []const u8,
    return_buffer: bool,
    resolve_fn: jsc.JSValueRef,
    reject_fn: jsc.JSValueRef,
) void {
    const allocator = globals.current_allocator orelse return;
    var file = std.fs.openFileAbsolute(resolved, .{}) catch |e| {
        if (e == std.fs.File.OpenError.FileNotFound) {
            const msg = std.fmt.allocPrint(allocator, "File not found: {s}", .{resolved}) catch resolved;
            errors.reportToStderr(.{ .code = .file_not_found, .message = msg }) catch {};
            if (msg.ptr != resolved.ptr) allocator.free(msg);
        }
        return;
    };
    const stat = file.stat() catch {
        file.close();
        return;
    };
    const size = @min(stat.size, ASYNC_READ_MAX_BYTES);
    if (size == 0) {
        file.close();
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
        file.close();
        return;
    };
    const buffer = state.allocator.alloc(u8, size) catch {
        file.close();
        return;
    };
    const user_data = state.next_id;
    state.next_id +%= 1;
    state.async_file_io.submitReadFile(file.handle, buffer.ptr, buffer.len, 0, user_data) catch |e| {
        state.allocator.free(buffer);
        file.close();
        const err_ref = jsc.JSStringCreateWithUTF8CString(@errorName(e).ptr);
        defer jsc.JSStringRelease(err_ref);
        var err_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeString(ctx, err_ref)};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(jsc.JSValueToObject(ctx, reject_fn, null)), null, 1, &err_arg, null);
        return;
    };
    jsc.JSValueProtect(ctx, resolve_fn);
    jsc.JSValueProtect(ctx, reject_fn);
    state.pending.put(user_data, .{
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
        file.close();
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
    var file = std.fs.createFileAbsolute(resolved, .{}) catch {
        allocator.free(content);
        return;
    };
    var state = ensureAsyncFileIO() catch {
        file.close();
        allocator.free(content);
        return;
    };
    const user_data = state.next_id;
    state.next_id +%= 1;
    state.async_file_io.submitWriteFile(file.handle, content.ptr, content.len, 0, user_data) catch |e| {
        file.close();
        allocator.free(content);
        const err_ref = jsc.JSStringCreateWithUTF8CString(@errorName(e).ptr);
        defer jsc.JSStringRelease(err_ref);
        var err_arg: [1]jsc.JSValueRef = .{jsc.JSValueMakeString(ctx, err_ref)};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(jsc.JSValueToObject(ctx, reject_fn, null)), null, 1, &err_arg, null);
        return;
    };
    jsc.JSValueProtect(ctx, resolve_fn);
    jsc.JSValueProtect(ctx, reject_fn);
    state.pending.put(user_data, .{
        .resolve = resolve_fn,
        .reject = reject_fn,
        .file = file,
        .allocator = state.allocator,
        .kind = .write,
        .write_data = content,
    }) catch {
        jsc.JSValueUnprotect(ctx, resolve_fn);
        jsc.JSValueUnprotect(ctx, reject_fn);
        file.close();
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

/// 向 shu_obj 上注册 Shu.fs 子对象（委托 getExports），与 node:fs/deno:fs 命名统一；并注册内部 __fsSubmitRead/__fsSubmitWrite 供异步 read/write 使用
pub fn register(ctx: jsc.JSGlobalContextRef, shu_obj: jsc.JSObjectRef) void {
    const allocator = globals.current_allocator orelse return;
    const name_fs = jsc.JSStringCreateWithUTF8CString("fs");
    defer jsc.JSStringRelease(name_fs);
    _ = jsc.JSObjectSetProperty(ctx, shu_obj, name_fs, getExports(ctx, allocator), jsc.kJSPropertyAttributeNone, null);
    common.setMethod(ctx, shu_obj, "__fsSubmitRead", fsSubmitReadCallback);
    common.setMethod(ctx, shu_obj, "__fsSubmitWrite", fsSubmitWriteCallback);
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
    const resolved = std.fs.path.resolve(allocator, &.{ cwd, path }) catch {
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

/// read/write 在内存不足等 fallback 时仍用脚本创建 Promise（仅此二处）；其余异步 fs 一律走 createDeferredFsPromise 纯 Zig
fn makeDeferredPromiseOne(ctx: jsc.JSContextRef, allocator: std.mem.Allocator, syncMethod: []const u8, path_json: []const u8) jsc.JSValueRef {
    var script: [4096]u8 = undefined;
    const written = std.fmt.bufPrint(&script, "(function(){{ var p = {s}; return new Promise(function(resolve,reject){{ setTimeout(function(){{ try {{ resolve(Shu.fs.{s}(p)); }} catch(e) {{ reject(e); }} }}, 0); }}); }})();", .{ path_json, syncMethod }) catch return jsc.JSValueMakeUndefined(ctx);
    _ = allocator;
    return common.evalPromiseScript(ctx, written);
}
fn makeDeferredPromiseTwo(ctx: jsc.JSContextRef, allocator: std.mem.Allocator, syncMethod: []const u8, a_json: []const u8, b_json: []const u8) jsc.JSValueRef {
    var script: [8192]u8 = undefined;
    const written = std.fmt.bufPrint(&script, "(function(){{ var a = {s}, b = {s}; return new Promise(function(resolve,reject){{ setTimeout(function(){{ try {{ Shu.fs.{s}(a, b); resolve(); }} catch(e) {{ reject(e); }} }}, 0); }}); }})();", .{ a_json, b_json, syncMethod }) catch return jsc.JSValueMakeUndefined(ctx);
    _ = allocator;
    return common.evalPromiseScript(ctx, written);
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
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_promise = jsc.JSStringCreateWithUTF8CString("Promise");
    defer jsc.JSStringRelease(k_promise);
    const promise_val = jsc.JSObjectGetProperty(ctx, global, k_promise, null);
    const promise_ctor = jsc.JSValueToObject(ctx, promise_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const k_exec = jsc.JSStringCreateWithUTF8CString("executor");
    defer jsc.JSStringRelease(k_exec);
    const executor_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_exec, deferredFsExecutor);
    var one: [1]jsc.JSValueRef = .{executor_fn};
    return jsc.JSObjectCallAsConstructor(ctx, promise_ctor, 1, &one, null);
}

// ---------- 同步回调 ----------

/// 从 options 对象读取 encoding：'utf8' 或未传则返回 string，null/'buffer' 则返回 Buffer（零拷贝）；大文件且 encoding 为 null 时用 io_core.mapFileReadOnly
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
    const file = std.fs.openFileAbsolute(resolved, .{}) catch |e| {
        if (e == std.fs.File.OpenError.FileNotFound) {
            const msg = std.fmt.allocPrint(allocator, "File not found: {s}", .{resolved}) catch resolved;
            errors.reportToStderr(.{ .code = .file_not_found, .message = msg }) catch {};
            if (msg.ptr != resolved.ptr) allocator.free(msg);
        }
        return jsc.JSValueMakeUndefined(ctx);
    };
    const stat = file.stat() catch {
        file.close();
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
        const enc = buf[0 .. if (n > 0) n - 1 else 0];
        if (std.mem.eql(u8, enc, "buffer") or std.mem.eql(u8, enc, "binary") or enc.len == 0) break :blk true;
        break :blk false;
    };
    // 大文件且返回 Buffer 时走 io_core.mapFileReadOnly，减少整文件读入与 OOM
    if (return_buffer and stat.size >= FS_MAP_THRESHOLD and stat.kind == .file) {
        file.close();
        var mapped = io_core.mapFileReadOnly(resolved) catch {
            var fallback_file = std.fs.openFileAbsolute(resolved, .{}) catch return jsc.JSValueMakeUndefined(ctx);
            defer fallback_file.close();
            const content = fallback_file.readToEndAlloc(allocator, std.math.maxInt(usize)) catch return jsc.JSValueMakeUndefined(ctx);
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
    const content = file.readToEndAlloc(allocator, std.math.maxInt(usize)) catch {
        file.close();
        return jsc.JSValueMakeUndefined(ctx);
    };
    defer file.close();
    if (return_buffer) {
        var dc = allocator.create(FileBufferDeallocContext) catch {
            allocator.free(content);
            return jsc.JSValueMakeUndefined(ctx);
        };
        dc.allocator = allocator;
        dc.slice = content;
        var exc: ?jsc.JSValueRef = null;
        const out = jsc.JSObjectMakeTypedArrayWithBytesNoCopy(
            ctx,
            .Uint8Array,
            content.ptr,
            content.len,
            fileBufferDeallocator,
            dc,
            @ptrCast(&exc),
        );
        if (out == null) {
            allocator.free(content);
            allocator.destroy(dc);
            if (exc) |e| exception[0] = e;
            return jsc.JSValueMakeUndefined(ctx);
        }
        return out.?;
    }
    defer allocator.free(content);
    const content_z = allocator.dupeZ(u8, content) catch return jsc.JSValueMakeUndefined(ctx);
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
    const file = std.fs.createFileAbsolute(resolved, .{}) catch return jsc.JSValueMakeUndefined(ctx);
    defer file.close();
    file.writeAll(content) catch return jsc.JSValueMakeUndefined(ctx);
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
    var dir = std.fs.openDirAbsolute(resolved, .{ .iterate = true }) catch return jsc.JSValueMakeUndefined(ctx);
    defer dir.close();
    var buf: [512]jsc.JSValueRef = undefined;
    var count: usize = 0;
    var iter = dir.iterate();
    while (iter.next() catch return jsc.JSValueMakeUndefined(ctx)) |entry| {
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
    std.fs.makeDirAbsolute(resolved) catch return jsc.JSValueMakeUndefined(ctx);
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
    std.fs.accessAbsolute(resolved, .{}) catch return jsc.JSValueMakeBoolean(ctx, false);
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
    const file = std.fs.openFileAbsolute(resolved, .{}) catch |e| {
        if (e == std.fs.File.OpenError.IsDir) {
            var dir = std.fs.openDirAbsolute(resolved, .{}) catch return jsc.JSValueMakeUndefined(ctx);
            defer dir.close();
            const s = dir.stat() catch return jsc.JSValueMakeUndefined(ctx);
            const mtime_ns: i64 = @intCast(@min(s.mtime, std.math.maxInt(i64)));
            return makeStatObject(ctx, false, s.size, mtime_ns);
        }
        return jsc.JSValueMakeUndefined(ctx);
    };
    defer file.close();
    const s = file.stat() catch return jsc.JSValueMakeUndefined(ctx);
    const mtime_ns: i64 = @intCast(@min(s.mtime, std.math.maxInt(i64)));
    return makeStatObject(ctx, true, s.size, mtime_ns);
}

/// 解析符号链接与 . / .. 得到规范绝对路径；realpathSync(path)，需要 --allow-read
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
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const canonical = std.fs.realpath(resolved, &buf) catch return jsc.JSValueMakeUndefined(ctx);
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
    const dir_path = std.fs.path.dirname(resolved) orelse ".";
    const base = std.fs.path.basename(resolved);
    var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return jsc.JSValueMakeUndefined(ctx);
    defer dir.close();
    const s = if (base.len == 0)
        dir.stat() catch return jsc.JSValueMakeUndefined(ctx)
    else
        dir.statFile(base) catch return jsc.JSValueMakeUndefined(ctx);
    const is_file = (s.kind == .file);
    const is_dir = (s.kind == .directory);
    const is_sym = (s.kind == .sym_link);
    const mtime_ns: i64 = @intCast(@min(s.mtime, std.math.maxInt(i64)));
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
    const file = std.fs.openFileAbsolute(resolved, .{ .mode = .read_write }) catch return jsc.JSValueMakeUndefined(ctx);
    defer file.close();
    std.posix.ftruncate(file.handle, len) catch return jsc.JSValueMakeUndefined(ctx);
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
    var flags: std.fs.File.OpenFlags = .{};
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
    std.fs.accessAbsolute(resolved, flags) catch return jsc.JSValueMakeBoolean(ctx, false);
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
    var dir = std.fs.openDirAbsolute(resolved, .{ .iterate = true }) catch return jsc.JSValueMakeBoolean(ctx, false);
    defer dir.close();
    var iter = dir.iterate();
    var has_any = false;
    while (iter.next() catch return jsc.JSValueMakeBoolean(ctx, false)) |_| {
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
    const file = std.fs.openFileAbsolute(resolved, .{}) catch |e| {
        if (e == std.fs.File.OpenError.IsDir) {
            return jsc.JSValueMakeNumber(ctx, 0);
        }
        return jsc.JSValueMakeUndefined(ctx);
    };
    defer file.close();
    const s = file.stat() catch return jsc.JSValueMakeUndefined(ctx);
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
    const file = std.fs.openFileAbsolute(resolved, .{}) catch return jsc.JSValueMakeBoolean(ctx, false);
    defer file.close();
    const s = file.stat() catch return jsc.JSValueMakeBoolean(ctx, false);
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
    var dir = std.fs.openDirAbsolute(resolved, .{}) catch return jsc.JSValueMakeBoolean(ctx, false);
    defer dir.close();
    _ = dir.stat() catch return jsc.JSValueMakeBoolean(ctx, false);
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
    var dir = std.fs.openDirAbsolute(resolved, .{ .iterate = true }) catch return jsc.JSValueMakeUndefined(ctx);
    defer dir.close();
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
    while (iter.next() catch return jsc.JSValueMakeUndefined(ctx)) |entry| {
        if (count >= buf.len) break;
        const s = dir.statFile(entry.name) catch continue;
        const is_file = (s.kind == .file);
        const is_dir = (s.kind == .directory);
        const is_sym = (s.kind == .sym_link);
        const mtime_ns: i64 = @intCast(@min(s.mtime, std.math.maxInt(i64)));
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
    const file = std.fs.openFileAbsolute(resolved, .{}) catch |e| {
        if (e == std.fs.File.OpenError.FileNotFound) {
            const parent = std.fs.path.dirname(resolved) orelse return jsc.JSValueMakeUndefined(ctx);
            if (parent.len > 0 and parent.len < resolved.len) {
                makeDirRecursiveAbsolute(allocator, parent);
            }
            var f = std.fs.createFileAbsolute(resolved, .{}) catch return jsc.JSValueMakeUndefined(ctx);
            f.close();
            return jsc.JSValueMakeUndefined(ctx);
        }
        if (e == std.fs.File.OpenError.IsDir) {
            errors.reportToStderr(.{ .code = .file_not_found, .message = "Shu.fs.ensureFile: path is a directory" }) catch {};
        }
        return jsc.JSValueMakeUndefined(ctx);
    };
    file.close();
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
    std.fs.deleteFileAbsolute(resolved) catch return jsc.JSValueMakeUndefined(ctx);
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
    std.fs.deleteDirAbsolute(resolved) catch return jsc.JSValueMakeUndefined(ctx);
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
    std.fs.renameAbsolute(old_resolved, new_resolved) catch return jsc.JSValueMakeUndefined(ctx);
    return jsc.JSValueMakeUndefined(ctx);
}

/// 同步复制文件：copySync(srcPath, destPath)，需要源可读、目标可写；大文件走 io_core.mapFileReadOnly 减少拷贝与 OOM
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
    const src_file = std.fs.openFileAbsolute(src_resolved, .{}) catch |e| {
        if (e == std.fs.File.OpenError.FileNotFound) {
            const msg = std.fmt.allocPrint(allocator, "File not found: {s}", .{src_resolved}) catch src_resolved;
            errors.reportToStderr(.{ .code = .file_not_found, .message = msg }) catch {};
            if (msg.ptr != src_resolved.ptr) allocator.free(msg);
        }
        return jsc.JSValueMakeUndefined(ctx);
    };
    const src_stat = src_file.stat() catch {
        src_file.close();
        return jsc.JSValueMakeUndefined(ctx);
    };
    if (src_stat.size >= FS_MAP_THRESHOLD and src_stat.kind == .file) {
        src_file.close();
        var mapped = io_core.mapFileReadOnly(src_resolved) catch {
            var fallback_src = std.fs.openFileAbsolute(src_resolved, .{}) catch return jsc.JSValueMakeUndefined(ctx);
            defer fallback_src.close();
            const content = fallback_src.readToEndAlloc(allocator, std.math.maxInt(usize)) catch return jsc.JSValueMakeUndefined(ctx);
            defer allocator.free(content);
            const dest_file = std.fs.createFileAbsolute(dest_resolved, .{}) catch return jsc.JSValueMakeUndefined(ctx);
            defer dest_file.close();
            dest_file.writeAll(content) catch return jsc.JSValueMakeUndefined(ctx);
            return jsc.JSValueMakeUndefined(ctx);
        };
        defer mapped.deinit();
        const dest_file = std.fs.createFileAbsolute(dest_resolved, .{}) catch return jsc.JSValueMakeUndefined(ctx);
        defer dest_file.close();
        dest_file.writeAll(mapped.slice()) catch return jsc.JSValueMakeUndefined(ctx);
        return jsc.JSValueMakeUndefined(ctx);
    }
    src_file.close();
    // §3.1/§5 小文件用 std.fs.copyFileAbsolute，由内核 copy_file_range/sendfile 等实现，避免 readToEndAlloc+writeAll 用户态拷贝
    std.fs.copyFileAbsolute(src_resolved, dest_resolved, .{}) catch return jsc.JSValueMakeUndefined(ctx);
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
    var file = std.fs.openFileAbsolute(resolved, .{ .mode = .write_only }) catch |e| {
        if (e == std.fs.File.OpenError.FileNotFound) {
            var new_file = std.fs.createFileAbsolute(resolved, .{}) catch return jsc.JSValueMakeUndefined(ctx);
            defer new_file.close();
            new_file.writeAll(content) catch return jsc.JSValueMakeUndefined(ctx);
            return jsc.JSValueMakeUndefined(ctx);
        }
        return jsc.JSValueMakeUndefined(ctx);
    };
    defer file.close();
    const end_pos = file.getEndPos() catch return jsc.JSValueMakeUndefined(ctx);
    file.seekTo(end_pos) catch return jsc.JSValueMakeUndefined(ctx);
    file.writeAll(content) catch return jsc.JSValueMakeUndefined(ctx);
    return jsc.JSValueMakeUndefined(ctx);
}

/// 递归创建目录（mkdir -p）：先创建父目录再创建当前路径
fn makeDirRecursiveAbsolute(allocator: std.mem.Allocator, absolute_path: []const u8) void {
    std.fs.makeDirAbsolute(absolute_path) catch |e| {
        switch (e) {
            error.PathAlreadyExists => return,
            else => {
                const parent = std.fs.path.dirname(absolute_path) orelse return;
                if (parent.len == 0 or parent.len >= absolute_path.len) return;
                makeDirRecursiveAbsolute(allocator, parent);
                std.fs.makeDirAbsolute(absolute_path) catch return;
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
    std.fs.symLinkAbsolute(target_resolved, link_resolved, .{}) catch return jsc.JSValueMakeUndefined(ctx);
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
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = std.fs.readLinkAbsolute(resolved, &buf) catch return jsc.JSValueMakeUndefined(ctx);
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
    std.fs.deleteTreeAbsolute(resolved) catch return jsc.JSValueMakeUndefined(ctx);
    return jsc.JSValueMakeUndefined(ctx);
}

// ---------- 异步回调 ----------

/// Shu.fs.read(path [, options])：异步读文件，走 io_core.AsyncFileIO；Zig 侧直接 new Promise(executor) 无脚本解析；options.encoding 为 null/'buffer' 时返回 Buffer，否则 UTF-8 字符串；失败时回退 setTimeout+readSync
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
        if (std.mem.eql(u8, enc, "buffer") or std.mem.eql(u8, enc, "binary") or enc.len == 0) break :blk true;
        break :blk false;
    };
    const resolved_owned = allocator.dupe(u8, resolved) catch {
        const path_json = jsonEscapeString(allocator, path) orelse return jsc.JSValueMakeUndefined(ctx);
        defer allocator.free(path_json);
        return makeDeferredPromiseOne(ctx, allocator, "readSync", path_json);
    };
    fs_read_promise_args = .{ .resolved = resolved_owned, .return_buffer = return_buffer };
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_promise = jsc.JSStringCreateWithUTF8CString("Promise");
    defer jsc.JSStringRelease(k_promise);
    const promise_val = jsc.JSObjectGetProperty(ctx, global, k_promise, null);
    const promise_ctor = jsc.JSValueToObject(ctx, promise_val, null) orelse {
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
    return jsc.JSObjectCallAsConstructor(ctx, promise_ctor, 1, &executor_arg, null);
}

/// Shu.fs.write(path, content)：异步写文件，走 io_core.AsyncFileIO；Zig 侧直接 new Promise(executor) 无脚本解析；init 失败或 content 超 512KB 时回退 setTimeout+writeSync
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
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_promise = jsc.JSStringCreateWithUTF8CString("Promise");
    defer jsc.JSStringRelease(k_promise);
    const promise_val = jsc.JSObjectGetProperty(ctx, global, k_promise, null);
    const promise_ctor = jsc.JSValueToObject(ctx, promise_val, null) orelse {
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
    const result = jsc.JSObjectCallAsConstructor(ctx, promise_ctor, 1, &one, null);
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
