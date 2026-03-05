// shu:os 内置：Node 风格 os 模块，平台/架构/类型/CPU 个数走 libs_os，homedir/tmpdir/hostname/EOL 仍在本模块
// 供 require("shu:os") / node:os 共用，无内嵌 JS 脚本

const std = @import("std");
const builtin = @import("builtin");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");
const libs_os = @import("libs_os");

/// platform()：返回 'darwin' | 'linux' | 'win32' 等，委托 libs_os.platformName()
fn platformCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const s = libs_os.platformName();
    const ref = jsc.JSStringCreateWithUTF8CString(s.ptr);
    return jsc.JSValueMakeString(ctx, ref);
}

/// arch()：返回 'x64' | 'arm64' | 'ia32' 等，委托 libs_os.archName()
fn archCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const s = libs_os.archName();
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

/// type()：系统类型名，如 'Darwin'、'Linux'、'Windows_NT'，委托 libs_os.typeName()
fn typeCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const s = libs_os.typeName();
    const ref = jsc.JSStringCreateWithUTF8CString(s.ptr);
    return jsc.JSValueMakeString(ctx, ref);
}

/// cpus()：返回逻辑 CPU 数量个对象数组，每项含 model、speed、times；个数来自 libs_os.getCpuCount()，Zig 无详细 CPU 信息时用占位
fn cpusCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const count: usize = @intCast(libs_os.getCpuCount());
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

/// loadavg()：系统负载 [1 分钟, 5 分钟, 15 分钟]，委托 libs_os.getLoadAverage()；不支持或失败时返回 [0,0,0]
fn loadavgCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const load = libs_os.getLoadAverage() catch {
        var zeros: [3]jsc.JSValueRef = .{
            jsc.JSValueMakeNumber(ctx, 0),
            jsc.JSValueMakeNumber(ctx, 0),
            jsc.JSValueMakeNumber(ctx, 0),
        };
        return jsc.JSObjectMakeArray(ctx, 3, &zeros, null);
    };
    var arr: [3]jsc.JSValueRef = .{
        jsc.JSValueMakeNumber(ctx, load.load_1),
        jsc.JSValueMakeNumber(ctx, load.load_5),
        jsc.JSValueMakeNumber(ctx, load.load_15),
    };
    return jsc.JSObjectMakeArray(ctx, 3, &arr, null);
}

/// uptime()：系统运行时间（秒），委托 libs_os.getUptimeSeconds()；不支持或失败时返回 0
fn uptimeCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const sec = libs_os.getUptimeSeconds() catch 0;
    return jsc.JSValueMakeNumber(ctx, @floatFromInt(sec));
}

/// totalmem()：系统总内存（字节），委托 libs_os.getMemoryInfo()；不支持或失败时返回 0
fn totalmemCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const info = libs_os.getMemoryInfo() catch return jsc.JSValueMakeNumber(ctx, 0);
    const bytes = info.total_kb * 1024;
    return jsc.JSValueMakeNumber(ctx, @floatFromInt(bytes));
}

/// freemem()：系统可用内存（字节），委托 libs_os.getMemoryInfo().available_kb；不支持或失败时返回 0
fn freememCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const info = libs_os.getMemoryInfo() catch return jsc.JSValueMakeNumber(ctx, 0);
    const bytes = info.available_kb * 1024;
    return jsc.JSValueMakeNumber(ctx, @floatFromInt(bytes));
}

/// [Allocates] 从 JS 第一个参数取 UTF-8 字符串；调用方负责 free 返回的 slice。
fn getPathFromArg(ctx: jsc.JSContextRef, arguments: [*]const jsc.JSValueRef, allocator: std.mem.Allocator) ?[]const u8 {
    const val = arguments[0];
    const js_str = jsc.JSValueToStringCopy(ctx, val, null);
    defer jsc.JSStringRelease(js_str);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(js_str);
    if (max_sz == 0 or max_sz > 65536) return null;
    const buf = allocator.alloc(u8, max_sz) catch return null;
    defer allocator.free(buf);
    const n = jsc.JSStringGetUTF8CString(js_str, buf.ptr, max_sz);
    if (n == 0) return null;
    return allocator.dupe(u8, buf[0 .. n - 1]) catch null;
}

/// cpuUsage()：系统整体 CPU 利用率 0..100，委托 libs_os.getCpuUsage()；不支持或失败时返回 0
fn cpuUsageCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const percent = libs_os.getCpuUsage() catch 0;
    return jsc.JSValueMakeNumber(ctx, @floatFromInt(percent));
}

/// processRssKb()：当前进程 RSS（KB），委托 libs_os.getProcessRssKb()；不支持或失败时返回 0
fn processRssKbCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const kb = libs_os.getProcessRssKb() catch 0;
    return jsc.JSValueMakeNumber(ctx, @floatFromInt(kb));
}

