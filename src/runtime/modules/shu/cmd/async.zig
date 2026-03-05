//! cmd 异步 API 纯 Zig 实现：用 Promise(executor) + queueMicrotask 延后执行同步逻辑并 resolve，无内联 JS。
//! 供 exec.zig、run.zig、spawn.zig 的 exec/run/spawn 回调使用。

const std = @import("std");
const jsc = @import("jsc");
const globals = @import("../../../globals.zig");
const libs_process = @import("libs_process");
const promise = @import("../promise.zig");
const child_run = @import("child_run.zig");
const run_mod = @import("run.zig");
const system_allocator = @import("allocator.zig");

const k_holder = "holder";
const k_resolve = "resolve";
const k_reject = "reject";
const k_cmd = "cmd";
const k_options = "options";

/// 从 JS 值取 UTF-8 字符串；返回的切片由调用方 free。
fn jsValueToUtf8(allocator: std.mem.Allocator, ctx: jsc.JSContextRef, val: jsc.JSValueRef) ?[]const u8 {
    const str_ref = jsc.JSValueToStringCopy(ctx, val, null);
    defer jsc.JSStringRelease(str_ref);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(str_ref);
    if (max_sz == 0 or max_sz > 65536) return null;
    const buf = allocator.alloc(u8, max_sz) catch return null;
    defer allocator.free(buf);
    const n = jsc.JSStringGetUTF8CString(str_ref, buf.ptr, max_sz);
    if (n == 0) return null;
    return allocator.dupe(u8, buf[0 .. n - 1]) catch null;
}

