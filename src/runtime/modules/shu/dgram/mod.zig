// shu:dgram — Node 风格 API：createSocket(type)、socket.bind、socket.send、socket.on('message')、socket.close
// 与 node:dgram 对齐；recv 使用 io_core RingBuffer + 缓冲池，零拷贝交付 Buffer，GC 时归还槽位

const std = @import("std");
const builtin = @import("builtin");
const jsc = @import("jsc");
const libs_io = @import("libs_io");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");

/// 是否 Windows（comptime 分派，用于非阻塞/socket 选项等分支）
const is_windows = builtin.os.tag == .windows;

/// Zig 0.16 无 std.net，用 posix.sockaddr 存储 + 本文件内辅助。sockaddr_storage 通常 128 字节。
const DGRAM_ADDR_STORAGE_LEN = 128;
const DgramAddr = struct {
    storage: [DGRAM_ADDR_STORAGE_LEN]u8 align(8),

    fn ptr(self: *DgramAddr) *std.posix.sockaddr {
        return @ptrCast(self);
    }
    fn len(self: *const DgramAddr) std.posix.socklen_t {
        const sa = @as(*const std.posix.sockaddr, @ptrCast(self));
        if (sa.family == std.posix.AF.INET) return @sizeOf(std.posix.sockaddr.in);
        return @sizeOf(std.posix.sockaddr.in6);
    }
    fn getPort(self: *const DgramAddr) u16 {
        const sa = @as(*const std.posix.sockaddr, @ptrCast(self));
        if (sa.family == std.posix.AF.INET) {
            const in4 = @as(*const std.posix.sockaddr.in, @ptrCast(self));
            return @byteSwap(in4.port);
        }
        const in6 = @as(*const std.posix.sockaddr.in6, @ptrCast(self));
        return @byteSwap(in6.port);
    }
    fn family(self: *const DgramAddr) u16 {
        return @as(*const std.posix.sockaddr, @ptrCast(self)).family;
    }
    /// 格式化为 "ip:port" 字符串；调用方 free 返回的 slice。
    fn formatAddress(self: *const DgramAddr, allocator: std.mem.Allocator) ![]const u8 {
        const sa = @as(*const std.posix.sockaddr, @ptrCast(self));
        const port = self.getPort();
        if (sa.family == std.posix.AF.INET) {
            const in4 = @as(*const std.posix.sockaddr.in, @ptrCast(self));
            const addr_bytes = std.mem.asBytes(&in4.addr);
            return std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}:{d}", .{ addr_bytes[0], addr_bytes[1], addr_bytes[2], addr_bytes[3], port });
        }
        const in6 = @as(*const std.posix.sockaddr.in6, @ptrCast(self));
        var buf: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.print("[", .{}) catch return std.fmt.allocPrint(allocator, "[::]:{d}", .{port});
        for (0..8) |i| {
            const a = in6.addr[i * 2];
            const b = in6.addr[i * 2 + 1];
            if (i > 0) w.print(":", .{}) catch {};
            w.print("{x:0>2}{x:0>2}", .{ a, b }) catch return std.fmt.allocPrint(allocator, "[::]:{d}", .{port});
        }
        w.print("]:{d}", .{port}) catch return std.fmt.allocPrint(allocator, "[::]:{d}", .{port});
        return allocator.dupe(u8, std.Io.Writer.buffered(&w));
    }
    fn initIp4(bytes: [4]u8, port: u16) DgramAddr {
        var addr: DgramAddr = undefined;
        @memset(&addr.storage, 0);
        const in4 = @as(*std.posix.sockaddr.in, @ptrCast(&addr));
        in4.family = std.posix.AF.INET;
        in4.port = @byteSwap(port);
        in4.addr = std.mem.readInt(u32, &bytes, .big);
        return addr;
    }
    fn initIp6(bytes: [16]u8, port: u16, flow: u32, scope: u32) DgramAddr {
        var addr: DgramAddr = undefined;
        @memset(&addr.storage, 0);
        const in6 = @as(*std.posix.sockaddr.in6, @ptrCast(&addr));
        in6.family = std.posix.AF.INET6;
        in6.port = @byteSwap(port);
        in6.flowinfo = flow;
        @memcpy(&in6.addr, &bytes);
        in6.scope_id = scope;
        return addr;
    }
    /// 用 std.Io.net.IpAddress.resolve(io, host, port) 解析后写入 storage。
    fn resolve(addr: *DgramAddr, io: std.Io, host: []const u8, port: u16) !void {
        const ip = try std.Io.net.IpAddress.resolve(io, host, port);
        switch (ip) {
            .ip4 => |a| {
                addr.* = initIp4(a.bytes, port);
            },
            .ip6 => |a| {
                addr.* = initIp6(a.bytes, port, a.flow, a.interface.index);
            },
        }
    }
};

