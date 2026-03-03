//! io_core 统一文件/目录 API（file.zig）
//!
//! 职责
//!   - 同步文件/目录操作：openFileAbsolute、openDirAbsolute、realpath、makeDirAbsolute、
//!     deleteFileAbsolute、deleteDirAbsolute、renameAbsolute、accessAbsolute、createFileAbsolute、
//!     readLinkAbsolute、symLinkAbsolute；路径字符串：pathDirname、pathBasename、pathJoin、pathResolve、
//!     pathRelative、pathExtension、pathIsAbsolute；当前为 std.fs 薄封装，供 fs 等调用，后续可按平台特化。
//!   - 异步文件 I/O（AsyncFileIO）：Linux/Darwin/Windows 三种实现均在本模块内（Linux 独立 io_uring，Darwin/Windows 工作线程 + pread/pwrite 或 ReadFile/WriteFile），按 builtin.os.tag 统一导出。
//!
//! 规范对应（§3.0）：所有文件/目录 I/O 经 io_core，fs 逐步从 std.fs 迁至本模块。

const std = @import("std");
const builtin = @import("builtin");
const api = @import("api.zig");
const libs_process = @import("libs_process");

// 类型再导出：Zig 0.16 使用 std.Io.Dir/File，调用方仅依赖 io_core 即可
pub const File = std.Io.File;
pub const Dir = std.Io.Dir;
pub const FileOpenFlags = std.Io.File.OpenFlags;
pub const FileCreateFlags = std.Io.File.CreateFlags;
pub const DirOpenOptions = std.Io.Dir.OpenOptions;
pub const DirSymLinkFlags = std.Io.Dir.SymLinkFlags;
pub const DirCopyFileOptions = std.Io.Dir.CopyFileOptions;
pub const FileOpenError = std.Io.File.OpenError;

// -----------------------------------------------------------------------------
// 同步文件/目录 API（当前 std.fs 薄封装，跨平台一致）
// -----------------------------------------------------------------------------

/// 打开绝对路径文件；调用方负责 close。Zig 0.16 使用 std.Io。
pub fn openFileAbsolute(path: []const u8, flags: std.Io.File.OpenFlags) !std.Io.File {
    const io = libs_process.getProcessIo() orelse return error.ProcessIoNotSet;
    return std.Io.Dir.openFileAbsolute(io, path, flags);
}

/// 创建绝对路径文件；调用方负责 close。Zig 0.16 使用 std.Io。
pub fn createFileAbsolute(path: []const u8, flags: std.Io.File.CreateFlags) !std.Io.File {
    const io = libs_process.getProcessIo() orelse return error.ProcessIoNotSet;
    return std.Io.Dir.createFileAbsolute(io, path, flags);
}

/// 以 O_DIRECT 打开绝对路径文件（仅 Linux），绕过内核页缓存，数据直通磁盘（DMA）；调用方负责 close。
/// 要求：读写缓冲区地址与长度须按扇区大小（通常 512 或 4096）对齐，否则 EINVAL。非 Linux 返回 error.Unsupported。
pub fn openFileAbsoluteDirect(path: []const u8, read_only: bool) !std.fs.File {
    if (builtin.os.tag != .linux) return error.Unsupported;
    const posix = std.posix;
    if (path.len >= max_path_bytes) return error.NameTooLong;
    var path_z: [max_path_bytes]u8 = undefined;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    const o_flags: u32 = if (read_only)
        posix.O.RDONLY | posix.O.DIRECT
    else
        posix.O.RDWR | posix.O.DIRECT;
    const fd = posix.openat(posix.AT.FDCWD, path_z[0..path.len :0].ptr, o_flags, 0o644) catch return error.FileNotFound;
    return std.Io.File{ .handle = fd };
}

/// 打开绝对路径目录；调用方负责 close。Zig 0.16 使用 std.Io.Dir，需 process io。
pub fn openDirAbsolute(path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    const io = libs_process.getProcessIo() orelse return error.ProcessIoNotSet;
    return std.Io.Dir.openDirAbsolute(io, path, options);
}

/// 以当前工作目录为基准打开相对路径目录；调用方负责 close。Zig 0.16 使用 std.Io.Dir。
pub fn openDirCwd(relative_path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    const io = libs_process.getProcessIo() orelse return error.ProcessIoNotSet;
    return std.Io.Dir.cwd().openDir(io, relative_path, options);
}