/// 微任务回调：从 holder 取 resolve/reject 与参数，执行 execSync 逻辑后 resolve(result)
fn execDeferredCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    callee: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const k_holder_ref = jsc.JSStringCreateWithUTF8CString(k_holder);
    defer jsc.JSStringRelease(k_holder_ref);
    const holder_val = jsc.JSObjectGetProperty(ctx, callee, k_holder_ref, null);
    const holder = jsc.JSValueToObject(ctx, holder_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const k_resolve_ref = jsc.JSStringCreateWithUTF8CString(k_resolve);
    defer jsc.JSStringRelease(k_resolve_ref);
    const k_reject_ref = jsc.JSStringCreateWithUTF8CString(k_reject);
    defer jsc.JSStringRelease(k_reject_ref);
    const k_cmd_ref = jsc.JSStringCreateWithUTF8CString(k_cmd);
    defer jsc.JSStringRelease(k_cmd_ref);
    const resolve_val = jsc.JSObjectGetProperty(ctx, holder, k_resolve_ref, null);
    const reject_val = jsc.JSObjectGetProperty(ctx, holder, k_reject_ref, null);
    const allocator = system_allocator.get() orelse {
        _ = jsCall(ctx, reject_val, 0, null);
        jsc.JSValueUnprotect(@ptrCast(ctx), holder);
        return jsc.JSValueMakeUndefined(ctx);
    };
    const cmd_val = jsc.JSObjectGetProperty(ctx, holder, k_cmd_ref, null);
    const cmd_slice = jsValueToUtf8(allocator, ctx, cmd_val) orelse {
        _ = jsCall(ctx, reject_val, 0, null);
        jsc.JSValueUnprotect(@ptrCast(ctx), holder);
        return jsc.JSValueMakeUndefined(ctx);
    };
    defer allocator.free(cmd_slice);
    const opts = globals.current_run_options orelse {
        _ = jsCall(ctx, reject_val, 0, null);
        jsc.JSValueUnprotect(@ptrCast(ctx), holder);
        return jsc.JSValueMakeUndefined(ctx);
    };
    const io = libs_process.getProcessIo() orelse {
        _ = jsCall(ctx, reject_val, 0, null);
        jsc.JSValueUnprotect(@ptrCast(ctx), holder);
        return jsc.JSValueMakeUndefined(ctx);
    };
    const argv = [_][]const u8{ "sh", "-c", cmd_slice };
    const result = child_run.runProcess(allocator, &argv, opts.cwd, io) catch {
        _ = jsCall(ctx, reject_val, 0, null);
        jsc.JSValueUnprotect(@ptrCast(ctx), holder);
        return jsc.JSValueMakeUndefined(ctx);
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const result_obj = execMakeResultObject(ctx, result.stdout, result.stderr, result.code);
    var one: [1]jsc.JSValueRef = .{result_obj};
    _ = jsCall(ctx, resolve_val, 1, &one);
    jsc.JSValueUnprotect(@ptrCast(ctx), holder);
    return jsc.JSValueMakeUndefined(ctx);
}

fn jsCall(ctx: jsc.JSContextRef, fn_val: jsc.JSValueRef, argc: usize, args: ?[*]const jsc.JSValueRef) jsc.JSValueRef {
    const fn_obj = jsc.JSValueToObject(ctx, fn_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const a = args orelse @as([*]const jsc.JSValueRef, &[_]jsc.JSValueRef{});
    return jsc.JSObjectCallAsFunction(ctx, fn_obj, null, argc, a, null);
}

/// 创建 { stdout, stderr, code } 的 JS 对象（与 exec.zig makeExecResultObject 一致）
fn execMakeResultObject(ctx: jsc.JSContextRef, stdout: []const u8, stderr: []const u8, code: u8) jsc.JSValueRef {
    const allocator = system_allocator.get() orelse return jsc.JSObjectMake(ctx, null, null);
    const stdout_z = allocator.dupeZ(u8, stdout) catch return jsc.JSObjectMake(ctx, null, null);
    defer allocator.free(stdout_z);
    const stderr_z = allocator.dupeZ(u8, stderr) catch return jsc.JSObjectMake(ctx, null, null);
    defer allocator.free(stderr_z);
    const obj = jsc.JSObjectMake(ctx, null, null);
    const k_stdout = jsc.JSStringCreateWithUTF8CString("stdout");
    defer jsc.JSStringRelease(k_stdout);
    const k_stderr = jsc.JSStringCreateWithUTF8CString("stderr");
    defer jsc.JSStringRelease(k_stderr);
    const k_code = jsc.JSStringCreateWithUTF8CString("code");
    defer jsc.JSStringRelease(k_code);
    const stdout_ref = jsc.JSStringCreateWithUTF8CString(stdout_z.ptr);
    defer jsc.JSStringRelease(stdout_ref);
    const stderr_ref = jsc.JSStringCreateWithUTF8CString(stderr_z.ptr);
    defer jsc.JSStringRelease(stderr_ref);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_stdout, jsc.JSValueMakeString(ctx, stdout_ref), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_stderr, jsc.JSValueMakeString(ctx, stderr_ref), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_code, jsc.JSValueMakeNumber(ctx, @floatFromInt(code)), jsc.kJSPropertyAttributeNone, null);
    return obj;
}

/// 微任务回调：从 holder 取 resolve/reject 与 options，执行 runSync 逻辑后 resolve(result)
fn runDeferredCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    callee: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const k_holder_ref = jsc.JSStringCreateWithUTF8CString(k_holder);
    defer jsc.JSStringRelease(k_holder_ref);
    const holder_val = jsc.JSObjectGetProperty(ctx, callee, k_holder_ref, null);
    const holder = jsc.JSValueToObject(ctx, holder_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const k_resolve_ref = jsc.JSStringCreateWithUTF8CString(k_resolve);
    defer jsc.JSStringRelease(k_resolve_ref);
    const k_reject_ref = jsc.JSStringCreateWithUTF8CString(k_reject);
    defer jsc.JSStringRelease(k_reject_ref);
    const k_options_ref = jsc.JSStringCreateWithUTF8CString(k_options);
    defer jsc.JSStringRelease(k_options_ref);
    const resolve_val = jsc.JSObjectGetProperty(ctx, holder, k_resolve_ref, null);
    const reject_val = jsc.JSObjectGetProperty(ctx, holder, k_reject_ref, null);
    const options_val = jsc.JSObjectGetProperty(ctx, holder, k_options_ref, null);
    const options_obj = jsc.JSValueToObject(ctx, options_val, null) orelse {
        _ = jsCall(ctx, reject_val, 0, null);
        jsc.JSValueUnprotect(@ptrCast(ctx), holder);
        return jsc.JSValueMakeUndefined(ctx);
    };
    const allocator = system_allocator.get() orelse {
        _ = jsCall(ctx, reject_val, 0, null);
        jsc.JSValueUnprotect(@ptrCast(ctx), holder);
        return jsc.JSValueMakeUndefined(ctx);
    };
    const opts = globals.current_run_options orelse {
        _ = jsCall(ctx, reject_val, 0, null);
        jsc.JSValueUnprotect(@ptrCast(ctx), holder);
        return jsc.JSValueMakeUndefined(ctx);
    };
    const cmd_slices = run_mod.getOptionsCmd(allocator, ctx, options_obj) orelse {
        _ = jsCall(ctx, reject_val, 0, null);
        jsc.JSValueUnprotect(@ptrCast(ctx), holder);
        return jsc.JSValueMakeUndefined(ctx);
    };
    defer {
        for (cmd_slices) |s| allocator.free(s);
        allocator.free(cmd_slices);
    }
    const cwd = run_mod.getOptionsCwd(allocator, ctx, options_obj);
    defer if (cwd) |c| allocator.free(c);
    const cwd_opt = if (cwd) |c| c else opts.cwd;
    const io = libs_process.getProcessIo() orelse {
        _ = jsCall(ctx, reject_val, 0, null);
        jsc.JSValueUnprotect(@ptrCast(ctx), holder);
        return jsc.JSValueMakeUndefined(ctx);
    };
    const result = child_run.runProcess(allocator, cmd_slices, cwd_opt, io) catch {
        _ = jsCall(ctx, reject_val, 0, null);
        jsc.JSValueUnprotect(@ptrCast(ctx), holder);
        return jsc.JSValueMakeUndefined(ctx);
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    const result_obj = runMakeResultObject(ctx, result.code, result.stdout, result.stderr);
    var one: [1]jsc.JSValueRef = .{result_obj};
    _ = jsCall(ctx, resolve_val, 1, &one);
    jsc.JSValueUnprotect(@ptrCast(ctx), holder);
    return jsc.JSValueMakeUndefined(ctx);
}

fn runMakeResultObject(ctx: jsc.JSContextRef, status: u8, stdout: []const u8, stderr: []const u8) jsc.JSValueRef {
    const allocator = system_allocator.get() orelse return jsc.JSObjectMake(ctx, null, null);
    const stdout_z = allocator.dupeZ(u8, stdout) catch return jsc.JSObjectMake(ctx, null, null);
    defer allocator.free(stdout_z);
    const stderr_z = allocator.dupeZ(u8, stderr) catch return jsc.JSObjectMake(ctx, null, null);
    defer allocator.free(stderr_z);
    const obj = jsc.JSObjectMake(ctx, null, null);
    const k_status = jsc.JSStringCreateWithUTF8CString("status");
    defer jsc.JSStringRelease(k_status);
    const k_stdout = jsc.JSStringCreateWithUTF8CString("stdout");
    defer jsc.JSStringRelease(k_stdout);
    const k_stderr = jsc.JSStringCreateWithUTF8CString("stderr");
    defer jsc.JSStringRelease(k_stderr);
    const stdout_ref = jsc.JSStringCreateWithUTF8CString(stdout_z.ptr);
    defer jsc.JSStringRelease(stdout_ref);
    const stderr_ref = jsc.JSStringCreateWithUTF8CString(stderr_z.ptr);
    defer jsc.JSStringRelease(stderr_ref);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_status, jsc.JSValueMakeNumber(ctx, @floatFromInt(status)), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_stdout, jsc.JSValueMakeString(ctx, stdout_ref), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_stderr, jsc.JSValueMakeString(ctx, stderr_ref), jsc.kJSPropertyAttributeNone, null);
    return obj;
}

/// Promise executor：收到 resolve/reject 后入队微任务，微任务内执行同步逻辑并 resolve；cmd 从 callee.cmd 取
fn execExecutorCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    callee: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const resolve_val = arguments[0];
    const reject_val = arguments[1];
    const k_cmd_ref = jsc.JSStringCreateWithUTF8CString(k_cmd);
    defer jsc.JSStringRelease(k_cmd_ref);
    const cmd_val = jsc.JSObjectGetProperty(ctx, callee, k_cmd_ref, null);
    const holder = jsc.JSObjectMake(ctx, null, null);
    const k_resolve_ref = jsc.JSStringCreateWithUTF8CString(k_resolve);
    defer jsc.JSStringRelease(k_resolve_ref);
    const k_reject_ref = jsc.JSStringCreateWithUTF8CString(k_reject);
    defer jsc.JSStringRelease(k_reject_ref);
    _ = jsc.JSObjectSetProperty(ctx, holder, k_resolve_ref, resolve_val, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, holder, k_reject_ref, reject_val, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, holder, k_cmd_ref, cmd_val, jsc.kJSPropertyAttributeNone, null);
    jsc.JSValueProtect(@ptrCast(ctx), holder);
    const name_deferred = jsc.JSStringCreateWithUTF8CString("execDeferred");
    defer jsc.JSStringRelease(name_deferred);
    const deferred_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, name_deferred, execDeferredCallback);
    const k_holder_ref = jsc.JSStringCreateWithUTF8CString(k_holder);
    defer jsc.JSStringRelease(k_holder_ref);
    _ = jsc.JSObjectSetProperty(ctx, deferred_fn, k_holder_ref, holder, jsc.kJSPropertyAttributeNone, null);
    jsc.JSValueProtect(@ptrCast(ctx), deferred_fn);
    const state = globals.current_timer_state orelse {
        jsc.JSValueUnprotect(@ptrCast(ctx), deferred_fn);
        jsc.JSValueUnprotect(@ptrCast(ctx), holder);
        return jsc.JSValueMakeUndefined(ctx);
    };
    state.enqueueMicrotask(@ptrCast(ctx), deferred_fn);
    return jsc.JSValueMakeUndefined(ctx);
}