/// 接收池槽位数；扩大可减少池满时走 makeMessageBufferCopy 拷贝路径（§3.1）
const DGRAM_RECV_POOL_SIZE = 64;
const DGRAM_RECV_BUF_SIZE = 2048;

/// 池槽位归还上下文：JSC 回收 message Buffer 时把 slot 推回 free_list，然后 destroy 本上下文
const DgramSlotContext = struct {
    allocator: std.mem.Allocator,
    slot: usize,
    free_list: *libs_io.RingBuffer(usize),
};
fn dgramSlotDeallocator(bytes: *anyopaque, deallocator_context: ?*anyopaque) callconv(.c) void {
    _ = bytes;
    const ctx = @as(*DgramSlotContext, @ptrCast(@alignCast(deallocator_context orelse return)));
    _ = ctx.free_list.push(ctx.slot);
    ctx.allocator.destroy(ctx);
}

/// 拷贝 Buffer 的归还上下文；JSC 回收时 free slice 并 destroy 本结构
const DgramCopyContext = struct { allocator: std.mem.Allocator, slice: []u8 };
fn dgramCopyDeallocator(bytes: *anyopaque, deallocator_context: ?*anyopaque) callconv(.c) void {
    _ = bytes;
    const ctx = @as(*DgramCopyContext, @ptrCast(@alignCast(deallocator_context orelse return)));
    ctx.allocator.free(ctx.slice);
    ctx.allocator.destroy(ctx);
}

/// recv 缓冲池：free_list 可用槽位，pending 待交付槽位，meta 存每槽 len+addr+socket_id
const DgramRecvPool = struct {
    buffers: [DGRAM_RECV_POOL_SIZE][]u8,
    free_list: libs_io.RingBuffer(usize),
    pending: libs_io.RingBuffer(usize),
    meta: [DGRAM_RECV_POOL_SIZE]struct { len: usize, addr: DgramAddr, socket_id: u32 },
    allocator: std.mem.Allocator,
};
var g_dgram_recv_pool: ?DgramRecvPool = null;

/// 单条 dgram socket 记录：fd、地址族、是否已 bind、创建时 ctx；Node 兼容 ref_count、broadcast、multicast_ttl
const DgramEntry = struct {
    fd: std.posix.socket_t,
    family: u32,
    bound: bool,
    ctx: jsc.JSContextRef,
    ref_count: i32 = 1,
    broadcast: bool = false,
    multicast_ttl: u32 = 1,
};
/// Unmanaged，put/fetchRemove 显式传 allocator（01 §1.2）
var g_dgram_sockets: ?std.AutoHashMapUnmanaged(u32, DgramEntry) = null;
var g_dgram_next_id: u32 = 1;
/// socket id -> JS 对象（供 on('message') 等）。Unmanaged
var g_dgram_socket_objs: ?std.AutoHashMapUnmanaged(u32, jsc.JSObjectRef) = null;

/// 首次有 bound socket 时初始化 recv 池；失败则保持 null，tick 内走栈缓冲
fn ensureDgramRecvPool() void {
    if (g_dgram_recv_pool != null) return;
    const allocator = globals.current_allocator orelse return;
    var i: usize = 0;
    var buffers: [DGRAM_RECV_POOL_SIZE][]u8 = undefined;
    while (i < DGRAM_RECV_POOL_SIZE) : (i += 1) {
        buffers[i] = allocator.alloc(u8, DGRAM_RECV_BUF_SIZE) catch return;
    }
    var free_list = libs_io.RingBuffer(usize).init(allocator, DGRAM_RECV_POOL_SIZE) catch {
        i = 0;
        while (i < DGRAM_RECV_POOL_SIZE) : (i += 1) allocator.free(buffers[i]);
        return;
    };
    const pending = libs_io.RingBuffer(usize).init(allocator, DGRAM_RECV_POOL_SIZE) catch {
        free_list.deinit(allocator);
        i = 0;
        while (i < DGRAM_RECV_POOL_SIZE) : (i += 1) allocator.free(buffers[i]);
        return;
    };
    i = 0;
    while (i < DGRAM_RECV_POOL_SIZE) : (i += 1) _ = free_list.push(i);
    g_dgram_recv_pool = .{
        .buffers = buffers,
        .free_list = free_list,
        .pending = pending,
        .meta = undefined,
        .allocator = allocator,
    };
}

