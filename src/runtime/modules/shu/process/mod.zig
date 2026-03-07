//! # shu:process — 全局 process 与 Node node:process API 兼容层
//!
//! 本模块向 JSC 全局对象注入 `process` 对象及 `__dirname`、`__filename`，与 Node.js
//! 的 `node:process` 在常用 API 上保持兼容，便于现有 Node 脚本与生态在 shu 上运行。
//!
//! ## 调用约定
//!
//! - **入口**：由 `bindings.registerGlobals` 在 `options != null` 时调用 `register(allocator, ctx, options)`。
//! - **协议**：`require('shu:process')` / `getExports(ctx, allocator)` 返回与全局 `process` 同一对象引用。
//! - **依赖**：不依赖 engine，仅依赖 run_options、globals、libs_process、libs_os、common、fork_child、thread_worker、build_options。
//!
//! ## 所有权与生命周期
//!
//! - process 对象及其属性、方法由 JSC 持有；Zig 侧不返回需调用方 free 的 [Allocates] 切片。
//! - `__dirname`、`__filename` 的字符串来自 RunOptions.entry_path，由调用方保证生命周期。
//! - `process.chdir()` 会更新 globals.process_cwd_override（由本模块 allocator.dupe，下次 chdir 时 free 旧值）。
//!
//! ## process 对象：属性（只读或可写）
//!
//! | 属性 | 类型 | 说明 |
//! |------|------|------|
//! | argv | string[] | 命令行参数（来自 RunOptions.argv） |
//! | argv0 | string | 可执行名或首参（无则 "shu"） |
//! | execArgv | string[] | 运行时专用参数（当前为空数组） |
//! | execPath | string | 可执行路径（argv[0]） |
//! | env | object | 环境变量（需 permissions.allow_env，否则 {}） |
//! | platform | string | darwin / linux / win32 等（libs_os.platformName） |
//! | arch | string | x64 / arm64 等（libs_os.archName） |
//! | pid | number | 进程 ID（仅 Unix，非 WASI/Windows） |
//! | ppid | number | 父进程 ID（仅 Unix） |
//! | exitCode | number | 退出码，可写；exit(code) 会同步更新 |
//! | version | string | 如 "v0.1.0"（build_options.version） |
//! | versions | object | { shu: version } |
//! | release | object | { name: "shu" } |
//! | title | string | 进程标题（当前为 "shu"） |
//! | allowedNodeEnvironmentFlags | string[] | 当前为空数组 |
//! | stdin | object | { fd: 0 } |
//! | stdout | object | { fd: 1, write(chunk) }，write 写入系统 stdout |
//! | stderr | object | { fd: 2, write(chunk) }，write 写入系统 stderr |
//! | _events | object | 内部事件表，供 on/emit/off 使用（Node EventEmitter 风格） |
//!
//! ## process 对象：方法
//!
//! | 方法 | 说明 |
//! |------|------|
//! | cwd() | 返回当前工作目录（优先 process_cwd_override，否则 RunOptions.cwd） |
//! | chdir(dir) | 切换当前工作目录（更新 process_cwd_override） |
//! | exit(code?) | 先触发 'beforeExit'/'exit' 事件，再设 exitCode 与 pending_process_exit；宿主 run 返回后应 std.process.exit |
//! | nextTick(cb) | 将 cb 加入微任务队列（与 queueMicrotask 同源） |
//! | uptime() | 进程运行秒数（浮点），依赖 process_start_time_ns 与 std.Io.Clock |
//! | hrtime([prev]) | 高精度时间 [sec, nsec]；传 prev 时返回与 prev 的差值 |
//! | hrtime.bigint() | 返回当前时间纳秒数（数字） |
//! | memoryUsage() | 返回 { rss, heapTotal, heapUsed, external, arrayBuffers }（当前为 stub 0） |
//! | cpuUsage([prev]) | 返回 { user, system } 微秒（当前为 stub 0） |
//! | emitWarning(msg[, type[, code]]) | 触发 process 'warning' 事件 |
//! | on(ev, fn) | 注册事件监听（EventEmitter 风格） |
//! | emit(ev, ...args) | 触发事件 |
//! | off(ev, fn?) | 移除监听器；不传 fn 则清空该事件 |
//! | getuid() / geteuid() / getgid() / getegid() | 仅 Unix（非 WASI/Windows），C getuid/getgid 等 |
//! | umask([mask]) | 仅 Unix，C umask |
//!
//! ## 事件
//!
//! - **beforeExit**：process.exit(code) 时先触发，参数为 exit code。
//! - **exit**：process.exit(code) 时随后触发，参数为 exit code；仅同步逻辑可执行。
//! - **warning**：由 process.emitWarning() 或内部触发，参数为 warning 对象/消息。
//! - 其他自定义事件可通过 process.on(name, fn) / process.emit(name, ...args) 使用。
//!
//! ## 全局变量（本 run 内）
//!
//! - **__dirname**：入口文件所在目录（RunOptions.entry_path 的 dirname）。
//! - **__filename**：入口文件绝对或相对路径（RunOptions.entry_path）。
//!
//! ## 条件挂载
//!
//! - **is_forked**：RunOptions.is_forked 为 true 时，由 fork_child 挂载 process.send / process.receiveSync（IPC）。
//! - **is_thread_worker**：RunOptions.is_thread_worker 且 thread_channel 非 null 时，由 thread_worker 挂载线程通道的 send/receiveSync。

