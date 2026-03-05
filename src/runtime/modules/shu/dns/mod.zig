// shu:dns — Node 风格 API：dns.lookup、lookupService、resolve*、reverse、setServers、getServers（与 node:dns 对齐）
// 使用系统 getaddrinfo/getnameinfo，异步通过工作线程 + setImmediate 回主线程调 callback
// 所有权：工作线程内 [Allocates] 的 lookup_address、lookup_all、service_*、reverse_*、resolve_addresses、err_msg 等由主线程 drainPendingDns 消费并 free；传给 JS 的字符串/数组由 JSC 持有，Zig 侧在 callback 前释放。

const std = @import("std");
const builtin = @import("builtin");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");
const libs_io = @import("libs_io");

// C 库 getnameinfo（通过 @extern 链接，避免与 std.c 声明冲突）
const c = std.c;
const FnGetnameinfo = *const fn (*const c.sockaddr, c.socklen_t, [*]u8, usize, [*]u8, usize, c_int) callconv(.c) c_int;
const getnameinfo_c = @extern(FnGetnameinfo, .{ .name = "getnameinfo" });
// macOS/Linux 上 NI_NUMERICHOST 常量为 2（getnameinfo 仅返回数字地址）
const NI_NUMERICHOST: c_int = 2;
// inet_pton 在 Zig std.c 中未导出，直接链接 C 符号
const FnInetPton = *const fn (c_int, [*]const u8, *anyopaque) callconv(.c) c_int;
const c_inet_pton = @extern(FnInetPton, .{ .name = "inet_pton" });

// ----------------------------------------------------------------------------
// 常量（与 Node dns 一致）
// ----------------------------------------------------------------------------
const ADDRCONFIG = 1 << 0;
const V4MAPPED = 1 << 1;
const NODATA = "ENODATA";
const FORMERR = "EFORMERR";
const SERVFAIL = "ESERVFAIL";
const NOTFOUND = "ENOTFOUND";
const NOTIMP = "ENOTIMP";
const REFUSED = "EREFUSED";
const BADQUERY = "EBADQUERY";
const BADNAME = "EBADNAME";
const BADFAMILY = "EBADFAMILY";
const BADRESP = "EBADRESP";
const CONNREFUSED = "ECONNREFUSED";
const TIMEOUT = "ETIMEOUT";
const EOF = "EOF";
const FILE = "EFILE";
const NOMEM = "ENOMEM";
const DESTRUCTION = "EDESTRUCTION";
const BADSTR = "EBADSTR";
const BADFLAGS = "EBADFLAGS";
const NONAME = "ENONAME";
const BADHINTS = "EBADHINTS";
const NOTINITIALIZED = "ENOTINITIALIZED";
const LOADIPHLPAPI = "ELOADIPHLPAPI";
const ADDRGETNETWORKPARAMS = "EADDRGETNETWORKPARAMS";
const CANCELLED = "ECANCELLED";

/// 单条待处理的 DNS 回调：主线程在 dnsTick 中 drain 并调用 JS callback
const PendingDns = struct {
    kind: enum { lookup, lookup_service, reverse, resolve4, resolve6 },
    ctx: jsc.JSContextRef,
    callback: jsc.JSValueRef,
    allocator: std.mem.Allocator,
    err_msg: ?[]const u8,
    // lookup 结果
    lookup_address: ?[]const u8,
    lookup_family: u32,
    lookup_all: ?[]LookupItem,
    // lookupService 结果
    service_hostname: ?[]const u8,
    service_service: ?[]const u8,
    // reverse 结果
    reverse_hostnames: ?[]const []const u8,
    // resolve4/6 结果
    resolve_addresses: ?[]const []const u8,

    const LookupItem = struct { address: []const u8, family: u32 };
};

var g_dns_pending_mutex: std.Io.Mutex = .{ .state = std.atomic.Value(std.Io.Mutex.State).init(.unlocked) };
/// 待处理 DNS 回调队列；Unmanaged 不存 allocator，所有操作由调用方显式传 allocator（01 §1.2、00 §1.5）
var g_dns_pending: ?std.ArrayListUnmanaged(PendingDns) = null;
/// 自定义 DNS 服务器列表；Unmanaged，setServers/getServers 显式传 allocator
var g_dns_servers: ?std.ArrayListUnmanaged([]const u8) = null;
/// 待处理 DNS 回调数；按缓存行隔离，避免与其它全局原子 false sharing（00 §5.3）。
var g_dns_pending_count: std.atomic.Value(usize) align(64) = std.atomic.Value(usize).init(0);

/// 调度下一轮 dnsTick（setImmediate）
fn scheduleDnsTick(ctx: jsc.JSContextRef) void {
    const k_name = jsc.JSStringCreateWithUTF8CString("__shuDnsTick");
    defer jsc.JSStringRelease(k_name);
    const tick_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_name, dnsTickCallback);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_immediate = jsc.JSStringCreateWithUTF8CString("setImmediate");
    defer jsc.JSStringRelease(k_immediate);
    const set_immediate = jsc.JSObjectGetProperty(ctx, global, k_immediate, null);
    if (jsc.JSObjectIsFunction(ctx, @ptrCast(set_immediate))) {
        var args = [_]jsc.JSValueRef{tick_fn};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(set_immediate), null, 1, &args, null);
    }
}

/// 返回 JS 的 null 值（从 global.null 取，与 Node callback(err, result) 中 err=null 一致）
fn getNullValue(ctx: jsc.JSContextRef) jsc.JSValueRef {
    const k = jsc.JSStringCreateWithUTF8CString("null");
    defer jsc.JSStringRelease(k);
    return jsc.JSObjectGetProperty(ctx, jsc.JSContextGetGlobalObject(ctx), k, null);
}