/// 从池槽位创建 NoCopy Buffer（message），GC 时归还 slot
fn makeBufferFromPoolSlot(ctx: jsc.JSContextRef, slot: usize, pool: *const DgramRecvPool) jsc.JSValueRef {
    const slice = pool.buffers[slot][0..pool.meta[slot].len];
    const allocator = pool.allocator;
    const slot_ctx = allocator.create(DgramSlotContext) catch return jsc.JSValueMakeUndefined(ctx);
    slot_ctx.* = .{
        .allocator = allocator,
        .slot = slot,
        .free_list = @constCast(&pool.free_list),
    };
    var exc: jsc.JSValueRef = undefined;
    const arr = jsc.JSObjectMakeTypedArrayWithBytesNoCopy(
        ctx,
        .Uint8Array,
        @ptrCast(slice.ptr),
        slice.len,
        dgramSlotDeallocator,
        slot_ctx,
        @ptrCast(&exc),
    );
    return if (arr != null) @ptrCast(arr.?) else jsc.JSValueMakeUndefined(ctx);
}

/// 从拷贝创建 message Buffer（池不可用时的回退）；调用方不负责 free
fn makeMessageBufferCopy(ctx: jsc.JSContextRef, slice: []const u8) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const copy = allocator.dupe(u8, slice) catch return jsc.JSValueMakeUndefined(ctx);
    const dc = allocator.create(DgramCopyContext) catch {
        allocator.free(copy);
        return jsc.JSValueMakeUndefined(ctx);
    };
    dc.* = .{ .allocator = allocator, .slice = copy };
    var exc: jsc.JSValueRef = undefined;
    const arr = jsc.JSObjectMakeTypedArrayWithBytesNoCopy(ctx, .Uint8Array, copy.ptr, copy.len, dgramCopyDeallocator, dc, @ptrCast(&exc));
    return if (arr != null) @ptrCast(arr.?) else jsc.JSValueMakeUndefined(ctx);
}

/// 将 fd 设为非阻塞，便于 tick 内 recvfrom 不阻塞。Zig 0.16：std.c.fcntl 返回 c_int，不返回错误联合。
fn setNonBlocking(fd: std.posix.socket_t) void {
    if (is_windows) return;
    const flags = std.c.fcntl(fd, std.posix.F.GETFL, @as(c_int, 0));
    if (flags >= 0) _ = std.c.fcntl(fd, std.posix.F.SETFL, @as(c_int, @intCast(flags | 0x4)));
}

/// 调度下一轮 dgramTick（setImmediate），用于接收 UDP 并触发 message
fn scheduleDgramTick(ctx: jsc.JSContextRef) void {
    const k_name = jsc.JSStringCreateWithUTF8CString("__shuDgramTick");
    defer jsc.JSStringRelease(k_name);
    const tick_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_name, dgramTickCallback);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_immediate = jsc.JSStringCreateWithUTF8CString("setImmediate");
    defer jsc.JSStringRelease(k_immediate);
    const set_immediate = jsc.JSObjectGetProperty(ctx, global, k_immediate, null);
    if (jsc.JSObjectIsFunction(ctx, @ptrCast(set_immediate))) {
        var args = [_]jsc.JSValueRef{tick_fn};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(set_immediate), null, 1, &args, null);
    }
}