/// 解析路径为规范绝对路径，写入 buffer，返回有效切片。Zig 0.16：std.fs 已迁至 std.Io.Dir，路径长度用 Io.Dir.max_path_bytes。
pub fn realpath(path: []const u8, buffer: *[std.Io.Dir.max_path_bytes]u8) ![]const u8 {
    if (path.len >= max_path_bytes) return error.NameTooLong;
    var path_z: [max_path_bytes]u8 = undefined;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    const result = std.c.realpath(path_z[0..path.len :0].ptr, buffer.ptr);
    if (result == null) return error.RealPathFailed; // C realpath 失败，errno 未透传
    const len = std.mem.len(result.?);
    if (len > buffer.len) return error.NameTooLong;
    return buffer[0..len];
}

/// 单层创建目录。Zig 0.16 使用 std.Io.Dir，permissions 用默认。
pub fn makeDirAbsolute(path: []const u8) !void {
    const io = libs_process.getProcessIo() orelse return error.ProcessIoNotSet;
    try std.Io.Dir.createDirAbsolute(io, path, .default_dir);
}

/// 递归创建目录及所有父目录；路径须为绝对路径。已存在则忽略，其他错误则返回。
pub fn makePathAbsolute(path: []const u8) !void {
    if (path.len == 0) return;
    const parent = pathDirname(path);
    if (parent) |p| {
        if (p.len < path.len and p.len > 0 and !std.mem.eql(u8, p, path)) {
            makePathAbsolute(p) catch |e| if (e != error.PathAlreadyExists) return e;
        }
    }
    makeDirAbsolute(path) catch |e| if (e != error.PathAlreadyExists) return e;
}

/// 删除文件。Zig 0.16 使用 std.Io.Dir。
pub fn deleteFileAbsolute(path: []const u8) !void {
    const io = libs_process.getProcessIo() orelse return error.ProcessIoNotSet;
    try std.Io.Dir.cwd().deleteFile(io, path);
}

/// 删除空目录。Zig 0.16 使用 std.Io.Dir。
pub fn deleteDirAbsolute(path: []const u8) !void {
    const io = libs_process.getProcessIo() orelse return error.ProcessIoNotSet;
    try std.Io.Dir.cwd().deleteDir(io, path);
}

/// 重命名/移动。Zig 0.16 使用 std.Io.Dir。
pub fn renameAbsolute(old_path: []const u8, new_path: []const u8) !void {
    const io = libs_process.getProcessIo() orelse return error.ProcessIoNotSet;
    const cwd = std.Io.Dir.cwd();
    try cwd.rename(old_path, cwd, new_path, io);
}

/// 检查路径可访问性。Zig 0.16 使用 std.Io.Dir.AccessOptions。
pub fn accessAbsolute(path: []const u8, flags: std.Io.File.OpenFlags) !void {
    const io = libs_process.getProcessIo() orelse return error.ProcessIoNotSet;
    _ = flags;
    try std.Io.Dir.accessAbsolute(io, path, .{ .read = true });
}

/// 读符号链接目标路径，写入 buffer，返回有效切片。Zig 0.16 使用 std.Io.Dir。
pub fn readLinkAbsolute(path: []const u8, buffer: *[max_path_bytes]u8) ![]u8 {
    const io = libs_process.getProcessIo() orelse return error.ProcessIoNotSet;
    const n = try std.Io.Dir.readLinkAbsolute(io, path, buffer);
    return buffer[0..n];
}

/// 创建符号链接；flags 为 Dir.SymLinkFlags。Zig 0.16 使用 std.Io.Dir。
pub fn symLinkAbsolute(target_path: []const u8, link_path: []const u8, flags: std.Io.Dir.SymLinkFlags) !void {
    const io = libs_process.getProcessIo() orelse return error.ProcessIoNotSet;
    try std.Io.Dir.cwd().symLink(io, target_path, link_path, flags);
}

/// 与 std.Io.Dir.max_path_bytes 一致，用于 readLinkAbsolute/realpath 等缓冲区大小。
pub const max_path_bytes = std.Io.Dir.max_path_bytes;

/// 复制文件。Zig 0.16 使用 std.Io.Dir。
pub fn copyFileAbsolute(source_path: []const u8, dest_path: []const u8, options: std.Io.Dir.CopyFileOptions) !void {
    const io = libs_process.getProcessIo() orelse return error.ProcessIoNotSet;
    try std.Io.Dir.copyFileAbsolute(source_path, dest_path, io, options);
}