/// processCpuUsage()：当前进程 CPU 占用（0..100*核数），委托 libs_os.getProcessCpuUsage()；不支持或失败时返回 0
fn processCpuUsageCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const usage = libs_os.getProcessCpuUsage() catch 0;
    return jsc.JSValueMakeNumber(ctx, @floatFromInt(usage));
}

/// cpuUsagePerCore()：每核 CPU 利用率数组 [0..100]，委托 libs_os.getCpuUsagePerCore()；不支持或失败时返回 []
fn cpuUsagePerCoreCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSObjectMakeArray(ctx, 0, @as([*]const jsc.JSValueRef, &[_]jsc.JSValueRef{}), null);
    const per_core = libs_os.getCpuUsagePerCore(allocator) catch return jsc.JSObjectMakeArray(ctx, 0, @as([*]const jsc.JSValueRef, &[_]jsc.JSValueRef{}), null);
    defer allocator.free(per_core);
    var arr = allocator.alloc(jsc.JSValueRef, per_core.len) catch return jsc.JSObjectMakeArray(ctx, 0, @as([*]const jsc.JSValueRef, &[_]jsc.JSValueRef{}), null);
    defer allocator.free(arr);
    for (per_core, arr) |p, *a| {
        a.* = jsc.JSValueMakeNumber(ctx, @floatFromInt(p));
    }
    return jsc.JSObjectMakeArray(ctx, per_core.len, arr.ptr, null);
}

/// swapInfo()：Swap 信息 { totalKb, freeKb }，委托 libs_os.getSwapInfo()；不支持或失败时返回 { totalKb: 0, freeKb: 0 }
fn swapInfoCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const swap = libs_os.getSwapInfo() catch {
        const obj = jsc.JSObjectMake(ctx, null, null);
        _ = jsc.JSObjectSetProperty(ctx, obj, jsc.JSStringCreateWithUTF8CString("totalKb"), jsc.JSValueMakeNumber(ctx, 0), jsc.kJSPropertyAttributeNone, null);
        _ = jsc.JSObjectSetProperty(ctx, obj, jsc.JSStringCreateWithUTF8CString("freeKb"), jsc.JSValueMakeNumber(ctx, 0), jsc.kJSPropertyAttributeNone, null);
        return obj;
    };
    const obj = jsc.JSObjectMake(ctx, null, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, jsc.JSStringCreateWithUTF8CString("totalKb"), jsc.JSValueMakeNumber(ctx, @floatFromInt(swap.total_kb)), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, jsc.JSStringCreateWithUTF8CString("freeKb"), jsc.JSValueMakeNumber(ctx, @floatFromInt(swap.free_kb)), jsc.kJSPropertyAttributeNone, null);
    return obj;
}

/// diskUtilization()：磁盘 I/O 利用率 0..100，委托 libs_os.getDiskUtilization()；不支持或失败时返回 0
fn diskUtilizationCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const percent = libs_os.getDiskUtilization() catch 0;
    return jsc.JSValueMakeNumber(ctx, @floatFromInt(percent));
}

/// isDiskBusy()：磁盘是否繁忙，委托 libs_os.isDiskBusy()
fn isDiskBusyCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const busy = libs_os.isDiskBusy();
    return jsc.JSValueMakeBoolean(ctx, busy);
}

/// getDiskFreeSpace(path)：指定路径所在文件系统的剩余空间 { totalBytes, freeBytes }，委托 libs_os.getDiskFreeSpace()；失败时返回 undefined
fn getDiskFreeSpaceCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const path_slice = getPathFromArg(ctx, arguments, allocator) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(path_slice);
    const space = libs_os.getDiskFreeSpace(path_slice, allocator) catch return jsc.JSValueMakeUndefined(ctx);
    const obj = jsc.JSObjectMake(ctx, null, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, jsc.JSStringCreateWithUTF8CString("totalBytes"), jsc.JSValueMakeNumber(ctx, @floatFromInt(space.total_bytes)), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, jsc.JSStringCreateWithUTF8CString("freeBytes"), jsc.JSValueMakeNumber(ctx, @floatFromInt(space.free_bytes)), jsc.kJSPropertyAttributeNone, null);
    return obj;
}

/// networkActivityBytesDelta()：采样窗口内网络总流量 rx+tx 字节数，委托 libs_os.getNetworkActivityBytesDelta()；不支持或失败时返回 0
fn networkActivityBytesDeltaCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const delta = libs_os.getNetworkActivityBytesDelta() catch 0;
    return jsc.JSValueMakeNumber(ctx, @floatFromInt(delta));
}

/// isNetworkBusy()：网络是否繁忙（采样窗口内流量超过阈值），委托 libs_os.isNetworkBusy()
fn isNetworkBusyCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const busy = libs_os.isNetworkBusy();
    return jsc.JSValueMakeBoolean(ctx, busy);
}

