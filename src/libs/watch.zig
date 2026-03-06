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
const CACHE_LINE_BYTES = 64;

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
/// 无 io 场景下的自旋锁（与 fetch 一致）；Zig 0.16 无 std.Thread.Mutex 时使用
const Spinlock = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    fn lock(self: *Spinlock) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) == null) {
            std.Thread.yield() catch {};
        }
    }
    fn unlock(self: *Spinlock) void {
        self.state.store(0, .release);
    }
};

/// 通用事件队列：无锁环形队列替代 ArrayList.orderedRemove(0) 以压榨 drain 性能（00 §3.5、§5.3）
/// 由于 WatchEvent 含有切片，不适合 RingBuffer(T)，故用 Mutex 保护的循环队列
fn WatchEventRing(comptime CAP: usize) type {
    return struct {
        buf: [CAP]WatchEvent = undefined,
        head: usize = 0,
        len: usize = 0,

        fn readItem(self: *@This()) ?WatchEvent {
            if (self.len == 0) return null;
            const i = self.head;
            self.head = (self.head + 1) % CAP;
            self.len -= 1;
            return self.buf[i];
        }
        fn writeItem(self: *@This(), item: WatchEvent) bool {
            if (self.len >= CAP) return false;
            const tail = (self.head + self.len) % CAP;
            self.buf[tail] = item;
            self.len += 1;
            return true;
        }
    };
}

const WATCH_EVENT_CAP = 256;