/// run/spawn 的 Promise executor：options 从 callee.options 取
fn runExecutorCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    callee: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const resolve_val = arguments[0];
    const reject_val = arguments[1];
    const k_options_ref = jsc.JSStringCreateWithUTF8CString(k_options);
    defer jsc.JSStringRelease(k_options_ref);
    const options_val = jsc.JSObjectGetProperty(ctx, callee, k_options_ref, null);
    const holder = jsc.JSObjectMake(ctx, null, null);
    const k_resolve_ref = jsc.JSStringCreateWithUTF8CString(k_resolve);
    defer jsc.JSStringRelease(k_resolve_ref);
    const k_reject_ref = jsc.JSStringCreateWithUTF8CString(k_reject);
    defer jsc.JSStringRelease(k_reject_ref);
    _ = jsc.JSObjectSetProperty(ctx, holder, k_resolve_ref, resolve_val, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, holder, k_reject_ref, reject_val, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, holder, k_options_ref, options_val, jsc.kJSPropertyAttributeNone, null);
    jsc.JSValueProtect(@ptrCast(ctx), holder);
    const name_deferred = jsc.JSStringCreateWithUTF8CString("runDeferred");
    defer jsc.JSStringRelease(name_deferred);
    const deferred_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, name_deferred, runDeferredCallback);
    const k_holder_ref = jsc.JSStringCreateWithUTF8CString(k_holder);
    defer jsc.JSStringRelease(k_holder_ref);
    _ = jsc.JSObjectSetProperty(ctx, deferred_fn, k_holder_ref, holder, jsc.kJSPropertyAttributeNone, null);
    jsc.JSValueProtect(@ptrCast(ctx), deferred_fn);
    const state = globals.current_timer_state orelse {
        jsc.JSValueUnprotect(@ptrCast(ctx), deferred_fn);
        jsc.JSValueUnprotect(@ptrCast(ctx), holder);
        return jsc.JSValueMakeUndefined(ctx);
    };
    state.enqueueMicrotask(@ptrCast(ctx), deferred_fn);
    return jsc.JSValueMakeUndefined(ctx);
}

