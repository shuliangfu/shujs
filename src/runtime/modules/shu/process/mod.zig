// 全局 process（cwd、argv、env）、__dirname、__filename 注册；is_forked 时挂载 send/receiveSync
// shu:process 协议：getExports 返回与全局 process 同一对象（Node node:process 兼容）
// 由 bindings 在具备 RunOptions 时调用 register；本模块不依赖 engine。

const std = @import("std");
const jsc = @import("jsc");
const errors = @import("errors");
const libs_process = @import("libs_process");
const run_options_mod = @import("../../../run_options.zig");
const fork_child = @import("../system/fork_child.zig");
const thread_worker = @import("../threads/worker.zig");

/// 向全局对象注入 process（cwd、argv、env）、__dirname、__filename；is_forked 时挂 send/receiveSync，is_thread_worker 时挂线程通道
/// 由 bindings.registerGlobals 在 options 非 null 时调用；allocator/options 由调用方保证有效
pub fn register(allocator: std.mem.Allocator, ctx: jsc.JSGlobalContextRef, options: *const run_options_mod.RunOptions) void {
    const global = jsc.JSContextGetGlobalObject(ctx);

    const cwd_z = allocator.dupeZ(u8, options.cwd) catch return;
    defer allocator.free(cwd_z);
    const cwd_js = jsc.JSStringCreateWithUTF8CString(cwd_z.ptr);
    defer jsc.JSStringRelease(cwd_js);
    const cwd_val = jsc.JSValueMakeString(ctx, cwd_js);

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
    const name_cwd = jsc.JSStringCreateWithUTF8CString("cwd");
    defer jsc.JSStringRelease(name_cwd);
    const name_argv = jsc.JSStringCreateWithUTF8CString("argv");
    defer jsc.JSStringRelease(name_argv);
    _ = jsc.JSObjectSetProperty(ctx, process_obj, name_cwd, cwd_val, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, process_obj, name_argv, arr, jsc.kJSPropertyAttributeNone, null);

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
