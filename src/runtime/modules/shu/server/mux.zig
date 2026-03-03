// 多路复用：epoll / kqueue / io_uring / poll 的创建、注册、等待（从 mod.zig 拆出）
//
// 职责：setNonBlocking、setTcpNoDelay、muxPollerCreate/Add/UpdateWrite/Remove、muxIoUringWait、muxPollerWait。
// 依赖：state、constants。

const std = @import("std");
const builtin = @import("builtin");
const state_mod = @import("state.zig");
const constants = @import("constants.zig");

const ServerState = state_mod.ServerState;
const use_epoll = constants.use_epoll;
const use_kqueue = constants.use_kqueue;
const use_io_uring = constants.use_io_uring;

// ------------------------------------------------------------------------------
// 套接字选项
// ------------------------------------------------------------------------------

/// 将 fd/socket 设为非阻塞：POSIX 用 fcntl O_NONBLOCK，Windows 用 ioctlsocket FIONBIO
pub fn setNonBlocking(fd: std.posix.socket_t) void {
    if (builtin.os.tag == .windows) {
        var mode: std.c.uint = 1;
        _ = std.c.ioctlsocket(fd, std.c.FIONBIO, &mode);
        return;
    }
    const flags = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
    if (flags < 0) return;
    _ = std.c.fcntl(fd, std.c.F.SETFL, flags | 0x4);
}

/// 对已 accept 的 TCP stream 设置 TCP_NODELAY，降低小包延迟；非 POSIX 或失败时静默忽略
pub fn setTcpNoDelay(stream: *const std.Io.net.Stream) void {
    if (builtin.os.tag == .windows) return;
    const one: u32 = 1;
    std.posix.setsockopt(stream.socket.handle, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, std.mem.asBytes(&one)) catch {};
}

// ------------------------------------------------------------------------------
// epoll / kqueue / io_uring 多路复用
// ------------------------------------------------------------------------------

/// 创建 poller 并注册 server_fd；失败返回 error，成功写入 state.plain_mux.poller_fd
pub fn muxPollerCreate(state: *ServerState, server_fd: std.posix.socket_t) !void {
    if (state.plain_mux.poller_fd >= 0) return;
    if (use_epoll) {
        const epfd = std.posix.epoll_create1(0) catch return error.SystemResources;
        errdefer std.posix.close(epfd);
        var ev: std.posix.epoll_event = .{ .events = std.posix.EPOLL.IN, .data = .{ .fd = @intCast(server_fd) } };
        std.posix.epoll_ctl(epfd, std.posix.EPOLL.CTL_ADD, @intCast(server_fd), &ev) catch {
            std.posix.close(epfd);
            return error.SystemResources;
        };
        state.plain_mux.poller_fd = epfd;
    } else if (use_kqueue) {
        const kq = std.posix.kqueue() catch return error.SystemResources;
        errdefer std.posix.close(kq);
        var ch = [_]std.posix.Kevent{.{
            .ident = @intCast(server_fd),
            .filter = std.posix.system.EVFILT.READ,
            .flags = std.posix.system.EV.ADD,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        }};
        var no_ev: [0]std.posix.Kevent = undefined;
        _ = std.posix.kevent(kq, ch[0..], no_ev[0..], null) catch {
            std.posix.close(kq);
            return error.SystemResources;
        };
        state.plain_mux.poller_fd = kq;
    }
}

/// 向 poller 注册 client fd；want_write 为 true 时同时监听可写
pub fn muxPollerAdd(state: *ServerState, fd: std.posix.socket_t, want_write: bool) void {
    const pfd = state.plain_mux.poller_fd;
    if (pfd < 0) return;
    if (use_epoll) {
        var ev: std.posix.epoll_event = .{
            .events = std.posix.EPOLL.IN | (if (want_write) std.posix.EPOLL.OUT else 0),
            .data = .{ .fd = @intCast(fd) },
        };
        std.posix.epoll_ctl(pfd, std.posix.EPOLL.CTL_ADD, @intCast(fd), &ev) catch {};
    } else if (use_kqueue) {
        var kev: [2]std.posix.Kevent = undefined;
        kev[0] = .{ .ident = @intCast(fd), .filter = std.posix.system.EVFILT.READ, .flags = std.posix.system.EV.ADD, .fflags = 0, .data = 0, .udata = 0 };
        var n: usize = 1;
        if (want_write) {
            kev[1] = .{ .ident = @intCast(fd), .filter = std.posix.system.EVFILT.WRITE, .flags = std.posix.system.EV.ADD, .fflags = 0, .data = 0, .udata = 0 };
            n = 2;
        }
        var no_ev: [0]std.posix.Kevent = undefined;
        _ = std.posix.kevent(pfd, kev[0..n], no_ev[0..], null) catch {};
    }
}

/// 更新 client fd 的可写监听（writing 阶段需要 OUT，否则去掉）
pub fn muxPollerUpdateWrite(state: *ServerState, fd: std.posix.socket_t, want_write: bool) void {
    const pfd = state.plain_mux.poller_fd;
    if (pfd < 0) return;
    if (use_epoll) {
        var ev: std.posix.epoll_event = .{
            .events = std.posix.EPOLL.IN | (if (want_write) std.posix.EPOLL.OUT else 0),
            .data = .{ .fd = @intCast(fd) },
        };
        std.posix.epoll_ctl(pfd, std.posix.EPOLL.CTL_MOD, @intCast(fd), &ev) catch {};
    } else if (use_kqueue) {
        var ch = [_]std.posix.Kevent{.{
            .ident = @intCast(fd),
            .filter = std.posix.system.EVFILT.WRITE,
            .flags = if (want_write) std.posix.system.EV.ADD else std.posix.system.EV.DELETE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        }};
        var no_ev: [0]std.posix.Kevent = undefined;
        _ = std.posix.kevent(pfd, ch[0..], no_ev[0..], null) catch {};
    }
}

