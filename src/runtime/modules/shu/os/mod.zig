// shu:os 内置：纯 Zig 实现 Node 风格 os（platform、arch、homedir、tmpdir、EOL、cpus 等）
// 供 require("shu:os") / node:os 共用，无内嵌 JS 脚本

const std = @import("std");
const builtin = @import("builtin");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");

/// platform()：返回 'darwin' | 'linux' | 'win32' 等
fn platformCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const s: [:0]const u8 = switch (builtin.os.tag) {
        .macos => "darwin",
        .linux => "linux",
        .windows => "win32",
        .freebsd => "freebsd",
        .openbsd => "openbsd",
        .netbsd => "netbsd",
        else => "unknown",
    };
    const ref = jsc.JSStringCreateWithUTF8CString(s.ptr);
    return jsc.JSValueMakeString(ctx, ref);
}

/// arch()：返回 'x64' | 'arm64' | 'ia32' 等
fn archCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const s: [:0]const u8 = switch (builtin.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        .x86 => "ia32",
        .arm => "arm",
        .powerpc64 => "ppc64",
        .powerpc64le => "ppc64le",
        .s390x => "s390x",
        .mips, .mipsel => "mips",
        else => "unknown",
    };
    const ref = jsc.JSStringCreateWithUTF8CString(s.ptr);
    return jsc.JSValueMakeString(ctx, ref);
}

/// homedir()：从环境变量 HOME / USERPROFILE 取用户主目录
fn homedirCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString(""));
    const home = if (builtin.os.tag == .windows)
        std.c.getenv("USERPROFILE") orelse std.c.getenv("HOMEPATH")
    else
        std.c.getenv("HOME");
    const s = home orelse "/";
    const z = allocator.dupeZ(u8, std.mem.span(s)) catch return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString("/"));
    defer allocator.free(z);
    const ref = jsc.JSStringCreateWithUTF8CString(z.ptr);
    return jsc.JSValueMakeString(ctx, ref);
}

/// tmpdir()：系统临时目录，POSIX 用 TMPDIR 或 /tmp，Windows 用 TEMP/TMP
fn tmpdirCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString("/tmp"));
    const tmp = if (builtin.os.tag == .windows) blk: {
        const t = std.c.getenv("TEMP") orelse std.c.getenv("TMP") orelse "C:\\Windows\\Temp";
        break :blk t;
    } else blk: {
        break :blk std.c.getenv("TMPDIR") orelse "/tmp";
    };
    const z = allocator.dupeZ(u8, std.mem.span(tmp)) catch return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString("/tmp"));
    defer allocator.free(z);
    const ref = jsc.JSStringCreateWithUTF8CString(z.ptr);
    return jsc.JSValueMakeString(ctx, ref);
}

/// hostname()：当前主机名，Zig 无直接 API 时返回占位
fn hostnameCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString("localhost"));
    var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const name = std.posix.gethostname(&buf) catch return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString("localhost"));
    const z = allocator.dupeZ(u8, name) catch return jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString("localhost"));
    defer allocator.free(z);
    const ref = jsc.JSStringCreateWithUTF8CString(z.ptr);
    return jsc.JSValueMakeString(ctx, ref);
}

/// type()：系统类型名，如 'Darwin'、'Linux'、'Windows_NT'
fn typeCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const s: [:0]const u8 = switch (builtin.os.tag) {
        .macos => "Darwin",
        .linux => "Linux",
        .windows => "Windows_NT",
        .freebsd => "FreeBSD",
        .openbsd => "OpenBSD",
        .netbsd => "NetBSD",
        else => "Unknown",
    };
    const ref = jsc.JSStringCreateWithUTF8CString(s.ptr);
    return jsc.JSValueMakeString(ctx, ref);
}

