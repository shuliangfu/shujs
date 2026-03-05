// Thread-per-Core + 多环：N 个 I/O 线程（每线程一环 + CPU 亲和性）+ 无锁 Ring 向单 JS 线程投递（00 §3.5、§4.2） //
// 职责：io_threads > 1 时创建 N 个 listen fd（SO_REUSEPORT）、N 个 HighPerfIO、N×SPSC RingBuffer，
//       I/O 线程 poll → 完成项入 ring_to_js；JS 线程 tick 侧 drain ring → 处理 → 将 submitRecv/submitSend 入 ring_from_js；
//       I/O 线程 drain ring_from_js 执行 submit。当前仅 Linux/macOS TCP 支持 io_threads > 1。
// 依赖：constants、libs_io、state、tick（tick 侧消费 ring 的逻辑在 tick.zig 中按 state.io_threads_ctx 分派）。

const std = @import("std");
const builtin = @import("builtin");
const constants = @import("constants.zig");
const libs_io = @import("libs_io");
const state_mod = @import("state.zig");

const ServerState = state_mod.ServerState;

/// 完成项槽位：与 libs_io.api.Completion 布局一致，用于跨线程拷贝（I/O 线程写入，JS 线程读取）
pub const CompletionSlot = libs_io.api.Completion;

/// 由 JS 线程投递给 I/O 线程的工作类型：submitRecv 或 submitSend
pub const WorkTag = enum(u8) {
    submit_recv,
    submit_send,
};

/// 单条工作项：I/O 线程从 ring_from_js 取出索引后据此执行；submit_send 时 data_ptr 在 submit 完成前须保持有效（由 JS 侧保证）
pub const WorkEntry = struct {
    tag: WorkTag,
    fd: usize,
    stream: std.Io.net.Stream,
    /// 仅 submit_send 时有效；ptr[0..len] 须在 I/O 线程 submitSend 前保持有效
    send_ptr: [*]const u8 = undefined,
    send_len: usize = 0,
};