/// 递归删除目录及内容。Zig 0.16 使用 std.Io.Dir；walker 需 allocator，调用方传入。
pub fn deleteTreeAbsolute(allocator: std.mem.Allocator, absolute_path: []const u8) !void {
    const io = libs_process.getProcessIo() orelse return error.ProcessIoNotSet;
    var dir = try std.Io.Dir.openDirAbsolute(io, absolute_path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .file => try entry.dir.deleteFile(io, entry.basename),
            .directory => {
                var sub = try entry.dir.openDir(io, entry.basename, .{ .iterate = true });
                defer sub.close(io);
                try deleteTreeAbsoluteFromDir(allocator, io, &sub);
                try entry.dir.deleteDir(io, entry.basename);
            },
            else => {},
        }
    }
}
fn deleteTreeAbsoluteFromDir(allocator: std.mem.Allocator, io: std.Io, dir: *std.Io.Dir) !void {
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .file => try entry.dir.deleteFile(io, entry.basename),
            .directory => {
                var sub = try entry.dir.openDir(io, entry.basename, .{ .iterate = true });
                defer sub.close(io);
                try deleteTreeAbsoluteFromDir(allocator, io, &sub);
                try entry.dir.deleteDir(io, entry.basename);
            },
            else => {},
        }
    }
}

// -----------------------------------------------------------------------------
// 路径字符串解析（path.* 薄封装，无 I/O；统一从 io_core 调用以符合 §3.0）
// -----------------------------------------------------------------------------

/// 路径所在目录部分，无则返回 "."；与 std.fs.path.dirname 语义一致。
pub fn pathDirname(path: []const u8) ?[]const u8 {
    return std.fs.path.dirname(path);
}

/// 路径最后一段（文件名或目录名）；与 std.fs.path.basename 语义一致。
pub fn pathBasename(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

/// 路径扩展名（含点）；与 std.fs.path.extension 语义一致。
pub fn pathExtension(path: []const u8) []const u8 {
    return std.fs.path.extension(path);
}

/// 是否绝对路径；与 std.fs.path.isAbsolute 语义一致。
pub fn pathIsAbsolute(path: []const u8) bool {
    return std.fs.path.isAbsolute(path);
}

/// 将多段路径用分隔符连接；返回切片由调用方 free。与 std.fs.path.join 语义一致。
pub fn pathJoin(allocator: std.mem.Allocator, paths: []const []const u8) ![]const u8 {
    return std.fs.path.join(allocator, paths);
}

/// 解析为绝对路径；返回切片由调用方 free。与 std.fs.path.resolve 语义一致。
pub fn pathResolve(allocator: std.mem.Allocator, paths: []const []const u8) ![]const u8 {
    return std.fs.path.resolve(allocator, paths);
}

/// 计算 from 到 to 的相对路径；返回切片由调用方 free。与 std.fs.path.relative 语义一致。
pub fn pathRelative(allocator: std.mem.Allocator, from: []const u8, to: []const u8) ![]const u8 {
    return std.fs.path.relative(allocator, from, to);
}

// -----------------------------------------------------------------------------
// Stream Reader 辅助（std.Io.Reader 分块读取，供 HTTP 解压流等使用，避免 allocRemaining 触发 Writer.rebase）
// -----------------------------------------------------------------------------

/// 从 reader 读取最多 max_bytes 到新分配切片；内部用 std.Io.Reader.readVec 分块读，避免 gzip 等解压流触发 Writer.rebase（allocRemaining 会 unreachable）。
/// 若实际长度超过 max_bytes 返回 error.ResponseTooLarge。调用方 free 返回的切片。
pub fn readReaderUpTo(allocator: std.mem.Allocator, reader: *std.Io.Reader, max_bytes: usize) ![]const u8 {
    var list = std.ArrayList(u8).initCapacity(allocator, @min(65536, max_bytes)) catch return error.OutOfMemory;
    defer list.deinit(allocator);
    var buf: [8192]u8 = undefined;
    var total: usize = 0;
    while (total < max_bytes) {
        const to_read = @min(buf.len, max_bytes - total);
        var vec: [1][]u8 = .{buf[0..to_read]};
        const n = std.Io.Reader.readVec(reader, &vec) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e, // 传播底层错误（连接断开、解压失败等），便于排查
        };
        if (n == 0) break;
        list.appendSlice(allocator, buf[0..n]) catch return error.OutOfMemory;
        total += n;
    }
    // 已读满 max_bytes 时再读 1 字节，若有则响应过大
    if (total == max_bytes) {
        var one: [1]u8 = undefined;
        var one_vec: [1][]u8 = .{one[0..]};
        const extra = std.Io.Reader.readVec(reader, &one_vec) catch 0;
        if (extra > 0) return error.ResponseTooLarge;
    }
    return list.toOwnedSlice(allocator);
}

