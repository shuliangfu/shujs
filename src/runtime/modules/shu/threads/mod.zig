// Shu.thread：多线程 API，spawn(scriptPath [, options]) 在新线程中运行脚本，通过 channel 收发消息

// Shu.thread / shu:threads：多线程 API，spawn(scriptPath [, options]) 在新线程中运行脚本，通过 channel 收发消息
// 路径相对于 modules/shu/threads/

const std = @import("std");
const jsc = @import("jsc");
const globals = @import("../../../globals.zig");
const common = @import("../../../common.zig");
const run_options = @import("../../../run_options.zig");
const thread_worker = @import("worker.zig");
const strip_types = @import("../../../../transpiler/strip_types.zig");
const run_mod = @import("../system/run.zig");
const vm = @import("../../../vm.zig");

/// 传给工作线程的参数（由主线程分配，工作线程负责部分 free）
const WorkerArgs = struct {
    allocator: std.mem.Allocator,
    entry_path: []const u8,
    cwd: []const u8,
    channel: *thread_worker.ThreadChannel,
    permissions: run_options.Permissions,
};

/// 向 shu_obj 上挂载 thread 子对象（Shu.thread.spawn、worker 句柄的 send/receiveSync/join）
pub fn register(ctx: jsc.JSGlobalContextRef, shu_obj: jsc.JSObjectRef) void {
    const thread_obj = jsc.JSObjectMake(ctx, null, null);
    const name_thread = jsc.JSStringCreateWithUTF8CString("thread");
    defer jsc.JSStringRelease(name_thread);
    common.setMethod(ctx, thread_obj, "spawn", spawnCallback);
    _ = jsc.JSObjectSetProperty(ctx, shu_obj, name_thread, thread_obj, jsc.kJSPropertyAttributeNone, null);
}

/// 返回 shu:threads / node:worker_threads 的 exports（thread.spawn、isMainThread、parentPort、workerData），供 require("shu:threads") 使用
pub fn getExports(ctx: jsc.JSContextRef, _: std.mem.Allocator) jsc.JSValueRef {
    const exports = jsc.JSObjectMake(ctx, null, null);
    const thread_obj = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, thread_obj, "spawn", spawnCallback);
    const name_thread = jsc.JSStringCreateWithUTF8CString("thread");
    defer jsc.JSStringRelease(name_thread);
    _ = jsc.JSObjectSetProperty(ctx, exports, name_thread, thread_obj, jsc.kJSPropertyAttributeNone, null);
    const opts = globals.current_run_options orelse return exports;
    const name_is_main = jsc.JSStringCreateWithUTF8CString("isMainThread");
    defer jsc.JSStringRelease(name_is_main);
    _ = jsc.JSObjectSetProperty(ctx, exports, name_is_main, jsc.JSValueMakeBoolean(ctx, !opts.is_thread_worker), jsc.kJSPropertyAttributeNone, null);
    const name_parent = jsc.JSStringCreateWithUTF8CString("parentPort");
    defer jsc.JSStringRelease(name_parent);
    _ = jsc.JSObjectSetProperty(ctx, exports, name_parent, jsc.JSValueMakeUndefined(ctx), jsc.kJSPropertyAttributeNone, null);
    const name_data = jsc.JSStringCreateWithUTF8CString("workerData");
    defer jsc.JSStringRelease(name_data);
    _ = jsc.JSObjectSetProperty(ctx, exports, name_data, jsc.JSValueMakeUndefined(ctx), jsc.kJSPropertyAttributeNone, null);
    return exports;
}

