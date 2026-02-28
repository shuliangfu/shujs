// fork 子进程侧：当 is_forked 时提供 process.send / process.receiveSync，stdin 读线程 + stdout 写
// 由 modules/shu/process 在注册 process 时调用，不依赖 engine。

const std = @import("std");
const jsc = @import("jsc");
const ipc = @import("ipc.zig");
const common = @import("../../../common.zig");
const system_allocator = @import("allocator.zig");

/// 子进程侧状态：stdin 读线程 + 消息队列
pub const ForkChildState = struct {
    queue: std.ArrayList([]u8),
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    reader_thread: std.Thread,

    /// 释放队列与线程；调用方在进程退出前调用
    pub fn deinit(self: *ForkChildState) void {
        self.reader_thread.join();
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.queue.items) |s| self.allocator.free(s);
        self.queue.deinit(self.allocator);
    }
};

/// 从 stdin 读消息并推入 queue 的线程
fn forkChildReaderThread(state: *ForkChildState) void {
    var stdin_file = std.fs.File.stdin();
    while (true) {
        const msg = ipc.readMessage(state.allocator, &stdin_file) catch break;
        const m = msg orelse break;
        state.mutex.lock();
        state.queue.append(state.allocator, m) catch {
            state.allocator.free(m);
            state.mutex.unlock();
            break;
        };
        state.mutex.unlock();
    }
}

/// 全局子进程状态（仅当 is_forked 时非 null）
var fork_child_state: ?*ForkChildState = null;
var fork_child_mutex: std.Thread.Mutex = .{};

/// 启动子进程侧 IPC（在 process 注册前、is_forked 时调用）；allocator 需在进程存活期内有效
pub fn start(allocator: std.mem.Allocator) !*ForkChildState {
    fork_child_mutex.lock();
    defer fork_child_mutex.unlock();
    if (fork_child_state != null) return fork_child_state.?;
    var state = try allocator.create(ForkChildState);
    state.* = .{
        .queue = std.ArrayList([]u8).empty,
        .mutex = .{},
        .allocator = allocator,
        .reader_thread = undefined,
    };
    state.reader_thread = try std.Thread.spawn(.{}, forkChildReaderThread, .{state});
    fork_child_state = state;
    return state;
}

/// 获取当前子进程状态（子进程内 process.send/receiveSync 用）
pub fn getState() ?*ForkChildState {
    fork_child_mutex.lock();
    defer fork_child_mutex.unlock();
    return fork_child_state;
}

/// 向 process_obj 挂载 send、receiveSync（仅当 is_forked 时由 process 注册逻辑调用）
pub fn registerProcessForked(ctx: jsc.JSContextRef, process_obj: jsc.JSObjectRef) void {
    common.setMethod(ctx, process_obj, "send", processSendCallback);
    common.setMethod(ctx, process_obj, "receiveSync", processReceiveSyncCallback);
}

fn processSendCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    _ = getState() orelse return jsc.JSValueMakeUndefined(ctx);
    if (argumentCount == 0) return jsc.JSValueMakeUndefined(ctx);
    const json_str_ref = jsc.JSStringCreateWithUTF8CString("JSON.stringify");
    defer jsc.JSStringRelease(json_str_ref);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const json_val = jsc.JSObjectGetProperty(ctx, global, json_str_ref, null);
    const json_obj = jsc.JSValueToObject(ctx, json_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const strify_name = jsc.JSStringCreateWithUTF8CString("stringify");
    defer jsc.JSStringRelease(strify_name);
    const strify_val = jsc.JSObjectGetProperty(ctx, json_obj, strify_name, null);
    const strify_fn = jsc.JSValueToObject(ctx, strify_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const result = jsc.JSObjectCallAsFunction(ctx, strify_fn, json_obj, 1, arguments, null);
    const msg_js = jsc.JSValueToStringCopy(ctx, result, null);
    defer jsc.JSStringRelease(msg_js);
    const allocator = system_allocator.get() orelse return jsc.JSValueMakeUndefined(ctx);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(msg_js);
    if (max_sz == 0 or max_sz > 65536) return jsc.JSValueMakeUndefined(ctx);
    const buf = allocator.alloc(u8, max_sz) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(buf);
    const n = jsc.JSStringGetUTF8CString(msg_js, buf.ptr, max_sz);
    if (n == 0) return jsc.JSValueMakeUndefined(ctx);
    const msg = buf[0 .. n - 1];
    const stdout_file = std.fs.File.stdout();
    ipc.writeMessage(stdout_file, msg) catch return jsc.JSValueMakeUndefined(ctx);
    return jsc.JSValueMakeUndefined(ctx);
}

fn processReceiveSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const state = getState() orelse return jsc.JSValueMakeUndefined(ctx);
    state.mutex.lock();
    defer state.mutex.unlock();
    if (state.queue.items.len == 0) return jsc.JSValueMakeUndefined(ctx);
    const msg = state.queue.orderedRemove(0);
    defer state.allocator.free(msg);
    const msg_z = state.allocator.dupeZ(u8, msg) catch return jsc.JSValueMakeUndefined(ctx);
    defer state.allocator.free(msg_z);
    const ref = jsc.JSStringCreateWithUTF8CString(msg_z.ptr);
    defer jsc.JSStringRelease(ref);
    return jsc.JSValueMakeString(ctx, ref);
}