// -----------------------------------------------------------------------------
// 异步文件 I/O（AsyncFileIO）：Linux / Darwin / Windows 三种实现均在本模块内
// -----------------------------------------------------------------------------

const AsyncFileIOLinux = struct {
    const linux = std.os.linux;
    const posix = std.posix;

    const FILE_RING_ENTRIES: u16 = 256;
    const MAX_FILE_PENDING: usize = 256;
    const FILE_USER_DATA_TAG: u64 = 1 << 61;

    const FileOpKind = enum { read, write };
    const FilePendingSlot = struct {
        caller_user_data: usize = 0,
        buffer_ptr: [*]const u8 = undefined,
        op: FileOpKind = .read,
    };

    allocator: std.mem.Allocator,
    ring: linux.IoUring,
    completion_buffer: []api.Completion,
    completion_count: usize,
    pending: [MAX_FILE_PENDING]FilePendingSlot = .{.{}} ** MAX_FILE_PENDING,
    free_stack: [MAX_FILE_PENDING]usize = undefined,
    free_len: usize = 0,

    /// 初始化：优先尝试 IORING_SETUP_SQPOLL（内核线程轮询，submit 近零 syscall），EPERM 时优雅降级并打 performance-hint。
    pub fn init(allocator: std.mem.Allocator) !AsyncFileIOLinux {
        var ring = linux.IoUring.init(FILE_RING_ENTRIES, linux.IORING_SETUP_SQPOLL) catch |err| switch (err) {
            error.PermissionDenied => blk: {
                std.debug.print("[io_core] performance-hint: AsyncFileIO IORING_SETUP_SQPOLL failed (EPERM), falling back to standard io_uring; run with sufficient privileges for 0-syscall submit.\n", .{});
                break :blk linux.IoUring.init(FILE_RING_ENTRIES, 0) catch return err;
            },
            else => return err,
        };
        errdefer ring.deinit();
        const completion_buffer = try allocator.alloc(api.Completion, MAX_FILE_PENDING);
        errdefer allocator.free(completion_buffer);
        var self = AsyncFileIOLinux{
            .allocator = allocator,
            .ring = ring,
            .completion_buffer = completion_buffer,
            .completion_count = 0,
        };
        for (0..MAX_FILE_PENDING) |i| {
            self.free_stack[self.free_len] = i;
            self.free_len += 1;
        }
        return self;
    }

    pub fn deinit(self: *AsyncFileIOLinux) void {
        self.ring.deinit();
        self.allocator.free(self.completion_buffer);
        self.* = undefined;
    }

    /// Zig 0.16：Darwin/Windows 需 io 用于 Mutex/Condition；Linux 忽略。
    pub fn submitReadFile(
        self: *AsyncFileIOLinux,
        io: std.Io,
        fd: posix.fd_t,
        buffer_ptr: [*]u8,
        len: usize,
        offset: u64,
        caller_user_data: usize,
    ) !void {
        _ = io;
        const slot = self.popFree() orelse return error.TooManyPending;
        errdefer self.pushFree(slot);
        self.pending[slot] = .{
            .caller_user_data = caller_user_data,
            .buffer_ptr = @ptrCast(buffer_ptr),
            .op = .read,
        };
        _ = self.ring.read(
            FILE_USER_DATA_TAG | @as(u64, slot),
            fd,
            .{ .buffer = buffer_ptr[0..len] },
            offset,
        ) catch |e| {
            self.pending[slot] = .{};
            self.pushFree(slot);
            return e;
        };
        _ = self.ring.submit() catch |e| {
            self.pending[slot] = .{};
            self.pushFree(slot);
            return e;
        };
    }

    pub fn submitWriteFile(
        self: *AsyncFileIOLinux,
        io: std.Io,
        fd: posix.fd_t,
        data_ptr: [*]const u8,
        len: usize,
        offset: u64,
        caller_user_data: usize,
    ) !void {
        _ = io;
        const slot = self.popFree() orelse return error.TooManyPending;
        errdefer self.pushFree(slot);
        self.pending[slot] = .{
            .caller_user_data = caller_user_data,
            .buffer_ptr = data_ptr,
            .op = .write,
        };
        _ = self.ring.write(
            FILE_USER_DATA_TAG | @as(u64, slot),
            fd,
            data_ptr[0..len],
            offset,
        ) catch |e| {
            self.pending[slot] = .{};
            self.pushFree(slot);
            return e;
        };
        _ = self.ring.submit() catch |e| {
            self.pending[slot] = .{};
            self.pushFree(slot);
            return e;
        };
    }

    pub fn pollCompletions(self: *AsyncFileIOLinux, io: std.Io, timeout_ns: i64) []api.Completion {
        _ = io;
        self.completion_count = 0;
        const wait_nr: u32 = if (timeout_ns < 0) 1 else @intCast(@min(timeout_ns / std.time.ns_per_ms, std.math.maxInt(u32)));
        var cqes: [32]linux.io_uring_cqe = undefined;
        const n = self.ring.copy_cqes(&cqes, wait_nr) catch return self.completion_buffer[0..self.completion_count];
        for (cqes[0..n]) |*cqe| {
            const ud = cqe.user_data;
            if (ud & FILE_USER_DATA_TAG == 0) continue;
            const slot = @as(usize, @intCast(ud & ~FILE_USER_DATA_TAG));
            if (slot >= MAX_FILE_PENDING) continue;
            const pend = &self.pending[slot];
            const caller_ud = pend.caller_user_data;
            const buf_ptr = pend.buffer_ptr;
            const op = pend.op;
            self.pending[slot] = .{};
            self.pushFree(slot);
            const res = cqe.res;
            if (res < 0) {
                const err = posix.errno(@intCast(-res));
                const zig_err = posix.unexpectedErrno(err);
                self.pushFileCompletion(caller_ud, buf_ptr, 0, op, zig_err);
            } else {
                self.pushFileCompletion(caller_ud, buf_ptr, @as(usize, @intCast(res)), op, null);
            }
        }
        return self.completion_buffer[0..self.completion_count];
    }

    inline fn popFree(self: *AsyncFileIOLinux) ?usize {
        if (self.free_len == 0) return null;
        self.free_len -= 1;
        return self.free_stack[self.free_len];
    }
    inline fn pushFree(self: *AsyncFileIOLinux, slot: usize) void {
        self.free_stack[self.free_len] = slot;
        self.free_len += 1;
    }
    inline fn pushFileCompletion(
        self: *AsyncFileIOLinux,
        user_data: usize,
        buffer_ptr: [*]const u8,
        len: usize,
        op: FileOpKind,
        file_err: ?anyerror,
    ) void {
        if (self.completion_count >= self.completion_buffer.len) return;
        const tag: api.CompletionTag = if (op == .read) .file_read else .file_write;
        self.completion_buffer[self.completion_count] = .{
            .user_data = user_data,
            .buffer_ptr = buffer_ptr,
            .len = len,
            .err = null,
            .client_stream = null,
            .tag = tag,
            .chunk_index = null,
            .file_err = file_err,
        };
        self.completion_count += 1;
    }
};