/// 工作线程入口：在新线程中创建 VM、运行脚本
fn threadWorkerEntry(args: *WorkerArgs) void {
    defer args.allocator.free(args.entry_path);
    defer args.allocator.free(args.cwd);
    defer args.allocator.destroy(args);

    const file = std.fs.openFileAbsolute(args.entry_path, .{}) catch return;
    defer file.close();
    const raw = file.readToEndAlloc(args.allocator, std.math.maxInt(usize)) catch return;
    defer args.allocator.free(raw);

    var stripped_to_free: ?[]const u8 = null;
    const source: []const u8 = blk: {
        if (hasExtension(args.entry_path, ".ts") or hasExtension(args.entry_path, ".tsx") or hasExtension(args.entry_path, ".mts")) {
            const stripped = strip_types.strip(args.allocator, raw) catch return;
            stripped_to_free = stripped;
            break :blk stripped;
        }
        break :blk raw;
    };
    defer if (stripped_to_free) |s| args.allocator.free(s);

    var argv_buf = [_][]const u8{ "shu", args.entry_path };
    const options = run_options.RunOptions{
        .entry_path = args.entry_path,
        .cwd = args.cwd,
        .argv = &argv_buf,
        .permissions = args.permissions,
        .is_thread_worker = true,
        .thread_channel = @ptrCast(args.channel),
    };
    var runtime = vm.VM.init(args.allocator, &options) catch return;
    defer runtime.deinit();
    runtime.run(source, args.entry_path) catch {};
}

fn hasExtension(path: []const u8, ext: []const u8) bool {
    if (path.len < ext.len) return false;
    return std.mem.eql(u8, path[path.len - ext.len ..], ext);
}

/// 主线程侧句柄：持有 thread、channel
const ThreadHandle = struct {
    thread: std.Thread,
    channel: *thread_worker.ThreadChannel,
    allocator: std.mem.Allocator,
};

var thread_registry: std.AutoArrayHashMap(u32, *ThreadHandle) = undefined;
var thread_registry_mutex: std.Thread.Mutex = .{};
var thread_next_id: u32 = 1;
var thread_registry_ready: bool = false;

fn getArgString(allocator: std.mem.Allocator, ctx: jsc.JSContextRef, arguments: [*]const jsc.JSValueRef, argumentCount: usize, idx: usize) ?[]const u8 {
    if (argumentCount <= idx) return null;
    const s = jsc.JSValueToStringCopy(ctx, arguments[idx], null);
    defer jsc.JSStringRelease(s);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(s);
    if (max_sz == 0 or max_sz > 65536) return null;
    const buf = allocator.alloc(u8, max_sz) catch return null;
    defer allocator.free(buf);
    const n = jsc.JSStringGetUTF8CString(s, buf.ptr, max_sz);
    if (n == 0) return null;
    return allocator.dupe(u8, buf[0 .. n - 1]) catch null;
}

fn getThreadId(ctx: jsc.JSContextRef, this: jsc.JSObjectRef) ?u32 {
    const k = jsc.JSStringCreateWithUTF8CString("__threadId");
    defer jsc.JSStringRelease(k);
    const v = jsc.JSObjectGetProperty(ctx, this, k, null);
    const n = jsc.JSValueToNumber(ctx, v, null);
    if (n != n or n < 0) return null;
    return @intFromFloat(n);
}