/// 单条 I/O 线程上下文：一环、双栈 listen_fd（v4/v6 可仅其一有效）、完成项槽位池、四个 RingBuffer
pub const IoThreadCtx = struct {
    thread_index: u32,
    hio: *libs_io.HighPerfIO,
    buffer_pool: libs_io.api.BufferPool,
    /// IPv4 listen fd；-1 表示本线程未监听 IPv4
    listen_fd_v4: i32 = -1,
    /// IPv6 listen fd；-1 表示本线程未监听 IPv6
    listen_fd_v6: i32 = -1,
    completion_slots: []CompletionSlot,
    /// I/O → JS：完成项槽位索引
    ring_to_js: libs_io.RingBuffer(usize),
    work_pool: []WorkEntry,
    /// JS → I/O：工作项索引
    ring_from_js: libs_io.RingBuffer(usize),
    /// JS → I/O：归还完成项槽位索引以便复用
    ring_return_slots: libs_io.RingBuffer(usize),
    /// I/O → JS：归还 work 槽位索引以便复用（可选，若用固定池可省略）
    ring_work_free: libs_io.RingBuffer(usize),
    allocator: std.mem.Allocator,
    /// 停止标志：I/O 线程轮询此值，非 0 时退出循环
    stop: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

/// Thread-per-Core 根上下文：N 个 IoThreadCtx、N 个线程句柄、双栈 listen fd 列表
pub const IoThreadsContext = struct {
    allocator: std.mem.Allocator,
    n_threads: u32,
    listen_fds_v4: []i32,
    listen_fds_v6: []i32,
    threads: []IoThreadCtx,
    thread_handles: []std.Thread,
    state: *ServerState,
};

/// 双栈 listen fd 结果：v4 与 v6 可分别为空；调用方负责 close 所有 fd 并 free 两个 slice
pub const ListenFdsResult = struct {
    v4: []i32,
    v6: []i32,
};

/// 是否为「任意地址」双栈（同时监听 IPv4 + IPv6）
fn isDualStackHost(host: []const u8) bool {
    if (host.len == 0) return true;
    if (std.mem.eql(u8, host, "0.0.0.0") or std.mem.eql(u8, host, "::")) return true;
    return false;
}

/// 创建 N 个 IPv4 listen socket（SO_REUSEPORT），绑定给定地址；addr_bytes 为 null 时绑定 0.0.0.0
fn createV4ListenFds(
    allocator: std.mem.Allocator,
    port: u16,
    backlog: u31,
    n: u32,
    addr_bytes: ?[4]u8,
) ![]i32 {
    const posix = std.posix;
    const fds = try allocator.alloc(i32, n);
    errdefer allocator.free(fds);
    var sa: posix.sockaddr.in = .{
        .family = posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = if (addr_bytes) |b| std.mem.readInt(u32, &b, .big) else 0,
        .zero = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 },
    };
    for (0..n) |i| {
        const raw = std.c.socket(@intCast(posix.AF.INET), @intCast(posix.SOCK.STREAM | posix.SOCK.CLOEXEC), 0);
        if (raw == -1) {
            for (fds[0..i]) |f| _ = std.c.close(f);
            return std.posix.unexpectedErrno(std.c.errno(-1));
        }
        const fd = @as(i32, @intCast(raw));
        var opt: c_int = 1;
        if (std.c.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&opt).ptr, @sizeOf(c_int)) != 0) {
            _ = std.c.close(fd);
            for (fds[0..i]) |f| _ = std.c.close(f);
            return std.posix.unexpectedErrno(std.c.errno(-1));
        }
        if (builtin.os.tag == .linux) {
            _ = std.c.setsockopt(fd, posix.SOL.SOCKET, 15, std.mem.asBytes(&opt).ptr, @sizeOf(c_int));
        } else if (builtin.os.tag == .macos or builtin.os.tag == .freebsd) {
            _ = std.c.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, std.mem.asBytes(&opt).ptr, @sizeOf(c_int));
        }
        if (std.c.bind(fd, @as(*const posix.sockaddr, @ptrCast(&sa)), @sizeOf(posix.sockaddr.in)) != 0) {
            _ = std.c.close(fd);
            for (fds[0..i]) |f| _ = std.c.close(f);
            return std.posix.unexpectedErrno(std.c.errno(-1));
        }
        if (std.c.listen(fd, backlog) != 0) {
            _ = std.c.close(fd);
            for (fds[0..i]) |f| _ = std.c.close(f);
            return std.posix.unexpectedErrno(std.c.errno(-1));
        }
        fds[i] = @intCast(fd);
    }
    return fds;
}

/// 创建 N 个 IPv6 listen socket（SO_REUSEPORT），绑定给定地址；addr_bytes 为 null 时绑定 ::（SO_REUSEPORT），绑定给定地址；addr_bytes 为 null 时绑定 ::
fn createV6ListenFds(
    allocator: std.mem.Allocator,
    port: u16,
    backlog: u31,
    n: u32,
    addr_bytes: ?[16]u8,
) ![]i32 {
    const posix = std.posix;
    const fds = try allocator.alloc(i32, n);
    errdefer allocator.free(fds);
    var sa: posix.sockaddr.in6 = .{
        .family = posix.AF.INET6,
        .port = std.mem.nativeToBig(u16, port),
        .flowinfo = 0,
        .addr = addr_bytes orelse [_]u8{0} ** 16,
        .scope_id = 0,
    };
    for (0..n) |i| {
        const raw = std.c.socket(@intCast(posix.AF.INET6), @intCast(posix.SOCK.STREAM | posix.SOCK.CLOEXEC), 0);
        if (raw == -1) {
            for (fds[0..i]) |f| _ = std.c.close(f);
            return std.posix.unexpectedErrno(std.c.errno(-1));
        }
        const fd = @as(i32, @intCast(raw));
        var opt: c_int = 1;
        if (std.c.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&opt).ptr, @sizeOf(c_int)) != 0) {
            _ = std.c.close(fd);
            for (fds[0..i]) |f| _ = std.c.close(f);
            return std.posix.unexpectedErrno(std.c.errno(-1));
        }
        if (builtin.os.tag == .linux) {
            _ = std.c.setsockopt(fd, posix.SOL.SOCKET, 15, std.mem.asBytes(&opt).ptr, @sizeOf(c_int));
        } else if (builtin.os.tag == .macos or builtin.os.tag == .freebsd) {
            _ = std.c.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, std.mem.asBytes(&opt).ptr, @sizeOf(c_int));
        }
        var v6only: c_int = 1;
        // IPV6_V6ONLY = 1 (POSIX)
        _ = std.c.setsockopt(fd, posix.IPPROTO.IPV6, 1, @as(?*const anyopaque, @ptrCast(&v6only)), @as(std.c.socklen_t, @intCast(@sizeOf(c_int))));
        if (std.c.bind(fd, @as(*const posix.sockaddr, @ptrCast(&sa)), @sizeOf(posix.sockaddr.in6)) != 0) {
            _ = std.c.close(fd);
            for (fds[0..i]) |f| _ = std.c.close(f);
            return std.posix.unexpectedErrno(std.c.errno(-1));
        }
        if (std.c.listen(fd, backlog) != 0) {
            _ = std.c.close(fd);
            for (fds[0..i]) |f| _ = std.c.close(f);
            return std.posix.unexpectedErrno(std.c.errno(-1));
        }
        fds[i] = @intCast(fd);
    }
    return fds;
}

