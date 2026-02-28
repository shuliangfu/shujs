// setImmediate 每轮 tick 的完整实现（从 mod.zig 拆出）
//
// 职责：stop/restart/signal、cluster worker 监控、io_core 明文/TLS、poll/iocp fallback、runLoop 节流、setImmediate 续驱。
// 依赖：state、conn_state、constants、mux、step_plain、step_tls、connection、options、iocp、http2、errors、jsc、globals、timer_state、tls。

const std = @import("std");
const jsc = @import("jsc");
const globals = @import("../../../globals.zig");
const timer_state = @import("../timers/state.zig");
const errors = @import("../../../../errors.zig");
const build_options = @import("build_options");
const options = @import("options.zig");
const iocp = @import("iocp.zig");
const builtin = @import("builtin");
const tls = @import("tls");
const http2 = @import("http2.zig");

const state_mod = @import("state.zig");
const types = @import("types.zig");
const conn_state = @import("conn_state.zig");
const constants = @import("constants.zig");
const mux = @import("mux.zig");
const step_plain = @import("step_plain.zig");
const step_tls = @import("step_tls.zig");
const connection = @import("connection.zig");

const ServerState = state_mod.ServerState;
const PlainConnState = conn_state.PlainConnState;
const TlsConnState = conn_state.TlsConnState;
const TlsPendingEntry = conn_state.TlsPendingEntry;
const MuxStepResult = conn_state.MuxStepResult;
const IocpOpCtx = constants.IocpOpCtx;
const use_iocp_full = constants.use_iocp_full;
const use_iocp_full_tls = constants.use_iocp_full_tls;
const use_epoll = constants.use_epoll;
const use_kqueue = constants.use_kqueue;
const use_io_uring = constants.use_io_uring;

const WsSendEntry = types.WsSendEntry;

/// 连续 N 个 tick 有事件则把 poll 超时降为 0（高负载模式）
const CONSECUTIVE_HIGH_LOAD_TICKS_TO_GO_ZERO = 2;
/// 空闲时每 tick 增加的有效超时步长（毫秒），直至达到 config 上限
const POLL_IDLE_STEP_MS: i64 = 5;
/// TLS BIO 模式 drain getSend 时用的缓冲区大小（单次取出的密文块）
const TLS_SEND_BUF_SIZE = 16 * 1024;

/// 由 mod.zig 提供的回调，用于 cleanup、do_listen、handoff，避免 tick 依赖 mod（打破循环依赖）
pub const TickCallbacks = struct {
    cleanup: *const fn (jsc.JSContextRef, *ServerState) void,
    do_listen: *const fn (*ServerState) anyerror!void,
    handoff_plain: *const fn (*ServerState, std.mem.Allocator, jsc.JSContextRef, *std.net.Stream, ?[]const u8) u32,
    handoff_conn: *const fn (*ServerState, std.mem.Allocator, jsc.JSContextRef, *anyopaque) u32,
    step_plain_cb: *const step_plain.StepPlainCallbacks,
};