const std = @import("std");
const builtin = @import("builtin");
const jsc = @import("jsc");
const errors = @import("errors");
const libs_process = @import("libs_process");
const libs_os = @import("libs_os");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");
const run_options_mod = @import("../../../run_options.zig");
const fork_child = @import("../cmd/fork_child.zig");
const thread_worker = @import("../threads/worker.zig");
const build_options = @import("build_options");

// 仅 Unix（非 WASI/Windows）下通过 C 获取 pid/ppid，与 Node process.pid/ppid 一致
const have_posix_pid = builtin.os.tag != .wasi and builtin.os.tag != .windows;
const posix_pid = if (have_posix_pid) struct {
    extern "c" fn getpid() i32;
    extern "c" fn getppid() i32;
    pub fn pid() i32 {
        return getpid();
    }
    pub fn ppid() i32 {
        return getppid();
    }
} else struct {
    pub fn pid() i32 {
        return 0;
    }
    pub fn ppid() i32 {
        return 0;
    }
};

// 与 shu:events 一致的 _events 键名，供 process.on/emit/off 使用
var k_events: jsc.JSStringRef = undefined;
var k_length: jsc.JSStringRef = undefined;
var k_push: jsc.JSStringRef = undefined;
var k_prototype: jsc.JSStringRef = undefined;
var process_strings_init = false;
fn ensureProcessStrings() void {
    if (process_strings_init) return;
    k_events = jsc.JSStringCreateWithUTF8CString("_events");
    k_length = jsc.JSStringCreateWithUTF8CString("length");
    k_push = jsc.JSStringCreateWithUTF8CString("push");
    k_prototype = jsc.JSStringCreateWithUTF8CString("prototype");
    process_strings_init = true;
}

/// process.on(event, fn)：与 Node EventEmitter 一致，供 process.on('exit', ...) 等
fn processOnCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return thisObject;
    ensureProcessStrings();
    const events_val = jsc.JSObjectGetProperty(ctx, thisObject, k_events, null);
    const events = jsc.JSValueToObject(ctx, events_val, null) orelse return thisObject;
    const name_str = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(name_str);
    const list_val = jsc.JSObjectGetProperty(ctx, events, name_str, null);
    const list_obj = jsc.JSValueToObject(ctx, list_val, null);
    if (list_obj == null) {
        var one: [1]jsc.JSValueRef = .{arguments[1]};
        const new_arr = jsc.JSObjectMakeArray(ctx, 1, &one, null);
        _ = jsc.JSObjectSetProperty(ctx, events, name_str, new_arr, jsc.kJSPropertyAttributeNone, null);
        return thisObject;
    }
    const global = jsc.JSContextGetGlobalObject(ctx);
    const arr_name = jsc.JSStringCreateWithUTF8CString("Array");
    defer jsc.JSStringRelease(arr_name);
    const arr_val = jsc.JSObjectGetProperty(ctx, global, arr_name, null);
    const arr_obj = jsc.JSValueToObject(ctx, arr_val, null) orelse return thisObject;
    const proto_val = jsc.JSObjectGetProperty(ctx, arr_obj, k_prototype, null);
    const proto_obj = jsc.JSValueToObject(ctx, proto_val, null) orelse return thisObject;
    const push_val = jsc.JSObjectGetProperty(ctx, proto_obj, k_push, null);
    const push_fn = jsc.JSValueToObject(ctx, push_val, null) orelse return thisObject;
    var args: [1]jsc.JSValueRef = .{arguments[1]};
    _ = jsc.JSObjectCallAsFunction(ctx, push_fn, list_obj, 1, &args, null);
    return thisObject;
}

/// process.emit(event, ...args)：与 Node EventEmitter 一致
fn processEmitCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeBoolean(ctx, false);
    ensureProcessStrings();
    const events_val = jsc.JSObjectGetProperty(ctx, thisObject, k_events, null);
    const events = jsc.JSValueToObject(ctx, events_val, null) orelse return jsc.JSValueMakeBoolean(ctx, false);
    const name_str = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(name_str);
    const list_val = jsc.JSObjectGetProperty(ctx, events, name_str, null);
    const list_obj = jsc.JSValueToObject(ctx, list_val, null) orelse return jsc.JSValueMakeBoolean(ctx, false);
    if (jsc.JSValueIsUndefined(ctx, list_val)) return jsc.JSValueMakeBoolean(ctx, false);
    const len_val = jsc.JSObjectGetProperty(ctx, list_obj, k_length, null);
    const len_f = jsc.JSValueToNumber(ctx, len_val, null);
    const len: usize = @intFromFloat(len_f);
    if (len == 0) return jsc.JSValueMakeBoolean(ctx, false);
    const argc = argumentCount -% 1;
    var no_args: [0]jsc.JSValueRef = undefined;
    const argv: [*]const jsc.JSValueRef = if (argc > 0) arguments + 1 else &no_args;
    var i: c_uint = 0;
    while (i < len) : (i += 1) {
        const fn_val = jsc.JSObjectGetPropertyAtIndex(ctx, list_obj, i, null);
        const fn_obj = jsc.JSValueToObject(ctx, fn_val, null) orelse continue;
        _ = jsc.JSObjectCallAsFunction(ctx, fn_obj, thisObject, argc, argv, null);
    }
    return jsc.JSValueMakeBoolean(ctx, true);
}

