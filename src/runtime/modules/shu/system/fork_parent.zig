// Node 式 fork 父端：spawn 子 Shu 进程、reader 线程、send/kill/receiveSync
// 子进程通过 env SHU_FORKED=1 识别，用 stdin/stdout 做 length-prefix IPC

const std = @import("std");
const ipc = @import("ipc.zig");

/// 单条消息最大 1MB（与 ipc.zig 一致）
const max_message_len: u32 = 1024 * 1024;

/// 父进程侧 fork 句柄：持有子进程、消息队列、reader 线程
pub const ForkHandle = struct {
    child: std.process.Child,
    queue: std.ArrayList([]u8),
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    reader_thread: std.Thread,
    /// reader 是否已结束（子进程关闭 stdout）
    done: std.atomic.Value(bool),

    /// 向子进程 stdin 写入一条消息（已序列化为 JSON 字符串）；调用方保证 msg 为合法 UTF-8
    pub fn send(self: *ForkHandle, msg: []const u8) !void {
        const stdin_file = self.child.stdin orelse return error.ChildStdinClosed;
        try ipc.writeMessage(stdin_file, msg);
    }

    /// 从队列中取出一条消息；返回的切片由调用方 free；无消息返回 null
    pub fn receiveSync(self: *ForkHandle) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.queue.items.len == 0) return null;
        return self.queue.orderedRemove(0);
    }

    /// 结束子进程并等待；之后勿再使用 handle
    pub fn killAndWait(self: *ForkHandle) void {
        _ = self.child.kill() catch {};
        self.reader_thread.join();
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.queue.items) |s| self.allocator.free(s);
        self.queue.deinit(self.allocator);
        if (self.child.stdin) |*f| f.close();
        if (self.child.stdout) |*f| f.close();
        if (self.child.stderr) |*f| f.close();
    }
};

/// reader 线程入口：从 child.stdout 读 length-prefix 消息并推入 queue
fn forkReaderThread(handle: *ForkHandle) void {
    var stdout_file = handle.child.stdout orelse {
        handle.done.store(true, .seq_cst);
        return;
    };
    while (true) {
        const msg = ipc.readMessage(handle.allocator, &stdout_file) catch break;
        const m = msg orelse break;
        handle.mutex.lock();
        handle.queue.append(handle.allocator, m) catch {
            handle.allocator.free(m);
            handle.mutex.unlock();
            break;
        };
        handle.mutex.unlock();
    }
    handle.done.store(true, .seq_cst);
}

/// 全局 fork 句柄表（id -> *ForkHandle），用于从 JS 回调根据 __forkId 查找
var fork_registry: std.AutoArrayHashMap(u32, *ForkHandle) = undefined;
var fork_registry_mutex: std.Thread.Mutex = .{};
var fork_next_id: u32 = 1;

/// 注册 handle，返回 id；调用方负责在 kill 后调用 unregister
pub fn registerHandle(allocator: std.mem.Allocator, handle: *ForkHandle) !u32 {
    _ = allocator;
    fork_registry_mutex.lock();
    defer fork_registry_mutex.unlock();
    const id = fork_next_id;
    fork_next_id += 1;
    try fork_registry.put(id, handle);
    return id;
}

/// 根据 id 取 handle；不存在返回 null
pub fn getHandle(id: u32) ?*ForkHandle {
    fork_registry_mutex.lock();
    defer fork_registry_mutex.unlock();
    return fork_registry.get(id);
}

/// 注销并释放 handle 占用的表项（不 free handle 本身，由调用方在 killAndWait 后 free）
pub fn unregisterHandle(allocator: std.mem.Allocator, id: u32) void {
    fork_registry_mutex.lock();
    defer fork_registry_mutex.unlock();
    _ = fork_registry.swapRemove(id);
    _ = allocator;
}

/// 初始化全局 registry（在引擎或 main 启动时调用一次）
pub fn initRegistry(allocator: std.mem.Allocator) void {
    fork_registry = std.AutoArrayHashMap(u32, *ForkHandle).init(allocator);
}

/// 创建 fork 句柄：spawn 子进程、启动 reader 线程；失败返回 error，成功返回 handle（调用方负责 free 与 killAndWait）
pub fn createForkHandle(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    env_map: ?*const std.process.EnvMap,
) !*ForkHandle {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.cwd = cwd;
    child.env_map = env_map;
    try child.spawn();
    var handle = try allocator.create(ForkHandle);
    handle.* = .{
        .child = child,
        .queue = std.ArrayList([]u8).empty,
        .mutex = .{},
        .allocator = allocator,
        .reader_thread = undefined,
        .done = std.atomic.Value(bool).init(false),
    };
    handle.reader_thread = try std.Thread.spawn(.{}, forkReaderThread, .{handle});
    return handle;
}
