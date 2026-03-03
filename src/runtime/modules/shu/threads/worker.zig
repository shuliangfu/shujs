// Shu.thread 工作线程侧：ThreadChannel 消息队列，process.send / process.receiveSync 使用该 channel

const std = @import("std");
const jsc = @import("jsc");
const globals = @import("../../../globals.zig");
const common = @import("../../../common.zig");

/// 主线程与工作线程之间的双向消息队列（主 -> 工作：to_worker；工作 -> 主：to_main）
pub const ThreadChannel = struct {
    to_worker: std.ArrayList([]u8),
    to_main: std.ArrayList([]u8),
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    /// 主线程：向工作线程发一条消息（JSON 字符串，调用方已序列化）
    pub fn sendToWorker(self: *ThreadChannel, msg: []const u8) !void {
        const copy = try self.allocator.dupe(u8, msg);
        errdefer self.allocator.free(copy);
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.to_worker.append(self.allocator, copy);
    }

    /// 主线程：从工作线程收一条消息；返回的切片由调用方 free，无消息返回 null
    pub fn receiveFromWorker(self: *ThreadChannel) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.to_main.items.len == 0) return null;
        return self.to_main.orderedRemove(0);
    }

    /// 工作线程：向主线程发一条消息（JSON 字符串）
    pub fn sendToMain(self: *ThreadChannel, msg: []const u8) !void {
        const copy = try self.allocator.dupe(u8, msg);
        errdefer self.allocator.free(copy);
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.to_main.append(self.allocator, copy);
    }

    /// 工作线程：从主线程收一条消息；返回的切片由调用方 free，无消息返回 null
    pub fn receiveFromMain(self: *ThreadChannel) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.to_worker.items.len == 0) return null;
        return self.to_worker.orderedRemove(0);
    }

    pub fn deinit(self: *ThreadChannel) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.to_worker.items) |s| self.allocator.free(s);
        for (self.to_main.items) |s| self.allocator.free(s);
        self.to_worker.deinit(self.allocator);
        self.to_main.deinit(self.allocator);
    }
};

/// 当前线程的 channel（仅工作线程内非 null，供 process.send/receiveSync 使用）
var current_thread_channel: ?*ThreadChannel = null;

/// 设置当前线程的 channel（由 process.register 在 is_thread_worker 时调用）
pub fn setCurrentChannel(channel: *ThreadChannel) void {
    current_thread_channel = channel;
}

/// 向 process_obj 挂载 send、receiveSync（使用 thread channel）
pub fn registerProcessThreaded(ctx: jsc.JSContextRef, process_obj: jsc.JSObjectRef, channel_ptr: *anyopaque) void {
    const channel: *ThreadChannel = @ptrCast(@alignCast(channel_ptr));
    setCurrentChannel(channel);
    common.setMethod(ctx, process_obj, "send", threadProcessSendCallback);
    common.setMethod(ctx, process_obj, "receiveSync", threadProcessReceiveSyncCallback);
}

fn threadProcessSendCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const channel = current_thread_channel orelse return jsc.JSValueMakeUndefined(ctx);
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
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(msg_js);
    if (max_sz == 0 or max_sz > 65536) return jsc.JSValueMakeUndefined(ctx);
    const buf = allocator.alloc(u8, max_sz) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(buf);
    const n = jsc.JSStringGetUTF8CString(msg_js, buf.ptr, max_sz);
    if (n == 0) return jsc.JSValueMakeUndefined(ctx);
    const msg = buf[0 .. n - 1];
    channel.sendToMain(msg) catch return jsc.JSValueMakeUndefined(ctx);
    return jsc.JSValueMakeUndefined(ctx);
}

fn threadProcessReceiveSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const channel = current_thread_channel orelse return jsc.JSValueMakeUndefined(ctx);
    const msg = channel.receiveFromMain() orelse return jsc.JSValueMakeUndefined(ctx);
    defer channel.allocator.free(msg);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const msg_z = allocator.dupeZ(u8, msg) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(msg_z);
    const ref = jsc.JSStringCreateWithUTF8CString(msg_z.ptr);
    defer jsc.JSStringRelease(ref);
    return jsc.JSValueMakeString(ctx, ref);
}