/// cpus()：返回逻辑 CPU 数量个对象数组，每项含 model、speed、times（Zig 无详细 CPU 信息时用占位）
fn cpusCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const count = std.Thread.getCpuCount() catch 1;
    if (count == 0) return jsc.JSObjectMakeArray(ctx, 0, @as([*]const jsc.JSValueRef, &[_]jsc.JSValueRef{}), null);
    const allocator = globals.current_allocator orelse return jsc.JSObjectMakeArray(ctx, 0, @as([*]const jsc.JSValueRef, &[_]jsc.JSValueRef{}), null);
    var arr = allocator.alloc(jsc.JSValueRef, count) catch return jsc.JSObjectMakeArray(ctx, 0, @as([*]const jsc.JSValueRef, &[_]jsc.JSValueRef{}), null);
    defer allocator.free(arr);
    const model_ref = jsc.JSStringCreateWithUTF8CString("model");
    defer jsc.JSStringRelease(model_ref);
    const speed_ref = jsc.JSStringCreateWithUTF8CString("speed");
    defer jsc.JSStringRelease(speed_ref);
    const times_ref = jsc.JSStringCreateWithUTF8CString("times");
    defer jsc.JSStringRelease(times_ref);
    const unknown_ref = jsc.JSStringCreateWithUTF8CString("Unknown");
    defer jsc.JSStringRelease(unknown_ref);
    const times_obj = jsc.JSObjectMake(ctx, null, null);
    _ = jsc.JSObjectSetProperty(ctx, times_obj, jsc.JSStringCreateWithUTF8CString("user"), jsc.JSValueMakeNumber(ctx, 0), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, times_obj, jsc.JSStringCreateWithUTF8CString("nice"), jsc.JSValueMakeNumber(ctx, 0), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, times_obj, jsc.JSStringCreateWithUTF8CString("sys"), jsc.JSValueMakeNumber(ctx, 0), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, times_obj, jsc.JSStringCreateWithUTF8CString("idle"), jsc.JSValueMakeNumber(ctx, 0), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, times_obj, jsc.JSStringCreateWithUTF8CString("irq"), jsc.JSValueMakeNumber(ctx, 0), jsc.kJSPropertyAttributeNone, null);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const obj = jsc.JSObjectMake(ctx, null, null);
        _ = jsc.JSObjectSetProperty(ctx, obj, model_ref, jsc.JSValueMakeString(ctx, unknown_ref), jsc.kJSPropertyAttributeNone, null);
        _ = jsc.JSObjectSetProperty(ctx, obj, speed_ref, jsc.JSValueMakeNumber(ctx, 0), jsc.kJSPropertyAttributeNone, null);
        _ = jsc.JSObjectSetProperty(ctx, obj, times_ref, times_obj, jsc.kJSPropertyAttributeNone, null);
        arr[i] = obj;
    }
    return jsc.JSObjectMakeArray(ctx, count, arr.ptr, null);
}

/// EOL：行尾符常量 '\n' 或 '\r\n'
fn eolValue(ctx: jsc.JSContextRef) jsc.JSValueRef {
    const s = if (builtin.os.tag == .windows) "\r\n" else "\n";
    const ref = jsc.JSStringCreateWithUTF8CString(s);
    return jsc.JSValueMakeString(ctx, ref);
}

pub fn getExports(ctx: jsc.JSContextRef, _: std.mem.Allocator) jsc.JSValueRef {
    const exports = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, exports, "platform", platformCallback);
    common.setMethod(ctx, exports, "arch", archCallback);
    common.setMethod(ctx, exports, "homedir", homedirCallback);
    common.setMethod(ctx, exports, "tmpdir", tmpdirCallback);
    common.setMethod(ctx, exports, "hostname", hostnameCallback);
    common.setMethod(ctx, exports, "type", typeCallback);
    common.setMethod(ctx, exports, "cpus", cpusCallback);
    _ = jsc.JSObjectSetProperty(ctx, exports, jsc.JSStringCreateWithUTF8CString("EOL"), eolValue(ctx), jsc.kJSPropertyAttributeNone, null);
    return exports;
}