/// setImmediate 每轮：对已 bind 的 dgram socket 做 recvfrom（优先池缓冲+RingBuffer 队列），有数据则触发 on('message')(msg, rinfo)，msg 为 Buffer
fn dgramTickCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (g_dgram_sockets == null or g_dgram_socket_objs == null) return jsc.JSValueMakeUndefined(ctx);
    const sockets = &g_dgram_sockets.?;
    const objs = &g_dgram_socket_objs.?;
    var has_bound: bool = false;
    var has_ref: bool = false;

    if (g_dgram_recv_pool == null) ensureDgramRecvPool();

    var it = sockets.iterator();
    while (it.next()) |kv| {
        const id = kv.key_ptr.*;
        const entry = kv.value_ptr.*;
        if (!entry.bound) continue;
        has_bound = true;
        if (entry.ref_count > 0) has_ref = true;
        const socket_obj = objs.get(id) orelse continue;
        const k_on_msg = jsc.JSStringCreateWithUTF8CString("_onMessage");
        defer jsc.JSStringRelease(k_on_msg);
        const on_msg = jsc.JSObjectGetProperty(ctx, socket_obj, k_on_msg, null);
        if (!jsc.JSObjectIsFunction(ctx, @ptrCast(on_msg))) continue;

        if (g_dgram_recv_pool) |*p| {
            while (p.free_list.pop()) |slot| {
                var src_addr: DgramAddr = undefined;
                var addr_len: std.posix.socklen_t = DGRAM_ADDR_STORAGE_LEN;
                const n_raw = std.c.recvfrom(entry.fd, p.buffers[slot].ptr, p.buffers[slot].len, 0, src_addr.ptr(), &addr_len);
                if (n_raw < 0) {
                    _ = p.free_list.push(slot);
                    if (std.c.errno(n_raw) == std.posix.E.AGAIN) break;
                    break;
                }
                const n = @as(usize, @intCast(n_raw));
                if (n == 0) {
                    _ = p.free_list.push(slot);
                    break;
                }
                p.meta[slot] = .{ .len = n, .addr = src_addr, .socket_id = id };
                _ = p.pending.push(slot);
            }
        } else {
            var recv_buf: [DGRAM_RECV_BUF_SIZE]u8 = undefined;
            while (true) {
                var src_addr: DgramAddr = undefined;
                var addr_len: std.posix.socklen_t = DGRAM_ADDR_STORAGE_LEN;
                const n_raw = std.c.recvfrom(entry.fd, &recv_buf, recv_buf.len, 0, src_addr.ptr(), &addr_len);
                if (n_raw < 0) {
                    if (std.c.errno(n_raw) == std.posix.E.AGAIN) break;
                    break;
                }
                const n = @as(usize, @intCast(n_raw));
                if (n == 0) break;
                const msg_val = makeMessageBufferCopy(entry.ctx, recv_buf[0..n]);
                const rinfo = makeRinfoObject(entry.ctx, &src_addr);
                var args = [_]jsc.JSValueRef{ msg_val, rinfo };
                _ = jsc.JSObjectCallAsFunction(entry.ctx, @ptrCast(on_msg), socket_obj, 2, &args, null);
            }
        }
    }

    if (g_dgram_recv_pool) |*p| {
        while (p.pending.pop()) |slot| {
            const socket_id_for_slot = p.meta[slot].socket_id;
            const socket_obj = objs.get(socket_id_for_slot) orelse continue;
            const k_on_msg = jsc.JSStringCreateWithUTF8CString("_onMessage");
            defer jsc.JSStringRelease(k_on_msg);
            const on_msg = jsc.JSObjectGetProperty(ctx, socket_obj, k_on_msg, null);
            if (!jsc.JSObjectIsFunction(ctx, @ptrCast(on_msg))) continue;
            const msg_val = makeBufferFromPoolSlot(ctx, slot, p);
            const rinfo = makeRinfoObject(ctx, &p.meta[slot].addr);
            var args = [_]jsc.JSValueRef{ msg_val, rinfo };
            _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(on_msg), socket_obj, 2, &args, null);
        }
    }

    if (has_bound and has_ref) scheduleDgramTick(ctx);
    return jsc.JSValueMakeUndefined(ctx);
}

/// socket.ref()：Node 兼容；增加 ref_count，使 socket 参与事件循环保活
fn dgramRefCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const id = getDgramIdFromThis(ctx, this) orelse return @ptrCast(this);
    if (g_dgram_sockets) |*sockets| {
        if (sockets.getPtr(id)) |e| e.ref_count += 1;
    }
    return @ptrCast(this);
}

/// socket.unref()：Node 兼容；减少 ref_count，为 0 时不参与事件循环保活
fn dgramUnrefCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const id = getDgramIdFromThis(ctx, this) orelse return @ptrCast(this);
    if (g_dgram_sockets) |*sockets| {
        if (sockets.getPtr(id)) |e| {
            e.ref_count -= 1;
            if (e.ref_count < 0) e.ref_count = 0;
        }
    }
    return @ptrCast(this);
}