// Darwin/BSD：kqueue 无文件完成事件，用工作线程 + pread/pwrite 模拟异步
const MAX_FILE_PENDING_DARWIN: usize = 256;
const FileOpKindDarwin = enum { read, write };
const FileJobDarwin = struct {
    fd: std.posix.fd_t,
    caller_user_data: usize,
    op: FileOpKindDarwin,
    buffer_ptr: [*]u8,
    data_ptr: [*]const u8,
    len: usize,
    offset: u64,
};

/// 固定容量环形队列：O(1) 入队/出队，替代 ArrayList.orderedRemove(0) 的 O(n) 平移；需与 job_mutex 配合使用。
/// 不能复用 io_core.RingBuffer：RingBuffer 要求 T 为单字类型（usize/指针）以无锁 SPSC；此处 T 为 FileJobDarwin/FileJobWin 等 struct，故用本实现。
fn FileJobRing(comptime T: type, comptime CAP: usize) type {
    return struct {
        buf: [CAP]T = undefined,
        head: usize = 0,
        len: usize = 0,

        fn writableLength(self: *const @This()) usize {
            return CAP - self.len;
        }
        fn readItem(self: *@This()) ?T {
            if (self.len == 0) return null;
            const i = self.head;
            self.head = (self.head + 1) % CAP;
            self.len -= 1;
            return self.buf[i];
        }
        fn writeItem(self: *@This(), item: T) void {
            const tail = (self.head + self.len) % CAP;
            self.buf[tail] = item;
            self.len += 1;
        }
    };
}

