// shu:permissions — 与 node:permissions API 兼容，基于当前 RunOptions 权限，纯 Zig 实现
//
// ========== API 兼容情况 ==========
//
// | API | 兼容 | 说明 |
// |-----|------|------|
// | has(scope?) | ✅ 已实现 | scope 为 'fs.read'/'fs.write'/'net'/'env'/'child'/'run'/'hrtime'/'ffi' 等，与 Deno 对齐（--allow-run/--allow-hrtime/--allow-ffi）
// | request(scope?) | ✅ 已实现 | 同 has，返回 { state: 'granted'|'denied' }；不改变权限，仅查询 |
//

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");

/// 从 JS 取第一个参数字符串，最多 64 字节；调用方不 free（栈上）
fn getScopeArg(ctx: jsc.JSContextRef, argumentCount: usize, arguments: [*]const jsc.JSValueRef) ?[]const u8 {
    if (argumentCount < 1) return null;
    var buf: [64]u8 = undefined;
    const str_ref = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(str_ref);
    const n = jsc.JSStringGetUTF8CString(str_ref, &buf, buf.len);
    if (n == 0) return null;
    return buf[0 .. n - 1];
}

/// 取 scope 前 8 字节转 u64（不足零填充），用于与 comptime 常量整型比较（00 §2.1）
fn scopePrefix(scope: []const u8) u64 {
    var buf: [8]u8 = [_]u8{0} ** 8;
    const n = @min(8, scope.len);
    @memcpy(buf[0..n], scope[0..n]);
    return @as(u64, @bitCast(buf));
}
fn scopePrefix8(comptime s: []const u8) u64 {
    var buf: [8]u8 = [_]u8{0} ** 8;
    const n = @min(8, s.len);
    for (s[0..n], buf[0..n]) |a, *b| b.* = a;
    return @as(u64, @bitCast(buf));
}

/// 根据 scope 字符串判断当前是否具备该权限（与 RunOptions.permissions 对齐）
/// 按长度分派 + u64 前缀整型比较（00 §2.1）
fn scopeGranted(scope: []const u8) bool {
    const opts = globals.current_run_options orelse return false;
    const p = opts.permissions;
    switch (scope.len) {
        3 => {
            const q = scopePrefix(scope);
            if (q == scopePrefix8("net")) return p.allow_net;
            if (q == scopePrefix8("env")) return p.allow_env;
            if (q == scopePrefix8("ffi")) return p.allow_ffi;
            if (q == scopePrefix8("run")) return p.allow_run;
            return false;
        },
        4 => {
            const q = scopePrefix(scope);
            if (q == scopePrefix8("read")) return p.allow_read;
            if (q == scopePrefix8("exec")) return p.allow_run;
            return false;
        },
        5 => {
            const q = scopePrefix(scope);
            if (q == scopePrefix8("write")) return p.allow_write;
            if (q == scopePrefix8("child")) return p.allow_run;
            return false;
        },
        6 => return scopePrefix(scope) == scopePrefix8("hrtime") and p.allow_hrtime,
        7 => return scopePrefix(scope) == scopePrefix8("fs.read") and p.allow_read,
        8 => {
            const q = scopePrefix(scope);
            if (q == scopePrefix8("fs.write")) return p.allow_write;
            if (q == scopePrefix8("network")) return p.allow_net;
            return false;
        },
        else => return false,
    }
}

/// permissions.has(scope?)：缺省无参时返回是否有任意权限；有参则查该 scope
fn hasCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) {
        const opts = globals.current_run_options orelse return jsc.JSValueMakeBoolean(ctx, false);
        const p = opts.permissions;
        const any = p.allow_read or p.allow_write or p.allow_net or p.allow_env or p.allow_run or p.allow_hrtime or p.allow_ffi;
        return jsc.JSValueMakeBoolean(ctx, any);
    }
    const scope = getScopeArg(ctx, argumentCount, arguments) orelse return jsc.JSValueMakeBoolean(ctx, false);
    return jsc.JSValueMakeBoolean(ctx, scopeGranted(scope));
}

/// permissions.request(scope?)：返回 { state: 'granted'|'denied' }，不改变权限
fn requestCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const granted = if (argumentCount < 1) blk: {
        const opts = globals.current_run_options orelse break :blk false;
        const p = opts.permissions;
        break :blk p.allow_read or p.allow_write or p.allow_net or p.allow_env or p.allow_run or p.allow_hrtime or p.allow_ffi;
    } else blk: {
        const scope = getScopeArg(ctx, argumentCount, arguments) orelse break :blk false;
        break :blk scopeGranted(scope);
    };
    const obj = jsc.JSObjectMake(ctx, null, null);
    const k_state = jsc.JSStringCreateWithUTF8CString("state");
    defer jsc.JSStringRelease(k_state);
    const state_val = if (granted)
        jsc.JSStringCreateWithUTF8CString("granted")
    else
        jsc.JSStringCreateWithUTF8CString("denied");
    defer jsc.JSStringRelease(state_val);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_state, jsc.JSValueMakeString(ctx, state_val), jsc.kJSPropertyAttributeNone, null);
    return obj;
}

pub fn getExports(ctx: jsc.JSContextRef, _: std.mem.Allocator) jsc.JSValueRef {
    const exports = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, exports, "has", hasCallback);
    common.setMethod(ctx, exports, "request", requestCallback);
    return exports;
}