/// 创建 N 个 listen socket（SO_REUSEPORT），支持 IPv4、IPv6 或双栈；失败返回 error，调用方负责 close 并 free
/// host 为空或 "0.0.0.0"/"::" 时创建双栈（n 个 v4 + n 个 v6）；否则按 parse 结果只创建对应族
/// 仅 Linux/macOS 实现；Windows 返回 error.UnsupportedOs
fn createListenFdsReusePort(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    backlog: u31,
    n: u32,
) !ListenFdsResult {
    if (builtin.os.tag == .windows) return error.UnsupportedOs;

    if (isDualStackHost(host)) {
        const v4 = try createV4ListenFds(allocator, port, backlog, n, null);
        errdefer {
            for (v4) |fd| _ = std.c.close(fd);
            allocator.free(v4);
        }
        const v6 = try createV6ListenFds(allocator, port, backlog, n, null);
        errdefer {
            for (v6) |fd| _ = std.c.close(fd);
            allocator.free(v6);
            for (v4) |fd| _ = std.c.close(fd);
            allocator.free(v4);
        }
        return .{ .v4 = v4, .v6 = v6 };
    }

    var host_buf: [256]u8 = undefined;
    if (host.len >= 256) return error.HostTooLong;
    @memcpy(host_buf[0..host.len], host);
    host_buf[host.len] = 0;
    const addr = std.Io.net.IpAddress.parse(host_buf[0..host.len :0], port) catch return error.InvalidHost;

    switch (addr) {
        .ip4 => |a| {
            const v4 = try createV4ListenFds(allocator, port, backlog, n, a.bytes);
            const v6_empty = try allocator.alloc(i32, 0);
            return .{ .v4 = v4, .v6 = v6_empty };
        },
        .ip6 => |a| {
            const v6 = try createV6ListenFds(allocator, port, backlog, n, a.bytes);
            const v4_empty = try allocator.alloc(i32, 0);
            return .{ .v4 = v4_empty, .v6 = v6 };
        },
    }
}