const AsyncFileIODarwin = struct {
    allocator: std.mem.Allocator,
    completion_buffer: []api.Completion,
    completion_count: usize,
    job_mutex: std.Io.Mutex = std.Io.Mutex.init,
    job_ring: FileJobRing(FileJobDarwin, MAX_FILE_PENDING_DARWIN) = .{},
    done_mutex: std.Io.Mutex = std.Io.Mutex.init,
    done_list: std.ArrayList(api.Completion) = undefined,
    cond: std.Io.Condition = std.Io.Condition.init,
    worker: ?std.Thread = null,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator) !AsyncFileIODarwin {
        const done_list = std.ArrayList(api.Completion).initCapacity(allocator, MAX_FILE_PENDING_DARWIN) catch return error.OutOfMemory;
        const completion_buffer = try allocator.alloc(api.Completion, MAX_FILE_PENDING_DARWIN);
        var self = AsyncFileIODarwin{
            .allocator = allocator,
            .completion_buffer = completion_buffer,
            .completion_count = 0,
            .done_list = done_list,
        };
        self.worker = try std.Thread.spawn(.{}, workerRunDarwin, .{&self});
        return self;
    }

    pub fn deinit(self: *AsyncFileIODarwin) void {
        self.shutdown.store(true, .seq_cst);
        if (libs_process.getProcessIo()) |io| self.cond.signal(io);
        if (self.worker) |t| t.join();
        self.done_list.deinit(self.allocator);
        self.allocator.free(self.completion_buffer);
        self.* = undefined;
    }

    fn workerRunDarwin(self: *AsyncFileIODarwin) void {
        const io = libs_process.getProcessIo() orelse return;
        while (!self.shutdown.load(.acquire)) {
            self.job_mutex.lock(io) catch return;
            const job: ?FileJobDarwin = self.job_ring.readItem();
            self.job_mutex.unlock(io);
            if (job) |j| {
                var comp: api.Completion = undefined;
                comp.user_data = j.caller_user_data;
                comp.client_stream = null;
                comp.err = null;
                comp.chunk_index = null;
                if (j.op == .read) {
                    const n_read = std.c.pread(j.fd, j.buffer_ptr, j.len, @as(std.c.off_t, @intCast(j.offset)));
                    if (n_read < 0) {
                        comp.buffer_ptr = j.buffer_ptr;
                        comp.len = 0;
                        comp.tag = .file_read;
                        comp.file_err = std.posix.unexpectedErrno(std.c.errno(n_read));
                        self.done_mutex.lock(io) catch {};
                        self.done_list.append(self.allocator, comp) catch {};
                        self.done_mutex.unlock(io);
                        continue;
                    }
                    comp.buffer_ptr = j.buffer_ptr;
                    comp.len = @as(usize, @intCast(n_read));
                    comp.tag = .file_read;
                    comp.file_err = null;
                } else {
                    const n_wrote = std.c.pwrite(j.fd, j.data_ptr, j.len, @as(std.c.off_t, @intCast(j.offset)));
                    if (n_wrote < 0) {
                        comp.buffer_ptr = @ptrCast(&[_]u8{});
                        comp.len = 0;
                        comp.tag = .file_write;
                        comp.file_err = std.posix.unexpectedErrno(std.c.errno(n_wrote));
                        self.done_mutex.lock(io) catch {};
                        self.done_list.append(self.allocator, comp) catch {};
                        self.done_mutex.unlock(io);
                        continue;
                    }
                    comp.buffer_ptr = @ptrCast(&[_]u8{});
                    comp.len = @as(usize, @intCast(n_wrote));
                    comp.tag = .file_write;
                    comp.file_err = null;
                }
                self.done_mutex.lock(io) catch {};
                self.done_list.append(self.allocator, comp) catch {};
                self.done_mutex.unlock(io);
            } else {
                self.job_mutex.lock(io) catch return;
                self.cond.wait(io, &self.job_mutex) catch {};
                self.job_mutex.unlock(io);
            }
        }
    }

    pub fn submitReadFile(
        self: *AsyncFileIODarwin,
        io: std.Io,
        fd: std.posix.fd_t,
        buffer_ptr: [*]u8,
        len: usize,
        offset: u64,
        caller_user_data: usize,
    ) !void {
        self.job_mutex.lock(io) catch return error.Unexpected;
        defer self.job_mutex.unlock(io);
        if (self.job_ring.writableLength() == 0) return error.TooManyPending;
        self.job_ring.writeItem(.{
            .fd = fd,
            .caller_user_data = caller_user_data,
            .op = .read,
            .buffer_ptr = buffer_ptr,
            .data_ptr = @ptrCast(&[_]u8{}),
            .len = len,
            .offset = offset,
        });
        self.cond.signal(io);
    }

    pub fn submitWriteFile(
        self: *AsyncFileIODarwin,
        io: std.Io,
        fd: std.posix.fd_t,
        data_ptr: [*]const u8,
        len: usize,
        offset: u64,
        caller_user_data: usize,
    ) !void {
        self.job_mutex.lock(io) catch return error.Unexpected;
        defer self.job_mutex.unlock(io);
        if (self.job_ring.writableLength() == 0) return error.TooManyPending;
        self.job_ring.writeItem(.{
            .fd = fd,
            .caller_user_data = caller_user_data,
            .op = .write,
            .buffer_ptr = @ptrCast(@constCast(&[_]u8{})),
            .data_ptr = data_ptr,
            .len = len,
            .offset = offset,
        });
        self.cond.signal(io);
    }

    /// 收割文件 I/O 完成项（从线程池结果队列取出）；返回切片有效至下次 pollCompletions 前。批量用 copyForwards 减少逐元素赋值。
    pub fn pollCompletions(self: *AsyncFileIODarwin, io: std.Io, timeout_ns: i64) []api.Completion {
        _ = timeout_ns;
        self.completion_count = 0;
        self.done_mutex.lock(io) catch return self.completion_buffer[0..0];
        const n = @min(self.done_list.items.len, self.completion_buffer.len);
        if (n > 0) {
            std.mem.copyForwards(api.Completion, self.completion_buffer[0..n], self.done_list.items[0..n]);
            var i: usize = n;
            while (i < self.done_list.items.len) : (i += 1) {
                self.done_list.items[i - n] = self.done_list.items[i];
            }
            self.done_list.shrinkRetainingCapacity(self.done_list.items.len - n);
        }
        self.done_mutex.unlock(io);
        self.completion_count = n;
        return self.completion_buffer[0..self.completion_count];
    }
};

