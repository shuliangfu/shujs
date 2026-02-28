// Shu.system 壳命令：exec(cmd [, options])、execSync(cmd [, options])
// 执行 shell 命令，缓冲 stdout/stderr，返回 { stdout, stderr, code }；需 --allow-exec

const std = @import("std");
const jsc = @import("jsc");
const errors = @import("../../../../errors.zig");
const globals = @import("../../../globals.zig");
const common = @import("../../../common.zig");
const child_run = @import("child_run.zig");
const system_allocator = @import("allocator.zig");

/// 将字符串转成 JSON 双引号字面量，用于拼接到 JS 脚本中；返回的切片需由调用方 free
fn jsonEscapeCmd(allocator: std.mem.Allocator, str: []const u8) ?[]const u8 {
    var list = std.ArrayList(u8).empty;
    list.append(allocator, '"') catch return null;
    for (str) |c| {
        switch (c) {
            '\\' => list.appendSlice(allocator, "\\\\") catch return null,
            '"' => list.appendSlice(allocator, "\\\"") catch return null,
            '\n' => list.appendSlice(allocator, "\\n") catch return null,
            '\r' => list.appendSlice(allocator, "\\r") catch return null,
            '\t' => list.appendSlice(allocator, "\\t") catch return null,
            else => list.append(allocator, c) catch return null,
        }
    }
    list.append(allocator, '"') catch return null;
    return list.toOwnedSlice(allocator) catch null;
}

/// 从 JS 参数取第 idx 个参数的 UTF-8 字符串，返回的切片需由调用方 free（与 file.zig getArgString 逻辑一致）
fn getArgString(allocator: std.mem.Allocator, ctx: jsc.JSContextRef, arguments: [*]const jsc.JSValueRef, argumentCount: usize, idx: usize) ?[]const u8 {
    if (argumentCount <= idx) return null;
    const path_js = jsc.JSValueToStringCopy(ctx, arguments[idx], null);
    defer jsc.JSStringRelease(path_js);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(path_js);
    if (max_sz == 0 or max_sz > 65536) return null;
    const path_buf = allocator.alloc(u8, max_sz) catch return null;
    defer allocator.free(path_buf);
    const n = jsc.JSStringGetUTF8CString(path_js, path_buf.ptr, max_sz);
    if (n == 0) return null;
    return allocator.dupe(u8, path_buf[0 .. n - 1]) catch null;
}

/// 在 ctx 中创建并返回 JS 对象 { stdout, stderr, code }（字符串为 UTF-8）
fn makeExecResultObject(ctx: jsc.JSContextRef, stdout: []const u8, stderr: []const u8, code: u8) jsc.JSValueRef {
    const obj = jsc.JSObjectMake(ctx, null, null);
    const k_stdout = jsc.JSStringCreateWithUTF8CString("stdout");
    defer jsc.JSStringRelease(k_stdout);
    const k_stderr = jsc.JSStringCreateWithUTF8CString("stderr");
    defer jsc.JSStringRelease(k_stderr);
    const k_code = jsc.JSStringCreateWithUTF8CString("code");
    defer jsc.JSStringRelease(k_code);
    const allocator = system_allocator.get() orelse return obj;
    const stdout_z = allocator.dupeZ(u8, stdout) catch return obj;
    defer allocator.free(stdout_z);
    const stderr_z = allocator.dupeZ(u8, stderr) catch return obj;
    defer allocator.free(stderr_z);
    const stdout_ref = jsc.JSStringCreateWithUTF8CString(stdout_z.ptr);
    defer jsc.JSStringRelease(stdout_ref);
    const stderr_ref = jsc.JSStringCreateWithUTF8CString(stderr_z.ptr);
    defer jsc.JSStringRelease(stderr_ref);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_stdout, jsc.JSValueMakeString(ctx, stdout_ref), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_stderr, jsc.JSValueMakeString(ctx, stderr_ref), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_code, jsc.JSValueMakeNumber(ctx, @floatFromInt(code)), jsc.kJSPropertyAttributeNone, null);
    return obj;
}

/// 向 system_obj 上注册 exec、execSync
pub fn register(ctx: jsc.JSGlobalContextRef, system_obj: jsc.JSObjectRef) void {
    common.setMethod(ctx, system_obj, "exec", execCallback);
    common.setMethod(ctx, system_obj, "execSync", execSyncCallback);
}

/// Shu.system.exec(cmd [, options])：异步，返回 Promise<{ stdout, stderr, code }>；需 --allow-exec
fn execCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    if (!opts.permissions.allow_exec) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.system.exec requires --allow-exec" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    if (argumentCount == 0) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const cmd = getArgString(allocator, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(cmd);
    const cmd_escaped = jsonEscapeCmd(allocator, cmd) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(cmd_escaped);
    var script_buf: [4096]u8 = undefined;
    const script = std.fmt.bufPrint(&script_buf, "(function(){{ var cmd = {s}; return new Promise(function(resolve,reject){{ setTimeout(function(){{ try {{ resolve(Shu.system.execSync(cmd)); }} catch(e) {{ reject(e); }} }}, 0); }}); }})();", .{cmd_escaped}) catch return jsc.JSValueMakeUndefined(ctx);
    const script_z = allocator.dupeZ(u8, script) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(script_z);
    const script_ref = jsc.JSStringCreateWithUTF8CString(script_z.ptr);
    defer jsc.JSStringRelease(script_ref);
    return jsc.JSEvaluateScript(ctx, script_ref, null, null, 1, null);
}

/// Shu.system.execSync(cmd [, options])：同步，返回 { stdout, stderr, code }；需 --allow-exec
fn execSyncCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    if (!opts.permissions.allow_exec) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.system.execSync requires --allow-exec" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    if (argumentCount == 0) return jsc.JSValueMakeUndefined(ctx);
    const allocator = system_allocator.get() orelse return jsc.JSValueMakeUndefined(ctx);
    const cmd = getArgString(allocator, ctx, arguments, argumentCount, 0) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(cmd);
    const argv = [_][]const u8{ "sh", "-c", cmd };
    const result = child_run.runProcess(allocator, &argv, opts.cwd) catch {
        return jsc.JSValueMakeUndefined(ctx);
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return makeExecResultObject(ctx, result.stdout, result.stderr, result.code);
}
