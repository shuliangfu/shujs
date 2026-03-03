// Server 运行时状态：ServerState、PlainMuxState 及 init/deinit（从 mod.zig 拆出）
//
// 职责：单次运行中的 listen/配置/多路复用状态；明文连接 epoll/kqueue/io_uring/poll 的创建与释放。
// 依赖：conn_state、types、constants、tls、iocp、io_core。

const std = @import("std");
const jsc = @import("jsc");
const build_options = @import("build_options");
const tls = @import("tls");
const types = @import("types.zig");
const conn_state = @import("conn_state.zig");
const iocp = @import("iocp.zig");
const libs_io = @import("libs_io");
const constants = @import("constants.zig");

const ServerConfig = types.ServerConfig;
const WsOptions = types.WsOptions;
const WsSendEntry = types.WsSendEntry;
const PlainConnState = conn_state.PlainConnState;
const TlsPendingEntry = conn_state.TlsPendingEntry;
const TlsConnState = conn_state.TlsConnState;

const use_io_uring = constants.use_io_uring;
const use_epoll = constants.use_epoll;
const use_kqueue = constants.use_kqueue;

// ------------------------------------------------------------------------------
// 明文连接多路复用状态
// ------------------------------------------------------------------------------

/// 单进程内明文连接多路复用：accept 后 non-blocking，epoll(Linux)/kqueue(macOS·BSD)/poll 等待 I/O，按状态机分步执行
/// max_conns 由 options.maxConnections 配置（1～5120），事件数组堆分配以支持高并发
pub const PlainMuxState = struct {
    conns: std.AutoHashMap(usize, PlainConnState),
    allocator: std.mem.Allocator,
    poller_fd: i32 = -1,
    max_conns: usize,
    ready_fds: []usize,
    epoll_events: ?[]u8 = null,
    kqueue_evs: ?[]std.posix.Kevent = null,
    poll_fds: ?[]std.posix.pollfd = null,
    client_fds: ?[]usize = null,
    to_step_buf: ?[]usize = null,
    io_uring: if (use_io_uring) ?*std.os.linux.IoUring else void = if (use_io_uring) null else {},

    /// 创建并初始化多路复用状态；失败返回 error，调用方负责 deinit
    pub fn init(allocator: std.mem.Allocator, max_conns: usize) !PlainMuxState {
        const cap = 1 + max_conns;
        const ready_fds = allocator.alloc(usize, cap) catch return error.OutOfMemory;
        errdefer allocator.free(ready_fds);
        var epoll_events: ?[]u8 = null;
        var kqueue_evs: ?[]std.posix.Kevent = null;
        var poll_fds: ?[]std.posix.pollfd = null;
        var client_fds: ?[]usize = null;
        if (use_io_uring) {
            const ring = allocator.create(std.os.linux.IoUring) catch {
                allocator.free(ready_fds);
                return error.OutOfMemory;
            };
            ring.* = std.os.linux.IoUring.init(256, 0) catch {
                allocator.destroy(ring);
                allocator.free(ready_fds);
                return error.SystemResources;
            };
            return .{
                .conns = std.AutoHashMap(usize, PlainConnState).init(allocator),
                .allocator = allocator,
                .poller_fd = -1,
                .max_conns = max_conns,
                .ready_fds = ready_fds,
                .epoll_events = null,
                .kqueue_evs = null,
                .poll_fds = null,
                .client_fds = null,
                .to_step_buf = null,
                .io_uring = ring,
            };
        } else if (use_epoll) {
            epoll_events = allocator.alloc(u8, cap * @sizeOf(std.os.linux.epoll_event)) catch {
                allocator.free(ready_fds);
                return error.OutOfMemory;
            };
        } else if (use_kqueue) {
            kqueue_evs = allocator.alloc(std.posix.Kevent, cap) catch {
                allocator.free(ready_fds);
                return error.OutOfMemory;
            };
        } else {
            poll_fds = allocator.alloc(std.posix.pollfd, cap) catch {
                allocator.free(ready_fds);
                return error.OutOfMemory;
            };
            client_fds = allocator.alloc(usize, max_conns) catch {
                allocator.free(ready_fds);
                if (poll_fds) |p| allocator.free(p);
                return error.OutOfMemory;
            };
            const to_step_buf = allocator.alloc(usize, max_conns) catch {
                allocator.free(ready_fds);
                if (poll_fds) |p| allocator.free(p);
                if (client_fds) |c| allocator.free(c);
                return error.OutOfMemory;
            };
            return .{
                .conns = std.AutoHashMap(usize, PlainConnState).init(allocator),
                .allocator = allocator,
                .poller_fd = -1,
                .max_conns = max_conns,
                .ready_fds = ready_fds,
                .epoll_events = epoll_events,
                .kqueue_evs = kqueue_evs,
                .poll_fds = poll_fds,
                .client_fds = client_fds,
                .to_step_buf = to_step_buf,
                .io_uring = if (use_io_uring) null else {},
            };
        }
        return .{
            .conns = std.AutoHashMap(usize, PlainConnState).init(allocator),
            .allocator = allocator,
            .poller_fd = -1,
            .max_conns = max_conns,
            .ready_fds = ready_fds,
            .epoll_events = epoll_events,
            .kqueue_evs = kqueue_evs,
            .poll_fds = poll_fds,
            .client_fds = client_fds,
            .to_step_buf = null,
            .io_uring = if (use_io_uring) null else {},
        };
    }

    /// 释放 poller、所有连接与堆缓冲；调用后不可再使用
    pub fn deinit(self: *PlainMuxState) void {
        if (self.poller_fd >= 0) {
            _ = std.c.close(self.poller_fd);
            self.poller_fd = -1;
        }
        var it = self.conns.iterator();
        while (it.next()) |e| e.value_ptr.deinit(self.allocator, true);
        self.conns.deinit();
        self.allocator.free(self.ready_fds);
        if (self.epoll_events) |e| self.allocator.free(e);
        if (self.kqueue_evs) |e| self.allocator.free(e);
        if (self.poll_fds) |p| self.allocator.free(p);
        if (self.client_fds) |c| self.allocator.free(c);
        if (self.to_step_buf) |t| self.allocator.free(t);
        if (use_io_uring and self.io_uring != null) {
            self.io_uring.?.deinit();
            self.allocator.destroy(self.io_uring.?);
        }
    }
};