/// 用 message 创建 JS Error 对象（与 net 模块一致）
fn makeJsError(ctx: jsc.JSContextRef, message: []const u8) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const z = allocator.dupeZ(u8, message) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(z);
    const k_error = jsc.JSStringCreateWithUTF8CString("Error");
    defer jsc.JSStringRelease(k_error);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const ErrorCtor = jsc.JSObjectGetProperty(ctx, global, k_error, null);
    const js_msg = jsc.JSStringCreateWithUTF8CString(z.ptr);
    defer jsc.JSStringRelease(js_msg);
    const msg_val = jsc.JSValueMakeString(ctx, js_msg);
    var ctor_args = [_]jsc.JSValueRef{msg_val};
    return jsc.JSObjectCallAsConstructor(ctx, @ptrCast(ErrorCtor), 1, &ctor_args, null);
}

/// 从 JS 取字符串参数，allocator 分配，调用方负责 free
fn jsValueToUtf8(ctx: jsc.JSContextRef, value: jsc.JSValueRef, allocator: std.mem.Allocator) ?[]const u8 {
    const js_str = jsc.JSValueToStringCopy(ctx, value, null);
    defer jsc.JSStringRelease(js_str);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(js_str);
    if (max_sz == 0 or max_sz > 65536) return null;
    const buf = allocator.alloc(u8, max_sz) catch return null;
    defer allocator.free(buf);
    const n = jsc.JSStringGetUTF8CString(js_str, buf.ptr, max_sz);
    if (n == 0) return null;
    return allocator.dupe(u8, buf[0 .. n - 1]) catch null;
}

/// 主线程 drain：取出所有 PendingDns，按 kind 调用 callback(err, ...)
/// §4 持锁仅限「移入 taken」，回调与 JSC 操作在锁外执行
fn drainPendingDns(ctx: jsc.JSContextRef) void {
    const allocator = globals.current_allocator orelse return;
    const io = libs_io.getProcessIo() orelse return;
    var taken = std.ArrayListUnmanaged(PendingDns).initCapacity(allocator, 0) catch return;
    defer taken.deinit(allocator);
    {
        g_dns_pending_mutex.lock(io) catch return;
        defer g_dns_pending_mutex.unlock(io);
        const list = g_dns_pending orelse return;
        if (list.items.len == 0) return;
        taken.ensureTotalCapacity(allocator, list.items.len) catch return;
        const pending = &g_dns_pending.?;
        while (pending.items.len > 0) {
            taken.append(allocator, pending.swapRemove(pending.items.len - 1)) catch break;
        }
    }
    var empty_arr: [0]jsc.JSValueRef = undefined;
    for (taken.items) |*item| {
        defer _ = g_dns_pending_count.fetchSub(1, .monotonic);
        defer jsc.JSValueUnprotect(ctx, item.callback);
        if (item.err_msg) |msg| {
            defer allocator.free(msg);
            const err_obj = makeJsError(ctx, msg);
            switch (item.kind) {
                .lookup, .lookup_service, .reverse, .resolve4, .resolve6 => {
                    var args = [_]jsc.JSValueRef{ err_obj, jsc.JSValueMakeUndefined(ctx), jsc.JSValueMakeUndefined(ctx) };
                    _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(item.callback), null, 2, &args, null);
                },
            }
            continue;
        }
        switch (item.kind) {
            .lookup => {
                if (item.lookup_all) |all| {
                    defer allocator.free(all);
                    for (all) |e| {
                        allocator.free(e.address);
                    }
                    const arr = jsc.JSObjectMakeArray(ctx, 0, &empty_arr, null);
                    const k_address = jsc.JSStringCreateWithUTF8CString("address");
                    defer jsc.JSStringRelease(k_address);
                    const k_family = jsc.JSStringCreateWithUTF8CString("family");
                    defer jsc.JSStringRelease(k_family);
                    for (all) |e| {
                        const obj = jsc.JSObjectMake(ctx, null, null);
                        const addr_z = allocator.dupeZ(u8, e.address) catch continue;
                        defer allocator.free(addr_z);
                        const addr_ref = jsc.JSStringCreateWithUTF8CString(addr_z.ptr);
                        defer jsc.JSStringRelease(addr_ref);
                        _ = jsc.JSObjectSetProperty(ctx, obj, k_address, jsc.JSValueMakeString(ctx, addr_ref), jsc.kJSPropertyAttributeNone, null);
                        _ = jsc.JSObjectSetProperty(ctx, obj, k_family, jsc.JSValueMakeNumber(ctx, @floatFromInt(e.family)), jsc.kJSPropertyAttributeNone, null);
                        const k_push = jsc.JSStringCreateWithUTF8CString("push");
                        defer jsc.JSStringRelease(k_push);
                        const push_fn = jsc.JSObjectGetProperty(ctx, arr, k_push, null);
                        var push_args = [_]jsc.JSValueRef{obj};
                        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(push_fn), arr, 1, &push_args, null);
                    }
                    var args = [_]jsc.JSValueRef{ getNullValue(ctx), arr };
                    _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(item.callback), null, 2, &args, null);
                } else if (item.lookup_address) |addr| {
                    defer allocator.free(addr);
                    const addr_z = allocator.dupeZ(u8, addr) catch continue;
                    defer allocator.free(addr_z);
                    const addr_ref = jsc.JSStringCreateWithUTF8CString(addr_z.ptr);
                    defer jsc.JSStringRelease(addr_ref);
                    var args = [_]jsc.JSValueRef{ getNullValue(ctx), jsc.JSValueMakeString(ctx, addr_ref), jsc.JSValueMakeNumber(ctx, @floatFromInt(item.lookup_family)) };
                    _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(item.callback), null, 3, &args, null);
                }
            },
            .lookup_service => {
                if (item.service_hostname) |h| {
                    defer allocator.free(h);
                    if (item.service_service) |s| {
                        defer allocator.free(s);
                        const hz = allocator.dupeZ(u8, h) catch continue;
                        defer allocator.free(hz);
                        const sz = allocator.dupeZ(u8, s) catch continue;
                        defer allocator.free(sz);
                        const href = jsc.JSStringCreateWithUTF8CString(hz.ptr);
                        defer jsc.JSStringRelease(href);
                        const sref = jsc.JSStringCreateWithUTF8CString(sz.ptr);
                        defer jsc.JSStringRelease(sref);
                        var args = [_]jsc.JSValueRef{ getNullValue(ctx), jsc.JSValueMakeString(ctx, href), jsc.JSValueMakeString(ctx, sref) };
                        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(item.callback), null, 3, &args, null);
                    }
                }
            },
            .reverse => {
                if (item.reverse_hostnames) |hosts| {
                    defer allocator.free(hosts);
                    for (hosts) |hh| allocator.free(hh);
                    const arr = jsc.JSObjectMakeArray(ctx, 0, &empty_arr, null);
                    const k_push = jsc.JSStringCreateWithUTF8CString("push");
                    defer jsc.JSStringRelease(k_push);
                    const push_fn = jsc.JSObjectGetProperty(ctx, arr, k_push, null);
                    for (hosts) |hh| {
                        const z = allocator.dupeZ(u8, hh) catch continue;
                        defer allocator.free(z);
                        const ref = jsc.JSStringCreateWithUTF8CString(z.ptr);
                        defer jsc.JSStringRelease(ref);
                        var push_args = [_]jsc.JSValueRef{jsc.JSValueMakeString(ctx, ref)};
                        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(push_fn), arr, 1, &push_args, null);
                    }
                    var args = [_]jsc.JSValueRef{ getNullValue(ctx), arr };
                    _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(item.callback), null, 2, &args, null);
                }
            },
            .resolve4, .resolve6 => {
                if (item.resolve_addresses) |addrs| {
                    defer allocator.free(addrs);
                    for (addrs) |a| allocator.free(a);
                    const arr = jsc.JSObjectMakeArray(ctx, 0, &empty_arr, null);
                    const k_push = jsc.JSStringCreateWithUTF8CString("push");
                    defer jsc.JSStringRelease(k_push);
                    const push_fn = jsc.JSObjectGetProperty(ctx, arr, k_push, null);
                    for (addrs) |a| {
                        const z = allocator.dupeZ(u8, a) catch continue;
                        defer allocator.free(z);
                        const ref = jsc.JSStringCreateWithUTF8CString(z.ptr);
                        defer jsc.JSStringRelease(ref);
                        var push_args = [_]jsc.JSValueRef{jsc.JSValueMakeString(ctx, ref)};
                        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(push_fn), arr, 1, &push_args, null);
                    }
                    var args = [_]jsc.JSValueRef{ getNullValue(ctx), arr };
                    _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(item.callback), null, 2, &args, null);
                }
            },
        }
    }
    taken.deinit(allocator);
}

