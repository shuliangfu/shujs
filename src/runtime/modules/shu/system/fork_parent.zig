// Node 式 fork 父端：spawn 子 Shu 进程、reader 线程、send/kill/receiveSync
// 子进程通过 env SHU_FORKED=1 识别，用 stdin/stdout 做 length-prefix IPC
// Zig 0.16：spawn(io, SpawnOptions)、Child.kill(io)、File.close(io)

const std = @import("std");
const errors = @import("errors");
const libs_process = @import("libs_process");
const ipc = @import("ipc.zig");

/// 单条消息最大 1MB（与 ipc.zig 一致）
const max_message_len: u32 = 1024 * 1024;

/// 父进程侧 fork 句柄：持有子进程、消息队列、reader 线程。0.16：Io.Mutex
pub const ForkHandle = struct {
    child: std.process.Child,
    queue: std.ArrayList([]u8),
    mutex: std.Io.Mutex,
    allocator: std.mem.Allocator,
    reader_thread: std.Thread,
    /// reader 是否已结束（子进程关闭 stdout）
    done: std.atomic.Value(bool),

    /// 向子进程 stdin 写入一条消息（已序列化为 JSON 字符串）；调用方保证 msg 为合法 UTF-8
    /// 0.16：ipc.writeMessage(io, file, msg)
    pub fn send(self: *ForkHandle, msg: []const u8) !void {
        const io = libs_process.getProcessIo() orelse return error.NoProcessIo;
        const stdin_file = self.child.stdin orelse return error.ChildStdinClosed;
        try ipc.writeMessage(io, stdin_file, msg);
    }

    /// 从队列中取出一条消息；返回的切片由调用方 free；无消息返回 null。0.16：mutex 需 io
    pub fn receiveSync(self: *ForkHandle) ?[]u8 {
        const io = libs_process.getProcessIo() orelse return null;
        self.mutex.lock(io) catch return null;
        defer self.mutex.unlock(io);
        if (self.queue.items.len == 0) return null;
        return self.queue.orderedRemove(0);
    }

    /// 结束子进程并等待；之后勿再使用 handle。0.16：child.kill(io)、file.close(io)
    pub fn killAndWait(self: *ForkHandle) void {
        const io = libs_process.getProcessIo() orelse return;
        self.child.kill(io);
        self.reader_thread.join();
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);
        for (self.queue.items) |s| self.allocator.free(s);
        self.queue.deinit(self.allocator);
        if (self.child.stdin) |*f| f.close(io);
        if (self.child.stdout) |*f| f.close(io);
        if (self.child.stderr) |*f| f.close(io);
    }
};

/// reader 线程入口：从 child.stdout 读 length-prefix 消息并推入 queue。0.16：Io.Mutex 需 io
fn forkReaderThread(handle: *ForkHandle) void {
    const io = libs_process.getProcessIo() orelse {
        handle.done.store(true, .seq_cst);
        return;
    };
    const stdout_file = handle.child.stdout orelse {
        handle.done.store(true, .seq_cst);
        return;
    };
    while (true) {
        const msg = ipc.readMessage(handle.allocator, io, stdout_file) catch break;
        const m = msg orelse break;
        handle.mutex.lock(io) catch break;
        handle.queue.append(handle.allocator, m) catch {
            handle.allocator.free(m);
            handle.mutex.unlock(io);
            break;
        };
        handle.mutex.unlock(io);
    }
    handle.done.store(true, .seq_cst);
}

/// 全局 fork 句柄表（id -> *ForkHandle），用于从 JS 回调根据 __forkId 查找。0.16：Io.Mutex
var fork_registry: std.AutoArrayHashMap(u32, *ForkHandle) = undefined;
var fork_registry_mutex: std.Io.Mutex = .{ .state = std.atomic.Value(std.Io.Mutex.State).init(.unlocked) };
var fork_next_id: u32 = 1;

/// 注册 handle，返回 id；调用方负责在 kill 后调用 unregister
pub fn registerHandle(allocator: std.mem.Allocator, handle: *ForkHandle) !u32 {
    _ = allocator;
    const io = libs_process.getProcessIo() orelse return error.NoProcessIo;
    fork_registry_mutex.lock(io) catch return error.NoProcessIo;
    defer fork_registry_mutex.unlock(io);
    const id = fork_next_id;
    fork_next_id += 1;
    try fork_registry.put(id, handle);
    return id;
}

/// 根据 id 取 handle；不存在返回 null
pub fn getHandle(id: u32) ?*ForkHandle {
    const io = libs_process.getProcessIo() orelse return null;
    fork_registry_mutex.lock(io) catch return null;
    defer fork_registry_mutex.unlock(io);
    return fork_registry.get(id);
}

/// 注销并释放 handle 占用的表项（不 free handle 本身，由调用方在 killAndWait 后 free）
pub fn unregisterHandle(allocator: std.mem.Allocator, id: u32) void {
    const io = libs_process.getProcessIo() orelse return;
    fork_registry_mutex.lock(io) catch return;
    defer fork_registry_mutex.unlock(io);
    _ = fork_registry.swapRemove(id);
    _ = allocator;
}

/// 初始化全局 registry（在引擎或 main 启动时调用一次）
pub fn initRegistry(allocator: std.mem.Allocator) void {
    fork_registry = std.AutoArrayHashMap(u32, *ForkHandle).init(allocator);
}

/// 创建 fork 句柄：spawn 子进程、启动 reader 线程；失败返回 error，成功返回 handle（调用方负责 free 与 killAndWait）
/// 0.16：使用 std.process.spawn(io, SpawnOptions)，environ_map 为 Environ.Map
pub fn createForkHandle(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    env_map: ?*const std.process.Environ.Map,
    io: std.Io,
) !*ForkHandle {
    const cwd_opt: std.process.Child.Cwd = if (cwd) |c| .{ .path = c } else .inherit;
    const child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = cwd_opt,
        .environ_map = env_map,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    var handle = try allocator.create(ForkHandle);
    handle.* = .{
        .child = child,
        .queue = std.ArrayList([]u8).empty,
        .mutex = .{ .state = std.atomic.Value(std.Io.Mutex.State).init(.unlocked) },
        .allocator = allocator,
        .reader_thread = undefined,
        .done = std.atomic.Value(bool).init(false),
    };
    handle.reader_thread = try std.Thread.spawn(.{}, forkReaderThread, .{handle});
    return handle;
}