/// 创建 exec 的 Promise：executor 上挂 cmd（JS 字符串），executor(resolve, reject) 时由 JSC 调用，内部入队微任务执行 execSync 并 resolve
pub fn createExecPromise(ctx: jsc.JSContextRef, cmd_js: jsc.JSValueRef) jsc.JSValueRef {
    const Promise = promise.getPromiseConstructor(ctx) orelse return jsc.JSValueMakeUndefined(ctx);
    const name_exec = jsc.JSStringCreateWithUTF8CString("execExecutor");
    defer jsc.JSStringRelease(name_exec);
    const executor_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, name_exec, execExecutorCallback);
    const k_cmd_ref = jsc.JSStringCreateWithUTF8CString(k_cmd);
    defer jsc.JSStringRelease(k_cmd_ref);
    _ = jsc.JSObjectSetProperty(ctx, executor_fn, k_cmd_ref, cmd_js, jsc.kJSPropertyAttributeNone, null);
    var one: [1]jsc.JSValueRef = .{executor_fn};
    return jsc.JSObjectCallAsConstructor(ctx, Promise, 1, &one, null);
}

/// 创建 run/spawn 的 Promise：executor 上挂 options（JS 对象），executor(resolve, reject) 时入队微任务执行 runSync 并 resolve
pub fn createRunPromise(ctx: jsc.JSContextRef, options_js: jsc.JSValueRef) jsc.JSValueRef {
    const Promise = promise.getPromiseConstructor(ctx) orelse return jsc.JSValueMakeUndefined(ctx);
    const name_run = jsc.JSStringCreateWithUTF8CString("runExecutor");
    defer jsc.JSStringRelease(name_run);
    const executor_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, name_run, runExecutorCallback);
    const k_options_ref = jsc.JSStringCreateWithUTF8CString(k_options);
    defer jsc.JSStringRelease(k_options_ref);
    _ = jsc.JSObjectSetProperty(ctx, executor_fn, k_options_ref, options_js, jsc.kJSPropertyAttributeNone, null);
    var one: [1]jsc.JSValueRef = .{executor_fn};
    return jsc.JSObjectCallAsConstructor(ctx, Promise, 1, &one, null);
}