/// socket.setBroadcast(flag)：Node 兼容；设置 SO_BROADCAST
fn dgramSetBroadcastCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const id = getDgramIdFromThis(ctx, this) orelse return jsc.JSValueMakeUndefined(ctx);
    const sockets = g_dgram_sockets orelse return jsc.JSValueMakeUndefined(ctx);
    const entry = sockets.getPtr(id) orelse return jsc.JSValueMakeUndefined(ctx);
    const flag = argumentCount >= 1 and jsc.JSValueToBoolean(ctx, arguments[0]);
    entry.broadcast = flag;
    if (!is_windows) {
        const enable: c_int = if (flag) 1 else 0;
        std.posix.setsockopt(entry.fd, std.posix.SOL.SOCKET, std.posix.SO.BROADCAST, std.mem.asBytes(&enable)) catch {};
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// socket.setMulticastTTL(ttl)：Node 兼容；设置 IP_MULTICAST_TTL（IPv4）或 IPV6_MULTICAST_HOPS（IPv6）
fn dgramSetMulticastTTLCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const id = getDgramIdFromThis(ctx, this) orelse return jsc.JSValueMakeUndefined(ctx);
    const sockets = g_dgram_sockets orelse return jsc.JSValueMakeUndefined(ctx);
    const entry = sockets.getPtr(id) orelse return jsc.JSValueMakeUndefined(ctx);
    var ttl: u32 = 1;
    if (argumentCount >= 1) {
        const v = jsc.JSValueToNumber(ctx, arguments[0], null);
        if (v == v and v >= 0 and v <= 255) ttl = @intFromFloat(v);
    }
    entry.multicast_ttl = ttl;
    if (!is_windows) {
        if (entry.family == @as(u32, @intCast(std.posix.AF.INET6))) {
            const hop: c_int = @intCast(ttl);
            std.posix.setsockopt(entry.fd, std.posix.IPPROTO.IPV6, 18, std.mem.asBytes(&hop)) catch {}; // IPV6_MULTICAST_HOPS
        } else {
            const ttl_c: c_int = @intCast(ttl);
            std.posix.setsockopt(entry.fd, std.posix.IPPROTO.IP, 33, std.mem.asBytes(&ttl_c)) catch {}; // IP_MULTICAST_TTL
        }
    }
    return jsc.JSValueMakeUndefined(ctx);
}

fn makeBufferFromSlice(ctx: jsc.JSContextRef, slice: []const u8) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const z = allocator.dupeZ(u8, slice) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(z);
    const js_str = jsc.JSStringCreateWithUTF8CString(z.ptr);
    defer jsc.JSStringRelease(js_str);
    return jsc.JSValueMakeString(ctx, js_str);
}

fn makeRinfoObject(ctx: jsc.JSContextRef, addr: *const DgramAddr) jsc.JSValueRef {
    const obj = jsc.JSObjectMake(ctx, null, null);
    const allocator = globals.current_allocator orelse return obj;
    const addr_str = addr.*.formatAddress(allocator) catch return obj;
    defer allocator.free(addr_str);
    const k_addr = jsc.JSStringCreateWithUTF8CString("address");
    defer jsc.JSStringRelease(k_addr);
    const k_port = jsc.JSStringCreateWithUTF8CString("port");
    defer jsc.JSStringRelease(k_port);
    const k_family = jsc.JSStringCreateWithUTF8CString("family");
    defer jsc.JSStringRelease(k_family);
    const z = allocator.dupeZ(u8, addr_str) catch return obj;
    defer allocator.free(z);
    const addr_js = jsc.JSStringCreateWithUTF8CString(z.ptr);
    defer jsc.JSStringRelease(addr_js);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_addr, jsc.JSValueMakeString(ctx, addr_js), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_port, jsc.JSValueMakeNumber(ctx, @floatFromInt(addr.getPort())), jsc.kJSPropertyAttributeNone, null);
    const family_str = if (addr.family() == std.posix.AF.INET) "IPv4" else "IPv6";
    const fam_js = jsc.JSStringCreateWithUTF8CString(family_str);
    defer jsc.JSStringRelease(fam_js);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_family, jsc.JSValueMakeString(ctx, fam_js), jsc.kJSPropertyAttributeNone, null);
    return obj;
}

/// 返回 shu:dgram 的 exports：createSocket（与 node:dgram 对齐）
pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    _ = allocator;
    const dgram_obj = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, dgram_obj, "createSocket", createSocketCallback);
    return dgram_obj;
}