fn spawnCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount == 0) return jsc.JSValueMakeUndefined(ctx);
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);

    const script_path = getArgString(allocator, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(script_path);

    var cwd = opts.cwd;
    var cwd_override_to_free: ?[]const u8 = null;
    if (argumentCount > 1) {
        const options_val = arguments[1];
        const options_obj = jsc.JSValueToObject(ctx, options_val, null);
        if (options_obj != null) {
            cwd_override_to_free = run_mod.getOptionsCwd(allocator, ctx, options_obj.?);
            if (cwd_override_to_free) |co| cwd = co;
        }
    }
    defer if (cwd_override_to_free) |co| allocator.free(co);

    const entry_path = std.fs.path.resolve(allocator, &.{ cwd, script_path }) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(entry_path);
    const entry_path_owned = allocator.dupe(u8, entry_path) catch return jsc.JSValueMakeUndefined(ctx);
    const cwd_owned = allocator.dupe(u8, cwd) catch {
        allocator.free(entry_path_owned);
        return jsc.JSValueMakeUndefined(ctx);
    };

    var channel = allocator.create(thread_worker.ThreadChannel) catch return jsc.JSValueMakeUndefined(ctx);
    channel.* = .{
        .to_worker = std.ArrayList([]u8).empty,
        .to_main = std.ArrayList([]u8).empty,
        .mutex = .{},
        .allocator = allocator,
    };
    errdefer allocator.destroy(channel);

    const worker_args = allocator.create(WorkerArgs) catch {
        channel.deinit();
        allocator.destroy(channel);
        allocator.free(entry_path_owned);
        allocator.free(cwd_owned);
        return jsc.JSValueMakeUndefined(ctx);
    };
    worker_args.* = .{
        .allocator = allocator,
        .entry_path = entry_path_owned,
        .cwd = cwd_owned,
        .channel = channel,
        .permissions = opts.permissions,
    };

    const thread = std.Thread.spawn(.{}, threadWorkerEntry, .{worker_args}) catch {
        allocator.destroy(worker_args);
        channel.deinit();
        allocator.destroy(channel);
        allocator.free(entry_path_owned);
        allocator.free(cwd_owned);
        return jsc.JSValueMakeUndefined(ctx);
    };

    var handle = allocator.create(ThreadHandle) catch {
        thread.join();
        allocator.destroy(worker_args);
        channel.deinit();
        allocator.destroy(channel);
        allocator.free(entry_path_owned);
        allocator.free(cwd_owned);
        return jsc.JSValueMakeUndefined(ctx);
    };
    handle.* = .{ .thread = thread, .channel = channel, .allocator = allocator };

    if (!thread_registry_ready) {
        thread_registry_mutex.lock();
        thread_registry = std.AutoArrayHashMap(u32, *ThreadHandle).init(allocator);
        thread_registry_ready = true;
        thread_registry_mutex.unlock();
    }
    thread_registry_mutex.lock();
    const id = thread_next_id;
    thread_next_id += 1;
    thread_registry.put(id, handle) catch {
        thread_registry_mutex.unlock();
        handle.thread.join();
        channel.deinit();
        allocator.destroy(channel);
        allocator.destroy(handle);
        allocator.destroy(worker_args);
        return jsc.JSValueMakeUndefined(ctx);
    };
    thread_registry_mutex.unlock();

    const obj = jsc.JSObjectMake(ctx, null, null);
    const k_id = jsc.JSStringCreateWithUTF8CString("__threadId");
    defer jsc.JSStringRelease(k_id);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_id, jsc.JSValueMakeNumber(ctx, @floatFromInt(id)), jsc.kJSPropertyAttributeNone, null);
    common.setMethod(ctx, obj, "send", threadSendCallback);
    common.setMethod(ctx, obj, "receiveSync", threadReceiveSyncCallback);
    common.setMethod(ctx, obj, "join", threadJoinCallback);
    return obj;
}

fn threadSendCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const id = getThreadId(ctx, this) orelse return jsc.JSValueMakeUndefined(ctx);
    thread_registry_mutex.lock();
    const handle = thread_registry.get(id);
    thread_registry_mutex.unlock();
    if (handle == null) return jsc.JSValueMakeUndefined(ctx);
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
    handle.?.channel.sendToWorker(buf[0 .. n - 1]) catch return jsc.JSValueMakeUndefined(ctx);
    return jsc.JSValueMakeUndefined(ctx);
}

fn threadReceiveSyncCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const id = getThreadId(ctx, this) orelse return jsc.JSValueMakeUndefined(ctx);
    thread_registry_mutex.lock();
    const handle = thread_registry.get(id);
    thread_registry_mutex.unlock();
    if (handle == null) return jsc.JSValueMakeUndefined(ctx);
    const msg = handle.?.channel.receiveFromWorker() orelse return jsc.JSValueMakeUndefined(ctx);
    defer handle.?.channel.allocator.free(msg);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const msg_z = allocator.dupeZ(u8, msg) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(msg_z);
    const ref = jsc.JSStringCreateWithUTF8CString(msg_z.ptr);
    defer jsc.JSStringRelease(ref);
    return jsc.JSValueMakeString(ctx, ref);
}

fn threadJoinCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const id = getThreadId(ctx, this) orelse return jsc.JSValueMakeUndefined(ctx);
    thread_registry_mutex.lock();
    const h = thread_registry.get(id);
    if (h != null) _ = thread_registry.swapRemove(id);
    thread_registry_mutex.unlock();
    if (h == null) return jsc.JSValueMakeUndefined(ctx);
    h.?.thread.join();
    h.?.channel.deinit();
    h.?.allocator.destroy(h.?.channel);
    h.?.allocator.destroy(h.?);
    return jsc.JSValueMakeUndefined(ctx);
}