/// I/O 线程主循环：绑核 → poll → 完成项入 ring_to_js → drain ring_from_js 执行 work → 补 accept
fn ioThreadLoop(ctx: *IoThreadCtx, poll_timeout_ns: i64) void {
    if (builtin.os.tag == .linux) {
        const c = @cImport({ @cDefine("_GNU_SOURCE", "1"); @cInclude("sched.h"); });
        var cpu_set: c.cpu_set_t = undefined;
        c.CPU_ZERO(&cpu_set);
        c.CPU_SET(@intCast(ctx.thread_index), &cpu_set);
        _ = c.sched_setaffinity(0, @sizeOf(c.cpu_set_t), &cpu_set);
    } else if (builtin.os.tag == .windows) {
        _ = std.os.windows.kernel32.SetThreadAffinityMask(
            std.os.windows.kernel32.GetCurrentThread(),
            @as(std.os.windows.DWORD_PTR, 1) << @intCast(ctx.thread_index),
        );
    }
    const hio = ctx.hio;
    while (ctx.stop.load(.acquire) == 0) {
        const comps = hio.pollCompletions(poll_timeout_ns);
        for (comps) |*c| {
            const slot = ctx.ring_return_slots.pop() orelse continue;
            ctx.completion_slots[slot] = c.*;
            _ = ctx.ring_to_js.push(slot);
        }
        while (ctx.ring_from_js.pop()) |work_idx| {
            const work = &ctx.work_pool[work_idx];
            switch (work.tag) {
                .submit_recv => hio.submitRecv(work.stream, work.fd),
                .submit_send => hio.submitSend(work.stream, work.send_ptr[0..work.send_len], work.fd),
            }
            _ = ctx.ring_work_free.push(work_idx);
        }
        var refill: u32 = 0;
        const max_refill = 8;
        while (refill < max_refill) : (refill += 1) {
            if (ctx.listen_fd_v4 >= 0) {
                if (builtin.os.tag == .linux) {
                    hio.submitAcceptWithBuffer(@intCast(ctx.listen_fd_v4), 0, 0);
                } else {
                    hio.submitAcceptWithBuffer(@intCast(ctx.listen_fd_v4), 0);
                }
            }
            if (ctx.listen_fd_v6 >= 0) {
                if (builtin.os.tag == .linux) {
                    hio.submitAcceptWithBuffer(@intCast(ctx.listen_fd_v6), 0, 0);
                } else {
                    hio.submitAcceptWithBuffer(@intCast(ctx.listen_fd_v6), 0);
                }
            }
        }
    }
}