/// createSocket(type [, callback])：type 为 'udp4' 或 'udp6'，返回 dgram.Socket 形状对象
fn createSocketCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const type_str = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(type_str);
    var buf: [8]u8 = undefined;
    const n = jsc.JSStringGetUTF8CString(type_str, buf[0..].ptr, buf.len);
    const is_udp6 = (n > 0 and std.mem.indexOf(u8, buf[0..], "udp6") != null);
    const family: u32 = if (is_udp6) @intCast(std.posix.AF.INET6) else @intCast(std.posix.AF.INET);
    const fd = std.c.socket(@intCast(family), std.posix.SOCK.DGRAM, 0);
    if (fd == -1) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse {
        _ = std.c.close(fd);
        return jsc.JSValueMakeUndefined(ctx);
    };
    if (g_dgram_sockets == null) g_dgram_sockets = .{};
    if (g_dgram_socket_objs == null) g_dgram_socket_objs = .{};
    const id = g_dgram_next_id;
    g_dgram_next_id +%= 1;
    setNonBlocking(fd);
    g_dgram_sockets.?.put(allocator, id, .{ .fd = fd, .family = family, .bound = false, .ctx = ctx, .ref_count = 1, .broadcast = false, .multicast_ttl = 1 }) catch {
        _ = std.c.close(fd);
        return jsc.JSValueMakeUndefined(ctx);
    };
    const socket = makeDgramSocketObject(ctx, id);
    g_dgram_socket_objs.?.put(allocator, id, socket) catch {};
    if (argumentCount >= 2 and jsc.JSObjectIsFunction(ctx, @ptrCast(arguments[1]))) {
        var args = [_]jsc.JSValueRef{socket};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(arguments[1]), null, 1, &args, null);
    }
    return socket;
}

fn makeDgramSocketObject(ctx: jsc.JSContextRef, id: u32) jsc.JSObjectRef {
    const socket = jsc.JSObjectMake(ctx, null, null);
    const k_id = jsc.JSStringCreateWithUTF8CString("_dgramId");
    defer jsc.JSStringRelease(k_id);
    _ = jsc.JSObjectSetProperty(ctx, socket, k_id, jsc.JSValueMakeNumber(ctx, @floatFromInt(id)), jsc.kJSPropertyAttributeNone, null);
    common.setMethod(ctx, socket, "bind", dgramBindCallback);
    common.setMethod(ctx, socket, "send", dgramSendCallback);
    common.setMethod(ctx, socket, "close", dgramCloseCallback);
    common.setMethod(ctx, socket, "address", dgramAddressCallback);
    common.setMethod(ctx, socket, "ref", dgramRefCallback);
    common.setMethod(ctx, socket, "unref", dgramUnrefCallback);
    common.setMethod(ctx, socket, "setBroadcast", dgramSetBroadcastCallback);
    common.setMethod(ctx, socket, "setMulticastTTL", dgramSetMulticastTTLCallback);
    common.setMethod(ctx, socket, "on", dgramOnCallback);
    return socket;
}

/// socket.address()：Node 兼容；返回 { address, port, family }，未 bind 时行为未定义（由 getsockname 取得）
fn dgramAddressCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const id = getDgramIdFromThis(ctx, this) orelse return jsc.JSValueMakeUndefined(ctx);
    const sockets = g_dgram_sockets orelse return jsc.JSValueMakeUndefined(ctx);
    const entry = sockets.get(id) orelse return jsc.JSValueMakeUndefined(ctx);
    var addr: DgramAddr = undefined;
    var len: std.posix.socklen_t = DGRAM_ADDR_STORAGE_LEN;
    if (std.c.getsockname(entry.fd, addr.ptr(), &len) != 0) return jsc.JSValueMakeUndefined(ctx);
    return makeRinfoObject(ctx, &addr);
}

fn getDgramIdFromThis(ctx: jsc.JSContextRef, this: jsc.JSObjectRef) ?u32 {
    const k = jsc.JSStringCreateWithUTF8CString("_dgramId");
    defer jsc.JSStringRelease(k);
    const v = jsc.JSObjectGetProperty(ctx, this, k, null);
    const num = jsc.JSValueToNumber(ctx, v, null);
    if (num != num or num < 0) return null;
    return @as(u32, @intFromFloat(num));
}

