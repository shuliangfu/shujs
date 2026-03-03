// Shu.system 直接执行程序：run(options)、runSync(options)
// options: { cmd: string[], cwd?, env?, stdout?, stderr?, timeout? }，不经过 shell；需 --allow-run

const std = @import("std");
const jsc = @import("jsc");
const errors = @import("errors");
const libs_process = @import("libs_process");
const globals = @import("../../../globals.zig");
const common = @import("../../../common.zig");
const system_allocator = @import("allocator.zig");
const child_run = @import("child_run.zig");

/// 从 JS 对象 options 中读取 cmd（字符串数组），返回的切片及其中每个元素需由调用方 free（供 spawn.zig 复用）
pub fn getOptionsCmd(allocator: std.mem.Allocator, ctx: jsc.JSContextRef, options_obj: jsc.JSObjectRef) ?[]const []const u8 {
    const k_cmd = jsc.JSStringCreateWithUTF8CString("cmd");
    defer jsc.JSStringRelease(k_cmd);
    const cmd_val = jsc.JSObjectGetProperty(ctx, options_obj, k_cmd, null);
    const cmd_obj = jsc.JSValueToObject(ctx, cmd_val, null) orelse return null;
    const k_length = jsc.JSStringCreateWithUTF8CString("length");
    defer jsc.JSStringRelease(k_length);
    const len_val = jsc.JSObjectGetProperty(ctx, cmd_obj, k_length, null);
    const len_f = jsc.JSValueToNumber(ctx, len_val, null);
    if (len_f != len_f or len_f < 0) return null;
    const len: usize = @intFromFloat(len_f);
    if (len == 0 or len > 1024) return null;
    const arr = allocator.alloc([]const u8, len) catch return null;
    errdefer allocator.free(arr);
    for (0..len) |i| {
        const elem = jsc.JSObjectGetPropertyAtIndex(ctx, cmd_obj, @intCast(i), null);
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
        arr[i] = allocator.dupe(u8, buf[0 .. n - 1]) catch {
            allocator.free(buf);
            return null;
        };
        allocator.free(buf);
    }
    return arr;
}

/// 从 JS 对象 options 中读取 cwd（可选字符串），返回的切片需由调用方 free；若未提供或为 undefined 则返回 null（供 spawn.zig 复用）
pub fn getOptionsCwd(allocator: std.mem.Allocator, ctx: jsc.JSContextRef, options_obj: jsc.JSObjectRef) ?[]const u8 {
    const k_cwd = jsc.JSStringCreateWithUTF8CString("cwd");
    defer jsc.JSStringRelease(k_cwd);
    const cwd_val = jsc.JSObjectGetProperty(ctx, options_obj, k_cwd, null);
    if (jsc.JSValueIsUndefined(ctx, cwd_val)) return null;
    const str_ref = jsc.JSValueToStringCopy(ctx, cwd_val, null);
    defer jsc.JSStringRelease(str_ref);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(str_ref);
    if (max_sz == 0 or max_sz > 65536) return null;
    const buf = allocator.alloc(u8, max_sz) catch return null;
    defer allocator.free(buf);
    const n = jsc.JSStringGetUTF8CString(str_ref, buf.ptr, max_sz);
    if (n == 0) return null;
    return allocator.dupe(u8, buf[0 .. n - 1]) catch null;
}

/// 在 ctx 中创建并返回 JS 对象 { status, stdout, stderr }
fn makeRunResultObject(ctx: jsc.JSContextRef, status: u8, stdout: []const u8, stderr: []const u8) jsc.JSValueRef {
    const obj = jsc.JSObjectMake(ctx, null, null);
    const k_status = jsc.JSStringCreateWithUTF8CString("status");
    defer jsc.JSStringRelease(k_status);
    const k_stdout = jsc.JSStringCreateWithUTF8CString("stdout");
    defer jsc.JSStringRelease(k_stdout);
    const k_stderr = jsc.JSStringCreateWithUTF8CString("stderr");
    defer jsc.JSStringRelease(k_stderr);
    const allocator = system_allocator.get() orelse return obj;
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

/// 向 system_obj 上注册 run、runSync
pub fn register(ctx: jsc.JSGlobalContextRef, system_obj: jsc.JSObjectRef) void {
    common.setMethod(ctx, system_obj, "run", runCallback);
    common.setMethod(ctx, system_obj, "runSync", runSyncCallback);
}

/// Shu.system.run(options)：异步，返回 Promise<{ status, stdout?, stderr? }>；需 --allow-run
fn runCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    if (!opts.permissions.allow_run) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.system.run requires --allow-run" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    if (argumentCount == 0) return jsc.JSValueMakeUndefined(ctx);
    _ = jsc.JSValueToObject(ctx, arguments[0], null) orelse return jsc.JSValueMakeUndefined(ctx);
    const script_ref = jsc.JSStringCreateWithUTF8CString("(function(opts){ return new Promise(function(resolve,reject){ setTimeout(function(){ try { resolve(Shu.system.runSync(opts)); } catch(e) { reject(e); } }, 0); }); })");
    defer jsc.JSStringRelease(script_ref);
    const fn_val = jsc.JSEvaluateScript(ctx, script_ref, null, null, 1, null);
    const fn_obj = jsc.JSValueToObject(ctx, fn_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const result = jsc.JSObjectCallAsFunction(ctx, fn_obj, null, 1, arguments, null);
    return result;
}

/// Shu.system.runSync(options)：同步，返回 { status, stdout, stderr }；需 --allow-run
fn runSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    if (!opts.permissions.allow_run) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.system.runSync requires --allow-run" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    if (argumentCount == 0) return jsc.JSValueMakeUndefined(ctx);
    const options_val = arguments[0];
    const options_obj = jsc.JSValueToObject(ctx, options_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = system_allocator.get() orelse return jsc.JSValueMakeUndefined(ctx);
    const cmd_slices = getOptionsCmd(allocator, ctx, options_obj) orelse return jsc.JSValueMakeUndefined(ctx);
    defer {
        for (cmd_slices) |s| allocator.free(s);
        allocator.free(cmd_slices);
    }
    const cwd = getOptionsCwd(allocator, ctx, options_obj);
    defer if (cwd) |c| allocator.free(c);
    const cwd_opt = if (cwd) |c| c else opts.cwd;
    const io = libs_process.getProcessIo() orelse return jsc.JSValueMakeUndefined(ctx);
    const result = child_run.runProcess(allocator, cmd_slices, cwd_opt, io) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return makeRunResultObject(ctx, result.code, result.stdout, result.stderr);
}
