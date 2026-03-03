// Shu.system 子进程（流式）：spawn(options)、spawnSync(options)
// 当前实现与 run 一致：同步收集 stdout/stderr，返回 { status, stdout, stderr }；需 --allow-run

const std = @import("std");
const jsc = @import("jsc");
const errors = @import("errors");
const libs_process = @import("libs_process");
const globals = @import("../../../globals.zig");
const common = @import("../../../common.zig");
const system_allocator = @import("allocator.zig");
const child_run = @import("child_run.zig");
const run_mod = @import("run.zig");

/// 在 ctx 中创建并返回 JS 对象 { status, stdout, stderr }（与 runSync 一致）
fn makeSpawnResultObject(ctx: jsc.JSContextRef, status: u8, stdout: []const u8, stderr: []const u8) jsc.JSValueRef {
    const obj = jsc.JSObjectMake(ctx, null, null);
    const k_status = jsc.JSStringCreateWithUTF8CString("status");
    defer jsc.JSStringRelease(k_status);
    const k_stdout = jsc.JSStringCreateWithUTF8CString("stdout");
    defer jsc.JSStringRelease(k_stdout);
    const k_stderr = jsc.JSStringCreateWithUTF8CString("stderr");
    defer jsc.JSStringRelease(k_stderr);
    const allocator = globals.current_allocator orelse return obj;
    const stdout_z = allocator.dupeZ(u8, stdout) catch return obj;
    defer allocator.free(stdout_z);
    const stderr_z = allocator.dupeZ(u8, stderr) catch return obj;
    defer allocator.free(stderr_z);
    const stdout_ref = jsc.JSStringCreateWithUTF8CString(stdout_z.ptr);
    defer jsc.JSStringRelease(stdout_ref);
    const stderr_ref = jsc.JSStringCreateWithUTF8CString(stderr_z.ptr);
    defer jsc.JSStringRelease(stderr_ref);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_status, jsc.JSValueMakeNumber(ctx, @floatFromInt(status)), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_stdout, jsc.JSValueMakeString(ctx, stdout_ref), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_stderr, jsc.JSValueMakeString(ctx, stderr_ref), jsc.kJSPropertyAttributeNone, null);
    return obj;
}

/// 向 system_obj 上注册 spawn、spawnSync
pub fn register(ctx: jsc.JSGlobalContextRef, system_obj: jsc.JSObjectRef) void {
    common.setMethod(ctx, system_obj, "spawn", spawnCallback);
    common.setMethod(ctx, system_obj, "spawnSync", spawnSyncCallback);
}

/// Shu.system.spawn(options)：异步，返回 Promise<{ status, stdout, stderr }>；需 --allow-run
fn spawnCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    if (!opts.permissions.allow_run) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.system.spawn requires --allow-run" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    if (argumentCount == 0) return jsc.JSValueMakeUndefined(ctx);
    _ = jsc.JSValueToObject(ctx, arguments[0], null) orelse return jsc.JSValueMakeUndefined(ctx);
    const script_ref = jsc.JSStringCreateWithUTF8CString("(function(opts){ return new Promise(function(resolve,reject){ setTimeout(function(){ try { resolve(Shu.system.spawnSync(opts)); } catch(e) { reject(e); } }, 0); }); })");
    defer jsc.JSStringRelease(script_ref);
    const fn_val = jsc.JSEvaluateScript(ctx, script_ref, null, null, 1, null);
    const fn_obj = jsc.JSValueToObject(ctx, fn_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    return jsc.JSObjectCallAsFunction(ctx, fn_obj, null, 1, arguments, null);
}

/// Shu.system.spawnSync(options)：同步，返回 { status, stdout, stderr }；需 --allow-run
fn spawnSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    if (!opts.permissions.allow_run) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.system.spawnSync requires --allow-run" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    if (argumentCount == 0) return jsc.JSValueMakeUndefined(ctx);
    const options_obj = jsc.JSValueToObject(ctx, arguments[0], null) orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = system_allocator.get() orelse return jsc.JSValueMakeUndefined(ctx);
    const cmd_slices = run_mod.getOptionsCmd(allocator, ctx, options_obj) orelse return jsc.JSValueMakeUndefined(ctx);
    defer {
        for (cmd_slices) |s| allocator.free(s);
        allocator.free(cmd_slices);
    }
    const cwd = run_mod.getOptionsCwd(allocator, ctx, options_obj);
    defer if (cwd) |c| allocator.free(c);
    const cwd_opt = if (cwd) |c| c else opts.cwd;
    const io = libs_process.getProcessIo() orelse return jsc.JSValueMakeUndefined(ctx);
    const result = child_run.runProcess(allocator, cmd_slices, cwd_opt, io) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return makeSpawnResultObject(ctx, result.code, result.stdout, result.stderr);
}