/// networkStatsPerInterface()：各网络接口的累计 rx/tx 字节数组 [{ name, rxBytes, txBytes }]，委托 libs_os.getNetworkStatsPerInterface()；不支持或失败时返回 []
fn networkStatsPerInterfaceCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSObjectMakeArray(ctx, 0, @as([*]const jsc.JSValueRef, &[_]jsc.JSValueRef{}), null);
    const stats = libs_os.getNetworkStatsPerInterface(allocator) catch return jsc.JSObjectMakeArray(ctx, 0, @as([*]const jsc.JSValueRef, &[_]jsc.JSValueRef{}), null);
    defer {
        for (stats) |s| allocator.free(s.name);
        allocator.free(stats);
    }
    var arr = allocator.alloc(jsc.JSValueRef, stats.len) catch return jsc.JSObjectMakeArray(ctx, 0, @as([*]const jsc.JSValueRef, &[_]jsc.JSValueRef{}), null);
    defer allocator.free(arr);
    for (stats, arr) |s, *a| {
        const name_z = allocator.dupeZ(u8, s.name) catch continue;
        defer allocator.free(name_z);
        const obj = jsc.JSObjectMake(ctx, null, null);
        const name_ref = jsc.JSStringCreateWithUTF8CString(name_z.ptr);
        _ = jsc.JSObjectSetProperty(ctx, obj, jsc.JSStringCreateWithUTF8CString("name"), jsc.JSValueMakeString(ctx, name_ref), jsc.kJSPropertyAttributeNone, null);
        _ = jsc.JSObjectSetProperty(ctx, obj, jsc.JSStringCreateWithUTF8CString("rxBytes"), jsc.JSValueMakeNumber(ctx, @floatFromInt(s.rx_bytes)), jsc.kJSPropertyAttributeNone, null);
        _ = jsc.JSObjectSetProperty(ctx, obj, jsc.JSStringCreateWithUTF8CString("txBytes"), jsc.JSValueMakeNumber(ctx, @floatFromInt(s.tx_bytes)), jsc.kJSPropertyAttributeNone, null);
        a.* = obj;
    }
    return jsc.JSObjectMakeArray(ctx, stats.len, arr.ptr, null);
}

/// tcpConnectionCount()：当前 TCP 连接数，委托 libs_os.getTcpConnectionCount()；不支持或失败时返回 0
fn tcpConnectionCountCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeNumber(ctx, 0);
    const count = libs_os.getTcpConnectionCount(allocator) catch 0;
    return jsc.JSValueMakeNumber(ctx, @floatFromInt(count));
}

/// networkRttMs(host, port)：对 host:port 的 RTT 探针（毫秒），委托 libs_os.getNetworkRttMs()；失败或不支持时返回 undefined
fn networkRttMsCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const host_slice = getPathFromArg(ctx, arguments, allocator) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(host_slice);
    const port_val = jsc.JSValueToNumber(ctx, arguments[1], null);
    const port_u16: u16 = @intFromFloat(@min(@max(port_val, 0), 65535));
    const rtt = libs_os.getNetworkRttMs(allocator, host_slice, port_u16) catch return jsc.JSValueMakeUndefined(ctx);
    return jsc.JSValueMakeNumber(ctx, @floatFromInt(rtt));
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
    common.setMethod(ctx, exports, "loadavg", loadavgCallback);
    common.setMethod(ctx, exports, "uptime", uptimeCallback);
    common.setMethod(ctx, exports, "totalmem", totalmemCallback);
    common.setMethod(ctx, exports, "freemem", freememCallback);
    common.setMethod(ctx, exports, "cpuUsage", cpuUsageCallback);
    common.setMethod(ctx, exports, "processRssKb", processRssKbCallback);
    common.setMethod(ctx, exports, "processCpuUsage", processCpuUsageCallback);
    common.setMethod(ctx, exports, "cpuUsagePerCore", cpuUsagePerCoreCallback);
    common.setMethod(ctx, exports, "swapInfo", swapInfoCallback);
    common.setMethod(ctx, exports, "diskUtilization", diskUtilizationCallback);
    common.setMethod(ctx, exports, "isDiskBusy", isDiskBusyCallback);
    common.setMethod(ctx, exports, "getDiskFreeSpace", getDiskFreeSpaceCallback);
    common.setMethod(ctx, exports, "networkActivityBytesDelta", networkActivityBytesDeltaCallback);
    common.setMethod(ctx, exports, "isNetworkBusy", isNetworkBusyCallback);
    common.setMethod(ctx, exports, "networkStatsPerInterface", networkStatsPerInterfaceCallback);
    common.setMethod(ctx, exports, "tcpConnectionCount", tcpConnectionCountCallback);
    common.setMethod(ctx, exports, "networkRttMs", networkRttMsCallback);
    _ = jsc.JSObjectSetProperty(ctx, exports, jsc.JSStringCreateWithUTF8CString("EOL"), eolValue(ctx), jsc.kJSPropertyAttributeNone, null);
    return exports;
}
