//! 文件/目录监视 API（libs_io watch）
//!
//! 职责：按平台提供 startWatch / drainWatchEvents / WatchHandle.deinit；
//! 工作线程仅写事件队列，主线程在 drain 中取事件并回调 JS，禁止在非主线程使用 JSC（与 dns 一致）。
//! 平台分派：comptime switch(builtin.os.tag)，无运行时分支（00 §2.2、§4.4）。
//!
//! 平台：Linux => inotify；Darwin/BSD => kqueue EVFILT_VNODE；Windows => ReadDirectoryChangesW。

const std = @import("std");
const builtin = @import("builtin");

/// 缓存行宽度，用于跨线程原子/锁的隔离（00 §5.3 False Sharing 防御）
const CACHE_LINE = std.atomic.cache_line;

/// 事件类型：与 Node.js fs.watch 的 eventType 一致
pub const WatchEventType = enum { change, rename };

/// 单条监视事件：主线程 drain 时取出。
/// [Allocates] filename 由内部分配，调用方须用同一 allocator free（空切片可不 free）。
pub const WatchEvent = struct {
    event_type: WatchEventType,
    /// 发生变更的文件名（相对于监视目录）；可为空。调用方 free（01 §1.3）
    filename: []const u8,
};

/// 不透明句柄：startWatch 返回，deinit 停止监视并释放资源；内部为各平台 *WatchHandle* 的指针
pub const WatchHandle = struct {
    _opaque: [*]u8 align(8) = undefined,
    _len: usize = 0,

    /// 停止监视并释放句柄；idempotent，可多次调用
    pub fn deinit(self: *WatchHandle) void {
        switch (builtin.os.tag) {
            .linux => {
                const inner = @as(*WatchHandleLinux, @ptrCast(@alignCast(self)));
                inner.deinit();
            },
            .macos, .freebsd, .netbsd, .openbsd => {
                const inner = @as(*WatchHandleDarwin, @ptrCast(@alignCast(self)));
                inner.deinit();
            },
            .windows => {
                const inner = @as(*WatchHandleWindows, @ptrCast(@alignCast(self)));
                inner.deinit();
            },
            else => {},
        }
    }
};

// ---------- Linux：inotify 实现 ----------
/// 极速单生产者单消费者（SPSC）无锁环形队列；容量必须为 2 的幂（00 §3.5、§5.3）
/// head 与 tail 分别对齐缓存行，避免 False Sharing；
fn WatchEventQueue(comptime T: type, comptime CAP: usize) type {
    const mask = CAP - 1;
    std.debug.assert(std.math.isPowerOfTwo(CAP));
    return struct {
        buffer: [CAP]T = undefined,
        _pad_prod: [CACHE_LINE]u8 align(CACHE_LINE) = undefined,
        tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        cached_head: usize = 0,

        _pad_cons: [CACHE_LINE]u8 align(CACHE_LINE) = undefined,
        head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        cached_tail: usize = 0,

        const Self = @This();

        /// 生产者：入队
        pub fn push(self: *Self, value: T) bool {
            @setRuntimeSafety(false);
            const t = self.tail.load(.monotonic);
            if (t - self.cached_head >= CAP) {
                self.cached_head = self.head.load(.acquire);
                if (t - self.cached_head >= CAP) return false;
            }
            self.buffer[t & mask] = value;
            self.tail.store(t + 1, .release);
            return true;
        }

        /// 消费者：出队
        pub fn pop(self: *Self) ?T {
            @setRuntimeSafety(false);
            const h = self.head.load(.monotonic);
            if (h >= self.cached_tail) {
                self.cached_tail = self.tail.load(.acquire);
                if (h >= self.cached_tail) return null;
            }
            const value = self.buffer[h & mask];
            self.head.store(h + 1, .release);
            return value;
        }

        /// 消费者：批量出队（减少跨核缓存一致性流量）
        pub fn popBatch(self: *Self, out: []WatchEvent) usize {
            @setRuntimeSafety(false);
            const h = self.head.load(.monotonic);
            var available = self.cached_tail - h;
            if (available < out.len) {
                self.cached_tail = self.tail.load(.acquire);
                available = self.cached_tail - h;
            }
            const n = @min(available, out.len);
            if (n == 0) return 0;
            for (0..n) |i| {
                out[i] = self.buffer[(h + i) & mask];
            }
            self.head.store(h + n, .release);
            return n;
        }
    };
}