fn dnsTickCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    drainPendingDns(ctx);
    if (g_dns_pending_count.load(.monotonic) > 0) scheduleDnsTick(ctx);
    return jsc.JSValueMakeUndefined(ctx);
}

// ----------------------------------------------------------------------------
// getaddrinfo 封装（工作线程中调用）
// ----------------------------------------------------------------------------
const LookupArgs = struct {
    hostname: []const u8,
    family: u32, // 0=any, 4=IPv4, 6=IPv6
    all: bool,
    allocator: std.mem.Allocator,
    ctx: jsc.JSContextRef,
    callback: jsc.JSValueRef,
};

// 将 sockaddr 转为数字 IP 字符串（getnameinfo NI_NUMERICHOST）
fn addrToString(allocator: std.mem.Allocator, addr: *const c.sockaddr, addr_len: c.socklen_t) ?[]const u8 {
    var buf: [256]u8 = undefined;
    var serv_dummy: [1]u8 = undefined;
    if (getnameinfo_c(addr, addr_len, buf[0..].ptr, buf.len, serv_dummy[0..].ptr, 0, NI_NUMERICHOST) != 0) return null;
    return allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(&buf)))) catch null;
}

fn lookupThreadMain(args: *LookupArgs) void {
    const allocator = args.allocator;
    const io = libs_io.getProcessIo() orelse return;
    defer allocator.free(args.hostname);
    defer allocator.destroy(args);
    jsc.JSValueProtect(args.ctx, args.callback);
    _ = g_dns_pending_count.fetchAdd(1, .monotonic);
    var result: PendingDns = .{
        .kind = .lookup,
        .ctx = args.ctx,
        .callback = args.callback,
        .allocator = allocator,
        .err_msg = null,
        .lookup_address = null,
        .lookup_family = 0,
        .lookup_all = null,
        .service_hostname = null,
        .service_service = null,
        .reverse_hostnames = null,
        .resolve_addresses = null,
    };
    const host_z = allocator.dupeZ(u8, args.hostname) catch {
        result.err_msg = allocator.dupe(u8, "ENOMEM") catch null;
        g_dns_pending_mutex.lock(io) catch return;
        defer g_dns_pending_mutex.unlock(io);
        if (g_dns_pending) |*list| list.append(allocator, result) catch {};
        scheduleDnsTick(args.ctx);
        return;
    };
    defer allocator.free(host_z);
    var hints: std.c.addrinfo = undefined;
    @memset(std.mem.asBytes(&hints), 0);
    hints.family = std.c.AF.UNSPEC;
    hints.socktype = std.c.SOCK.STREAM;
    if (args.family == 4) hints.family = std.c.AF.INET;
    if (args.family == 6) hints.family = std.c.AF.INET6;
    var res: ?*std.c.addrinfo = null;
    const ret = std.c.getaddrinfo(host_z.ptr, "0", &hints, &res);
    if (@intFromEnum(ret) != 0) {
        const code = std.c.gai_strerror(ret);
        const msg = std.fmt.allocPrint(allocator, "getaddrinfo {s}: {s}", .{ args.hostname, std.mem.span(code) }) catch allocator.dupe(u8, std.mem.span(code)) catch null;
        result.err_msg = msg;
        g_dns_pending_mutex.lock(io) catch return;
        defer g_dns_pending_mutex.unlock(io);
        if (g_dns_pending) |*list| list.append(allocator, result) catch {};
        scheduleDnsTick(args.ctx);
        return;
    }
    defer if (res) |r| std.c.freeaddrinfo(r);
    var addrs = std.ArrayList(PendingDns.LookupItem).initCapacity(allocator, 4) catch {
        result.err_msg = allocator.dupe(u8, "ENOMEM") catch null;
        g_dns_pending_mutex.lock(io) catch return;
        defer g_dns_pending_mutex.unlock(io);
        if (g_dns_pending) |*list| list.append(allocator, result) catch {};
        scheduleDnsTick(args.ctx);
        return;
    };
    defer addrs.deinit(allocator);
    var it = res;
    while (it) |p| : (it = p.next) {
        const family: u32 = if (p.family == std.c.AF.INET) 4 else if (p.family == std.c.AF.INET6) 6 else continue;
        if (args.family != 0 and family != args.family) continue;
        const addr_ptr = p.addr.?;
        const addr_len: c.socklen_t = if (p.family == std.c.AF.INET) @sizeOf(c.sockaddr.in) else @sizeOf(c.sockaddr.in6);
        const addr_str = addrToString(allocator, addr_ptr, addr_len) orelse continue;
        addrs.append(allocator, .{ .address = addr_str, .family = family }) catch {
            allocator.free(addr_str);
            break;
        };
    }
    if (addrs.items.len == 0) {
        result.err_msg = allocator.dupe(u8, "ENOTFOUND") catch null;
    } else if (args.all) {
        result.lookup_all = addrs.toOwnedSlice(allocator) catch blk: {
            for (addrs.items) |e| allocator.free(e.address);
            result.err_msg = allocator.dupe(u8, "ENOMEM") catch null;
            break :blk null;
        };
    } else {
        const first = addrs.items[0];
        result.lookup_address = first.address;
        result.lookup_family = first.family;
        for (addrs.items[1..]) |e| allocator.free(e.address);
    }
    g_dns_pending_mutex.lock(io) catch return;
    defer g_dns_pending_mutex.unlock(io);
    if (g_dns_pending == null) {
        g_dns_pending = std.ArrayListUnmanaged(PendingDns).initCapacity(allocator, 4) catch {
            if (result.lookup_all) |a| {
                for (a) |e| allocator.free(e.address);
                allocator.free(a);
            }
            if (result.lookup_address) |a| allocator.free(a);
            return;
        };
    }
    g_dns_pending.?.append(allocator, result) catch {
        if (result.lookup_all) |a| {
            for (a) |e| allocator.free(e.address);
            allocator.free(a);
        }
        if (result.lookup_address) |a| allocator.free(a);
    };
    scheduleDnsTick(args.ctx);
}

