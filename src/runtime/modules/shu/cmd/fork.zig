// Shu.system fork：fork(modulePath [, args] [, options]) — Node 式
// 启动子 Shu 进程运行指定脚本，通过 stdin/stdout 做 length-prefix IPC；需 --allow-run

const std = @import("std");
const jsc = @import("jsc");
const errors = @import("errors");
const libs_process = @import("libs_process");
const globals = @import("../../../globals.zig");
const common = @import("../../../common.zig");
const run_mod = @import("run.zig");
const fork_parent = @import("fork_parent.zig");

/// 是否已初始化 fork 全局 registry（首次 fork 时初始化）
var fork_registry_ready: bool = false;

/// 从 JS 参数取第 idx 个字符串；返回的切片需由调用方 free
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

/// 从 JS 取可选数组参数（如 args），转为 []const []const u8；返回的切片及元素需由调用方 free
fn getArgArrayOfStrings(allocator: std.mem.Allocator, ctx: jsc.JSContextRef, val: jsc.JSValueRef) ?[]const []const u8 {
    const arr_obj = jsc.JSValueToObject(ctx, val, null) orelse return null;
    const k_len = jsc.JSStringCreateWithUTF8CString("length");
    defer jsc.JSStringRelease(k_len);
    const len_val = jsc.JSObjectGetProperty(ctx, arr_obj, k_len, null);
    const len_f = jsc.JSValueToNumber(ctx, len_val, null);
    if (len_f != len_f or len_f < 0) return null;
    const len: usize = @intFromFloat(len_f);
    if (len > 256) return null;
    const out = allocator.alloc([]const u8, len) catch return null;
    errdefer allocator.free(out);
    for (0..len) |i| {
        const elem = jsc.JSObjectGetPropertyAtIndex(ctx, arr_obj, @intCast(i), null);
        const str_ref = jsc.JSValueToStringCopy(ctx, elem, null);
        defer jsc.JSStringRelease(str_ref);
        const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(str_ref);
        if (max_sz == 0 or max_sz > 65536) return null;
        const buf = allocator.alloc(u8, max_sz) catch return null;
        const n = jsc.JSStringGetUTF8CString(str_ref, buf.ptr, max_sz);
        if (n == 0) {
            allocator.free(buf);
            return null;
        }
        out[i] = allocator.dupe(u8, buf[0 .. n - 1]) catch {
            allocator.free(buf);
            return null;
        };
        allocator.free(buf);
    }
    return out;
}

/// 从 JS 对象上读取 __forkId（number）
fn getForkId(ctx: jsc.JSContextRef, this: jsc.JSObjectRef) ?u32 {
    const k = jsc.JSStringCreateWithUTF8CString("__forkId");
    defer jsc.JSStringRelease(k);
    const v = jsc.JSObjectGetProperty(ctx, this, k, null);
    const n = jsc.JSValueToNumber(ctx, v, null);
    if (n != n or n < 0) return null;
    return @intFromFloat(n);
}

/// 向 system_obj 上注册 fork
pub fn register(ctx: jsc.JSGlobalContextRef, system_obj: jsc.JSObjectRef) void {
    common.setMethod(ctx, system_obj, "fork", forkCallback);
}