// Windows：工作线程 + ReadFile/WriteFile 阻塞调用，与 HighPerfIO 的 IOCP 分离
const win = std.os.windows;
const kernel32 = win.kernel32;
const MAX_FILE_PENDING_WIN: usize = 256;
const FILE_BEGIN_WIN: win.DWORD = 0;
const FileOpKindWin = enum { read, write };
const FileJobWin = struct {
    handle: win.HANDLE,
    caller_user_data: usize,
    op: FileOpKindWin,
    buffer_ptr: [*]u8,
    data_ptr: [*]const u8,
    len: usize,
    offset: u64,
};

const AsyncFileIOWindows = struct {
    allocator: std.mem.Allocator,
    completion_buffer: []api.Completion,
    completion_count: usize,
    job_mutex: std.Io.Mutex = std.Io.Mutex.init,
    job_ring: FileJobRing(FileJobWin, MAX_FILE_PENDING_WIN) = .{},
    done_mutex: std.Io.Mutex = std.Io.Mutex.init,
    done_list: std.ArrayList(api.Completion) = undefined,
    cond: std.Io.Condition = std.Io.Condition.init,
    worker: ?std.Thread = null,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator) !AsyncFileIOWindows {
        const done_list = std.ArrayList(api.Completion).initCapacity(allocator, MAX_FILE_PENDING_WIN) catch return error.OutOfMemory;
        const completion_buffer = try allocator.alloc(api.Completion, MAX_FILE_PENDING_WIN);
        var self = AsyncFileIOWindows{
            .allocator = allocator,
            .completion_buffer = completion_buffer,
            .completion_count = 0,
            .done_list = done_list,
        };
        self.worker = try std.Thread.spawn(.{}, workerRunWin, .{&self});
        return self;
    }

    pub fn deinit(self: *AsyncFileIOWindows) void {
        self.shutdown.store(true, .seq_cst);
        if (libs_process.getProcessIo()) |io| self.cond.signal(io);
        if (self.worker) |t| t.join();
        self.done_list.deinit(self.allocator);
        self.allocator.free(self.completion_buffer);
        self.* = undefined;
    }

    fn workerRunWin(self: *AsyncFileIOWindows) void {
        const io = libs_process.getProcessIo() orelse return;
        while (!self.shutdown.load(.acquire)) {
            self.job_mutex.lock(io);
            const job: ?FileJobWin = self.job_ring.readItem();
            self.job_mutex.unlock(io);
            if (job) |j| {
                var comp: api.Completion = undefined;
                comp.user_data = j.caller_user_data;
                comp.client_stream = null;
                comp.err = null;
                comp.chunk_index = null;
                if (j.op == .read) {
                    var bytes_read: win.DWORD = 0;
                    const move: win.LARGE_INTEGER = @intCast(j.offset);
                    if (kernel32.SetFilePointerEx(j.handle, move, null, FILE_BEGIN_WIN) == 0) {
                        comp.buffer_ptr = j.buffer_ptr;
                        comp.len = 0;
                        comp.tag = .file_read;
                        comp.file_err = error.FileRead;
                    } else if (kernel32.ReadFile(j.handle, j.buffer_ptr, @intCast(j.len), &bytes_read, null) != 0) {
                        comp.buffer_ptr = j.buffer_ptr;
                        comp.len = bytes_read;
                        comp.tag = .file_read;
                        comp.file_err = null;
                    } else {
                        comp.buffer_ptr = j.buffer_ptr;
                        comp.len = 0;
                        comp.tag = .file_read;
                        comp.file_err = error.FileRead;
                    }
                } else {
                    var bytes_written: win.DWORD = 0;
                    const move: win.LARGE_INTEGER = @intCast(j.offset);
                    if (kernel32.SetFilePointerEx(j.handle, move, null, FILE_BEGIN_WIN) == 0) {
                        comp.buffer_ptr = @ptrCast(&[_]u8{});
                        comp.len = 0;
                        comp.tag = .file_write;
                        comp.file_err = error.FileWrite;
                    } else if (kernel32.WriteFile(j.handle, j.data_ptr, @intCast(j.len), &bytes_written, null) != 0) {
                        comp.buffer_ptr = @ptrCast(&[_]u8{});
                        comp.len = bytes_written;
                        comp.tag = .file_write;
                        comp.file_err = null;
                    } else {
                        comp.buffer_ptr = @ptrCast(&[_]u8{});
                        comp.len = 0;
                        comp.tag = .file_write;
                        comp.file_err = error.FileWrite;
                    }
                }
                self.done_mutex.lock(io);
                self.done_list.append(self.allocator, comp) catch {};
                self.done_mutex.unlock(io);
            } else {
                self.job_mutex.lock(io);
                self.cond.wait(io, &self.job_mutex);
                self.job_mutex.unlock(io);
            }
        }
    }

    pub fn submitReadFile(
        self: *AsyncFileIOWindows,
        io: std.Io,
        fd: std.posix.fd_t,
        buffer_ptr: [*]u8,
        len: usize,
        offset: u64,
        caller_user_data: usize,
    ) !void {
        self.job_mutex.lock(io);
        defer self.job_mutex.unlock(io);
        if (self.job_ring.writableLength() == 0) return error.TooManyPending;
        self.job_ring.writeItem(.{
            .handle = @ptrCast(fd),
            .caller_user_data = caller_user_data,
            .op = .read,
            .buffer_ptr = buffer_ptr,
            .data_ptr = @ptrCast(&[_]u8{}),
            .len = len,
            .offset = offset,
        });
        self.cond.signal(io);
    }

    pub fn submitWriteFile(
        self: *AsyncFileIOWindows,
        io: std.Io,
        fd: std.posix.fd_t,
        data_ptr: [*]const u8,
        len: usize,
        offset: u64,
        caller_user_data: usize,
    ) !void {
        self.job_mutex.lock(io);
        defer self.job_mutex.unlock(io);
        if (self.job_ring.writableLength() == 0) return error.TooManyPending;
        self.job_ring.writeItem(.{
            .handle = @ptrCast(fd),
            .caller_user_data = caller_user_data,
            .op = .write,
            .buffer_ptr = @ptrCast(&[_]u8{}),
            .data_ptr = data_ptr,
            .len = len,
            .offset = offset,
        });
        self.cond.signal(io);
    }

    /// 收割完成项；批量用 copyForwards 减少逐元素赋值。
    pub fn pollCompletions(self: *AsyncFileIOWindows, io: std.Io, timeout_ns: i64) []api.Completion {
        _ = timeout_ns;
        self.completion_count = 0;
        self.done_mutex.lock(io);
        const n = @min(self.done_list.items.len, self.completion_buffer.len);
        if (n > 0) {
            std.mem.copyForwards(api.Completion, self.completion_buffer[0..n], self.done_list.items[0..n]);
            var i: usize = n;
            while (i < self.done_list.items.len) : (i += 1) {
                self.done_list.items[i - n] = self.done_list.items[i];
            }
            self.done_list.shrinkRetainingCapacity(self.done_list.items.len - n);
        }
        self.done_mutex.unlock(io);
        self.completion_count = n;
        return self.completion_buffer[0..self.completion_count];
    }
};

/// 异步文件 I/O：submitReadFile/submitWriteFile + pollCompletions 返回 tag=file_read/file_write；三平台实现均在本模块内
pub const AsyncFileIO = switch (builtin.os.tag) {
    .linux => AsyncFileIOLinux,
    .macos, .freebsd, .netbsd, .openbsd => AsyncFileIODarwin,
    .windows => AsyncFileIOWindows,
    else => @compileError("io_core.file 暂不支持此平台"),
};