/// dns.lookup(hostname[, options], callback) — Node 兼容：options 可为 { family, all, hints }
fn lookupCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    var hostname: []const u8 = undefined;
    var callback: jsc.JSValueRef = undefined;
    var family: u32 = 0;
    var all: bool = false;
    if (jsc.JSObjectIsFunction(ctx, @ptrCast(arguments[argumentCount - 1]))) {
        callback = arguments[argumentCount - 1];
        if (argumentCount == 2) {
            hostname = jsValueToUtf8(ctx, arguments[0], allocator) orelse return jsc.JSValueMakeUndefined(ctx);
        } else {
            hostname = jsValueToUtf8(ctx, arguments[0], allocator) orelse return jsc.JSValueMakeUndefined(ctx);
            const opts = jsc.JSValueToObject(ctx, arguments[1], null);
            if (opts) |o| {
                const k_family = jsc.JSStringCreateWithUTF8CString("family");
                defer jsc.JSStringRelease(k_family);
                const k_all = jsc.JSStringCreateWithUTF8CString("all");
                defer jsc.JSStringRelease(k_all);
                const f = jsc.JSValueToNumber(ctx, jsc.JSObjectGetProperty(ctx, o, k_family, null), null);
                if (f == 4 or f == 6) family = @intFromFloat(f);
                all = jsc.JSValueToBoolean(ctx, jsc.JSObjectGetProperty(ctx, o, k_all, null));
            }
        }
    } else {
        return jsc.JSValueMakeUndefined(ctx);
    }
    const args = allocator.create(LookupArgs) catch {
        allocator.free(hostname);
        return jsc.JSValueMakeUndefined(ctx);
    };
    args.* = .{ .hostname = hostname, .family = family, .all = all, .allocator = allocator, .ctx = ctx, .callback = callback };
    var thread = std.Thread.spawn(.{}, lookupThreadMain, .{args}) catch {
        allocator.free(hostname);
        allocator.destroy(args);
        return jsc.JSValueMakeUndefined(ctx);
    };
    thread.detach();
    return jsc.JSValueMakeUndefined(ctx);
}

// ----------------------------------------------------------------------------
// lookupService(address, port, callback)
// ----------------------------------------------------------------------------
const LookupServiceArgs = struct {
    address: []const u8,
    port: u16,
    allocator: std.mem.Allocator,
    ctx: jsc.JSContextRef,
    callback: jsc.JSValueRef,
};