/// process.off(event, fn?)：与 Node EventEmitter 一致
fn processOffCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return thisObject;
    ensureProcessStrings();
    const events_val = jsc.JSObjectGetProperty(ctx, thisObject, k_events, null);
    const events = jsc.JSValueToObject(ctx, events_val, null) orelse return thisObject;
    const name_str = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(name_str);
    const list_val = jsc.JSObjectGetProperty(ctx, events, name_str, null);
    if (jsc.JSValueIsUndefined(ctx, list_val)) return thisObject;
    const list_obj = jsc.JSValueToObject(ctx, list_val, null) orelse return thisObject;
    const len_val = jsc.JSObjectGetProperty(ctx, list_obj, k_length, null);
    const len_f = jsc.JSValueToNumber(ctx, len_val, null);
    const len: usize = @intFromFloat(len_f);
    if (argumentCount < 2) {
        var empty_elems: [0]jsc.JSValueRef = undefined;
        const empty_arr = jsc.JSObjectMakeArray(ctx, 0, &empty_elems, null);
        _ = jsc.JSObjectSetProperty(ctx, events, name_str, empty_arr, jsc.kJSPropertyAttributeNone, null);
        return thisObject;
    }
    const fn_to_remove = arguments[1];
    var keep: [256]jsc.JSValueRef = undefined;
    var nkeep: usize = 0;
    var i: c_uint = 0;
    while (i < len and nkeep < 256) : (i += 1) {
        const v = jsc.JSObjectGetPropertyAtIndex(ctx, list_obj, i, null);
        if (v != fn_to_remove) {
            keep[nkeep] = v;
            nkeep += 1;
        }
    }
    var empty_off: [0]jsc.JSValueRef = undefined;
    const new_arr = jsc.JSObjectMakeArray(ctx, nkeep, if (nkeep > 0) &keep else &empty_off, null);
    _ = jsc.JSObjectSetProperty(ctx, events, name_str, new_arr, jsc.kJSPropertyAttributeNone, null);
    return thisObject;
}

/// process.nextTick(callback, ...args)：在下一轮微任务执行 callback，与 Node process.nextTick 一致
fn nextTickCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const callback = arguments[0];
    const timer_state = globals.current_timer_state orelse return jsc.JSValueMakeUndefined(ctx);
    _ = jsc.JSValueProtect(ctx, callback);
    timer_state.enqueueMicrotask(ctx, callback);
    return jsc.JSValueMakeUndefined(ctx);
}

/// process.chdir(directory)：切换当前工作目录（更新 process_cwd_override），与 Node process.chdir 一致
fn chdirCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const path_str = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(path_str);
    var buf: [4096]u8 = undefined;
    const n = jsc.JSStringGetMaximumUTF8CStringSize(path_str);
    if (n > buf.len) return jsc.JSValueMakeUndefined(ctx);
    const written = jsc.JSStringGetUTF8CString(path_str, buf[0..].ptr, buf.len);
    const path_slice = buf[0..written];
    if (path_slice.len == 0) return jsc.JSValueMakeUndefined(ctx);
    const path_z = allocator.dupeZ(u8, path_slice) catch return jsc.JSValueMakeUndefined(ctx);
    const path_owned = path_z[0 .. path_z.len - 1];
    if (globals.process_cwd_override) |old| allocator.free(old);
    globals.process_cwd_override = allocator.dupe(u8, path_owned) catch {
        allocator.free(path_z);
        return jsc.JSValueMakeUndefined(ctx);
    };
    allocator.free(path_z);
    return jsc.JSValueMakeUndefined(ctx);
}

/// process.uptime()：返回进程运行秒数（浮点），与 Node process.uptime 一致
fn uptimeCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const start = globals.process_start_time_ns;
    if (start == 0) return jsc.JSValueMakeNumber(ctx, 0);
    const io = libs_process.getProcessIo() orelse return jsc.JSValueMakeNumber(ctx, 0);
    const now_ns: u64 = @intCast(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds);
    const sec = @as(f64, @floatFromInt(now_ns - start)) / 1_000_000_000.0;
    return jsc.JSValueMakeNumber(ctx, sec);
}

/// process.hrtime(time?)：返回 [sec, nsec]，与 Node process.hrtime 一致
fn hrtimeCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const io = libs_process.getProcessIo() orelse {
        var zero: [2]jsc.JSValueRef = .{ jsc.JSValueMakeNumber(ctx, 0), jsc.JSValueMakeNumber(ctx, 0) };
        return jsc.JSObjectMakeArray(ctx, 2, &zero, null);
    };
    var ns: i64 = @intCast(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds);
    if (argumentCount >= 1) {
        const prev_val = arguments[0];
        if (jsc.JSValueToObject(ctx, prev_val, null)) |prev_obj| {
            const k0 = jsc.JSStringCreateWithUTF8CString("0");
            defer jsc.JSStringRelease(k0);
            const k1 = jsc.JSStringCreateWithUTF8CString("1");
            defer jsc.JSStringRelease(k1);
            const s = jsc.JSObjectGetProperty(ctx, prev_obj, k0, null);
            const n = jsc.JSObjectGetProperty(ctx, prev_obj, k1, null);
            const sec_prev = jsc.JSValueToNumber(ctx, s, null);
            const nsec_prev = jsc.JSValueToNumber(ctx, n, null);
            const prev_ns = @as(i64, @intFromFloat(sec_prev)) * std.time.ns_per_s + @as(i64, @intFromFloat(nsec_prev));
            ns -= prev_ns;
        }
    }
    const sec = @divTrunc(ns, std.time.ns_per_s);
    const nsec = ns - sec * std.time.ns_per_s;
    var arr: [2]jsc.JSValueRef = .{
        jsc.JSValueMakeNumber(ctx, @floatFromInt(sec)),
        jsc.JSValueMakeNumber(ctx, @floatFromInt(nsec)),
    };
    return jsc.JSObjectMakeArray(ctx, 2, &arr, null);
}