/// Shu.system.fork(modulePath [, args] [, options])：启动子 Shu 进程，返回 { send, kill, receiveSync }
fn forkCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    if (!opts.permissions.allow_run) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.cmd.fork requires --allow-run" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    if (argumentCount == 0) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);

    const module_path = getArgString(allocator, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(module_path);

    var args_slices: ?[]const []const u8 = null;
    if (argumentCount > 1) {
        args_slices = getArgArrayOfStrings(allocator, ctx, arguments[1]);
    }
    defer if (args_slices) |s| {
        for (s) |e| allocator.free(e);
        allocator.free(s);
    };

    var cwd_opt: ?[]const u8 = null;
    if (argumentCount > 2) {
        const options_obj = jsc.JSValueToObject(ctx, arguments[2], null);
        if (options_obj != null) cwd_opt = run_mod.getOptionsCwd(allocator, ctx, options_obj.?);
    }
    defer if (cwd_opt) |c| allocator.free(c);

    const proc_io = libs_process.getProcessIo() orelse return jsc.JSValueMakeUndefined(ctx);
    const self_exe = std.process.executablePathAlloc(proc_io, allocator) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(self_exe);

    var argv_list = std.ArrayList([]const u8).empty;
    defer argv_list.deinit(allocator);
    argv_list.append(allocator, self_exe) catch return jsc.JSValueMakeUndefined(ctx);
    argv_list.append(allocator, "run") catch return jsc.JSValueMakeUndefined(ctx);
    argv_list.append(allocator, module_path) catch return jsc.JSValueMakeUndefined(ctx);
    if (args_slices) |s| for (s) |arg| argv_list.append(allocator, arg) catch return jsc.JSValueMakeUndefined(ctx);

    const env_block = libs_process.getProcessEnviron() orelse std.process.Environ.empty;
    var env_map = std.process.Environ.createMap(env_block, allocator) catch return jsc.JSValueMakeUndefined(ctx);
    defer env_map.deinit();
    env_map.put("SHU_FORKED", "1") catch return jsc.JSValueMakeUndefined(ctx);

    const io = libs_process.getProcessIo() orelse return jsc.JSValueMakeUndefined(ctx);
    const handle = fork_parent.createForkHandle(allocator, argv_list.items, cwd_opt, &env_map, io) catch return jsc.JSValueMakeUndefined(ctx);
    if (!fork_registry_ready) {
        fork_parent.initRegistry(allocator);
        fork_registry_ready = true;
    }
    const id = fork_parent.registerHandle(allocator, handle) catch {
        std.process.Child.kill(&handle.child, io);
        handle.reader_thread.join();
        allocator.destroy(handle);
        return jsc.JSValueMakeUndefined(ctx);
    };

    const obj = jsc.JSObjectMake(ctx, null, null);
    const k_id = jsc.JSStringCreateWithUTF8CString("__forkId");
    defer jsc.JSStringRelease(k_id);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_id, jsc.JSValueMakeNumber(ctx, @floatFromInt(id)), jsc.kJSPropertyAttributeNone, null);
    common.setMethod(ctx, obj, "send", forkSendCallback);
    common.setMethod(ctx, obj, "kill", forkKillCallback);
    common.setMethod(ctx, obj, "receiveSync", forkReceiveSyncCallback);
    return obj;
}

/// child.send(msg)：将 msg 用 JSON.stringify 序列化后通过 IPC 发给子进程
fn forkSendCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const id = getForkId(ctx, this) orelse return jsc.JSValueMakeUndefined(ctx);
    const handle = fork_parent.getHandle(id) orelse return jsc.JSValueMakeUndefined(ctx);
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
    handle.send(msg) catch return jsc.JSValueMakeUndefined(ctx);
    return jsc.JSValueMakeUndefined(ctx);
}

/// child.kill()：结束子进程并释放句柄
fn forkKillCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const id = getForkId(ctx, this) orelse return jsc.JSValueMakeUndefined(ctx);
    const handle = fork_parent.getHandle(id) orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = handle.allocator;
    handle.killAndWait();
    fork_parent.unregisterHandle(allocator, id);
    allocator.destroy(handle);
    return jsc.JSValueMakeUndefined(ctx);
}

/// child.receiveSync()：从队列取一条消息，返回 JSON 字符串（用户可 JSON.parse）
fn forkReceiveSyncCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const id = getForkId(ctx, this) orelse return jsc.JSValueMakeUndefined(ctx);
    const handle = fork_parent.getHandle(id) orelse return jsc.JSValueMakeUndefined(ctx);
    const msg = handle.receiveSync() orelse return jsc.JSValueMakeUndefined(ctx);
    defer handle.allocator.free(msg);
    const msg_z = handle.allocator.dupeZ(u8, msg) catch return jsc.JSValueMakeUndefined(ctx);
    defer handle.allocator.free(msg_z);
    const ref = jsc.JSStringCreateWithUTF8CString(msg_z.ptr);
    defer jsc.JSStringRelease(ref);
    return jsc.JSValueMakeString(ctx, ref);
}