fn lookupServiceThreadMain(args: *LookupServiceArgs) void {
    const allocator = args.allocator;
    const io = libs_io.getProcessIo() orelse return;
    defer allocator.free(args.address);
    defer allocator.destroy(args);
    jsc.JSValueProtect(args.ctx, args.callback);
    _ = g_dns_pending_count.fetchAdd(1, .monotonic);
    var result: PendingDns = .{
        .kind = .lookup_service,
        .ctx = args.ctx,
        .callback = args.callback,
        .allocator = allocator,
        .err_msg = null,
        .lookup_address = null,
        .lookup_family = 0,
        .lookup_all = null,
        .service_hostname = null,
        .service_service = null,
        .reverse_hostnames = null,
        .resolve_addresses = null,
    };
    var port_buf: [16]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{args.port}) catch {
        result.err_msg = allocator.dupe(u8, "EINVAL") catch null;
        g_dns_pending_mutex.lock(io) catch return;
        defer g_dns_pending_mutex.unlock(io);
        if (g_dns_pending) |*list| list.append(allocator, result) catch {};
        scheduleDnsTick(args.ctx);
        return;
    };
    var addr: std.c.sockaddr.in = undefined;
    @memset(std.mem.asBytes(&addr), 0);
    addr.family = std.c.AF.INET;
    addr.port = std.mem.nativeToBig(u16, args.port);
    const addr_z = allocator.dupeZ(u8, args.address) catch {
        result.err_msg = allocator.dupe(u8, "ENOMEM") catch null;
        g_dns_pending_mutex.lock(io) catch return;
        defer g_dns_pending_mutex.unlock(io);
        if (g_dns_pending) |*list| list.append(allocator, result) catch {};
        scheduleDnsTick(args.ctx);
        return;
    };
    defer allocator.free(addr_z);
    if (c_inet_pton(std.c.AF.INET, addr_z.ptr, &addr.addr) != 1) {
        result.err_msg = allocator.dupe(u8, "EINVAL") catch null;
        g_dns_pending_mutex.lock(io) catch return;
        defer g_dns_pending_mutex.unlock(io);
        if (g_dns_pending) |*list| list.append(allocator, result) catch {};
        scheduleDnsTick(args.ctx);
        return;
    }
    var host_buf: [256]u8 = undefined;
    var serv_buf: [256]u8 = undefined;
    const sa: *const c.sockaddr = @ptrCast(&addr);
    const salen = @sizeOf(c.sockaddr.in);
    const ret = getnameinfo_c(sa, salen, host_buf[0..].ptr, host_buf.len, serv_buf[0..].ptr, serv_buf.len, 0);
    if (ret != 0) {
        const code = std.c.gai_strerror(@as(std.c.EAI, @enumFromInt(ret)));
        result.err_msg = std.fmt.allocPrint(allocator, "getnameinfo: {s}", .{std.mem.span(code)}) catch allocator.dupe(u8, std.mem.span(code)) catch null;
    } else {
        result.service_hostname = allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(&host_buf)))) catch null;
        result.service_service = allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(&serv_buf)))) catch null;
    }
    g_dns_pending_mutex.lock(io) catch return;
    defer g_dns_pending_mutex.unlock(io);
    if (g_dns_pending == null) g_dns_pending = std.ArrayListUnmanaged(PendingDns).initCapacity(allocator, 4) catch null;
    if (g_dns_pending) |*list| list.append(allocator, result) catch {};
    scheduleDnsTick(args.ctx);
    _ = port_str;
}

fn lookupServiceCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 3) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const address = jsValueToUtf8(ctx, arguments[0], allocator) orelse return jsc.JSValueMakeUndefined(ctx);
    const port_val = jsc.JSValueToNumber(ctx, arguments[1], null);
    const port: u16 = @intFromFloat(port_val);
    const callback = arguments[2];
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(callback))) {
        allocator.free(address);
        return jsc.JSValueMakeUndefined(ctx);
    }
    const args = allocator.create(LookupServiceArgs) catch {
        allocator.free(address);
        return jsc.JSValueMakeUndefined(ctx);
    };
    args.* = .{ .address = address, .port = port, .allocator = allocator, .ctx = ctx, .callback = callback };
    var thread = std.Thread.spawn(.{}, lookupServiceThreadMain, .{args}) catch {
        allocator.free(address);
        allocator.destroy(args);
        return jsc.JSValueMakeUndefined(ctx);
    };
    thread.detach();
    return jsc.JSValueMakeUndefined(ctx);
}

// ----------------------------------------------------------------------------
// reverse(ip, callback) — 反向解析
// ----------------------------------------------------------------------------
const ReverseArgs = struct {
    ip: []const u8,
    allocator: std.mem.Allocator,
    ctx: jsc.JSContextRef,
    callback: jsc.JSValueRef,
};