const WATCH_EVENT_CAP = 4096;

/// Linux inotify 句柄；closed 与 event_queue 分别对齐，极致减少缓存抖动（00 §5.3）
const WatchHandleLinux = struct {
    closed: std.atomic.Value(bool) align(CACHE_LINE),
    fd: std.posix.fd_t,
    wd: i32,
    allocator: std.mem.Allocator,
    event_queue: WatchEventQueue(WatchEvent, WATCH_EVENT_CAP) align(CACHE_LINE) = .{},
    thread: std.Thread = undefined,
    thread_started: bool = false,

    const INOTIFY_BUF_LEN = 64 * 1024; // 64KB 缓冲区，支持大量瞬时并发事件

    /// 工作线程入口：阻塞读 inotify 事件，映射并入队；关闭 fd 会唤醒此循环
    fn runThread(self: *WatchHandleLinux) void {
        @setRuntimeSafety(false);
        var buf: [INOTIFY_BUF_LEN]u8 align(@alignOf(std.posix.linux.inotify_event)) = undefined;
        while (true) {
            if (self.closed.load(.acquire)) break;
            // 使用阻塞读以压榨 CPU 效率（00 §3.3 虽推荐非阻塞，但此为专用线程且读操作低频高瞬发）
            const n = std.posix.read(self.fd, &buf) catch break;
            if (n <= 0) break;
            var off: usize = 0;
            while (off + @sizeOf(std.posix.linux.inotify_event) <= n) {
                const ev = @as(*const std.posix.linux.inotify_event, @ptrCast(&buf[off]));
                off += @sizeOf(std.posix.linux.inotify_event);
                const name_len = ev.len;
                const name_slice: []const u8 = if (name_len > 0 and off + name_len <= n) blk: {
                    const s = buf[off..][0..name_len];
                    const actual_len = std.mem.indexOfScalar(u8, s, 0) orelse s.len;
                    break :blk s[0..actual_len];
                } else "";
                off += name_len;

                // 映射事件类型 (rename/change)
                const event_type: WatchEventType = if (ev.mask & (std.posix.linux.IN.MOVED_FROM | std.posix.linux.IN.MOVED_TO | std.posix.linux.IN.CREATE | std.posix.linux.IN.DELETE | std.posix.linux.IN.DELETE_SELF | std.posix.linux.IN.MOVE_SELF) != 0)
                    .rename
                else
                    .change;

                // [Allocates] 为 JS 侧提供堆分配名称 (01 §1.3)
                const filename_owned = self.allocator.dupe(u8, name_slice) catch continue;

                if (!self.event_queue.push(.{ .event_type = event_type, .filename = filename_owned })) {
                    // 队列溢出，丢弃事件，释放内存 (01 §1.1)
                    self.allocator.free(filename_owned);
                }
            }
        }
    }

    /// 置 closed、销毁 watch、join 线程、清理队列 (idempotent)
    fn deinit(self: *WatchHandleLinux) void {
        self.closed.store(true, .release);
        if (self.fd != std.posix.INVALID_FD) {
            _ = std.posix.linux.inotify_rm_watch(self.fd, @intCast(self.wd));
            // 关闭 fd 会唤醒 read 阻塞，终止 runThread
            std.posix.close(self.fd);
            self.fd = std.posix.INVALID_FD;
        }
        if (self.thread_started) self.thread.join();
        
        // 清理未被 drain 的残留内存
        while (self.event_queue.pop()) |e| {
            if (e.filename.len > 0) self.allocator.free(e.filename);
        }
    }
};