/// 初始化 Thread-per-Core 上下文；io_threads==1 或 use_unix 时返回 null（沿用单线程）；失败返回 error
pub fn init(
    allocator: std.mem.Allocator,
    state: *ServerState,
    n: u32,
    host: []const u8,
    port: u16,
) !?*IoThreadsContext {
    if (n <= 1 or state.use_unix) return null;
    if (builtin.os.tag == .windows) return null;

    const config = &state.config;
    const listen_result = try createListenFdsReusePort(
        allocator,
        host,
        port,
        state.listen_backlog,
        n,
    );
    errdefer {
        for (listen_result.v4) |fd| _ = std.c.close(fd);
        for (listen_result.v6) |fd| _ = std.c.close(fd);
        allocator.free(listen_result.v4);
        allocator.free(listen_result.v6);
    }

    const threads = try allocator.alloc(IoThreadCtx, n);
    errdefer allocator.free(threads);
    var thread_handles = try allocator.alloc(std.Thread, n);
    errdefer allocator.free(thread_handles);

    const completion_slots_per = constants.IO_THREAD_COMPLETION_SLOTS;
    const work_slots_per = constants.IO_THREAD_WORK_SLOTS;

    for (0..n) |i| {
        const pool_size = config.max_connections * (64 * 1024);
        var buffer_pool = libs_io.api.BufferPool.allocAligned(allocator, pool_size) catch {
            for (threads[0..i]) |*t| {
                t.buffer_pool.deinit();
                t.hio.deinit();
                allocator.destroy(t.hio);
                t.ring_to_js.deinit(allocator);
                t.ring_from_js.deinit(allocator);
                t.ring_return_slots.deinit(allocator);
                t.ring_work_free.deinit(allocator);
                allocator.free(t.completion_slots);
                allocator.free(t.work_pool);
            }
            for (listen_result.v4) |fd| _ = std.c.close(fd);
            for (listen_result.v6) |fd| _ = std.c.close(fd);
            allocator.free(listen_result.v4);
            allocator.free(listen_result.v6);
            allocator.free(threads);
            allocator.free(thread_handles);
            return error.OutOfMemory;
        };
        const hio = try allocator.create(libs_io.HighPerfIO);
        hio.* = libs_io.HighPerfIO.init(allocator, .{
            .max_connections = config.max_connections,
            .max_completions = config.max_completions,
            .linux_sq_thread_cpu = config.linux_sq_thread_cpu,
        }) catch {
            buffer_pool.deinit();
            allocator.destroy(hio);
            for (threads[0..i]) |*t| {
                t.buffer_pool.deinit();
                t.hio.deinit();
                allocator.destroy(t.hio);
                t.ring_to_js.deinit(allocator);
                t.ring_from_js.deinit(allocator);
                t.ring_return_slots.deinit(allocator);
                t.ring_work_free.deinit(allocator);
                allocator.free(t.completion_slots);
                allocator.free(t.work_pool);
            }
            for (listen_result.v4) |fd| _ = std.c.close(fd);
            for (listen_result.v6) |fd| _ = std.c.close(fd);
            allocator.free(listen_result.v4);
            allocator.free(listen_result.v6);
            allocator.free(threads);
            allocator.free(thread_handles);
            return error.OutOfMemory;
        };
        hio.registerBufferPool(&buffer_pool);
        const completion_slots = try allocator.alloc(CompletionSlot, completion_slots_per);
        const ring_to_js = try libs_io.RingBuffer(usize).init(allocator, completion_slots_per);
        const work_pool = try allocator.alloc(WorkEntry, work_slots_per);
        // work_pool 槽位在 JS 线程写入后才会被 I/O 线程读取，无需先填默认值
        const ring_from_js = try libs_io.RingBuffer(usize).init(allocator, work_slots_per);
        var ring_return_slots = try libs_io.RingBuffer(usize).init(allocator, completion_slots_per);
        var ring_work_free = try libs_io.RingBuffer(usize).init(allocator, work_slots_per);
        for (0..completion_slots_per) |s| _ = ring_return_slots.push(s);
        for (0..work_slots_per) |w| _ = ring_work_free.push(w);

        threads[i] = .{
            .thread_index = @intCast(i),
            .hio = hio,
            .buffer_pool = buffer_pool,
            .listen_fd_v4 = if (listen_result.v4.len > i) listen_result.v4[i] else -1,
            .listen_fd_v6 = if (listen_result.v6.len > i) listen_result.v6[i] else -1,
            .completion_slots = completion_slots,
            .ring_to_js = ring_to_js,
            .work_pool = work_pool,
            .ring_from_js = ring_from_js,
            .ring_return_slots = ring_return_slots,
            .ring_work_free = ring_work_free,
            .allocator = allocator,
        };
    }

    const root = try allocator.create(IoThreadsContext);
    root.* = .{
        .allocator = allocator,
        .n_threads = n,
        .listen_fds_v4 = listen_result.v4,
        .listen_fds_v6 = listen_result.v6,
        .threads = threads,
        .thread_handles = thread_handles,
        .state = state,
    };

    const poll_timeout_ns: i64 = if (config.io_core_poll_idle_ms > 0) config.io_core_poll_idle_ms * std.time.ns_per_ms else 0;
    for (threads, 0..) |*t, i| {
        thread_handles[i] = try std.Thread.spawn(.{}, ioThreadLoop, .{ t, poll_timeout_ns });
    }
    return root;
}

/// 停止所有 I/O 线程并释放资源
pub fn deinit(root: *IoThreadsContext) void {
    for (root.threads) |*t| t.stop.store(1, .release);
    for (root.thread_handles) |h| h.join();
    root.allocator.free(root.thread_handles);
    for (root.threads) |*t| {
        t.buffer_pool.deinit();
        t.hio.deinit();
        root.allocator.destroy(t.hio);
        t.ring_to_js.deinit(root.allocator);
        t.ring_from_js.deinit(root.allocator);
        t.ring_return_slots.deinit(root.allocator);
        t.ring_work_free.deinit(root.allocator);
        root.allocator.free(t.completion_slots);
        root.allocator.free(t.work_pool);
    }
    root.allocator.free(root.threads);
    for (root.listen_fds_v4) |fd| _ = std.c.close(fd);
    for (root.listen_fds_v6) |fd| _ = std.c.close(fd);
    root.allocator.free(root.listen_fds_v4);
    root.allocator.free(root.listen_fds_v6);
    root.allocator.destroy(root);
}