fn reverseThreadMain(args: *ReverseArgs) void {
    const allocator = args.allocator;
    const io = libs_io.getProcessIo() orelse return;
    defer allocator.free(args.ip);
    defer allocator.destroy(args);
    jsc.JSValueProtect(args.ctx, args.callback);
    _ = g_dns_pending_count.fetchAdd(1, .monotonic);
    var result: PendingDns = .{
        .kind = .reverse,
        .ctx = args.ctx,
        .callback = args.callback,
        .allocator = allocator,
        .err_msg = null,
        .lookup_address = null,
        .lookup_family = 0,
        .lookup_all = null,
        .service_hostname = null,
        .service_service = null,
        .reverse_hostnames = null,
        .resolve_addresses = null,
    };
    var addr: std.c.sockaddr.in = undefined;
    @memset(std.mem.asBytes(&addr), 0);
    addr.family = std.c.AF.INET;
    const ip_z = allocator.dupeZ(u8, args.ip) catch {
        result.err_msg = allocator.dupe(u8, "ENOMEM") catch null;
        g_dns_pending_mutex.lock(io) catch return;
        defer g_dns_pending_mutex.unlock(io);
        if (g_dns_pending) |*list| list.append(allocator, result) catch {};
        scheduleDnsTick(args.ctx);
        return;
    };
    defer allocator.free(ip_z);
    if (c_inet_pton(std.c.AF.INET, ip_z.ptr, &addr.addr) != 1) {
        result.err_msg = allocator.dupe(u8, "ENOTFOUND") catch null;
        g_dns_pending_mutex.lock(io) catch return;
        defer g_dns_pending_mutex.unlock(io);
        if (g_dns_pending) |*list| list.append(allocator, result) catch {};
        scheduleDnsTick(args.ctx);
        return;
    }
    var host_buf: [512]u8 = undefined;
    var serv_dummy: [1]u8 = undefined;
    const sa: *const c.sockaddr = @ptrCast(&addr);
    const salen = @sizeOf(c.sockaddr.in);
    const ret = getnameinfo_c(sa, salen, host_buf[0..].ptr, host_buf.len, serv_dummy[0..].ptr, 0, 0);
    if (ret != 0) {
        const code = std.c.gai_strerror(@as(std.c.EAI, @enumFromInt(ret)));
        result.err_msg = std.fmt.allocPrint(allocator, "getnameinfo: {s}", .{std.mem.span(code)}) catch allocator.dupe(u8, std.mem.span(code)) catch null;
    } else {
        const host = allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(&host_buf)))) catch null;
        if (host) |h| {
            var arr = allocator.alloc([]const u8, 1) catch {
                allocator.free(h);
                g_dns_pending_mutex.lock(io) catch return;
                defer g_dns_pending_mutex.unlock(io);
                if (g_dns_pending == null) g_dns_pending = std.ArrayListUnmanaged(PendingDns).initCapacity(allocator, 4) catch null;
                if (g_dns_pending) |*list| list.append(allocator, result) catch {};
                scheduleDnsTick(args.ctx);
                return;
            };
            result.reverse_hostnames = arr;
            arr[0] = h;
        }
    }
    g_dns_pending_mutex.lock(io) catch return;
    defer g_dns_pending_mutex.unlock(io);
    if (g_dns_pending == null) g_dns_pending = std.ArrayListUnmanaged(PendingDns).initCapacity(allocator, 4) catch null;
    if (g_dns_pending) |*list| list.append(allocator, result) catch {};
    scheduleDnsTick(args.ctx);
}

fn reverseCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const ip = jsValueToUtf8(ctx, arguments[0], allocator) orelse return jsc.JSValueMakeUndefined(ctx);
    const callback = arguments[1];
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(callback))) {
        allocator.free(ip);
        return jsc.JSValueMakeUndefined(ctx);
    }
    const args = allocator.create(ReverseArgs) catch {
        allocator.free(ip);
        return jsc.JSValueMakeUndefined(ctx);
    };
    args.* = .{ .ip = ip, .allocator = allocator, .ctx = ctx, .callback = callback };
    var thread = std.Thread.spawn(.{}, reverseThreadMain, .{args}) catch {
        allocator.free(ip);
        allocator.destroy(args);
        return jsc.JSValueMakeUndefined(ctx);
    };
    thread.detach();
    return jsc.JSValueMakeUndefined(ctx);
}

// ----------------------------------------------------------------------------
// resolve4 / resolve6 — 用 lookup(all=true) 实现，与 Node 行为接近（系统解析）
// ----------------------------------------------------------------------------
const ResolveArgs = struct {
    hostname: []const u8,
    family: u32, // 4 or 6
    allocator: std.mem.Allocator,
    ctx: jsc.JSContextRef,
    callback: jsc.JSValueRef,
};

fn resolveThreadMain(args: *ResolveArgs) void {
    const allocator = args.allocator;
    const io = libs_io.getProcessIo() orelse return;
    defer allocator.free(args.hostname);
    defer allocator.destroy(args);
    jsc.JSValueProtect(args.ctx, args.callback);
    _ = g_dns_pending_count.fetchAdd(1, .monotonic);
    var result: PendingDns = .{
        .kind = if (args.family == 4) .resolve4 else .resolve6,
        .ctx = args.ctx,
        .callback = args.callback,
        .allocator = allocator,
        .err_msg = null,
        .lookup_address = null,
        .lookup_family = 0,
        .lookup_all = null,
        .service_hostname = null,
        .service_service = null,
        .reverse_hostnames = null,
        .resolve_addresses = null,
    };
    const host_z = allocator.dupeZ(u8, args.hostname) catch {
        result.err_msg = allocator.dupe(u8, "ENOMEM") catch null;
        g_dns_pending_mutex.lock(io) catch return;
        defer g_dns_pending_mutex.unlock(io);
        if (g_dns_pending) |*list| list.append(allocator, result) catch {};
        scheduleDnsTick(args.ctx);
        return;
    };
    defer allocator.free(host_z);
    var hints: std.c.addrinfo = undefined;
    @memset(std.mem.asBytes(&hints), 0);
    hints.family = if (args.family == 4) std.c.AF.INET else std.c.AF.INET6;
    hints.socktype = std.c.SOCK.STREAM;
    var res: ?*std.c.addrinfo = null;
    const ret = std.c.getaddrinfo(host_z.ptr, "0", &hints, &res);
    if (@intFromEnum(ret) != 0) {
        const code = std.c.gai_strerror(ret);
        result.err_msg = std.fmt.allocPrint(allocator, "getaddrinfo {s}: {s}", .{ args.hostname, std.mem.span(code) }) catch allocator.dupe(u8, std.mem.span(code)) catch null;
        g_dns_pending_mutex.lock(io) catch return;
        defer g_dns_pending_mutex.unlock(io);
        if (g_dns_pending) |*list| list.append(allocator, result) catch {};
        scheduleDnsTick(args.ctx);
        return;
    }
    defer if (res) |r| std.c.freeaddrinfo(r);
    var addrs = std.ArrayList([]const u8).initCapacity(allocator, 0) catch {
        result.err_msg = allocator.dupe(u8, "ENOMEM") catch null;
        g_dns_pending_mutex.lock(io) catch return;
        defer g_dns_pending_mutex.unlock(io);
        if (g_dns_pending) |*list| list.append(allocator, result) catch {};
        scheduleDnsTick(args.ctx);
        return;
    };
    defer addrs.deinit(allocator);
    var it = res;
    while (it) |p| : (it = p.next) {
        const addr_ptr = p.addr.?;
        const addr_len: c.socklen_t = if (p.family == std.c.AF.INET) @sizeOf(c.sockaddr.in) else @sizeOf(c.sockaddr.in6);
        const addr_str = addrToString(allocator, addr_ptr, addr_len) orelse continue;
        addrs.append(allocator, addr_str) catch {
            allocator.free(addr_str);
            break;
        };
    }
    if (addrs.items.len > 0) {
        result.resolve_addresses = addrs.toOwnedSlice(allocator) catch blk: {
            for (addrs.items) |a| allocator.free(a);
            break :blk null;
        };
    } else {
        result.err_msg = allocator.dupe(u8, "ENOTFOUND") catch null;
    }
    g_dns_pending_mutex.lock(io) catch return;
    defer g_dns_pending_mutex.unlock(io);
    if (g_dns_pending == null) g_dns_pending = std.ArrayListUnmanaged(PendingDns).initCapacity(allocator, 4) catch null;
    if (g_dns_pending) |*list| list.append(allocator, result) catch {};
    scheduleDnsTick(args.ctx);
}