// ---------- Darwin/BSD：kqueue EVFILT_VNODE 实现 ----------
const posix = std.posix;
// macOS/BSD sys/event.h 常量（与 Zig std 未导出的 NOTE_/EVFILT_VNODE 对齐）
const EVFILT_VNODE: i16 = 2;
const NOTE_DELETE: u32 = 0x0002;
const NOTE_WRITE: u32 = 0x0004;
const NOTE_EXTEND: u32 = 0x0008;
const NOTE_ATTRIB: u32 = 0x0010;
const NOTE_RENAME: u32 = 0x0020;

/// Darwin/BSD kqueue 句柄；对齐并隔离，消除跨核 CPU 缓存争用（00 §3.5、§5.3）
const WatchHandleDarwin = struct {
    closed: std.atomic.Value(bool) align(CACHE_LINE),
    path_fd: posix.fd_t,
    kq_fd: posix.fd_t,
    allocator: std.mem.Allocator,
    event_queue: WatchEventQueue(WatchEvent, WATCH_EVENT_CAP) align(CACHE_LINE) = .{},
    thread: std.Thread = undefined,
    thread_started: bool = false,

    /// 工作线程入口：kevent 阻塞等待 EVFILT_VNODE 事件
    fn runThread(self: *WatchHandleDarwin) void {
        @setRuntimeSafety(false);
        var ev_list: [1]posix.Kevent = undefined;
        const changelist = [_]posix.Kevent{.{
            .ident = @intCast(self.path_fd),
            .filter = EVFILT_VNODE,
            .flags = posix.system.EV.ADD | posix.system.EV.CLEAR,
            .fflags = NOTE_DELETE | NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB | NOTE_RENAME,
            .data = 0,
            .udata = 0,
        }};
        _ = std.c.kevent(self.kq_fd, changelist[0..].ptr, 1, ev_list[0..].ptr, 1, null);
        var dummy_changelist: [1]posix.Kevent = undefined;
        while (true) {
            if (self.closed.load(.acquire)) break;
            const n = std.c.kevent(self.kq_fd, dummy_changelist[0..].ptr, 0, ev_list[0..].ptr, 1, null);
            if (n <= 0) break;
            
            const fflags = ev_list[0].fflags;
            const ev_type: WatchEventType = if (fflags & (NOTE_DELETE | NOTE_RENAME) != 0) .rename else .change;
            
            // Darwin vnode 监视不直接返回文件名，由 JS 层按需读取或全量扫描 (TODO: 目录监视增强)
            const filename_empty = self.allocator.dupe(u8, &.{}) catch continue;
            if (!self.event_queue.push(.{ .event_type = ev_type, .filename = filename_empty })) {
                self.allocator.free(filename_empty);
            }
        }
    }

    /// 停止监视并 join 线程 (idempotent)
    fn deinit(self: *WatchHandleDarwin) void {
        self.closed.store(true, .release);
        if (self.kq_fd != -1) {
            // 关闭 kq_fd 会唤醒阻塞中的 kevent
            _ = std.c.close(self.kq_fd);
            self.kq_fd = -1;
        }
        if (self.path_fd != -1) {
            _ = std.c.close(self.path_fd);
            self.path_fd = -1;
        }
        if (self.thread_started) self.thread.join();
        while (self.event_queue.pop()) |e| {
            if (e.filename.len > 0) self.allocator.free(e.filename);
        }
    }
};