/// Linux inotify 句柄；closed 与 event_mutex 缓存行隔离，减少主/工作线程 false sharing（00 §5.3）
const WatchHandleLinux = struct {
    closed: std.atomic.Value(bool),
    /// 填充至 64 字节，使 event_mutex 从下一缓存行开始
    _pad: [CACHE_LINE_BYTES - @sizeOf(std.atomic.Value(bool))]u8 = undefined,
    fd: std.posix.fd_t,
    wd: i32,
    allocator: std.mem.Allocator,
    event_ring: WatchEventRing(WATCH_EVENT_CAP) = .{},
    event_mutex: Spinlock = .{},
    thread: std.Thread = undefined,
    thread_started: bool = false,

    const INOTIFY_BUF_LEN = 4096;

    /// 工作线程入口：读 inotify 事件，映射为 change/rename，入队；不触碰 JSC
    fn runThread(self: *WatchHandleLinux) void {
        var buf: [INOTIFY_BUF_LEN]u8 align(@alignOf(std.posix.linux.inotify_event)) = undefined;
        while (true) {
            if (self.closed.load(.acquire)) break;
            const n = std.posix.read(self.fd, &buf) catch continue;
            if (n <= 0) continue;
            var off: usize = 0;
            while (off + @sizeOf(std.posix.linux.inotify_event) <= n) {
                const ev = @as(*const std.posix.linux.inotify_event, @ptrCast(&buf[off]));
                off += @sizeOf(std.posix.linux.inotify_event);
                const name_len = ev.len;
                const name_slice: []const u8 = if (name_len > 0 and off + name_len <= n)
                    buf[off..][0..name_len]
                else
                    "";
                off += name_len;

                const event_type: WatchEventType = blk: {
                    const m = ev.mask;
                    if (m & (std.posix.linux.IN.MOVED_FROM | std.posix.linux.IN.MOVED_TO | std.posix.linux.IN.CREATE | std.posix.linux.IN.DELETE | std.posix.linux.IN.DELETE_SELF | std.posix.linux.IN.MOVE_SELF) != 0)
                        break :blk .rename;
                    break :blk .change;
                };
                const filename_owned = if (name_slice.len > 0)
                    self.allocator.dupe(u8, name_slice) catch continue
                else
                    self.allocator.dupe(u8, &.{}) catch continue;

                self.event_mutex.lock();
                defer self.event_mutex.unlock();
                if (!self.event_ring.writeItem(.{ .event_type = event_type, .filename = filename_owned })) {
                    self.allocator.free(filename_owned);
                }
            }
        }
    }

    /// 置 closed、移除 watch、join 线程、释放 event_ring 及其中 filename；idempotent
    fn deinit(self: *WatchHandleLinux) void {
        self.closed.store(true, .release);
        if (self.fd != std.posix.INVALID_FD) {
            _ = std.posix.linux.inotify_rm_watch(self.fd, @intCast(self.wd));
            std.posix.close(self.fd);
            self.fd = std.posix.INVALID_FD;
        }
        if (self.thread_started) self.thread.join();
        self.event_mutex.lock();
        defer self.event_mutex.unlock();
        while (self.event_ring.readItem()) |e| {
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

/// Darwin/BSD kqueue 句柄；closed 与 event_mutex 缓存行隔离（00 §5.3）
const WatchHandleDarwin = struct {
    closed: std.atomic.Value(bool),
    _pad: [CACHE_LINE_BYTES - @sizeOf(std.atomic.Value(bool))]u8 = undefined,
    path_fd: posix.fd_t,
    kq_fd: posix.fd_t,
    allocator: std.mem.Allocator,
    event_ring: WatchEventRing(WATCH_EVENT_CAP) = .{},
    event_mutex: Spinlock = .{},
    thread: std.Thread = undefined,
    thread_started: bool = false,

    /// 工作线程入口：kevent 取 EVFILT_VNODE，入队；不触碰 JSC
    fn runThread(self: *WatchHandleDarwin) void {
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
            if (n <= 0) continue;
            const fflags = ev_list[0].fflags;
            const ev_type = if (fflags & (NOTE_DELETE | NOTE_RENAME) != 0) WatchEventType.rename else WatchEventType.change;
            const filename_empty = self.allocator.dupe(u8, &.{}) catch continue;
            self.event_mutex.lock();
            defer self.event_mutex.unlock();
            if (!self.event_ring.writeItem(.{ .event_type = ev_type, .filename = filename_empty })) {
                self.allocator.free(filename_empty);
            }
        }
    }

    /// 置 closed、关闭 path_fd/kq_fd、join 线程、释放 event_ring 及其中 filename；idempotent
    fn deinit(self: *WatchHandleDarwin) void {
        self.closed.store(true, .release);
        if (self.path_fd != -1) {
            _ = std.c.close(self.path_fd);
            self.path_fd = -1;
        }
        if (self.kq_fd != -1) {
            _ = std.c.close(self.kq_fd);
            self.kq_fd = -1;
        }
        if (self.thread_started) self.thread.join();
        self.event_mutex.lock();
        defer self.event_mutex.unlock();
        while (self.event_ring.readItem()) |e| {
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
        ._pad = undefined,
        .path_fd = path_fd,
        .kq_fd = kq_fd,
        .allocator = allocator,
        .event_ring = .{},
        .event_mutex = .{},
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
/// Windows 句柄；closed 与 event_mutex 缓存行隔离（00 §5.3）
const WatchHandleWindows = struct {
    closed: std.atomic.Value(bool),
    _pad: [CACHE_LINE_BYTES - @sizeOf(std.atomic.Value(bool))]u8 = undefined,
    dir_handle: std.os.windows.HANDLE,
    allocator: std.mem.Allocator,
    event_ring: WatchEventRing(WATCH_EVENT_CAP) = .{},
    event_mutex: Spinlock = .{},
    thread: std.Thread = undefined,
    thread_started: bool = false,

    /// 工作线程入口：ReadDirectoryChangesW 取变更，转 UTF-8 入队；不触碰 JSC
    fn runThread(self: *WatchHandleWindows) void {
        const win = std.os.windows;
        const kernel32 = win.kernel32;
        var buf: [4096]u8 align(@alignOf(win.FILE_NOTIFY_INFORMATION)) = undefined;
        var bytes_read: win.DWORD = 0;
        while (true) {
            if (self.closed.load(.acquire)) break;
            bytes_read = 0;
            const ok = kernel32.ReadDirectoryChangesW(
                self.dir_handle,
                &buf,
                @intCast(buf.len),
                0, // watch subtree = false
                win.FILE_NOTIFY_CHANGE_FILE_NAME | win.FILE_NOTIFY_CHANGE_DIR_NAME | win.FILE_NOTIFY_CHANGE_ATTRIBUTES | win.FILE_NOTIFY_CHANGE_SIZE | win.FILE_NOTIFY_CHANGE_LAST_WRITE,
                &bytes_read,
                null,
                null,
            );
            if (ok == 0) break;
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
                const filename_owned = if (name_utf16.len > 0) blk: {
                    const utf8_len = std.unicode.utf16CountUtf8Bytes(name_utf16) catch break :blk self.allocator.dupe(u8, &.{}) catch continue;
                    const out = self.allocator.alloc(u8, utf8_len) catch break :blk self.allocator.dupe(u8, &.{}) catch continue;
                    _ = std.unicode.utf16ToUtf8(name_utf16, out);
                    break :blk out;
                } else self.allocator.dupe(u8, &.{}) catch continue;
                self.event_mutex.lock();
                defer self.event_mutex.unlock();
                if (!self.event_ring.writeItem(.{ .event_type = event_type, .filename = filename_owned })) {
                    self.allocator.free(filename_owned);
                }
                if (info.NextEntryOffset == 0) break;
                off += info.NextEntryOffset;
            }
        }
    }

    /// 置 closed、CloseHandle(dir_handle)、join 线程、释放 event_ring 及其中 filename；idempotent
    fn deinit(self: *WatchHandleWindows) void {
        self.closed.store(true, .release);
        if (self.dir_handle != std.os.windows.INVALID_HANDLE_VALUE) {
            std.os.windows.kernel32.CloseHandle(self.dir_handle);
            self.dir_handle = std.os.windows.INVALID_HANDLE_VALUE;
        }
        if (self.thread_started) self.thread.join();
        self.event_mutex.lock();
        defer self.event_mutex.unlock();
        while (self.event_ring.readItem()) |e| {
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
        ._pad = undefined,
        .dir_handle = dir_handle,
        .allocator = allocator,
        .event_ring = .{},
        .event_mutex = .{},
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
        ._pad = undefined,
        .fd = fd,
        .wd = wd,
        .allocator = allocator,
        .event_ring = .{},
        .event_mutex = .{},
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
        .linux => blk: {
            const inner = @as(*WatchHandleLinux, @ptrCast(@alignCast(handle)));
            inner.event_mutex.lock();
            defer inner.event_mutex.unlock();
            break :blk inner.event_ring.readItem();
        },
        .macos, .freebsd, .netbsd, .openbsd => blk: {
            const inner = @as(*WatchHandleDarwin, @ptrCast(@alignCast(handle)));
            inner.event_mutex.lock();
            defer inner.event_mutex.unlock();
            break :blk inner.event_ring.readItem();
        },
        .windows => blk: {
            const inner = @as(*WatchHandleWindows, @ptrCast(@alignCast(handle)));
            inner.event_mutex.lock();
            defer inner.event_mutex.unlock();
            break :blk inner.event_ring.readItem();
        },
        else => null,
    };
}