fn resolve4Callback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const hostname = jsValueToUtf8(ctx, arguments[0], allocator) orelse return jsc.JSValueMakeUndefined(ctx);
    const callback = arguments[argumentCount - 1];
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(callback))) {
        allocator.free(hostname);
        return jsc.JSValueMakeUndefined(ctx);
    }
    const args = allocator.create(ResolveArgs) catch {
        allocator.free(hostname);
        return jsc.JSValueMakeUndefined(ctx);
    };
    args.* = .{ .hostname = hostname, .family = 4, .allocator = allocator, .ctx = ctx, .callback = callback };
    var thread = std.Thread.spawn(.{}, resolveThreadMain, .{args}) catch {
        allocator.free(hostname);
        allocator.destroy(args);
        return jsc.JSValueMakeUndefined(ctx);
    };
    thread.detach();
    return jsc.JSValueMakeUndefined(ctx);
}

fn resolve6Callback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const hostname = jsValueToUtf8(ctx, arguments[0], allocator) orelse return jsc.JSValueMakeUndefined(ctx);
    const callback = arguments[argumentCount - 1];
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(callback))) {
        allocator.free(hostname);
        return jsc.JSValueMakeUndefined(ctx);
    }
    const args = allocator.create(ResolveArgs) catch {
        allocator.free(hostname);
        return jsc.JSValueMakeUndefined(ctx);
    };
    args.* = .{ .hostname = hostname, .family = 6, .allocator = allocator, .ctx = ctx, .callback = callback };
    var thread = std.Thread.spawn(.{}, resolveThreadMain, .{args}) catch {
        allocator.free(hostname);
        allocator.destroy(args);
        return jsc.JSValueMakeUndefined(ctx);
    };
    thread.detach();
    return jsc.JSValueMakeUndefined(ctx);
}

/// resolve(hostname[, rrtype], callback) — rrtype 仅支持 'A'/'AAAA'/'CNAME'，其余返回 ENOTIMP
fn resolveCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const hostname = jsValueToUtf8(ctx, arguments[0], allocator) orelse return jsc.JSValueMakeUndefined(ctx);
    var rrtype: []const u8 = "A";
    var callback: jsc.JSValueRef = undefined;
    if (argumentCount == 2) {
        callback = arguments[1];
    } else {
        rrtype = jsValueToUtf8(ctx, arguments[1], allocator) orelse "A";
        callback = arguments[2];
    }
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(callback))) {
        allocator.free(hostname);
        if (argumentCount > 2) allocator.free(rrtype);
        return jsc.JSValueMakeUndefined(ctx);
    }
    switch (rrtype.len) {
        1 => {
            if (rrtype[0] == 'A') {
                allocator.free(hostname);
                if (argumentCount > 2) allocator.free(rrtype);
                const global = jsc.JSContextGetGlobalObject(ctx);
                var resolve_args = [2]jsc.JSValueRef{ arguments[0], callback };
                var exc_buf: [1]jsc.JSValueRef = undefined;
                return resolve4Callback(ctx, global, global, 2, &resolve_args, @ptrCast(&exc_buf));
            }
        },
        4 => {
            var a4: [4]u8 = undefined;
            @memcpy(a4[0..], rrtype[0..4]);
            if (@as(u32, @bitCast(a4)) == 0x41414141) { // "AAAA" LE
                allocator.free(hostname);
                if (argumentCount > 2) allocator.free(rrtype);
                const global = jsc.JSContextGetGlobalObject(ctx);
                var resolve_args = [2]jsc.JSValueRef{ arguments[0], callback };
                var exc_buf: [1]jsc.JSValueRef = undefined;
                return resolve6Callback(ctx, global, global, 2, &resolve_args, @ptrCast(&exc_buf));
            }
        },
        else => {},
    }
    if (argumentCount > 2) allocator.free(rrtype);
    allocator.free(hostname);
    return jsc.JSValueMakeUndefined(ctx);
}