/// 内部：Darwin/BSD 下 openat + kqueue + EVFILT_VNODE， spawn 工作线程；[Allocates] 调用方 deinit
fn startWatchDarwin(allocator: std.mem.Allocator, path_abs: []const u8) WatchError!*WatchHandle {
    const path_z = allocator.dupeZ(u8, path_abs) catch return WatchError.SystemResources;
    defer allocator.free(path_z);

    const o_rdonly: posix.O = switch (builtin.os.tag) {
        .linux => posix.O.RDONLY,
        else => @bitCast(@as(u32, 0)), // O_RDONLY on Darwin/BSD
    };
    const path_fd = std.posix.openat(std.posix.AT.FDCWD, path_z[0..path_abs.len], o_rdonly, 0) catch |e| {
        return switch (e) {
            error.AccessDenied => WatchError.AccessDenied,
            error.FileNotFound => WatchError.FileNotFound,
            else => WatchError.SystemResources,
        };
    };
    errdefer _ = std.c.close(path_fd);

    const kq_fd = std.c.kqueue();
    if (kq_fd == -1) {
        _ = std.c.close(path_fd);
        return WatchError.SystemResources;
    }
    errdefer _ = std.c.close(kq_fd);

    const inner = allocator.create(WatchHandleDarwin) catch {
        _ = std.c.close(kq_fd);
        _ = std.c.close(path_fd);
        return WatchError.SystemResources;
    };
    inner.* = .{
        .closed = std.atomic.Value(bool).init(false),
        .path_fd = path_fd,
        .kq_fd = kq_fd,
        .allocator = allocator,
        .event_queue = .{},
        .thread = undefined,
        .thread_started = false,
    };
    inner.thread = std.Thread.spawn(.{}, WatchHandleDarwin.runThread, .{inner}) catch {
        allocator.destroy(inner);
        _ = std.c.close(kq_fd);
        _ = std.c.close(path_fd);
        return WatchError.SystemResources;
    };
    inner.thread_started = true;

    return @as(*WatchHandle, @ptrCast(inner));
}

// ---------- Windows：ReadDirectoryChangesW 实现 ----------
/// Windows 句柄；对齐并隔离，支撑高并发文件变更（00 §3.5、§5.3）
const WatchHandleWindows = struct {
    closed: std.atomic.Value(bool) align(CACHE_LINE),
    dir_handle: std.os.windows.HANDLE,
    allocator: std.mem.Allocator,
    event_queue: WatchEventQueue(WatchEvent, WATCH_EVENT_CAP) align(CACHE_LINE) = .{},
    thread: std.Thread = undefined,
    thread_started: bool = false,

    const WIN_WATCH_BUF_LEN = 64 * 1024; // 64KB 缓冲区，ReadDirectoryChangesW 的推荐上限

    /// 工作线程入口：阻塞读目录变更并转码
    fn runThread(self: *WatchHandleWindows) void {
        @setRuntimeSafety(false);
        const win = std.os.windows;
        const kernel32 = win.kernel32;
        var buf: [WIN_WATCH_BUF_LEN]u8 align(@alignOf(win.FILE_NOTIFY_INFORMATION)) = undefined;
        var bytes_read: win.DWORD = 0;
        while (true) {
            if (self.closed.load(.acquire)) break;
            bytes_read = 0;
            // 阻塞读；关闭 dir_handle 将唤醒并返回错误
            const ok = kernel32.ReadDirectoryChangesW(
                self.dir_handle,
                &buf,
                @intCast(buf.len),
                0,
                win.FILE_NOTIFY_CHANGE_FILE_NAME | win.FILE_NOTIFY_CHANGE_DIR_NAME | win.FILE_NOTIFY_CHANGE_ATTRIBUTES | win.FILE_NOTIFY_CHANGE_SIZE | win.FILE_NOTIFY_CHANGE_LAST_WRITE,
                &bytes_read,
                null,
                null,
            );
            if (ok == 0 or bytes_read == 0) break;
            
            var off: usize = 0;
            while (off + @sizeOf(win.FILE_NOTIFY_INFORMATION) <= bytes_read) {
                const info = @as(*const win.FILE_NOTIFY_INFORMATION, @ptrCast(&buf[off]));
                const name_len = info.FileNameLength;
                const action = info.Action;
                const event_type: WatchEventType = if (action == win.FILE_ACTION_RENAMED_OLD_NAME or action == win.FILE_ACTION_RENAMED_NEW_NAME or action == win.FILE_ACTION_REMOVED or action == win.FILE_ACTION_ADDED) .rename else .change;
                
                const name_utf16 = if (name_len > 0 and off + @sizeOf(win.FILE_NOTIFY_INFORMATION) + name_len <= bytes_read)
                    @as([*]const u16, @ptrCast(&buf[off + @sizeOf(win.FILE_NOTIFY_INFORMATION)]))[0 .. name_len / 2]
                else
                    &[_]u16{};
                
                // 将 UTF-16 转换为 UTF-8
                const filename_owned = if (name_utf16.len > 0) blk: {
                    const utf8_len = std.unicode.utf16CountUtf8Bytes(name_utf16) catch break :blk self.allocator.dupe(u8, &.{}) catch continue;
                    const out = self.allocator.alloc(u8, utf8_len) catch break :blk self.allocator.dupe(u8, &.{}) catch continue;
                    _ = std.unicode.utf16ToUtf8(name_utf16, out);
                    break :blk out;
                } else self.allocator.dupe(u8, &.{}) catch continue;
                
                if (!self.event_queue.push(.{ .event_type = event_type, .filename = filename_owned })) {
                    self.allocator.free(filename_owned);
                }
                if (info.NextEntryOffset == 0) break;
                off += info.NextEntryOffset;
            }
        }
    }

    /// 停止监视 (idempotent)
    fn deinit(self: *WatchHandleWindows) void {
        self.closed.store(true, .release);
        if (self.dir_handle != std.os.windows.INVALID_HANDLE_VALUE) {
            // 关闭句柄唤醒 ReadDirectoryChangesW
            std.os.windows.kernel32.CloseHandle(self.dir_handle);
            self.dir_handle = std.os.windows.INVALID_HANDLE_VALUE;
        }
        if (self.thread_started) self.thread.join();
        while (self.event_queue.pop()) |e| {
            if (e.filename.len > 0) self.allocator.free(e.filename);
        }
    }
};