/// socket.bind(port[, address][, callback])
fn dgramBindCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const id = getDgramIdFromThis(ctx, this) orelse return jsc.JSValueMakeUndefined(ctx);
    const sockets = g_dgram_sockets orelse return jsc.JSValueMakeUndefined(ctx);
    const entry = sockets.getPtr(id) orelse return jsc.JSValueMakeUndefined(ctx);
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const port_n = jsc.JSValueToNumber(ctx, arguments[0], null);
    if (port_n != port_n or port_n < 0 or port_n > 65535) return jsc.JSValueMakeUndefined(ctx);
    const port = @as(u16, @intFromFloat(port_n));
    var addr: DgramAddr = if (entry.family == @as(u32, @intCast(std.posix.AF.INET6)))
        DgramAddr.initIp6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, port, 0, 0)
    else
        DgramAddr.initIp4(.{ 0, 0, 0, 0 }, port);
    if (argumentCount >= 2 and !jsc.JSValueIsUndefined(ctx, arguments[1])) {
        var host_buf: [256]u8 = undefined;
        const js_str = jsc.JSValueToStringCopy(ctx, arguments[1], null);
        defer jsc.JSStringRelease(js_str);
        const n = jsc.JSStringGetUTF8CString(js_str, host_buf[0..].ptr, host_buf.len);
        if (n > 0) {
            const host = host_buf[0 .. n - 1];
            const io = libs_io.getProcessIo() orelse return jsc.JSValueMakeUndefined(ctx);
            addr.resolve(io, host, port) catch return jsc.JSValueMakeUndefined(ctx);
        }
    }
    if (std.c.bind(entry.fd, addr.ptr(), addr.len()) != 0) return jsc.JSValueMakeUndefined(ctx);
    entry.bound = true;
    scheduleDgramTick(ctx);
    if (argumentCount >= 3 and jsc.JSObjectIsFunction(ctx, @ptrCast(arguments[2]))) {
        var args = [_]jsc.JSValueRef{this};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(arguments[2]), this, 1, &args, null);
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// socket.send(msg[, offset, length][, port][, address][, callback])：Node 兼容重载；msg 支持 string 或 Buffer/TypedArray；(msg, port, address) 与 (msg, offset, length, port, address, callback)；callback(err, bytes)
fn dgramSendCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const id = getDgramIdFromThis(ctx, this) orelse return jsc.JSValueMakeUndefined(ctx);
    const sockets = g_dgram_sockets orelse return jsc.JSValueMakeUndefined(ctx);
    const entry = sockets.getPtr(id) orelse return jsc.JSValueMakeUndefined(ctx);
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const msg_val = arguments[0];
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);

    // Node 兼容：msg 可为 Buffer/Uint8Array 或 string；优先按 TypedArray 取字节
    var data_slice: []const u8 = undefined;
    var data_len: usize = 0;
    var stack_buf: [65507]u8 = undefined;
    const typ = jsc.JSValueGetTypedArrayType(ctx, msg_val, null);
    if (typ != .None) {
        const obj = jsc.JSValueToObject(ctx, msg_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
        const byte_len = jsc.JSObjectGetTypedArrayByteLength(ctx, obj);
        const src_ptr = jsc.JSObjectGetTypedArrayBytesPtr(ctx, obj, null) orelse return jsc.JSValueMakeUndefined(ctx);
        if (byte_len > stack_buf.len) return jsc.JSValueMakeUndefined(ctx);
        data_slice = @as([*]const u8, @ptrCast(src_ptr))[0..byte_len];
        data_len = byte_len;
    } else {
        const js_str = jsc.JSValueToStringCopy(ctx, msg_val, null);
        defer jsc.JSStringRelease(js_str);
        const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(js_str);
        if (max_sz == 0 or max_sz > stack_buf.len) return jsc.JSValueMakeUndefined(ctx);
        const total_len = jsc.JSStringGetUTF8CString(js_str, stack_buf[0..].ptr, stack_buf.len);
        if (total_len == 0) return jsc.JSValueMakeUndefined(ctx);
        data_len = total_len - 1;
        data_slice = stack_buf[0..data_len];
    }

    const n1 = if (argumentCount >= 2) jsc.JSValueToNumber(ctx, arguments[1], null) else std.math.nan(f64);
    const n2 = if (argumentCount >= 3) jsc.JSValueToNumber(ctx, arguments[2], null) else std.math.nan(f64);
    const use_offset_length = argumentCount >= 3 and n1 == n1 and n2 == n2 and n1 >= 0 and n2 >= 0 and @as(usize, @intFromFloat(n1)) + @as(usize, @intFromFloat(n2)) <= data_len;
    const offset: usize = if (use_offset_length) @intFromFloat(n1) else 0;
    const length: usize = if (use_offset_length) @intFromFloat(n2) else data_len;
    const port_idx: usize = if (use_offset_length) 3 else 1;
    const address_idx: usize = if (use_offset_length) 4 else 2;
    const port: u16 = if (argumentCount > port_idx) @as(u16, @intFromFloat(jsc.JSValueToNumber(ctx, arguments[port_idx], null))) else 0;
    var dest_addr: DgramAddr = if (entry.family == @as(u32, @intCast(std.posix.AF.INET6)))
        DgramAddr.initIp6(.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }, port, 0, 0)
    else
        DgramAddr.initIp4(.{ 127, 0, 0, 1 }, port);
    if (argumentCount > address_idx and !jsc.JSObjectIsFunction(ctx, @ptrCast(arguments[address_idx]))) {
        var host_buf: [256]u8 = undefined;
        const hs = jsc.JSValueToStringCopy(ctx, arguments[address_idx], null);
        defer jsc.JSStringRelease(hs);
        const hn = jsc.JSStringGetUTF8CString(hs, host_buf[0..].ptr, host_buf.len);
        if (hn > 0) {
            const io = libs_io.getProcessIo() orelse return jsc.JSValueMakeUndefined(ctx);
            dest_addr.resolve(io, host_buf[0 .. hn - 1], port) catch return jsc.JSValueMakeUndefined(ctx);
        }
    }
    const send_result = std.c.sendto(entry.fd, data_slice[offset..].ptr, length, 0, dest_addr.ptr(), dest_addr.len());
    const cb_val = if (argumentCount >= 2 and jsc.JSObjectIsFunction(ctx, @ptrCast(arguments[argumentCount - 1]))) arguments[argumentCount - 1] else null;
    if (cb_val != null) {
        if (send_result >= 0) {
            const global = jsc.JSContextGetGlobalObject(ctx);
            const k_null = jsc.JSStringCreateWithUTF8CString("null");
            defer jsc.JSStringRelease(k_null);
            const null_val = jsc.JSObjectGetProperty(ctx, global, k_null, null);
            var args = [_]jsc.JSValueRef{ null_val, jsc.JSValueMakeNumber(ctx, @floatFromInt(length)) };
            _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(cb_val), this, 2, &args, null);
        } else {
            const err_str = std.fmt.allocPrint(allocator, "send failed (errno {d})", .{std.c.errno(send_result)}) catch "send failed";
            defer allocator.free(err_str);
            const z = allocator.dupeZ(u8, err_str) catch "";
            defer if (z.len > 0) allocator.free(z);
            const k_error = jsc.JSStringCreateWithUTF8CString("Error");
            defer jsc.JSStringRelease(k_error);
            const global = jsc.JSContextGetGlobalObject(ctx);
            const ErrorCtor = jsc.JSObjectGetProperty(ctx, global, k_error, null);
            const js_msg = jsc.JSStringCreateWithUTF8CString(if (z.len > 0) z.ptr else "send failed");
            defer jsc.JSStringRelease(js_msg);
            const err_val = jsc.JSValueMakeString(ctx, js_msg);
            var cb_args = [_]jsc.JSValueRef{ jsc.JSObjectCallAsConstructor(ctx, @ptrCast(ErrorCtor), 1, &[_]jsc.JSValueRef{err_val}, null), jsc.JSValueMakeUndefined(ctx) };
            _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(cb_val), this, 2, &cb_args, null);
        }
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// socket.close([callback])
fn dgramCloseCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const id = getDgramIdFromThis(ctx, this) orelse return jsc.JSValueMakeUndefined(ctx);
    if (g_dgram_sockets) |*sockets| {
        if (sockets.fetchRemove(id)) |kv| _ = std.c.close(kv.value.fd);
    }
    if (g_dgram_socket_objs) |*objs| _ = objs.fetchRemove(id);
    if (argumentCount >= 1 and jsc.JSObjectIsFunction(ctx, @ptrCast(arguments[0]))) {
        var args = [_]jsc.JSValueRef{this};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(arguments[0]), this, 1, &args, null);
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// socket.on(event, callback)：支持 'message'、'error'、'close' 等，存到 _onMessage/_onError/_onClose
fn dgramOnCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return @ptrCast(this);
    var buf: [32]u8 = undefined;
    const ev = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(ev);
    const n = jsc.JSStringGetUTF8CString(ev, buf[0..].ptr, buf.len);
    if (n == 0) return @ptrCast(this);
    const k = if (std.mem.indexOf(u8, buf[0..], "message") != null)
        "_onMessage"
    else if (std.mem.indexOf(u8, buf[0..], "error") != null)
        "_onError"
    else if (std.mem.indexOf(u8, buf[0..], "close") != null)
        "_onClose"
    else
        return @ptrCast(this);
    var k_buf: [16]u8 = undefined;
    const copy_len = @min(k.len, k_buf.len - 1);
    @memcpy(k_buf[0..copy_len], k[0..copy_len]);
    k_buf[copy_len] = 0;
    const k_str = jsc.JSStringCreateWithUTF8CString(k_buf[0..].ptr);
    defer jsc.JSStringRelease(k_str);
    _ = jsc.JSObjectSetProperty(ctx, this, k_str, arguments[1], jsc.kJSPropertyAttributeNone, null);
    return @ptrCast(this);
}