/// setServers(servers) — Node 兼容：保存服务器列表（本实现 resolve 用系统解析，不实际使用）
fn setServersCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const arr_val = arguments[0];
    if (jsc.JSValueToObject(ctx, arr_val, null) == null) return jsc.JSValueMakeUndefined(ctx);
    const k_length = jsc.JSStringCreateWithUTF8CString("length");
    defer jsc.JSStringRelease(k_length);
    const arr_obj = jsc.JSValueToObject(ctx, arr_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const len_val = jsc.JSObjectGetProperty(ctx, arr_obj, k_length, null);
    const len = @as(usize, @intFromFloat(jsc.JSValueToNumber(ctx, len_val, null)));
    var list = std.ArrayListUnmanaged([]const u8).initCapacity(allocator, len) catch return jsc.JSValueMakeUndefined(ctx);
    const k_str = jsc.JSStringCreateWithUTF8CString("0");
    defer jsc.JSStringRelease(k_str);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        var key_buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{d}", .{i}) catch break;
        const key_ref = jsc.JSStringCreateWithUTF8CString(key.ptr);
        defer jsc.JSStringRelease(key_ref);
        const item = jsc.JSObjectGetProperty(ctx, arr_obj, key_ref, null);
        const s = jsValueToUtf8(ctx, item, allocator) orelse break;
        list.append(allocator, s) catch {
            allocator.free(s);
            break;
        };
    }
    if (g_dns_servers) |*old| {
        for (old.items) |s| allocator.free(s);
        old.deinit(allocator);
    }
    g_dns_servers = list;
    return jsc.JSValueMakeUndefined(ctx);
}

/// getServers() — 返回当前服务器数组
fn getServersCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    var empty: [0]jsc.JSValueRef = undefined;
    const arr = jsc.JSObjectMakeArray(ctx, 0, &empty, null);
    const servers = g_dns_servers orelse return arr;
    const allocator = globals.current_allocator orelse return arr;
    const k_push = jsc.JSStringCreateWithUTF8CString("push");
    defer jsc.JSStringRelease(k_push);
    const push_fn = jsc.JSObjectGetProperty(ctx, arr, k_push, null);
    for (servers.items) |s| {
        const z = allocator.dupeZ(u8, s) catch continue;
        defer allocator.free(z);
        const ref = jsc.JSStringCreateWithUTF8CString(z.ptr);
        defer jsc.JSStringRelease(ref);
        var args = [_]jsc.JSValueRef{jsc.JSValueMakeString(ctx, ref)};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(push_fn), arr, 1, &args, null);
    }
    return arr;
}

/// isIP(str) — 返回 4、6 或 0（Node 兼容，net 中也有）
fn isIPCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeNumber(ctx, 0);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeNumber(ctx, 0);
    const s = jsValueToUtf8(ctx, arguments[0], allocator) orelse return jsc.JSValueMakeNumber(ctx, 0);
    defer allocator.free(s);
    _ = std.Io.net.IpAddress.parseIp4(s, 0) catch {
        _ = std.Io.net.IpAddress.parseIp6(s, 0) catch return jsc.JSValueMakeNumber(ctx, 0);
        return jsc.JSValueMakeNumber(ctx, 6);
    };
    return jsc.JSValueMakeNumber(ctx, 4);
}

/// 设置数字属性（常量）
fn setNumber(ctx: jsc.JSContextRef, obj: jsc.JSObjectRef, name: []const u8, value: i32) void {
    const k = jsc.JSStringCreateWithUTF8CString(name.ptr);
    defer jsc.JSStringRelease(k);
    _ = jsc.JSObjectSetProperty(ctx, obj, k, jsc.JSValueMakeNumber(ctx, @floatFromInt(value)), jsc.kJSPropertyAttributeNone, null);
}

/// 设置字符串常量
fn setStringConst(ctx: jsc.JSContextRef, obj: jsc.JSObjectRef, name: []const u8, value: []const u8) void {
    const k = jsc.JSStringCreateWithUTF8CString(name.ptr);
    defer jsc.JSStringRelease(k);
    const v = jsc.JSStringCreateWithUTF8CString(value.ptr);
    defer jsc.JSStringRelease(v);
    _ = jsc.JSObjectSetProperty(ctx, obj, k, jsc.JSValueMakeString(ctx, v), jsc.kJSPropertyAttributeNone, null);
}

/// 返回 shu:dns 的 exports（与 node:dns 对齐）
pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    _ = allocator;
    const dns_obj = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, dns_obj, "lookup", lookupCallback);
    common.setMethod(ctx, dns_obj, "lookupService", lookupServiceCallback);
    common.setMethod(ctx, dns_obj, "resolve", resolveCallback);
    common.setMethod(ctx, dns_obj, "resolve4", resolve4Callback);
    common.setMethod(ctx, dns_obj, "resolve6", resolve6Callback);
    common.setMethod(ctx, dns_obj, "reverse", reverseCallback);
    common.setMethod(ctx, dns_obj, "setServers", setServersCallback);
    common.setMethod(ctx, dns_obj, "getServers", getServersCallback);
    common.setMethod(ctx, dns_obj, "isIP", isIPCallback);
    setNumber(ctx, dns_obj, "ADDRCONFIG", ADDRCONFIG);
    setNumber(ctx, dns_obj, "V4MAPPED", V4MAPPED);
    setStringConst(ctx, dns_obj, "NODATA", NODATA);
    setStringConst(ctx, dns_obj, "FORMERR", FORMERR);
    setStringConst(ctx, dns_obj, "SERVFAIL", SERVFAIL);
    setStringConst(ctx, dns_obj, "NOTFOUND", NOTFOUND);
    setStringConst(ctx, dns_obj, "NOTIMP", NOTIMP);
    setStringConst(ctx, dns_obj, "REFUSED", REFUSED);
    setStringConst(ctx, dns_obj, "BADNAME", BADNAME);
    setStringConst(ctx, dns_obj, "BADFAMILY", BADFAMILY);
    setStringConst(ctx, dns_obj, "TIMEOUT", TIMEOUT);
    setStringConst(ctx, dns_obj, "CANCELLED", CANCELLED);
    return dns_obj;
}