fn startWatchWindows(allocator: std.mem.Allocator, path_abs: []const u8) WatchError!*WatchHandle {
    const win = std.os.windows;
    const kernel32 = win.kernel32;
    const path_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, path_abs) catch return WatchError.SystemResources;
    defer allocator.free(path_w);

    const dir_handle = kernel32.CreateFileW(
        path_w.ptr,
        win.GENERIC_READ,
        win.FILE_SHARE_READ,
        null,
        win.OPEN_EXISTING,
        win.FILE_FLAG_BACKUP_SEMANTICS,
        null,
    );
    if (dir_handle == win.INVALID_HANDLE_VALUE) {
        return switch (win.kernel32.GetLastError()) {
            win.win32_error.ACCESS_DENIED => WatchError.AccessDenied,
            win.win32_error.FILE_NOT_FOUND, win.win32_error.PATH_NOT_FOUND => WatchError.FileNotFound,
            else => WatchError.SystemResources,
        };
    }

    const inner = allocator.create(WatchHandleWindows) catch {
        kernel32.CloseHandle(dir_handle);
        return WatchError.SystemResources;
    };
    inner.* = .{
        .closed = std.atomic.Value(bool).init(false),
        .dir_handle = dir_handle,
        .allocator = allocator,
        .event_queue = .{},
        .thread = undefined,
        .thread_started = false,
    };
    inner.thread = std.Thread.spawn(.{}, WatchHandleWindows.runThread, .{inner}) catch {
        kernel32.CloseHandle(dir_handle);
        allocator.destroy(inner);
        return WatchError.SystemResources;
    };
    inner.thread_started = true;

    return @as(*WatchHandle, @ptrCast(inner));
}

/// 错误集：当前平台不支持监视时返回 Unsupported
pub const WatchError = error{
    Unsupported,
    SystemResources,
    AccessDenied,
    FileNotFound,
};

/// 开始监视 path_abs（绝对路径）；recursive 暂不实现（各平台均需递归遍历子目录）。
/// [Allocates] 返回的句柄由 allocator 分配，调用方须在不再需要时调用 handle.deinit()（内部会 destroy 并释放资源）（01 §1.3）。
/// 主线程应定期调用 drainWatchEvents，并对返回事件的 filename 负责 free。
pub fn startWatch(allocator: std.mem.Allocator, path_abs: []const u8, recursive: bool) WatchError!*WatchHandle {
    if (recursive) return WatchError.Unsupported; // TODO: 递归需遍历子目录并逐个 watch
    return switch (builtin.os.tag) {
        .linux => startWatchLinux(allocator, path_abs),
        .macos, .freebsd, .netbsd, .openbsd => startWatchDarwin(allocator, path_abs),
        .windows => startWatchWindows(allocator, path_abs),
        else => WatchError.Unsupported,
    };
}