/// process.hrtime.bigint()：返回纳秒大整数，与 Node process.hrtime.bigint 一致
fn hrtimeBigintCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const io = libs_process.getProcessIo() orelse return jsc.JSValueMakeNumber(ctx, 0);
    const ns: i64 = @intCast(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds);
    return jsc.JSValueMakeNumber(ctx, @floatFromInt(ns));
}

/// process.memoryUsage()：返回 { rss, heapTotal, heapUsed, external, arrayBuffers }，与 Node 一致；当前为 stub
fn memoryUsageCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const obj = jsc.JSObjectMake(ctx, null, null);
    const k_rss = jsc.JSStringCreateWithUTF8CString("rss");
    defer jsc.JSStringRelease(k_rss);
    const k_heapTotal = jsc.JSStringCreateWithUTF8CString("heapTotal");
    defer jsc.JSStringRelease(k_heapTotal);
    const k_heapUsed = jsc.JSStringCreateWithUTF8CString("heapUsed");
    defer jsc.JSStringRelease(k_heapUsed);
    const k_external = jsc.JSStringCreateWithUTF8CString("external");
    defer jsc.JSStringRelease(k_external);
    const k_arrayBuffers = jsc.JSStringCreateWithUTF8CString("arrayBuffers");
    defer jsc.JSStringRelease(k_arrayBuffers);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_rss, jsc.JSValueMakeNumber(ctx, 0), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_heapTotal, jsc.JSValueMakeNumber(ctx, 0), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_heapUsed, jsc.JSValueMakeNumber(ctx, 0), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_external, jsc.JSValueMakeNumber(ctx, 0), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_arrayBuffers, jsc.JSValueMakeNumber(ctx, 0), jsc.kJSPropertyAttributeNone, null);
    return obj;
}

/// process.cpuUsage(prev?)：返回 { user, system } 微秒，与 Node 一致；当前为 stub
fn cpuUsageCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const obj = jsc.JSObjectMake(ctx, null, null);
    const k_user = jsc.JSStringCreateWithUTF8CString("user");
    defer jsc.JSStringRelease(k_user);
    const k_system = jsc.JSStringCreateWithUTF8CString("system");
    defer jsc.JSStringRelease(k_system);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_user, jsc.JSValueMakeNumber(ctx, 0), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_system, jsc.JSValueMakeNumber(ctx, 0), jsc.kJSPropertyAttributeNone, null);
    return obj;
}

/// process.stdout.write(chunk) / process.stderr.write(chunk)：写入系统 stdout/stderr
fn stdoutWriteCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeBoolean(ctx, true);
    const io = libs_process.getProcessIo() orelse return jsc.JSValueMakeBoolean(ctx, true);
    const val = arguments[0];
    const str_ref = jsc.JSValueToStringCopy(ctx, val, null);
    defer jsc.JSStringRelease(str_ref);
    var buf: [4096]u8 = undefined;
    const n = jsc.JSStringGetMaximumUTF8CStringSize(str_ref);
    if (n > buf.len) return jsc.JSValueMakeBoolean(ctx, false);
    const written = jsc.JSStringGetUTF8CString(str_ref, buf[0..].ptr, buf.len);
    std.Io.File.stdout().writeStreamingAll(io, buf[0..written]) catch return jsc.JSValueMakeBoolean(ctx, false);
    return jsc.JSValueMakeBoolean(ctx, true);
}

fn stderrWriteCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeBoolean(ctx, true);
    const io = libs_process.getProcessIo() orelse return jsc.JSValueMakeBoolean(ctx, true);
    const val = arguments[0];
    const str_ref = jsc.JSValueToStringCopy(ctx, val, null);
    defer jsc.JSStringRelease(str_ref);
    var buf: [4096]u8 = undefined;
    const n = jsc.JSStringGetMaximumUTF8CStringSize(str_ref);
    if (n > buf.len) return jsc.JSValueMakeBoolean(ctx, false);
    const written = jsc.JSStringGetUTF8CString(str_ref, buf[0..].ptr, buf.len);
    std.Io.File.stderr().writeStreamingAll(io, buf[0..written]) catch return jsc.JSValueMakeBoolean(ctx, false);
    return jsc.JSValueMakeBoolean(ctx, true);
}

/// process.emitWarning(message[, type[, code]])：触发 process 'warning' 事件，与 Node 一致
fn emitWarningCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const msg_val = arguments[0];
    const k_emit = jsc.JSStringCreateWithUTF8CString("emit");
    defer jsc.JSStringRelease(k_emit);
    const emit_val = jsc.JSObjectGetProperty(ctx, this, k_emit, null);
    const emit_fn = jsc.JSValueToObject(ctx, emit_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const k_warning = jsc.JSStringCreateWithUTF8CString("warning");
    defer jsc.JSStringRelease(k_warning);
    var args: [2]jsc.JSValueRef = .{ jsc.JSValueMakeString(ctx, k_warning), msg_val };
    _ = jsc.JSObjectCallAsFunction(ctx, emit_fn, this, 2, &args, null);
    return jsc.JSValueMakeUndefined(ctx);
}

// POSIX getuid/geteuid/getgid/getegid/umask（仅 Unix 非 WASI/Windows）；extern 加 c_ 前缀避免与 pub fn 同名
const posix_uid = if (have_posix_pid) struct {
    extern "c" fn getuid() callconv(.c) u32;
    extern "c" fn geteuid() callconv(.c) u32;
    extern "c" fn getgid() callconv(.c) u32;
    extern "c" fn getegid() callconv(.c) u32;
    extern "c" fn umask(mask: u32) callconv(.c) u32;
    pub fn uid() u32 { return getuid(); }
    pub fn euid() u32 { return geteuid(); }
    pub fn gid() u32 { return getgid(); }
    pub fn egid() u32 { return getegid(); }
    pub fn mask(m: u32) u32 { return umask(m); }
} else struct {
    pub fn uid() u32 { return 0; }
    pub fn euid() u32 { return 0; }
    pub fn gid() u32 { return 0; }
    pub fn egid() u32 { return 0; }
    pub fn mask(_: u32) u32 { return 0; }
};