/// 执行一轮 tick：检查 stop/restart/signal → cluster 或 poll → accept/step/handoff → runLoop → setImmediate
/// ctx/state/allocator/timer/callee 由 mod 从全局取；cbs 提供 cleanup/do_listen/handoff/step_plain_cb；ws_registry_ptr 用于设置 g_ws_send_registry
pub fn run(
    ctx: jsc.JSContextRef,
    state: *ServerState,
    allocator: std.mem.Allocator,
    timer: *timer_state.TimerState,
    callee: jsc.JSObjectRef,
    cbs: *const TickCallbacks,
    ws_registry_ptr: *?*std.AutoHashMap(u32, WsSendEntry),
) jsc.JSValueRef {
    // 每轮 tick 先收割 AsyncFileIO 完成项，使 Shu.fs.read/write 的 Promise 在本轮 resolve/reject
    if (globals.drain_async_file_io) |drain| drain(ctx);
    if (state.stop_requested) {
        cbs.cleanup(ctx, state);
        return jsc.JSValueMakeUndefined(ctx);
    }
    if (state.signal_ref) |sr| {
        if (options.isSignalAborted(ctx, sr)) {
            state.stop_requested = true;
            cbs.cleanup(ctx, state);
            return jsc.JSValueMakeUndefined(ctx);
        }
    }
    if (state.restart_requested) {
        if (build_options.use_iocp and state.iocp != null) {
            state.iocp.?.deinit();
            state.iocp = null;
        }
        if (state.server) |*srv| srv.deinit();
        state.restart_requested = false;
        if (state.server != null) {
            cbs.do_listen(state) catch {
                cbs.cleanup(ctx, state);
                return jsc.JSValueMakeUndefined(ctx);
            };
            if (build_options.use_iocp and state.server != null and !state.use_unix) {
                state.iocp = iocp.IocpState.init(state.allocator, @ptrCast(state.server.?.stream.handle));
            }
        }
    }

    if (state.server == null) {
        if (state.run_loop_every == 0 or state.total_requests % state.run_loop_every == 0) {
            timer.runMicrotasks(ctx);
            timer.runLoop(ctx);
        }
        if (state.cluster_worker_pids) |pids| {
            if (state.cluster_argv) |argv| {
                for (pids, 0..) |pid, i| {
                    std.posix.kill(pid, 0) catch {
                        var env = std.process.getEnvMap(state.allocator) catch continue;
                        defer env.deinit();
                        var num_buf: [16]u8 = undefined;
                        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{i + 1}) catch continue;
                        env.put("SHU_CLUSTER_WORKER", num_str) catch continue;
                        var child = std.process.Child.init(argv, state.allocator);
                        child.stdin_behavior = .Inherit;
                        child.stdout_behavior = .Inherit;
                        child.stderr_behavior = .Inherit;
                        child.env_map = &env;
                        child.spawn() catch continue;
                        pids[i] = child.id;
                    };
                }
            }
        }
        const global = jsc.JSContextGetGlobalObject(ctx);
        const k_set_immediate = jsc.JSStringCreateWithUTF8CString("setImmediate");
        defer jsc.JSStringRelease(k_set_immediate);
        const set_immediate_fn = jsc.JSObjectGetProperty(ctx, global, k_set_immediate, null);
        if (jsc.JSObjectIsFunction(ctx, @ptrCast(set_immediate_fn))) {
            const args: [1]jsc.JSValueRef = .{callee};
            _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(set_immediate_fn), null, 1, &args, null);
        }
        return jsc.JSValueMakeUndefined(ctx);
    }

    ws_registry_ptr.* = &state.ws_registry;
    defer ws_registry_ptr.* = null;

    // 有 server 且已创建 io_core 时，明文与 TLS 均走 io_core（pollCompletions + submitRecv/submitSend）
    if (state.server != null and state.high_perf_io != null) {
        const server_fd = state.server.?.stream.handle;
        const hio = state.high_perf_io.?;
        const poll_timeout_ns: i64 = if (state.poll_idle_effective_ms > 0) state.poll_idle_effective_ms * std.time.ns_per_ms else 0;
        const comps = hio.pollCompletions(poll_timeout_ns);
        const num_comps = comps.len;
        for (comps) |*c| {
            switch (c.tag) {
                .accept => {
                    const stream = c.client_stream orelse continue;
                    const cfd = @as(usize, @intCast(stream.handle));
                    const total_conns = state.plain_mux.conns.count() + (if (state.tls_conns) |*m| m.count() else @as(usize, 0)) + (if (state.tls_pending) |*m| m.count() else @as(usize, 0));
                    if (total_conns >= state.plain_mux.max_conns) {
                        stream.close();
                        continue;
                    }
                    mux.setTcpNoDelay(&stream);
                    if (builtin.os.tag != .windows) mux.setNonBlocking(stream.handle);
                    const initial_slice = c.buffer_ptr[0..c.len];
                    if (state.tls_ctx == null) {
                        var plain_conn = PlainConnState.init(state.plain_mux.allocator, stream, &state.config, initial_slice) catch {
                            stream.close();
                            continue;
                        };
                        state.plain_mux.conns.put(cfd, plain_conn) catch {
                            plain_conn.deinit(state.plain_mux.allocator, true);
                            stream.close();
                            continue;
                        };
                        hio.submitRecv(stream, cfd);
                    } else if (build_options.have_tls and state.tls_ctx != null and state.tls_pending != null and state.tls_conns != null) {
                        var pending = tls.TlsPending.startBio(&state.tls_ctx.?) orelse {
                            stream.close();
                            continue;
                        };
                        _ = pending.feedRead(initial_slice);
                        var out_conn: ?*anyopaque = null;
                        switch (pending.stepBio(&out_conn)) {
                            .done => {
                                const conn_ptr = out_conn orelse {
                                    stream.close();
                                    continue;
                                };
                                var tls_stream = tls.TlsStream.fromConn(stream, conn_ptr);
                                var tls_conn = TlsConnState.init(state.allocator, tls_stream, &state.config) catch {
                                    tls_stream.close();
                                    continue;
                                };
                                state.tls_conns.?.put(cfd, tls_conn) catch {
                                    tls_conn.deinit(state.allocator, true);
                                    continue;
                                };
                                hio.submitRecv(stream, cfd);
                            },
                            .again => {
                                var send_buf: [TLS_SEND_BUF_SIZE]u8 = undefined;
                                var n_send = pending.getSend(&send_buf);
                                while (n_send > 0) {
                                    hio.submitSend(stream, send_buf[0..n_send], cfd);
                                    n_send = pending.getSend(&send_buf);
                                }
                                var raw_recv_buf: if (use_iocp_full_tls) []u8 else void = if (use_iocp_full_tls) undefined else {};
                                var raw_send_buf: if (use_iocp_full_tls) []u8 else void = if (use_iocp_full_tls) undefined else {};
                                if (use_iocp_full_tls) {
                                    raw_recv_buf = allocator.alloc(u8, conn_state.TLS_RAW_BUF_SIZE) catch {
                                        stream.close();
                                        continue;
                                    };
                                    raw_send_buf = allocator.alloc(u8, conn_state.TLS_RAW_BUF_SIZE) catch {
                                        allocator.free(raw_recv_buf);
                                        stream.close();
                                        continue;
                                    };
                                }
                                const entry: TlsPendingEntry = .{
                                    .pending = pending,
                                    .stream = stream,
                                    .read_op_ctx = if (use_iocp_full_tls) .{ .overlapped = .{ .Internal = 0, .InternalHigh = 0, .Union = .{ .Pointer = null }, .hEvent = null }, .is_write = false } else {},
                                    .write_op_ctx = if (use_iocp_full_tls) .{ .overlapped = .{ .Internal = 0, .InternalHigh = 0, .Union = .{ .Pointer = null }, .hEvent = null }, .is_write = true } else {},
                                    .raw_recv_buf = raw_recv_buf,
                                    .raw_send_buf = raw_send_buf,
                                };
                                state.tls_pending.?.put(cfd, entry) catch {
                                    if (use_iocp_full_tls) {
                                        allocator.free(raw_recv_buf);
                                        allocator.free(raw_send_buf);
                                    }
                                    stream.close();
                                    continue;
                                };
                                hio.submitRecv(stream, cfd);
                            },
                            .err => stream.close(),
                        }
                    }
                },
                .recv => {
                    const cfd = c.user_data;
                    if (c.chunk_index) |ci| hio.releaseChunk(ci);
                    if (state.plain_mux.conns.getPtr(cfd)) |conn| {
                        if (c.err != null) {
                            if (conn.ws_id != 0) _ = state.ws_registry.remove(conn.ws_id);
                            conn.deinit(state.plain_mux.allocator, true);
                            _ = state.plain_mux.conns.remove(cfd);
                            continue;
                        }
                        const need = conn.read_len + c.len;
                        if (need > conn.read_buf.len) {
                            const new_len = @max(conn.read_buf.len * 2, need);
                            const new_buf = state.plain_mux.allocator.alloc(u8, new_len) catch continue;
                            @memcpy(new_buf[0..conn.read_len], conn.read_buf[0..conn.read_len]);
                            state.plain_mux.allocator.free(conn.read_buf);
                            conn.read_buf = new_buf;
                        }
                        const copy_len = c.len;
                        @memcpy(conn.read_buf[conn.read_len..][0..copy_len], c.buffer_ptr[0..copy_len]);
                        conn.read_len += copy_len;
                        const res = step_plain.stepPlainConn(state, allocator, ctx, conn, .{ .tag = .from_read, .bytes = copy_len }, cfd, cbs.step_plain_cb);
                        switch (res) {
                            .continue_ => hio.submitRecv(conn.stream, cfd),
                            .remove_and_close => {
                                if (conn.ws_id != 0) _ = state.ws_registry.remove(conn.ws_id);
                                conn.deinit(state.plain_mux.allocator, true);
                                _ = state.plain_mux.conns.remove(cfd);
                            },
                            .handoff_plain => |slice| {
                                const copy = allocator.dupe(u8, slice) catch {
                                    if (conn.ws_id != 0) _ = state.ws_registry.remove(conn.ws_id);
                                    conn.deinit(state.plain_mux.allocator, true);
                                    _ = state.plain_mux.conns.remove(cfd);
                                    continue;
                                };
                                defer allocator.free(copy);
                                var stream = conn.stream;
                                if (conn.ws_id != 0) _ = state.ws_registry.remove(conn.ws_id);
                                conn.deinit(state.plain_mux.allocator, false);
                                _ = state.plain_mux.conns.remove(cfd);
                                const n = cbs.handoff_plain(state, allocator, ctx, &stream, copy);
                                stream.close();
                                state.total_requests += n;
                            },
                            .handoff_h2 => {
                                var stream = conn.stream;
                                if (conn.ws_id != 0) _ = state.ws_registry.remove(conn.ws_id);
                                conn.deinit(state.plain_mux.allocator, false);
                                _ = state.plain_mux.conns.remove(cfd);
                                const n = connection.handleH2Connection(allocator, ctx, &stream, state.handler_fn, &state.config, state.compression_enabled, state.error_callback, true) catch 0;
                                stream.close();
                                state.total_requests += n;
                            },
                        }
                    } else if (build_options.have_tls and state.tls_pending != null) {
                        if (state.tls_pending.?.getPtr(cfd)) |entry| {
                            if (c.err != null) {
                                entry.stream.close();
                                if (state.tls_pending.?.fetchRemove(cfd)) |kv| kv.value.deinit(allocator);
                                continue;
                            }
                            _ = entry.pending.feedRead(c.buffer_ptr[0..c.len]);
                            var out_conn: ?*anyopaque = null;
                            switch (entry.pending.stepBio(&out_conn)) {
                                .done => {
                                    const conn_ptr = out_conn orelse {
                                        entry.stream.close();
                                        if (state.tls_pending.?.fetchRemove(cfd)) |kv| kv.value.deinit(allocator);
                                        continue;
                                    };
                                    var tls_stream = tls.TlsStream.fromConn(entry.stream, conn_ptr);
                                    var tls_conn = TlsConnState.init(state.allocator, tls_stream, &state.config) catch {
                                        tls_stream.close();
                                        if (state.tls_pending.?.fetchRemove(cfd)) |kv| kv.value.deinit(allocator);
                                        continue;
                                    };
                                    if (state.tls_pending.?.fetchRemove(cfd)) |kv| kv.value.deinit(allocator);
                                    state.tls_conns.?.put(cfd, tls_conn) catch {
                                        tls_conn.deinit(state.allocator, true);
                                        continue;
                                    };
                                    const underlying = tls_conn.stream.underlying;
                                    var send_buf: [TLS_SEND_BUF_SIZE]u8 = undefined;
                                    var n_send = tls_conn.stream.getSend(&send_buf);
                                    while (n_send > 0) {
                                        hio.submitSend(underlying, send_buf[0..n_send], cfd);
                                        n_send = tls_conn.stream.getSend(&send_buf);
                                    }
                                    hio.submitRecv(underlying, cfd);
                                },
                                .again => {
                                    var send_buf: [TLS_SEND_BUF_SIZE]u8 = undefined;
                                    var n_send = entry.pending.getSend(&send_buf);
                                    while (n_send > 0) {
                                        hio.submitSend(entry.stream, send_buf[0..n_send], cfd);
                                        n_send = entry.pending.getSend(&send_buf);
                                    }
                                    hio.submitRecv(entry.stream, cfd);
                                },
                                .err => {
                                    entry.stream.close();
                                    if (state.tls_pending.?.fetchRemove(cfd)) |kv| kv.value.deinit(allocator);
                                },
                            }
                        }
                    } else if (build_options.have_tls and state.tls_conns != null) {
                        if (state.tls_conns.?.getPtr(cfd)) |tls_conn| {
                            if (c.err != null) {
                                if (tls_conn.ws_id != 0) _ = state.ws_registry.remove(tls_conn.ws_id);
                                tls_conn.deinit(state.allocator, true);
                                _ = state.tls_conns.?.remove(cfd);
                                continue;
                            }
                            _ = tls_conn.stream.feedRead(c.buffer_ptr[0..c.len]);
                            const res = step_tls.stepTlsConn(state, allocator, ctx, tls_conn, cfd, cbs.step_plain_cb);
                            var send_buf: [TLS_SEND_BUF_SIZE]u8 = undefined;
                            var n_send = tls_conn.stream.getSend(&send_buf);
                            while (n_send > 0) {
                                hio.submitSend(tls_conn.stream.underlying, send_buf[0..n_send], cfd);
                                n_send = tls_conn.stream.getSend(&send_buf);
                            }
                            switch (res) {
                                .continue_ => hio.submitRecv(tls_conn.stream.underlying, cfd),
                                .remove_and_close => {
                                    if (tls_conn.ws_id != 0) _ = state.ws_registry.remove(tls_conn.ws_id);
                                    tls_conn.deinit(state.allocator, true);
                                    _ = state.tls_conns.?.remove(cfd);
                                },
                                .handoff_plain, .handoff_h2 => {
                                    if (tls_conn.ws_id != 0) _ = state.ws_registry.remove(tls_conn.ws_id);
                                    tls_conn.deinit(state.allocator, true);
                                    _ = state.tls_conns.?.remove(cfd);
                                },
                            }
                        }
                    }
                },
                .send => {
                    const cfd = c.user_data;
                    if (state.plain_mux.conns.getPtr(cfd)) |conn| {
                        if (c.err != null) {
                            if (conn.ws_id != 0) _ = state.ws_registry.remove(conn.ws_id);
                            conn.deinit(state.plain_mux.allocator, true);
                            _ = state.plain_mux.conns.remove(cfd);
                            continue;
                        }
                        conn.write_off += c.len;
                        switch (step_plain.stepPlainConn(state, allocator, ctx, conn, .{ .tag = .from_write, .bytes = c.len }, cfd, cbs.step_plain_cb)) {
                            .continue_ => {
                                const slice = conn.write_buf.items[conn.write_off..];
                                if (slice.len > 0) {
                                    const to_send = if (conn.phase == .ws_handshake_writing or conn.phase == .ws_frames)
                                        slice[0..@min(slice.len, state.config.ws_max_write_per_tick)]
                                    else
                                        slice;
                                    hio.submitSend(conn.stream, to_send, cfd);
                                } else if (conn.phase == .reading_headers) {
                                    hio.submitRecv(conn.stream, cfd);
                                }
                            },
                            .remove_and_close => {
                                if (conn.ws_id != 0) _ = state.ws_registry.remove(conn.ws_id);
                                conn.deinit(state.plain_mux.allocator, true);
                                _ = state.plain_mux.conns.remove(cfd);
                            },
                            .handoff_plain => |slice| {
                                const copy = allocator.dupe(u8, slice) catch {
                                    if (conn.ws_id != 0) _ = state.ws_registry.remove(conn.ws_id);
                                    conn.deinit(state.plain_mux.allocator, true);
                                    _ = state.plain_mux.conns.remove(cfd);
                                    continue;
                                };
                                defer allocator.free(copy);
                                var stream = conn.stream;
                                if (conn.ws_id != 0) _ = state.ws_registry.remove(conn.ws_id);
                                conn.deinit(state.plain_mux.allocator, false);
                                _ = state.plain_mux.conns.remove(cfd);
                                const n = cbs.handoff_plain(state, allocator, ctx, &stream, copy);
                                stream.close();
                                state.total_requests += n;
                            },
                            .handoff_h2 => {
                                var stream = conn.stream;
                                if (conn.ws_id != 0) _ = state.ws_registry.remove(conn.ws_id);
                                conn.deinit(state.plain_mux.allocator, false);
                                _ = state.plain_mux.conns.remove(cfd);
                                const n = connection.handleH2Connection(allocator, ctx, &stream, state.handler_fn, &state.config, state.compression_enabled, state.error_callback, true) catch 0;
                                stream.close();
                                state.total_requests += n;
                            },
                        }
                    } else if (build_options.have_tls and state.tls_conns != null) {
                        if (state.tls_conns.?.getPtr(cfd)) |tls_conn| {
                            if (c.err != null) {
                                if (tls_conn.ws_id != 0) _ = state.ws_registry.remove(tls_conn.ws_id);
                                tls_conn.deinit(state.allocator, true);
                                _ = state.tls_conns.?.remove(cfd);
                                continue;
                            }
                            var send_buf: [TLS_SEND_BUF_SIZE]u8 = undefined;
                            const n_send = tls_conn.stream.getSend(&send_buf);
                            if (n_send > 0) {
                                hio.submitSend(tls_conn.stream.underlying, send_buf[0..n_send], cfd);
                            }
                            if (tls_conn.stream.wantRead()) {
                                hio.submitRecv(tls_conn.stream.underlying, cfd);
                            }
                        }
                    }
                },
                else => {}, // HighPerfIO 仅产生 accept/recv/send；file_read/file_write 由 AsyncFileIO 产生，不在此处理
            }
        }
        var refill: u32 = 0;
        const max_refill = state.config.max_accept_per_tick;
        while (refill < max_refill) : (refill += 1) {
            if (builtin.os.tag == .linux) {
                hio.submitAcceptWithBuffer(@intCast(server_fd), 0, 0);
            } else if (builtin.os.tag == .windows) {
                hio.submitAcceptWithBuffer(0, 0);
            } else {
                hio.submitAcceptWithBuffer(@intCast(server_fd), 0);
            }
        }
        // 自适应 poll 超时：有事件则趋向 0，无事件则逐步回升至 config 上限
        if (num_comps >= 1) {
            state.consecutive_high_load_ticks += 1;
            state.consecutive_idle_ticks = 0;
            if (state.consecutive_high_load_ticks >= CONSECUTIVE_HIGH_LOAD_TICKS_TO_GO_ZERO) {
                state.poll_idle_effective_ms = 0;
            }
        } else {
            state.consecutive_idle_ticks += 1;
            state.consecutive_high_load_ticks = 0;
            const max_ms = state.config.io_core_poll_idle_ms;
            if (max_ms > 0) {
                state.poll_idle_effective_ms = @min(state.poll_idle_effective_ms + POLL_IDLE_STEP_MS, max_ms);
            }
        }
    }
    // 其他路径（明文 poll/iocp fallback、TLS 全路径）尚未迁入，此处仅执行 runLoop + setImmediate 以维持事件循环

    if (state.run_loop_every == 0 or state.total_requests % state.run_loop_every == 0) {
        timer.runMicrotasks(ctx);
        timer.runLoop(ctx);
        state.last_run_loop_ms = std.time.milliTimestamp();
    } else if (state.run_loop_interval_ms > 0) {
        const now_ms = std.time.milliTimestamp();
        if (now_ms - state.last_run_loop_ms >= state.run_loop_interval_ms) {
            timer.runMicrotasks(ctx);
            timer.runLoop(ctx);
            state.last_run_loop_ms = now_ms;
        }
    }

    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_set_immediate = jsc.JSStringCreateWithUTF8CString("setImmediate");
    defer jsc.JSStringRelease(k_set_immediate);
    const set_immediate_fn = jsc.JSObjectGetProperty(ctx, global, k_set_immediate, null);
    if (jsc.JSObjectIsFunction(ctx, @ptrCast(set_immediate_fn))) {
        const args: [1]jsc.JSValueRef = .{callee};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(set_immediate_fn), null, 1, &args, null);
    }
    return jsc.JSValueMakeUndefined(ctx);
}