/// 内部：Linux inotify_init1 + inotify_add_watch，spawn 工作线程；[Allocates] 调用方 deinit
fn startWatchLinux(allocator: std.mem.Allocator, path_abs: []const u8) WatchError!*WatchHandle {
    const path_z = allocator.dupeZ(u8, path_abs) catch return WatchError.SystemResources;
    defer allocator.free(path_z);

    const fd = std.posix.linux.inotify_init1(std.posix.linux.IN.NONBLOCK | std.posix.linux.IN.CLOEXEC) catch |e| {
        return switch (e) {
            error.SystemResources => WatchError.SystemResources,
            else => WatchError.SystemResources,
        };
    };
    errdefer std.posix.close(fd);

    const mask: u32 = std.posix.linux.IN.MODIFY | std.posix.linux.IN.ATTRIB | std.posix.linux.IN.MOVED_FROM |
        std.posix.linux.IN.MOVED_TO | std.posix.linux.IN.CREATE | std.posix.linux.IN.DELETE |
        std.posix.linux.IN.DELETE_SELF | std.posix.linux.IN.MOVE_SELF;
    const wd = std.posix.linux.inotify_add_watch(fd, path_z.ptr, mask) catch |e| {
        std.posix.close(fd);
        return switch (e) {
            error.AccessDenied => WatchError.AccessDenied,
            error.FileNotFound => WatchError.FileNotFound,
            else => WatchError.SystemResources,
        };
    };

    const inner = allocator.create(WatchHandleLinux) catch {
        _ = std.posix.linux.inotify_rm_watch(fd, wd);
        std.posix.close(fd);
        return WatchError.SystemResources;
    };
    inner.* = .{
        .closed = std.atomic.Value(bool).init(false),
        .fd = fd,
        .wd = wd,
        .allocator = allocator,
        .event_queue = .{},
        .thread = undefined,
        .thread_started = false,
    };
    inner.thread = std.Thread.spawn(.{}, WatchHandleLinux.runThread, .{inner}) catch {
        _ = std.posix.linux.inotify_rm_watch(fd, wd);
        std.posix.close(fd);
        allocator.destroy(inner);
        return WatchError.SystemResources;
    };
    inner.thread_started = true;

    return @as(*WatchHandle, @ptrCast(inner));
}

/// 从句柄中取出一条待处理事件；无事件返回 null。
/// [Allocates] 返回的 WatchEvent.filename 由内部分配，调用方须用与 startWatch 相同的 allocator free（空切片可不 free）（01 §1.3）。
pub fn drainWatchEvents(handle: *WatchHandle) ?WatchEvent {
    return switch (builtin.os.tag) {
        .linux => {
            const inner = @as(*WatchHandleLinux, @ptrCast(@alignCast(handle)));
            return inner.event_queue.pop();
        },
        .macos, .freebsd, .netbsd, .openbsd => {
            const inner = @as(*WatchHandleDarwin, @ptrCast(@alignCast(handle)));
            return inner.event_queue.pop();
        },
        .windows => {
            const inner = @as(*WatchHandleWindows, @ptrCast(@alignCast(handle)));
            return inner.event_queue.pop();
        },
        else => null,
    };
}

/// 批量取出待处理事件；返回实际取出的数量。
/// [Allocates] 返回的 WatchEvent.filename 由内部分配，调用方须用与 startWatch 相同的 allocator free。
pub fn drainWatchEventsBatch(handle: *WatchHandle, out: []WatchEvent) usize {
    return switch (builtin.os.tag) {
        .linux => {
            const inner = @as(*WatchHandleLinux, @ptrCast(@alignCast(handle)));
            return inner.event_queue.popBatch(out);
        },
        .macos, .freebsd, .netbsd, .openbsd => {
            const inner = @as(*WatchHandleDarwin, @ptrCast(@alignCast(handle)));
            return inner.event_queue.popBatch(out);
        },
        .windows => {
            const inner = @as(*WatchHandleWindows, @ptrCast(@alignCast(handle)));
            return inner.event_queue.popBatch(out);
        },
        else => 0,
    };
}