fn getuidCallback(ctx: jsc.JSContextRef, _: jsc.JSObjectRef, _: jsc.JSObjectRef, _: usize, _: [*]const jsc.JSValueRef, _: [*]jsc.JSValueRef) callconv(.c) jsc.JSValueRef {
    return jsc.JSValueMakeNumber(ctx, @floatFromInt(posix_uid.uid()));
}
fn geteuidCallback(ctx: jsc.JSContextRef, _: jsc.JSObjectRef, _: jsc.JSObjectRef, _: usize, _: [*]const jsc.JSValueRef, _: [*]jsc.JSValueRef) callconv(.c) jsc.JSValueRef {
    return jsc.JSValueMakeNumber(ctx, @floatFromInt(posix_uid.euid()));
}
fn getgidCallback(ctx: jsc.JSContextRef, _: jsc.JSObjectRef, _: jsc.JSObjectRef, _: usize, _: [*]const jsc.JSValueRef, _: [*]jsc.JSValueRef) callconv(.c) jsc.JSValueRef {
    return jsc.JSValueMakeNumber(ctx, @floatFromInt(posix_uid.gid()));
}
fn getegidCallback(ctx: jsc.JSContextRef, _: jsc.JSObjectRef, _: jsc.JSObjectRef, _: usize, _: [*]const jsc.JSValueRef, _: [*]jsc.JSValueRef) callconv(.c) jsc.JSValueRef {
    return jsc.JSValueMakeNumber(ctx, @floatFromInt(posix_uid.egid()));
}
fn umaskCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const mask: u32 = if (argumentCount >= 1) @intFromFloat(jsc.JSValueToNumber(ctx, arguments[0], null)) else 0;
    return jsc.JSValueMakeNumber(ctx, @floatFromInt(posix_uid.mask(mask)));
}

/// process.cwd()：返回当前工作目录（优先 process_cwd_override，否则 current_run_options.cwd），与 Node process.cwd() 一致
fn cwdCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const cwd_slice = globals.process_cwd_override orelse blk: {
        const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
        break :blk opts.cwd;
    };
    var buf: [4096]u8 = undefined;
    const len = @min(cwd_slice.len, buf.len - 1);
    @memcpy(buf[0..len], cwd_slice[0..len]);
    buf[len] = 0;
    const cwd_js = jsc.JSStringCreateWithUTF8CString(buf[0..].ptr);
    defer jsc.JSStringRelease(cwd_js);
    return jsc.JSValueMakeString(ctx, cwd_js);
}

/// process.exit(code?)：先触发 beforeExit/exit 事件，再设置 exitCode 与 pending_process_exit；宿主在 run 返回后应检查并 std.process.exit
fn exitCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const code: u8 = if (argumentCount >= 1)
        @intCast(@min(255, @max(0, @as(i32, @intFromFloat(jsc.JSValueToNumber(ctx, arguments[0], null))))))
    else
        0;
    const code_val = jsc.JSValueMakeNumber(ctx, @floatFromInt(code));
    const k_emit = jsc.JSStringCreateWithUTF8CString("emit");
    defer jsc.JSStringRelease(k_emit);
    const emit_val = jsc.JSObjectGetProperty(ctx, this, k_emit, null);
    const emit_fn = jsc.JSValueToObject(ctx, emit_val, null);
    if (emit_fn) |fn_obj| {
        const k_beforeExit = jsc.JSStringCreateWithUTF8CString("beforeExit");
        defer jsc.JSStringRelease(k_beforeExit);
        const k_exit = jsc.JSStringCreateWithUTF8CString("exit");
        defer jsc.JSStringRelease(k_exit);
        var before_args: [2]jsc.JSValueRef = .{ jsc.JSValueMakeString(ctx, k_beforeExit), code_val };
        var exit_args: [2]jsc.JSValueRef = .{ jsc.JSValueMakeString(ctx, k_exit), code_val };
        _ = jsc.JSObjectCallAsFunction(ctx, fn_obj, this, 2, &before_args, null);
        _ = jsc.JSObjectCallAsFunction(ctx, fn_obj, this, 2, &exit_args, null);
    }
    const k_exitCode = jsc.JSStringCreateWithUTF8CString("exitCode");
    defer jsc.JSStringRelease(k_exitCode);
    _ = jsc.JSObjectSetProperty(ctx, this, k_exitCode, code_val, jsc.kJSPropertyAttributeNone, null);
    globals.pending_process_exit = code;
    return jsc.JSValueMakeUndefined(ctx);
}