/// 从 poller 中移除 client fd
pub fn muxPollerRemove(state: *ServerState, fd: std.posix.socket_t) void {
    const pfd = state.plain_mux.poller_fd;
    if (pfd < 0) return;
    if (use_epoll) {
        std.posix.epoll_ctl(pfd, std.posix.EPOLL.CTL_DEL, @intCast(fd), null) catch {};
    } else if (use_kqueue) {
        var kev: [2]std.posix.Kevent = undefined;
        kev[0] = .{ .ident = @intCast(fd), .filter = std.posix.system.EVFILT.READ, .flags = std.posix.system.EV.DELETE, .fflags = 0, .data = 0, .udata = 0 };
        kev[1] = .{ .ident = @intCast(fd), .filter = std.posix.system.EVFILT.WRITE, .flags = std.posix.system.EV.DELETE, .fflags = 0, .data = 0, .udata = 0 };
        var no_ev: [0]std.posix.Kevent = undefined;
        _ = std.posix.kevent(pfd, kev[0..], no_ev[0..], null) catch {};
    }
}

/// io_uring 路径：对 server_fd 与所有 client fd 提交 poll_add，submit_and_wait(1)，将就绪 fd 写入 ready_fds，返回数量
pub fn muxIoUringWait(state: *ServerState, server_fd: std.posix.socket_t, ready_fds: []usize) usize {
    if (comptime !use_io_uring) return 0;
    const ring = state.plain_mux.io_uring orelse return 0;
    const linux = std.os.linux;
    var n_sqe: u32 = 0;
    var sqe = ring.get_sqe() catch return 0;
    sqe.opcode = linux.IORING_OP.POLL_ADD;
    sqe.fd = @intCast(server_fd);
    sqe.user_data = @intCast(server_fd);
    sqe.u.poll.events = linux.POLL.IN;
    n_sqe += 1;
    var it = state.plain_mux.conns.iterator();
    while (it.next()) |entry| : (n_sqe += 1) {
        const fd = entry.key_ptr.*;
        const conn = entry.value_ptr;
        sqe = ring.get_sqe() catch break;
        sqe.opcode = linux.IORING_OP.POLL_ADD;
        sqe.fd = @intCast(fd);
        sqe.user_data = fd;
        const want_ws_out = conn.phase == .ws_handshake_writing or (conn.phase == .ws_frames and conn.write_buf.items.len > conn.write_off);
        const want_h2_out = conn.phase == .h2_send_preface or (conn.phase == .h2_frames and conn.write_buf.items.len > conn.write_off);
        sqe.u.poll.events = linux.POLL.IN | (if (conn.phase == .writing or want_ws_out or want_h2_out) linux.POLL.OUT else 0);
    }
    _ = ring.submit_and_wait(1) catch return 0;
    var out_i: usize = 0;
    while (ring.copy_cqe()) |cqe| {
        if (cqe.res >= 0 and out_i < ready_fds.len) {
            ready_fds[out_i] = @intCast(cqe.user_data);
            out_i += 1;
        }
    }
    return out_i;
}

/// 等待就绪事件，将就绪的 fd 写入 ready_fds，返回就绪数量；timeout_ms 0 表示不阻塞
pub fn muxPollerWait(
    state: *ServerState,
    server_fd: std.posix.socket_t,
    ready_fds: []usize,
    timeout_ms: i32,
) usize {
    const pfd = state.plain_mux.poller_fd;
    if (pfd < 0 or ready_fds.len == 0) return 0;
    if (use_epoll) {
        const events_buf = state.plain_mux.epoll_events orelse return 0;
        const events = @as([*]std.os.linux.epoll_event, @ptrCast(events_buf.ptr))[0..(events_buf.len / @sizeOf(std.os.linux.epoll_event))];
        const n = std.posix.epoll_wait(pfd, events, timeout_ms) catch return 0;
        for (events[0..n], ready_fds[0..n]) |*e, *out| out.* = @intCast(e.data.fd);
        return n;
    } else if (use_kqueue) {
        const evs = state.plain_mux.kqueue_evs orelse return 0;
        var tspec: std.posix.timespec = .{ .sec = @divTrunc(timeout_ms, 1000), .nsec = @as(i64, @mod(timeout_ms, 1000)) * 1000000 };
        var no_ch: [0]std.posix.Kevent = undefined;
        const n = std.posix.kevent(pfd, no_ch[0..], evs, &tspec) catch return 0;
        var out_i: usize = 0;
        for (evs[0..n]) |*ev| {
            const fd = @as(std.posix.socket_t, @intCast(ev.ident));
            if (fd == server_fd or state.plain_mux.conns.contains(@intCast(fd))) {
                if (out_i < ready_fds.len) {
                    ready_fds[out_i] = @intCast(fd);
                    out_i += 1;
                }
            }
        }
        return out_i;
    }
    return 0;
}