// ------------------------------------------------------------------------------
// 单次运行中的 server 状态
// ------------------------------------------------------------------------------

/// 单次运行中的 server 状态：listen 句柄、配置、handler、runLoop 节流等；stop/restart 时在此检查并清理
/// cluster 主进程时 server == null，cluster_worker_pids 为 worker 的 pid 列表
pub const ServerState = struct {
    allocator: std.mem.Allocator,
    server: ?std.Io.net.Server = null,
    cluster_worker_pids: ?[]std.posix.pid_t = null,
    cluster_workers: usize = 0,
    cluster_argv: ?[]const []const u8 = null,
    stop_requested: bool,
    restart_requested: bool,
    use_unix: bool,
    host_buf: [256]u8,
    host_len: usize,
    unix_path_buf: [512]u8,
    unix_path_len: usize,
    port: u16,
    listen_backlog: u31,
    handler_fn: jsc.JSValueRef,
    config: ServerConfig,
    /// 若从 options.server 解析则由此持有，cleanup 时释放；config.server_header 指向此或为 null
    server_header_owned: ?[]const u8 = null,
    compression_enabled: bool,
    error_callback: ?jsc.JSValueRef,
    ws_options: ?WsOptions,
    ws_registry: std.AutoHashMap(u32, WsSendEntry),
    next_ws_id: u32,
    tls_ctx: ?tls.TlsContext,
    run_loop_every: u32,
    run_loop_interval_ms: i64,
    total_requests: u32,
    last_run_loop_ms: i64,
    signal_ref: ?jsc.JSValueRef,
    plain_mux: PlainMuxState,
    tls_pending: if (build_options.have_tls) ?std.AutoHashMap(usize, TlsPendingEntry) else void = if (build_options.have_tls) null else {},
    tls_poll_fds: if (build_options.have_tls) ?[]std.posix.pollfd else void = if (build_options.have_tls) null else {},
    tls_poll_client_fds: if (build_options.have_tls) ?[]usize else void = if (build_options.have_tls) null else {},
    tls_conns: if (build_options.have_tls) ?std.AutoHashMap(usize, TlsConnState) else void = if (build_options.have_tls) null else {},
    iocp: if (build_options.use_iocp) ?iocp.IocpState else void = if (build_options.use_iocp) null else {},
    high_perf_io: ?*libs_io.HighPerfIO = null,
    buffer_pool: ?libs_io.api.BufferPool = null,
    // 自适应 poll 超时：当前有效值（0～config.io_core_poll_idle_ms），高负载时自动降为 0，空闲时逐步回升至上限
    poll_idle_effective_ms: i64 = 100,
    /// 连续有事件的 tick 数（≥1 个 completion 视为有负载）；达到阈值后 effective 置 0
    consecutive_high_load_ticks: u32 = 0,
    /// 连续无事件的 tick 数；用于空闲时逐步增加 effective 直至 config 上限
    consecutive_idle_ticks: u32 = 0,
};