/// 向全局对象注入 process（Node 兼容：_events、on/emit/off、cwd、chdir、argv、argv0、execArgv、env、platform、arch、pid、ppid、exitCode、exit、version、versions、execPath、release、title、stdin/stdout/stderr、nextTick、uptime、hrtime、memoryUsage、cpuUsage、emitWarning、getuid/getgid/umask 等）、__dirname、__filename；is_forked 时挂 send/receiveSync
/// 由 bindings.registerGlobals 在 options 非 null 时调用；allocator/options 由调用方保证有效
pub fn register(allocator: std.mem.Allocator, ctx: jsc.JSGlobalContextRef, options: *const run_options_mod.RunOptions) void {
    const global = jsc.JSContextGetGlobalObject(ctx);

    if (libs_process.getProcessIo()) |io| {
        globals.process_start_time_ns = @intCast(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds);
    }

    var argv_vals: [256]jsc.JSValueRef = undefined;
    var str_refs: [256]jsc.JSStringRef = undefined;
    var argc: usize = 0;
    const argv_limit = @min(options.argv.len, argv_vals.len);
    for (options.argv[0..argv_limit], 0..) |arg, i| {
        const z = allocator.dupeZ(u8, arg) catch break;
        defer allocator.free(z);
        str_refs[i] = jsc.JSStringCreateWithUTF8CString(z.ptr);
        argv_vals[i] = jsc.JSValueMakeString(ctx, str_refs[i]);
        argc = i + 1;
    }
    const arr = jsc.JSObjectMakeArray(ctx, argc, &argv_vals, null);
    for (0..argc) |i| jsc.JSStringRelease(str_refs[i]);

    const name_process = jsc.JSStringCreateWithUTF8CString("process");
    defer jsc.JSStringRelease(name_process);
    const process_obj = jsc.JSObjectMake(ctx, null, null);

    ensureProcessStrings();
    const empty_events = jsc.JSObjectMake(ctx, null, null);
    _ = jsc.JSObjectSetProperty(ctx, process_obj, k_events, empty_events, jsc.kJSPropertyAttributeNone, null);
    common.setMethod(ctx, process_obj, "on", processOnCallback);
    common.setMethod(ctx, process_obj, "emit", processEmitCallback);
    common.setMethod(ctx, process_obj, "off", processOffCallback);

    const name_cwd = jsc.JSStringCreateWithUTF8CString("cwd");
    defer jsc.JSStringRelease(name_cwd);
    const k_cwd_fn = jsc.JSStringCreateWithUTF8CString("");
    defer jsc.JSStringRelease(k_cwd_fn);
    const cwd_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_cwd_fn, cwdCallback);
    _ = jsc.JSObjectSetProperty(ctx, process_obj, name_cwd, cwd_fn, jsc.kJSPropertyAttributeNone, null);

    const name_argv = jsc.JSStringCreateWithUTF8CString("argv");
    defer jsc.JSStringRelease(name_argv);
    _ = jsc.JSObjectSetProperty(ctx, process_obj, name_argv, arr, jsc.kJSPropertyAttributeNone, null);

    const name_platform = jsc.JSStringCreateWithUTF8CString("platform");
    defer jsc.JSStringRelease(name_platform);
    const platform_js = jsc.JSStringCreateWithUTF8CString(libs_os.platformName().ptr);
    defer jsc.JSStringRelease(platform_js);
    _ = jsc.JSObjectSetProperty(ctx, process_obj, name_platform, jsc.JSValueMakeString(ctx, platform_js), jsc.kJSPropertyAttributeNone, null);

    const name_arch = jsc.JSStringCreateWithUTF8CString("arch");
    defer jsc.JSStringRelease(name_arch);
    const arch_js = jsc.JSStringCreateWithUTF8CString(libs_os.archName().ptr);
    defer jsc.JSStringRelease(arch_js);
    _ = jsc.JSObjectSetProperty(ctx, process_obj, name_arch, jsc.JSValueMakeString(ctx, arch_js), jsc.kJSPropertyAttributeNone, null);

    if (have_posix_pid) {
        const name_pid = jsc.JSStringCreateWithUTF8CString("pid");
        defer jsc.JSStringRelease(name_pid);
        const pid = posix_pid.pid();
        _ = jsc.JSObjectSetProperty(ctx, process_obj, name_pid, jsc.JSValueMakeNumber(ctx, @floatFromInt(pid)), jsc.kJSPropertyAttributeNone, null);
        const name_ppid = jsc.JSStringCreateWithUTF8CString("ppid");
        defer jsc.JSStringRelease(name_ppid);
        const ppid = posix_pid.ppid();
        _ = jsc.JSObjectSetProperty(ctx, process_obj, name_ppid, jsc.JSValueMakeNumber(ctx, @floatFromInt(ppid)), jsc.kJSPropertyAttributeNone, null);
    }

    const name_exitCode = jsc.JSStringCreateWithUTF8CString("exitCode");
    defer jsc.JSStringRelease(name_exitCode);
    _ = jsc.JSObjectSetProperty(ctx, process_obj, name_exitCode, jsc.JSValueMakeNumber(ctx, 0), jsc.kJSPropertyAttributeNone, null);

    const name_exit = jsc.JSStringCreateWithUTF8CString("exit");
    defer jsc.JSStringRelease(name_exit);
    const k_exit_fn = jsc.JSStringCreateWithUTF8CString("exit");
    defer jsc.JSStringRelease(k_exit_fn);
    const exit_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_exit_fn, exitCallback);
    _ = jsc.JSObjectSetProperty(ctx, process_obj, name_exit, exit_fn, jsc.kJSPropertyAttributeNone, null);

    common.setMethod(ctx, process_obj, "nextTick", nextTickCallback);
    common.setMethod(ctx, process_obj, "chdir", chdirCallback);
    common.setMethod(ctx, process_obj, "uptime", uptimeCallback);
    common.setMethod(ctx, process_obj, "memoryUsage", memoryUsageCallback);
    common.setMethod(ctx, process_obj, "cpuUsage", cpuUsageCallback);
    common.setMethod(ctx, process_obj, "emitWarning", emitWarningCallback);

    const name_hrtime = jsc.JSStringCreateWithUTF8CString("hrtime");
    defer jsc.JSStringRelease(name_hrtime);
    const hrtime_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, name_hrtime, hrtimeCallback);
    const k_bigint = jsc.JSStringCreateWithUTF8CString("bigint");
    defer jsc.JSStringRelease(k_bigint);
    const hrtime_bigint_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_bigint, hrtimeBigintCallback);
    _ = jsc.JSObjectSetProperty(ctx, hrtime_fn, k_bigint, hrtime_bigint_fn, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, process_obj, name_hrtime, hrtime_fn, jsc.kJSPropertyAttributeNone, null);

    const name_argv0 = jsc.JSStringCreateWithUTF8CString("argv0");
    defer jsc.JSStringRelease(name_argv0);
    var argv0_js: jsc.JSStringRef = undefined;
    if (options.argv.len > 0) {
        const argv0_z = allocator.dupeZ(u8, options.argv[0]) catch return;
        defer allocator.free(argv0_z);
        argv0_js = jsc.JSStringCreateWithUTF8CString(argv0_z.ptr);
    } else {
        argv0_js = jsc.JSStringCreateWithUTF8CString("shu");
    }
    defer jsc.JSStringRelease(argv0_js);
    _ = jsc.JSObjectSetProperty(ctx, process_obj, name_argv0, jsc.JSValueMakeString(ctx, argv0_js), jsc.kJSPropertyAttributeNone, null);

    var exec_argv_empty: [0]jsc.JSValueRef = .{};
    const exec_argv_arr = jsc.JSObjectMakeArray(ctx, 0, &exec_argv_empty, null);
    const name_execArgv = jsc.JSStringCreateWithUTF8CString("execArgv");
    defer jsc.JSStringRelease(name_execArgv);
    _ = jsc.JSObjectSetProperty(ctx, process_obj, name_execArgv, exec_argv_arr, jsc.kJSPropertyAttributeNone, null);

    const name_release = jsc.JSStringCreateWithUTF8CString("release");
    defer jsc.JSStringRelease(name_release);
    const release_obj = jsc.JSObjectMake(ctx, null, null);
    const k_name = jsc.JSStringCreateWithUTF8CString("name");
    defer jsc.JSStringRelease(k_name);
    const release_name_js = jsc.JSStringCreateWithUTF8CString("shu");
    defer jsc.JSStringRelease(release_name_js);
    _ = jsc.JSObjectSetProperty(ctx, release_obj, k_name, jsc.JSValueMakeString(ctx, release_name_js), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, process_obj, name_release, release_obj, jsc.kJSPropertyAttributeNone, null);

    const name_title = jsc.JSStringCreateWithUTF8CString("title");
    defer jsc.JSStringRelease(name_title);
    const title_js = jsc.JSStringCreateWithUTF8CString("shu");
    defer jsc.JSStringRelease(title_js);
    _ = jsc.JSObjectSetProperty(ctx, process_obj, name_title, jsc.JSValueMakeString(ctx, title_js), jsc.kJSPropertyAttributeNone, null);

    const name_allowedNodeEnvironmentFlags = jsc.JSStringCreateWithUTF8CString("allowedNodeEnvironmentFlags");
    defer jsc.JSStringRelease(name_allowedNodeEnvironmentFlags);
    const allowed_arr = jsc.JSObjectMakeArray(ctx, 0, &exec_argv_empty, null);
    _ = jsc.JSObjectSetProperty(ctx, process_obj, name_allowedNodeEnvironmentFlags, allowed_arr, jsc.kJSPropertyAttributeNone, null);

    const name_stdin = jsc.JSStringCreateWithUTF8CString("stdin");
    defer jsc.JSStringRelease(name_stdin);
    const stdin_obj = jsc.JSObjectMake(ctx, null, null);
    const k_fd = jsc.JSStringCreateWithUTF8CString("fd");
    defer jsc.JSStringRelease(k_fd);
    _ = jsc.JSObjectSetProperty(ctx, stdin_obj, k_fd, jsc.JSValueMakeNumber(ctx, 0), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, process_obj, name_stdin, stdin_obj, jsc.kJSPropertyAttributeNone, null);

    const name_stdout = jsc.JSStringCreateWithUTF8CString("stdout");
    defer jsc.JSStringRelease(name_stdout);
    const stdout_obj = jsc.JSObjectMake(ctx, null, null);
    _ = jsc.JSObjectSetProperty(ctx, stdout_obj, k_fd, jsc.JSValueMakeNumber(ctx, 1), jsc.kJSPropertyAttributeNone, null);
    common.setMethod(ctx, stdout_obj, "write", stdoutWriteCallback);
    _ = jsc.JSObjectSetProperty(ctx, process_obj, name_stdout, stdout_obj, jsc.kJSPropertyAttributeNone, null);

    const name_stderr = jsc.JSStringCreateWithUTF8CString("stderr");
    defer jsc.JSStringRelease(name_stderr);
    const stderr_obj = jsc.JSObjectMake(ctx, null, null);
    _ = jsc.JSObjectSetProperty(ctx, stderr_obj, k_fd, jsc.JSValueMakeNumber(ctx, 2), jsc.kJSPropertyAttributeNone, null);
    common.setMethod(ctx, stderr_obj, "write", stderrWriteCallback);
    _ = jsc.JSObjectSetProperty(ctx, process_obj, name_stderr, stderr_obj, jsc.kJSPropertyAttributeNone, null);

    if (have_posix_pid) {
        common.setMethod(ctx, process_obj, "getuid", getuidCallback);
        common.setMethod(ctx, process_obj, "geteuid", geteuidCallback);
        common.setMethod(ctx, process_obj, "getgid", getgidCallback);
        common.setMethod(ctx, process_obj, "getegid", getegidCallback);
        common.setMethod(ctx, process_obj, "umask", umaskCallback);
    }

    const name_version = jsc.JSStringCreateWithUTF8CString("version");
    defer jsc.JSStringRelease(name_version);
    var version_buf: [64]u8 = undefined;
    const version_slice = std.fmt.bufPrint(version_buf[0..], "v{s}", .{build_options.version}) catch return;
    version_buf[version_slice.len] = 0;
    const version_js = jsc.JSStringCreateWithUTF8CString(version_buf[0..].ptr);
    defer jsc.JSStringRelease(version_js);
    _ = jsc.JSObjectSetProperty(ctx, process_obj, name_version, jsc.JSValueMakeString(ctx, version_js), jsc.kJSPropertyAttributeNone, null);

    const name_versions = jsc.JSStringCreateWithUTF8CString("versions");
    defer jsc.JSStringRelease(name_versions);
    const versions_obj = jsc.JSObjectMake(ctx, null, null);
    const k_shu = jsc.JSStringCreateWithUTF8CString("shu");
    defer jsc.JSStringRelease(k_shu);
    const ver_js = jsc.JSStringCreateWithUTF8CString(build_options.version);
    defer jsc.JSStringRelease(ver_js);
    _ = jsc.JSObjectSetProperty(ctx, versions_obj, k_shu, jsc.JSValueMakeString(ctx, ver_js), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, process_obj, name_versions, versions_obj, jsc.kJSPropertyAttributeNone, null);

    if (options.argv.len > 0) {
        const name_execPath = jsc.JSStringCreateWithUTF8CString("execPath");
        defer jsc.JSStringRelease(name_execPath);
        const exec_z = allocator.dupeZ(u8, options.argv[0]) catch return;
        defer allocator.free(exec_z);
        const exec_js = jsc.JSStringCreateWithUTF8CString(exec_z.ptr);
        defer jsc.JSStringRelease(exec_js);
        _ = jsc.JSObjectSetProperty(ctx, process_obj, name_execPath, jsc.JSValueMakeString(ctx, exec_js), jsc.kJSPropertyAttributeNone, null);
    }

    const name_env = jsc.JSStringCreateWithUTF8CString("env");
    defer jsc.JSStringRelease(name_env);
    const env_obj = jsc.JSObjectMake(ctx, null, null);
    if (options.permissions.allow_env) {
        const env_block = libs_process.getProcessEnviron() orelse return;
        var env_map = std.process.Environ.createMap(env_block, allocator) catch return;
        defer env_map.deinit();
        const keys = env_map.keys();
        const vals = env_map.values();
        for (keys, vals) |k, v| {
            const k_z = allocator.dupeZ(u8, k) catch continue;
            defer allocator.free(k_z);
            const v_z = allocator.dupeZ(u8, v) catch continue;
            defer allocator.free(v_z);
            const k_ref = jsc.JSStringCreateWithUTF8CString(k_z.ptr);
            defer jsc.JSStringRelease(k_ref);
            const v_ref = jsc.JSStringCreateWithUTF8CString(v_z.ptr);
            defer jsc.JSStringRelease(v_ref);
            _ = jsc.JSObjectSetProperty(ctx, env_obj, k_ref, jsc.JSValueMakeString(ctx, v_ref), jsc.kJSPropertyAttributeNone, null);
        }
    }
    _ = jsc.JSObjectSetProperty(ctx, process_obj, name_env, env_obj, jsc.kJSPropertyAttributeNone, null);

    if (options.is_forked) {
        _ = fork_child.start(allocator) catch return;
        fork_child.registerProcessForked(ctx, process_obj);
    }
    if (options.is_thread_worker and options.thread_channel != null) {
        thread_worker.registerProcessThreaded(ctx, process_obj, options.thread_channel.?);
    }

    _ = jsc.JSObjectSetProperty(ctx, global, name_process, process_obj, jsc.kJSPropertyAttributeNone, null);

    const dirname = std.fs.path.dirname(options.entry_path) orelse ".";
    const dirname_z = allocator.dupeZ(u8, dirname) catch return;
    defer allocator.free(dirname_z);
    const dirname_js = jsc.JSStringCreateWithUTF8CString(dirname_z.ptr);
    defer jsc.JSStringRelease(dirname_js);
    const name_dirname = jsc.JSStringCreateWithUTF8CString("__dirname");
    defer jsc.JSStringRelease(name_dirname);
    _ = jsc.JSObjectSetProperty(ctx, global, name_dirname, jsc.JSValueMakeString(ctx, dirname_js), jsc.kJSPropertyAttributeNone, null);

    const filename_z = allocator.dupeZ(u8, options.entry_path) catch return;
    defer allocator.free(filename_z);
    const filename_js = jsc.JSStringCreateWithUTF8CString(filename_z.ptr);
    defer jsc.JSStringRelease(filename_js);
    const name_filename = jsc.JSStringCreateWithUTF8CString("__filename");
    defer jsc.JSStringRelease(name_filename);
    _ = jsc.JSObjectSetProperty(ctx, global, name_filename, jsc.JSValueMakeString(ctx, filename_js), jsc.kJSPropertyAttributeNone, null);
}

/// 返回 shu:process 的 exports（即 globalThis.process，与 register 注册的 process 同一引用）
pub fn getExports(ctx: jsc.JSContextRef, _: std.mem.Allocator) jsc.JSValueRef {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const name = jsc.JSStringCreateWithUTF8CString("process");
    defer jsc.JSStringRelease(name);
    const val = jsc.JSObjectGetProperty(ctx, global, name, null);
    return val;
}
