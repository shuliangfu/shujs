// Shu.server(options)：HTTP 服务端主 API
// 非阻塞：listen 后立即返回带 stop/reload/restart 的 server 对象，由 setImmediate 驱动每轮 accept → 处理 → runLoop
// 参考：HTTP_WEBSOCKET_SOCKETIO.md 三、1

const std = @import("std");
const jsc = @import("jsc");
const globals = @import("../../../globals.zig");
const common = @import("../../../common.zig");
const timer_state = @import("../timers/state.zig");
const errors = @import("errors");
const libs_process = @import("libs_process");
// 压缩实现统一从 modules/shu/zlib 引用，与 shu:zlib / node:zlib 共用
const shu_zlib = @import("../zlib/mod.zig");
const brotli = shu_zlib;
const gzip_mod = shu_zlib;
const build_options = @import("build_options");
const tls = @import("tls");
const ws_mod = @import("websocket.zig");
const http2 = @import("http2.zig");
const iocp = @import("iocp.zig");
const builtin = @import("builtin");
// 按功能拆分子模块：类型与解析/响应由 types / parse / response 提供，mod 只做协调
const types = @import("types.zig");
const parse = @import("parse.zig");
const response = @import("response.zig");
const request_js = @import("request_js.zig");
const options = @import("options.zig");
const libs_io = @import("libs_io");
const constants = @import("constants.zig");
const conn_state = @import("conn_state.zig");
const state_mod = @import("state.zig");
const mux = @import("mux.zig");
const step_plain = @import("step_plain.zig");
const step_tls = @import("step_tls.zig");
const connection = @import("connection.zig");
const tick = @import("tick.zig");
const io_threads_mod = @import("io_threads.zig");
const ParsedRequest = types.ParsedRequest;

/// Cluster worker CPU 亲和性：Linux/Windows 硬绑核；macOS 用「软建议」（亲和性标签 + QoS），无硬绑定。
/// Linux：sched_setaffinity；Windows：SetProcessAffinityMask；macOS：Thread Affinity Tag（Intel 有效，Silicon 忽略）+ QoS 跑 P 核。
const ClusterAffinityImpl = if (builtin.os.tag == .linux) struct {
    const c = @cImport({
        @cDefine("_GNU_SOURCE", "1");
        @cInclude("sched.h");
    });
    fn apply() void {
        const worker_env = std.c.getenv("SHU_CLUSTER_WORKER") orelse return;
        const worker_index = std.fmt.parseInt(usize, std.mem.span(worker_env), 10) catch return;
        const cpu_count = std.Thread.getCpuCount() catch return;
        if (cpu_count == 0) return;
        const cpu = worker_index % cpu_count;
        var mask: c.cpu_set_t = undefined;
        c.CPU_ZERO(&mask);
        c.CPU_SET(@as(c_int, @intCast(cpu)), &mask);
        _ = c.sched_setaffinity(0, @sizeOf(c.cpu_set_t), &mask);
    }
} else if (builtin.os.tag == .windows) struct {
    const win = std.os.windows;
    extern "kernel32" fn SetProcessAffinityMask(hProcess: win.HANDLE, dwProcessAffinityMask: win.DWORD_PTR) win.BOOL;
    fn apply() void {
        const worker_env = std.c.getenv("SHU_CLUSTER_WORKER") orelse return;
        const worker_index = std.fmt.parseInt(usize, std.mem.span(worker_env), 10) catch return;
        const cpu_count = std.Thread.getCpuCount() catch return;
        if (cpu_count == 0) return;
        const cpu = worker_index % cpu_count;
        const mask = @as(win.DWORD_PTR, 1) << @intCast(cpu);
        _ = SetProcessAffinityMask(win.kernel32.GetCurrentProcess(), mask);
    }
} else if (builtin.os.tag == .macos) struct {
    const c = @cImport({
        @cInclude("mach/mach.h");
        @cInclude("mach/thread_policy.h");
    });
    extern "c" fn pthread_set_qos_class_self_np(qos_class: u32, relative_priority: i32) i32;
    const QOS_CLASS_USER_INTERACTIVE: u32 = 0x21;
    fn apply() void {
        const worker_env = std.c.getenv("SHU_CLUSTER_WORKER") orelse return;
        const worker_index = std.fmt.parseInt(usize, std.mem.span(worker_env), 10) catch return;
        // 1) 亲和性标签：每个 worker 不同 tag，调度器尽量放到不同 L2 簇；Apple Silicon 会返回 KERN_NOT_SUPPORTED，忽略即可
        var policy: c.thread_affinity_policy_data_t = .{ .affinity_tag = @intCast(worker_index + 1) };
        const thread = c.mach_thread_self();
        _ = c.thread_policy_set(thread, c.THREAD_AFFINITY_POLICY, @ptrCast(&policy), c.THREAD_AFFINITY_POLICY_COUNT);
        _ = c.mach_port_deallocate(c.mach_task_self(), thread);
        // 2) QoS：当前线程优先跑在 P 核（高性能 Server）
        _ = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    }
} else struct {
    fn apply() void {}
};
fn applyClusterWorkerCpuAffinity() void {
    ClusterAffinityImpl.apply();
}
const ServerConfig = types.ServerConfig;
const ChunkedParseState = types.ChunkedParseState;
const WsOptions = types.WsOptions;
const WsSendEntry = types.WsSendEntry;

const use_iocp_full = constants.use_iocp_full;
const use_iocp_full_tls = constants.use_iocp_full_tls;
const IocpOpCtx = constants.IocpOpCtx;
const WS_READ_BUF_SIZE = constants.WS_READ_BUF_SIZE;
const use_io_uring = constants.use_io_uring;
const use_epoll = constants.use_epoll;
const use_kqueue = constants.use_kqueue;
const DEFAULT_MIN_BODY_TO_COMPRESS = constants.DEFAULT_MIN_BODY_TO_COMPRESS;
const DEFAULT_MAX_REQUEST_BODY = constants.DEFAULT_MAX_REQUEST_BODY;
const DEFAULT_MAX_REQUEST_LINE = constants.DEFAULT_MAX_REQUEST_LINE;
const DEFAULT_CHUNKED_WRITE_CHUNK_SIZE = constants.DEFAULT_CHUNKED_WRITE_CHUNK_SIZE;
const DEFAULT_CHUNKED_RESPONSE_THRESHOLD = constants.DEFAULT_CHUNKED_RESPONSE_THRESHOLD;
const DEFAULT_KEEP_ALIVE_TIMEOUT_SEC = constants.DEFAULT_KEEP_ALIVE_TIMEOUT_SEC;
const DEFAULT_LISTEN_BACKLOG = constants.DEFAULT_LISTEN_BACKLOG;
const DEFAULT_MAX_COMPLETIONS = constants.DEFAULT_MAX_COMPLETIONS;
const DEFAULT_MAX_ACCEPT_PER_TICK = constants.DEFAULT_MAX_ACCEPT_PER_TICK;
const DEFAULT_WS_MAX_WRITE_PER_TICK = constants.DEFAULT_WS_MAX_WRITE_PER_TICK;
const DEFAULT_READ_BUFFER_SIZE = constants.DEFAULT_READ_BUFFER_SIZE;
const DEFAULT_WRITE_BUF_INITIAL_CAPACITY = constants.DEFAULT_WRITE_BUF_INITIAL_CAPACITY;
const DEFAULT_WS_READ_BUFFER_SIZE = constants.DEFAULT_WS_READ_BUFFER_SIZE;
const DEFAULT_WS_MAX_PAYLOAD_SIZE = constants.DEFAULT_WS_MAX_PAYLOAD_SIZE;
const DEFAULT_WS_FRAME_BUFFER_SIZE = constants.DEFAULT_WS_FRAME_BUFFER_SIZE;

const MuxConnPhase = conn_state.MuxConnPhase;
const H2StreamEntry = conn_state.H2StreamEntry;
const PlainConnState = conn_state.PlainConnState;
const TlsPendingEntry = conn_state.TlsPendingEntry;
const TlsConnState = conn_state.TlsConnState;
const MuxStepResult = conn_state.MuxStepResult;
const IocpStepOpts = conn_state.IocpStepOpts;
const ServerState = state_mod.ServerState;
const PlainMuxState = state_mod.PlainMuxState;

/// WebSocket send 回调：id -> fd 或 blocking 写，供 ws.send(data) 时入队或直接写
/// 指向 state.ws_registry，类型为 Unmanaged（01 §1.2）
var g_ws_send_registry: ?*std.AutoHashMapUnmanaged(u32, WsSendEntry) = null;
var g_next_ws_id: u32 = 0;

/// 当前运行中的 server 实例（非阻塞模式下单例），供 tick 与 stop/reload/restart 回调访问
var g_server_state: ?*ServerState = null;
fn wsWriteNet(ctx: *anyopaque, data: []const u8) void {
    const s: *std.Io.net.Stream = @ptrCast(@alignCast(ctx));
    const io = libs_process.getProcessIo() orelse return;
    var wbuf: [8192]u8 = undefined;
    var w = s.writer(io, &wbuf);
    _ = std.Io.Writer.writeVec(&w.interface, &.{data}) catch return;
    w.interface.flush() catch {};
}
fn wsWriteTls(ctx: *anyopaque, data: []const u8) void {
    const s: *tls.TlsStream = @ptrCast(@alignCast(ctx));
    s.writeAll(data) catch {};
}
/// 00 §1.6：buf 为 64 字节对齐；调用 stream.read 时转为 []u8 以匹配 std.Io 接口
fn wsReadNet(ctx: *anyopaque, buf: []align(64) u8) usize {
    const s: *const std.Io.net.Stream = @ptrCast(@alignCast(ctx));
    const io = libs_process.getProcessIo() orelse return 0;
    const as_u8: []u8 = @as([*]u8, @ptrCast(buf.ptr))[0..buf.len];
    var rbuf: [4096]u8 = undefined;
    var r = s.reader(io, &rbuf);
    var dest = [1][]u8{as_u8};
    return std.Io.Reader.readVec(&r.interface, &dest) catch 0;
}
/// 00 §1.6：buf 为 64 字节对齐；调用 s.read 时转为 []u8 以匹配 TlsStream 接口
fn wsReadTls(ctx: *anyopaque, buf: []align(64) u8) usize {
    const s: *tls.TlsStream = @ptrCast(@alignCast(ctx));
    const as_u8: []u8 = @as([*]u8, @ptrCast(buf.ptr))[0..buf.len];
    return s.read(as_u8) catch 0;
}

/// 返回 server 模块的 exports 对象（供 require("shu:server") 等使用；若 builtin 未注册 shu:server 则仅作统一导出形态）
/// 对象上挂载 "server" 与 "default" 均为创建服务的回调，便于 ESM default 与 CommonJS .server 一致
pub fn getExports(ctx: jsc.JSContextRef, _: std.mem.Allocator) jsc.JSValueRef {
    const server_obj = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, server_obj, "server", serverCallback);
    common.setMethod(ctx, server_obj, "default", serverCallback);
    return server_obj;
}

/// 向 shu_obj 上挂载 Shu.server(options) 方法（与 getExports 一致：挂载同一 serverCallback）
pub fn register(ctx: jsc.JSGlobalContextRef, shu_obj: jsc.JSObjectRef) void {
    common.setMethod(ctx, shu_obj, "server", serverCallback);
}

/// Shu.server(options) 的 C 回调：解析 options → 检查 allow_net → listen → 循环 accept → 处理请求 → runLoop
fn serverCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    _ = globals.current_timer_state orelse return jsc.JSValueMakeUndefined(ctx);

    if (argumentCount == 0) return jsc.JSValueMakeUndefined(ctx);
    const options_obj = jsc.JSValueToObject(ctx, arguments[0], null) orelse return jsc.JSValueMakeUndefined(ctx);

    // 读取 options.unix（可选）：若为字符串路径则监听 Unix socket，否则用 host+port
    var unix_buf: [512]u8 = undefined;
    const unix_path = options.getOptionalString(ctx, options_obj, "unix", "", &unix_buf);

    // 读取 options.port（未配 unix 时必填）
    const k_port = jsc.JSStringCreateWithUTF8CString("port");
    defer jsc.JSStringRelease(k_port);
    const port_val = jsc.JSObjectGetProperty(ctx, options_obj, k_port, null);
    const port_f = jsc.JSValueToNumber(ctx, port_val, null);
    const port: u16 = if (unix_path != null and unix_path.?.len > 0)
        0
    else blk: {
        if (port_f != port_f or port_f < 1 or port_f > 65535) {
            errors.reportToStderr(.{ .code = .type_error, .message = "Shu.server(options) requires options.port (number 1-65535) when not using options.unix" }) catch {};
            return jsc.JSValueMakeUndefined(ctx);
        }
        break :blk @intFromFloat(port_f);
    };

    // 读取 options.host（可选，默认 "0.0.0.0"）；仅在不使用 unix 时生效
    var host_buf: [256]u8 = undefined;
    const host_slice = options.getOptionalString(ctx, options_obj, "host", "0.0.0.0", &host_buf) orelse "0.0.0.0";

    // 提前取 CPU 核数，供 workers / ioThreads 默认值使用（多进程默认=核数）
    const cpu_count: u32 = @intCast(std.Thread.getCpuCount() catch 1);

    // 读取 options.fetch 或 options.handler（可调用函数）
    const handler_fn = options.getHandlerFromOptions(ctx, options_obj) orelse {
        errors.reportToStderr(.{ .code = .type_error, .message = "Shu.server(options) requires options.fetch or options.handler (function)" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    };

    // 公共参数统一由 parseCommonOptions 解析（start 传 defaults=null 使用常量默认）
    const parsed = parseCommonOptions(ctx, options_obj, cpu_count, null);
    const config = parsed.config;
    const compression_enabled = parsed.compression_enabled;
    const run_loop_every = parsed.run_loop_every;
    const run_loop_interval_ms = parsed.run_loop_interval_ms;
    const io_threads = parsed.io_threads;
    if (config.max_request_line == 0) {
        errors.reportToStderr(.{ .code = .type_error, .message = "Shu.server options.maxRequestLineLength must be > 0" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }
    if (config.listen_backlog == 0) {
        errors.reportToStderr(.{ .code = .type_error, .message = "Shu.server options.listenBacklog must be > 0" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }

    // 可选：options.onError(err) 在 handler 抛错或返回无效响应时调用，与 onListen 命名一致；开发时错误页可由 onError 返回自定义 Response 实现
    const error_callback = options.getOptionalCallback(ctx, options_obj, "onError");

    // TLS（HTTPS）：options.tls: { cert, key } 为证书与私钥文件路径；默认已链接 OpenSSL，仅当用 -Dtls=false 编译时未启用
    var tls_cert_buf: [512]u8 = undefined;
    var tls_key_buf: [512]u8 = undefined;
    const tls_opts = options.getOptionalTlsOptions(ctx, options_obj, &tls_cert_buf, &tls_key_buf);
    var tls_ctx: ?tls.TlsContext = null;
    if (build_options.have_tls and tls_opts != null) {
        const tls_paths = tls_opts.?;
        tls_ctx = tls.TlsContext.create(allocator, tls_paths.cert, tls_paths.key) orelse {
            errors.reportToStderr(.{ .code = .unknown, .message = "Shu.server options.tls: failed to load cert/key (check paths and OpenSSL)" }) catch {};
            return jsc.JSValueMakeUndefined(ctx);
        };
    } else if (tls_opts != null and !build_options.have_tls) {
        errors.reportToStderr(.{ .code = .unknown, .message = "Shu.server options.tls: TLS was disabled at build time (-Dtls=false); rebuild without -Dtls=false to enable HTTPS" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }

    if (!opts.permissions.allow_net) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "Shu.server requires --allow-net" }) catch {};
        return jsc.JSValueMakeUndefined(ctx);
    }

    // options.workers：未设置时默认按 CPU 核数开多进程（方案 B）；上限为 min(核数×倍数, 绝对上限)，不写死
    var workers_u = options.getOptionalNumber(ctx, options_obj, "workers", 0);
    if (workers_u == 0) workers_u = cpu_count;
    if (workers_u < 1) workers_u = 1;
    const max_workers = @min(cpu_count * constants.WORKERS_MAX_MULTIPLIER, constants.WORKERS_ABSOLUTE_MAX);
    if (workers_u > max_workers) workers_u = max_workers;
    const workers: usize = workers_u;
    const is_cluster_worker = (std.c.getenv("SHU_CLUSTER_WORKER") != null);
    const is_cluster_master = (workers > 1 and !is_cluster_worker and opts.permissions.allow_run);

    const ws_options = options.getOptionalWebSocket(ctx, options_obj);
    const signal_ref = options.getOptionalAbortSignal(ctx, options_obj);

    const use_unix = (unix_path != null and unix_path.?.len > 0);
    var host_len: usize = 0;
    var unix_path_len: usize = 0;
    if (use_unix) {
        unix_path_len = @min(unix_path.?.len, 512);
    } else {
        host_len = @min(host_slice.len, 256);
    }

    var server: ?std.Io.net.Server = null;
    var cluster_worker_pids: ?[]std.posix.pid_t = null;
    var cluster_argv_owned: ?[]const []const u8 = null;
    var cluster_workers_count: usize = 0;

    if (is_cluster_master) {
        // 主进程：spawn workers 个子进程（同命令行 + env SHU_CLUSTER_WORKER=i），不 listen；保存 argv 副本供后续 worker 存活监控与自动重启
        const proc_io = libs_process.getProcessIo() orelse return jsc.JSValueMakeUndefined(ctx);
        const self_exe = std.process.executablePathAlloc(proc_io, allocator) catch {
            errors.reportToStderr(.{ .code = .unknown, .message = "Shu.server cluster: getSelfExePath failed" }) catch {};
            return jsc.JSValueMakeUndefined(ctx);
        };
        defer allocator.free(self_exe);
        var argv_buf: [128][]const u8 = undefined;
        argv_buf[0] = self_exe;
        var argv_len: usize = 1;
        for (opts.argv[1..]) |arg| {
            if (argv_len >= argv_buf.len) break;
            argv_buf[argv_len] = arg;
            argv_len += 1;
        }
        const argv_slice = argv_buf[0..argv_len];
        const argv_dup = allocator.alloc([]const u8, argv_len) catch return jsc.JSValueMakeUndefined(ctx);
        for (argv_slice, argv_dup) |s, *dst| {
            dst.* = allocator.dupe(u8, s) catch {
                for (argv_dup) |d| allocator.free(d);
                allocator.free(argv_dup);
                return jsc.JSValueMakeUndefined(ctx);
            };
        }
        cluster_argv_owned = argv_dup;
        cluster_workers_count = workers;
        const pids = allocator.alloc(std.posix.pid_t, workers) catch {
            if (cluster_argv_owned) |argv| {
                for (argv) |s| allocator.free(s);
                allocator.free(argv);
            }
            return jsc.JSValueMakeUndefined(ctx);
        };
        for (0..workers) |i| {
            const env_block = libs_process.getProcessEnviron() orelse std.process.Environ.empty;
            var env = std.process.Environ.createMap(env_block, allocator) catch return jsc.JSValueMakeUndefined(ctx);
            defer env.deinit();
            var num_buf: [16]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{i + 1}) catch return jsc.JSValueMakeUndefined(ctx);
            env.put("SHU_CLUSTER_WORKER", num_str) catch return jsc.JSValueMakeUndefined(ctx);
            // worker 不继承 stdout/stderr，终端只显示主进程的一次打印，与 bun/deno 行为一致
            var child = std.process.spawn(proc_io, .{
                .argv = argv_dup,
                .cwd = .inherit,
                .environ_map = &env,
                .stdin = .inherit,
                .stdout = .ignore,
                .stderr = .ignore,
            }) catch {
                for (pids[0..i]) |pid| std.posix.kill(pid, std.posix.SIG.TERM) catch {};
                allocator.free(pids);
                if (cluster_argv_owned) |argv| {
                    for (argv) |s| allocator.free(s);
                    allocator.free(argv);
                }
                errors.reportToStderr(.{ .code = .unknown, .message = "Shu.server cluster: spawn worker failed" }) catch {};
                return jsc.JSValueMakeUndefined(ctx);
            };
            pids[i] = child.id.?;
        }
        cluster_worker_pids = pids;
    } else {
        // 单进程或 worker：正常 listen；Linux 下 cluster worker 绑核以降低迁移与缓存抖动
        applyClusterWorkerCpuAffinity();
        const proc_io = libs_process.getProcessIo() orelse return jsc.JSValueMakeUndefined(ctx);
        if (unix_path != null and unix_path.?.len > 0) {
            const path = unix_path.?;
            var ua = std.Io.net.UnixAddress.init(path) catch |e| {
                var msg_buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "Shu.server listen (unix) failed: {s}", .{@errorName(e)}) catch "Shu.server listen failed";
                errors.reportToStderr(.{ .code = .unknown, .message = msg }) catch {};
                return jsc.JSValueMakeUndefined(ctx);
            };
            server = std.Io.net.UnixAddress.listen(&ua, proc_io, .{ .kernel_backlog = @as(u31, @intCast(config.listen_backlog)) }) catch |e| {
                var msg_buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "Shu.server listen (unix) failed: {s}", .{@errorName(e)}) catch "Shu.server listen failed";
                errors.reportToStderr(.{ .code = .unknown, .message = msg }) catch {};
                return jsc.JSValueMakeUndefined(ctx);
            };
        } else {
            var addr_buf: [256]u8 = undefined;
            const host_z = std.fmt.bufPrintZ(&addr_buf, "{s}", .{host_slice}) catch {
                errors.reportToStderr(.{ .code = .unknown, .message = "Shu.server host format error" }) catch {};
                return jsc.JSValueMakeUndefined(ctx);
            };
            const addr = std.Io.net.IpAddress.parse(host_z, port) catch |e| {
                var msg_buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "Shu.server listen failed: {s}", .{@errorName(e)}) catch "Shu.server listen failed";
                errors.reportToStderr(.{ .code = .unknown, .message = msg }) catch {};
                return jsc.JSValueMakeUndefined(ctx);
            };
            // io_threads > 1 时由 io_threads.init 创建 N 个 SO_REUSEPORT listen fd，此处不建单 listen（仅 Linux/macOS TCP）
            if (io_threads <= 1 or builtin.os.tag == .windows) {
                const tcp_listen_opts = std.Io.net.IpAddress.ListenOptions{
                    .kernel_backlog = @as(u31, @intCast(config.listen_backlog)),
                    .reuse_address = is_cluster_worker,
                };
                server = std.Io.net.IpAddress.listen(addr, proc_io, tcp_listen_opts) catch |e| {
                    var msg_buf: [128]u8 = undefined;
                    const msg = std.fmt.bufPrint(&msg_buf, "Shu.server listen failed: {s}", .{@errorName(e)}) catch "Shu.server listen failed";
                    errors.reportToStderr(.{ .code = .unknown, .message = msg }) catch {};
                    return jsc.JSValueMakeUndefined(ctx);
                };
            }
        }

        // reusePort 选项仅作 API 兼容；cluster 时已通过 reuse_address（SO_REUSEPORT）实现同端口多进程
        _ = options.getOptionalBool(ctx, options_obj, "reusePort");

        // 若有 options.onListen，在 listen 成功后调用一次
        const listen_info_host = if (unix_path != null and unix_path.?.len > 0) unix_path.? else host_slice;
        if (options.getOptionalCallback(ctx, options_obj, "onListen")) |on_listen_fn| {
            if (makeListenInfoObject(ctx, allocator, port, listen_info_host, tls_ctx != null)) |info_obj| {
                const args: [1]jsc.JSValueRef = .{info_obj};
                _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(on_listen_fn), null, 1, &args, null);
            }
        }
    }

    const state = allocator.create(ServerState) catch return jsc.JSValueMakeUndefined(ctx);
    state.* = .{
        .allocator = allocator,
        .server = server,
        .cluster_worker_pids = cluster_worker_pids,
        .cluster_workers = cluster_workers_count,
        .cluster_argv = cluster_argv_owned,
        .stop_requested = false,
        .restart_requested = false,
        .use_unix = use_unix,
        .host_buf = undefined,
        .host_len = host_len,
        .unix_path_buf = undefined,
        .unix_path_len = unix_path_len,
        .port = port,
        .listen_backlog = @intCast(config.listen_backlog),
        .handler_fn = handler_fn,
        .config = config,
        .poll_idle_effective_ms = config.io_core_poll_idle_ms,
        .compression_enabled = compression_enabled,
        .error_callback = error_callback,
        .ws_options = ws_options,
        .ws_registry = .{},
        .next_ws_id = g_next_ws_id,
        .tls_ctx = tls_ctx,
        .run_loop_every = @intCast(run_loop_every),
        .run_loop_interval_ms = @as(i64, @intCast(run_loop_interval_ms)),
        .total_requests = 0,
        .last_run_loop_ms = 0,
        .signal_ref = signal_ref,
        .plain_mux = PlainMuxState.init(allocator, config.max_connections) catch return jsc.JSValueMakeUndefined(ctx),
        .io_threads = io_threads,
        .io_threads_ctx = null,
    };
    if (build_options.have_tls and state.tls_ctx != null) {
        state.tls_pending = .{};
        state.tls_conns = .{};
        state.tls_poll_fds = state.allocator.alloc(std.posix.pollfd, 1 + state.plain_mux.max_conns) catch return jsc.JSValueMakeUndefined(ctx);
        state.tls_poll_client_fds = state.allocator.alloc(usize, state.plain_mux.max_conns) catch {
            state.allocator.free(state.tls_poll_fds.?);
            state.tls_poll_fds = null;
            return jsc.JSValueMakeUndefined(ctx);
        };
    }
    // Windows IOCP：有 server 且非 Unix 时即创建完成端口；无 TLS 时连接读写也走 IOCP，有 TLS 时仅 accept 走 IOCP
    if (build_options.use_iocp and state.server != null and !state.use_unix) {
        state.iocp = iocp.IocpState.init(state.allocator, @ptrCast(state.server.?.stream.handle));
    }
    // 有 listen socket 时即创建 io_core（TCP 与 Unix）：明文连接 I/O 全部走 io_core，便于统一维护与优化
    if (state.server != null) {
        const pool_size = config.max_connections * (64 * 1024);
        // Linux 下可选大页池（00 §4.2）；失败时回退到普通对齐分配
        if (builtin.os.tag == .linux and config.use_huge_pages) {
            state.buffer_pool = libs_io.api.BufferPool.allocHugePages(state.allocator, pool_size) catch
                libs_io.api.BufferPool.allocAligned(state.allocator, pool_size) catch return jsc.JSValueMakeUndefined(ctx);
        } else {
            state.buffer_pool = libs_io.api.BufferPool.allocAligned(state.allocator, pool_size) catch return jsc.JSValueMakeUndefined(ctx);
        }
        const hio = state.allocator.create(libs_io.HighPerfIO) catch {
            state.buffer_pool.?.deinit();
            state.buffer_pool = null;
            return jsc.JSValueMakeUndefined(ctx);
        };
        hio.* = libs_io.HighPerfIO.init(state.allocator, .{
            .max_connections = config.max_connections,
            .max_completions = config.max_completions,
            .linux_sq_thread_cpu = config.linux_sq_thread_cpu,
        }) catch {
            state.allocator.destroy(hio);
            state.buffer_pool.?.deinit();
            state.buffer_pool = null;
            return jsc.JSValueMakeUndefined(ctx);
        };
        state.high_perf_io = hio;
        state.high_perf_io.?.registerBufferPool(&state.buffer_pool.?);
        // NUMA：00 §4.2 多路服务器将 buffer 池绑定到当前 CPU 所在节点，可降约 30% 内存延迟；仅页对齐时生效
        if (state.buffer_pool) |*pool| {
            const s = pool.slice();
            const page = std.heap.page_size_min;
            if (@intFromPtr(s.ptr) % page == 0 and s.len % page == 0) {
                const ptr_page = @as([*]align(std.heap.page_size_min) const u8, @alignCast(s.ptr));
                libs_io.mbindToCurrentNode(ptr_page, s.len);
            }
        }
        if (builtin.os.tag == .windows) {
            state.high_perf_io.?.registerListenSocket(@ptrCast(state.server.?.stream.handle));
        }
    }
    if (!use_unix) @memcpy(state.host_buf[0..host_len], host_slice[0..host_len]);
    if (use_unix) @memcpy(state.unix_path_buf[0..unix_path_len], unix_path.?[0..unix_path_len]);

    // Thread-per-Core：无单 listen 且 io_threads > 1 且 TCP 且非 Windows 时，由 io_threads 创建 N 环与 listen fd
    if (state.server == null and state.io_threads > 1 and !state.use_unix and builtin.os.tag != .windows) {
        const root = io_threads_mod.init(state.allocator, state, state.io_threads, state.host_buf[0..state.host_len], state.port) catch |e| {
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Shu.server io_threads.init failed: {s}", .{@errorName(e)}) catch "Shu.server io_threads.init failed";
            errors.reportToStderr(.{ .code = .unknown, .message = msg }) catch {};
            state.plain_mux.deinit();
            state.allocator.destroy(state);
            g_server_state = null;
            return jsc.JSValueMakeUndefined(ctx);
        };
        if (root) |r| state.io_threads_ctx = @ptrCast(r);
    }

    // options.server：自定义 Server 头值（如 "Shu/1.0"），由 state 持有，cleanup 时释放
    var server_opt_buf: [256]u8 = undefined;
    const server_opt = options.getOptionalString(ctx, options_obj, "server", "", &server_opt_buf) orelse "";
    if (server_opt.len > 0) {
        state.server_header_owned = allocator.dupe(u8, server_opt) catch null;
        state.config.server_header = state.server_header_owned;
    }

    jsc.JSValueProtect(ctx, state.handler_fn);
    if (state.error_callback) |v| jsc.JSValueProtect(ctx, v);
    if (state.signal_ref) |v| jsc.JSValueProtect(ctx, v);
    if (state.ws_options) |*ws_opts| options.protectWsOptions(ctx, ws_opts);

    g_server_state = state;

    const server_obj = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, server_obj, "stop", serverStopCallback);
    common.setMethod(ctx, server_obj, "reload", serverReloadCallback);
    common.setMethod(ctx, server_obj, "restart", serverRestartCallback);

    const name_tick = jsc.JSStringCreateWithUTF8CString("serverTick");
    defer jsc.JSStringRelease(name_tick);
    const tick_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, name_tick, serverTickCallback);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_set_immediate = jsc.JSStringCreateWithUTF8CString("setImmediate");
    defer jsc.JSStringRelease(k_set_immediate);
    const set_immediate_fn = jsc.JSObjectGetProperty(ctx, global, k_set_immediate, null);
    const set_immediate_obj = jsc.JSValueToObject(ctx, set_immediate_fn, null);
    if (set_immediate_obj != null and jsc.JSObjectIsFunction(ctx, set_immediate_obj.?)) {
        const args: [1]jsc.JSValueRef = .{tick_fn};
        _ = jsc.JSObjectCallAsFunction(ctx, set_immediate_obj.?, null, 1, &args, null);
    }
    return server_obj;
}

/// start / reload / restart 共用的「未传 key 时的默认值」：start 传 null 用常量，reload 传当前 state 的对应字段以保留原值
const CommonOptionDefaults = struct {
    io_threads: u32,
    max_connections: usize,
    max_completions: usize,
    listen_backlog: u32,
};

/// start 与 reload/restart 共用的解析结果：仅含 config 与标量，不含 JS 引用（handler/onError/ws_options 等由调用方按需读并做 protect）
const ParsedCommonOptions = struct {
    config: ServerConfig,
    io_threads: u32,
    compression_enabled: bool,
    run_loop_every: u32,
    run_loop_interval_ms: i64,
};

/// 从 options 对象解析出 config、io_threads、compression、run_loop 等公共参数，供 start 与 updateStateFromOptions 共用，避免两处重复写。
/// cpu_count：仅当 defaults == null 时用于 ioThreads 默认值（start 时传核数）；defaults 非 null 时忽略。
/// defaults：null = start 场景，未传的 ioThreads/maxConnections/maxCompletions/listenBacklog 用常量；非 null = reload 场景，用 defaults.* 保留当前值。
fn parseCommonOptions(ctx: jsc.JSContextRef, options_obj: jsc.JSObjectRef, cpu_count: u32, defaults: ?*const CommonOptionDefaults) ParsedCommonOptions {
    const default_io = if (defaults) |d| d.io_threads else cpu_count;
    const default_max_conn: u32 = if (defaults) |d| @intCast(d.max_connections) else 2048;
    const default_max_comp: u32 = if (defaults) |d| @intCast(d.max_completions) else @intCast(DEFAULT_MAX_COMPLETIONS);
    const default_lb = if (defaults) |d| d.listen_backlog else DEFAULT_LISTEN_BACKLOG;

    const keep_alive_timeout_sec = options.getOptionalNumber(ctx, options_obj, "keepAliveTimeout", DEFAULT_KEEP_ALIVE_TIMEOUT_SEC);
    var ct = options.getOptionalNumber(ctx, options_obj, "chunkedResponseThreshold", DEFAULT_CHUNKED_RESPONSE_THRESHOLD);
    if (ct == 0) ct = DEFAULT_CHUNKED_RESPONSE_THRESHOLD;
    var cw = options.getOptionalNumber(ctx, options_obj, "chunkedWriteChunkSize", DEFAULT_CHUNKED_WRITE_CHUNK_SIZE);
    if (cw == 0) cw = DEFAULT_CHUNKED_WRITE_CHUNK_SIZE;
    const max_request_line = options.getOptionalNumber(ctx, options_obj, "maxRequestLineLength", DEFAULT_MAX_REQUEST_LINE);
    const min_body_to_compress = options.getOptionalNumber(ctx, options_obj, "minBodyToCompress", DEFAULT_MIN_BODY_TO_COMPRESS);
    var lb = options.getOptionalNumber(ctx, options_obj, "listenBacklog", default_lb);
    if (lb == 0) lb = DEFAULT_LISTEN_BACKLOG;
    var max_body = options.getOptionalNumber(ctx, options_obj, "maxRequestBodySize", DEFAULT_MAX_REQUEST_BODY);
    if (max_body == 0) max_body = DEFAULT_MAX_REQUEST_BODY;
    var max_conn_u = options.getOptionalNumber(ctx, options_obj, "maxConnections", default_max_conn);
    if (max_conn_u < 1) max_conn_u = 1;
    if (max_conn_u > 5120) max_conn_u = 5120;
    const max_connections: usize = max_conn_u;
    const max_accept_per_tick = options.getOptionalNumber(ctx, options_obj, "maxAcceptPerTick", DEFAULT_MAX_ACCEPT_PER_TICK);
    var max_completions_u = options.getOptionalNumber(ctx, options_obj, "maxCompletions", default_max_comp);
    if (max_completions_u == 0) max_completions_u = default_max_comp;
    const max_completions = options.clampSize(max_completions_u, 64, 5120);
    const ws_max_write_per_tick_u = options.getOptionalNumberFromWebSocket(ctx, options_obj, "maxWritePerTick", @intCast(DEFAULT_WS_MAX_WRITE_PER_TICK));
    const ws_max_write_per_tick = if (ws_max_write_per_tick_u == 0) DEFAULT_WS_MAX_WRITE_PER_TICK else @as(usize, ws_max_write_per_tick_u);
    const read_buf_sz = options.clampSize(options.getOptionalNumber(ctx, options_obj, "readBufferSize", @intCast(DEFAULT_READ_BUFFER_SIZE)), 4096, 256 * 1024);
    const write_cap = options.clampSize(options.getOptionalNumber(ctx, options_obj, "writeBufInitialCapacity", @intCast(DEFAULT_WRITE_BUF_INITIAL_CAPACITY)), 256, 65536);
    const header_cap = options.clampSize(options.getOptionalNumber(ctx, options_obj, "headerListInitialCapacity", @intCast(DEFAULT_WRITE_BUF_INITIAL_CAPACITY)), 256, 65536);
    const ws_read_sz = options.clampSize(options.getOptionalNumberFromWebSocket(ctx, options_obj, "readBufferSize", @intCast(DEFAULT_WS_READ_BUFFER_SIZE)), 4096, 512 * 1024);
    const ws_payload_sz = options.clampSize(options.getOptionalNumberFromWebSocket(ctx, options_obj, "maxPayloadSize", @intCast(DEFAULT_WS_MAX_PAYLOAD_SIZE)), 1024, 1024 * 1024);
    const ws_frame_sz = options.clampSize(options.getOptionalNumberFromWebSocket(ctx, options_obj, "frameBufferSize", @intCast(DEFAULT_WS_FRAME_BUFFER_SIZE)), 4096, 512 * 1024);
    const compression_enabled = options.getOptionalBoolDefault(ctx, options_obj, "compression", true);
    const run_loop_every = options.getOptionalNumber(ctx, options_obj, "runLoopEveryRequests", 1);
    const run_loop_interval_ms = options.getOptionalNumber(ctx, options_obj, "runLoopIntervalMs", 0);
    var io_threads_u = options.getOptionalNumber(ctx, options_obj, "ioThreads", default_io);
    if (io_threads_u < 1) io_threads_u = 1;
    if (io_threads_u > constants.MAX_IO_THREADS) io_threads_u = constants.MAX_IO_THREADS;
    const io_threads: u32 = io_threads_u;

    const config = ServerConfig{
        .keep_alive_timeout_sec = keep_alive_timeout_sec,
        .chunked_response_threshold = ct,
        .chunked_write_chunk_size = cw,
        .max_request_line = if (max_request_line > 0) max_request_line else DEFAULT_MAX_REQUEST_LINE,
        .min_body_to_compress = min_body_to_compress,
        .listen_backlog = lb,
        .max_request_body = max_body,
        .max_connections = max_connections,
        .max_completions = max_completions,
        .max_accept_per_tick = if (max_accept_per_tick == 0) DEFAULT_MAX_ACCEPT_PER_TICK else max_accept_per_tick,
        .ws_max_write_per_tick = ws_max_write_per_tick,
        .read_buffer_size = if (read_buf_sz == 0) DEFAULT_READ_BUFFER_SIZE else read_buf_sz,
        .write_buf_initial_capacity = if (write_cap == 0) DEFAULT_WRITE_BUF_INITIAL_CAPACITY else write_cap,
        .header_list_initial_capacity = if (header_cap == 0) DEFAULT_WRITE_BUF_INITIAL_CAPACITY else header_cap,
        .ws_read_buffer_size = if (ws_read_sz == 0) DEFAULT_WS_READ_BUFFER_SIZE else ws_read_sz,
        .ws_max_payload_size = if (ws_payload_sz == 0) DEFAULT_WS_MAX_PAYLOAD_SIZE else ws_payload_sz,
        .ws_frame_buffer_size = if (ws_frame_sz == 0) DEFAULT_WS_FRAME_BUFFER_SIZE else ws_frame_sz,
        .io_core_poll_idle_ms = @as(i64, @intCast(options.getOptionalNumber(ctx, options_obj, "pollIdleMs", 100))),
        .linux_sq_thread_cpu = options.getOptionalNumberOptional(ctx, options_obj, "linuxSqThreadCpu"),
        .use_huge_pages = options.getOptionalBoolDefault(ctx, options_obj, "useHugePages", false),
    };

    return .{
        .config = config,
        .io_threads = io_threads,
        .compression_enabled = compression_enabled,
        .run_loop_every = @intCast(run_loop_every),
        .run_loop_interval_ms = @as(i64, @intCast(run_loop_interval_ms)),
    };
}

/// 从 options 对象解析并更新 state 中的 handler、config、compression、error_callback、run_loop、ws_options（用于 reload/restart）。
/// 公共参数经 parseCommonOptions 统一解析；ioThreads/maxConnections 等需 restart 后 doListen 才生效，其余 reload 即生效。
fn updateStateFromOptions(ctx: jsc.JSContextRef, options_obj: jsc.JSObjectRef, state: *ServerState) void {
    const defaults = CommonOptionDefaults{
        .io_threads = state.io_threads,
        .max_connections = state.config.max_connections,
        .max_completions = state.config.max_completions,
        .listen_backlog = state.config.listen_backlog,
    };
    const parsed = parseCommonOptions(ctx, options_obj, 0, &defaults);
    state.config = parsed.config;
    state.listen_backlog = @intCast(parsed.config.listen_backlog);
    state.io_threads = parsed.io_threads;
    state.compression_enabled = parsed.compression_enabled;
    state.run_loop_every = parsed.run_loop_every;
    state.run_loop_interval_ms = parsed.run_loop_interval_ms;

    if (options.getHandlerFromOptions(ctx, options_obj)) |new_fn| {
        jsc.JSValueUnprotect(ctx, state.handler_fn);
        state.handler_fn = new_fn;
        jsc.JSValueProtect(ctx, state.handler_fn);
    }
    if (options.getOptionalCallback(ctx, options_obj, "onError")) |ec| {
        if (state.error_callback) |old| jsc.JSValueUnprotect(ctx, old);
        state.error_callback = ec;
        jsc.JSValueProtect(ctx, ec);
    }
    // 自适应 poll 超时：reload 后有效值不得超过新上限
    if (state.config.io_core_poll_idle_ms >= 0 and state.poll_idle_effective_ms > state.config.io_core_poll_idle_ms) {
        state.poll_idle_effective_ms = state.config.io_core_poll_idle_ms;
    }
    // options.server：reload 时更新 Server 头；赋新值前释放旧值
    var server_reload_buf: [256]u8 = undefined;
    const server_slice = options.getOptionalString(ctx, options_obj, "server", "", &server_reload_buf) orelse "";
    if (state.server_header_owned) |old| {
        state.allocator.free(old);
        state.server_header_owned = null;
        state.config.server_header = null;
    }
    if (server_slice.len > 0) {
        state.server_header_owned = state.allocator.dupe(u8, server_slice) catch null;
        state.config.server_header = state.server_header_owned;
    }
    if (options.getOptionalWebSocket(ctx, options_obj)) |new_ws| {
        if (state.ws_options) |*old| options.unprotectWsOptions(ctx, old);
        state.ws_options = new_ws;
        options.protectWsOptions(ctx, &new_ws);
    }
}

/// 释放 state 占用的资源并置空 g_server_state（stop 或出错时调用）。0.16：server.deinit(io)
fn serverStateCleanup(ctx: jsc.JSContextRef, state: *ServerState) void {
    if (build_options.use_iocp and state.iocp != null) {
        state.iocp.?.deinit();
        state.iocp = null;
    }
    if (state.high_perf_io) |hio| {
        hio.deinit();
        state.allocator.destroy(hio);
        state.high_perf_io = null;
    }
    if (state.buffer_pool) |*pool| {
        pool.deinit();
        state.buffer_pool = null;
    }
    if (state.io_threads_ctx) |threads_ctx| {
        io_threads_mod.deinit(@ptrCast(@alignCast(threads_ctx)));
        state.io_threads_ctx = null;
    }
    if (state.server) |*srv| {
        if (libs_process.getProcessIo()) |io| srv.deinit(io);
    }
    if (state.cluster_worker_pids) |pids| {
        for (pids) |pid| std.posix.kill(pid, std.posix.SIG.TERM) catch {};
        state.allocator.free(pids);
    }
    if (state.cluster_argv) |argv| {
        for (argv) |s| state.allocator.free(s);
        state.allocator.free(argv);
    }
    jsc.JSValueUnprotect(ctx, state.handler_fn);
    if (state.error_callback) |v| jsc.JSValueUnprotect(ctx, v);
    if (state.ws_options) |*opts| options.unprotectWsOptions(ctx, opts);
    if (state.signal_ref) |v| jsc.JSValueUnprotect(ctx, v);
    if (state.tls_ctx) |*tc| tc.destroy();
    if (build_options.have_tls and state.tls_pending != null) {
        const io_opt = libs_process.getProcessIo();
        var it = state.tls_pending.?.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(state.allocator);
            e.value_ptr.pending.free();
            if (io_opt) |i| e.value_ptr.stream.close(i);
        }
        state.tls_pending.?.deinit(state.allocator);
        if (state.tls_conns != null) {
            var it_conn = state.tls_conns.?.iterator();
            while (it_conn.next()) |e| e.value_ptr.deinit(state.allocator, true);
            state.tls_conns.?.deinit(state.allocator);
        }
        if (state.tls_poll_fds) |p| state.allocator.free(p);
        if (state.tls_poll_client_fds) |c| state.allocator.free(c);
    }
    state.ws_registry.deinit(state.allocator);
    state.plain_mux.deinit();
    if (state.server_header_owned) |s| state.allocator.free(s);
    state.allocator.destroy(state);
    g_server_state = null;
}

/// 根据 state 中保存的地址重新 listen，用于 restart。0.16：UnixAddress/IpAddress.listen(io, options)
fn doListen(state: *ServerState) !void {
    const io = libs_process.getProcessIo() orelse return error.NoProcessIo;
    if (state.use_unix) {
        const path = state.unix_path_buf[0..state.unix_path_len];
        var ua = std.Io.net.UnixAddress.init(path) catch |e| {
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Shu.server restart listen (unix) failed: {s}", .{@errorName(e)}) catch "restart listen failed";
            errors.reportToStderr(.{ .code = .unknown, .message = msg }) catch {};
            return e;
        };
        state.server = std.Io.net.UnixAddress.listen(&ua, io, .{ .kernel_backlog = state.listen_backlog }) catch |e| {
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Shu.server restart listen (unix) failed: {s}", .{@errorName(e)}) catch "restart listen failed";
            errors.reportToStderr(.{ .code = .unknown, .message = msg }) catch {};
            return e;
        };
    } else {
        if (state.io_threads > 1 and builtin.os.tag != .windows) {
            const root = io_threads_mod.init(state.allocator, state, state.io_threads, state.host_buf[0..state.host_len], state.port) catch |e| {
                var msg_buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "Shu.server restart io_threads.init failed: {s}", .{@errorName(e)}) catch "restart io_threads.init failed";
                errors.reportToStderr(.{ .code = .unknown, .message = msg }) catch {};
                return e;
            };
            if (root) |r| state.io_threads_ctx = @ptrCast(r);
            return;
        }
        var addr_buf: [256]u8 = undefined;
        const host_slice = state.host_buf[0..state.host_len];
        const host_z = std.fmt.bufPrintZ(&addr_buf, "{s}", .{host_slice}) catch return error.RestartListenFailed;
        const addr = std.Io.net.IpAddress.parse(host_z, state.port) catch |e| {
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Shu.server restart listen failed: {s}", .{@errorName(e)}) catch "restart listen failed";
            errors.reportToStderr(.{ .code = .unknown, .message = msg }) catch {};
            return e;
        };
        state.server = std.Io.net.IpAddress.listen(addr, io, .{ .kernel_backlog = state.listen_backlog }) catch |e| {
            var msg_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Shu.server restart listen failed: {s}", .{@errorName(e)}) catch "restart listen failed";
            errors.reportToStderr(.{ .code = .unknown, .message = msg }) catch {};
            return e;
        };
    }
}

/// tick 回调：明文 handoff 时调 handleConnectionPlain
fn handoffPlainForTick(state: *ServerState, allocator: std.mem.Allocator, ctx: jsc.JSContextRef, stream: *std.Io.net.Stream, initial_data: ?[]const u8) u32 {
    _ = allocator;
    return handleConnectionPlain(state.allocator, ctx, stream, state.handler_fn, &state.config, state.compression_enabled, state.error_callback, state.ws_options, &state.ws_registry, &state.next_ws_id, initial_data) catch 0;
}
/// tick 回调：TLS handoff 时调 handleConnection（stream_ptr 为 *connection.PreReadTlsStream）
fn handoffConnForTick(state: *ServerState, allocator: std.mem.Allocator, ctx: jsc.JSContextRef, stream_ptr: *anyopaque) u32 {
    _ = allocator;
    const pre = @as(*connection.PreReadTlsStream, @ptrCast(@alignCast(stream_ptr)));
    return handleConnection(state.allocator, ctx, pre, state.handler_fn, &state.config, state.compression_enabled, state.error_callback, state.ws_options, &state.ws_registry, &state.next_ws_id) catch 0;
}

/// setImmediate 每轮调用的 tick：委托 tick.run() 执行完整逻辑
fn serverTickCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    callee: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const state = g_server_state orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const timer = globals.current_timer_state orelse return jsc.JSValueMakeUndefined(ctx);
    const tick_cbs = tick.TickCallbacks{
        .cleanup = serverStateCleanup,
        .do_listen = doListen,
        .handoff_plain = handoffPlainForTick,
        .handoff_conn = handoffConnForTick,
        .step_plain_cb = &step_plain_cb,
    };
    return tick.run(ctx, state, allocator, timer, callee, &tick_cbs, &g_ws_send_registry);
}

/// server.stop()：请求停止监听，下一轮 tick 会关服并清理
fn serverStopCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (g_server_state) |state| state.stop_requested = true;
    return jsc.JSValueMakeUndefined(ctx);
}

/// server.reload(newOptions)：用新 options 更新 handler/config/compression/onError/runLoop/ws 等，不关 listener
fn serverReloadCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const state = g_server_state orelse return jsc.JSValueMakeUndefined(ctx);
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const options_obj = jsc.JSValueToObject(ctx, arguments[0], null) orelse return jsc.JSValueMakeUndefined(ctx);
    updateStateFromOptions(ctx, options_obj, state);
    return jsc.JSValueMakeUndefined(ctx);
}

/// server.restart() / server.restart(newOptions?)：下一轮 tick 关闭当前 listen 并用原地址或新 options 再 listen
fn serverRestartCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const state = g_server_state orelse return jsc.JSValueMakeUndefined(ctx);
    state.restart_requested = true;
    if (argumentCount >= 1) {
        const options_obj = jsc.JSValueToObject(ctx, arguments[0], null);
        if (options_obj != null) {
            var unix_buf: [512]u8 = undefined;
            const unix_path = options.getOptionalString(ctx, options_obj.?, "unix", "", &unix_buf);
            if (unix_path != null and unix_path.?.len > 0) {
                state.use_unix = true;
                state.unix_path_len = @min(unix_path.?.len, state.unix_path_buf.len);
                @memcpy(state.unix_path_buf[0..state.unix_path_len], unix_path.?[0..state.unix_path_len]);
            } else {
                state.use_unix = false;
                var host_buf: [256]u8 = undefined;
                const host_slice = options.getOptionalString(ctx, options_obj.?, "host", "0.0.0.0", &host_buf) orelse "0.0.0.0";
                state.host_len = @min(host_slice.len, state.host_buf.len);
                @memcpy(state.host_buf[0..state.host_len], host_slice[0..state.host_len]);
                const k_port = jsc.JSStringCreateWithUTF8CString("port");
                defer jsc.JSStringRelease(k_port);
                const port_val = jsc.JSObjectGetProperty(ctx, options_obj.?, k_port, null);
                const port_f = jsc.JSValueToNumber(ctx, port_val, null);
                if (port_f == port_f and port_f >= 1 and port_f <= 65535) state.port = @intFromFloat(port_f);
            }
            updateStateFromOptions(ctx, options_obj.?, state);
        }
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// 构造 onListen 回调的入参对象：{ port, host, hostname, protocol? }（TLS 时 protocol 为 "https"，否则不设）
fn makeListenInfoObject(ctx: jsc.JSContextRef, allocator: std.mem.Allocator, port: u16, host: []const u8, is_tls: bool) ?jsc.JSObjectRef {
    const info = jsc.JSObjectMake(ctx, null, null);
    const k_port = jsc.JSStringCreateWithUTF8CString("port");
    defer jsc.JSStringRelease(k_port);
    const k_host = jsc.JSStringCreateWithUTF8CString("host");
    defer jsc.JSStringRelease(k_host);
    const k_hostname = jsc.JSStringCreateWithUTF8CString("hostname");
    defer jsc.JSStringRelease(k_hostname);
    _ = jsc.JSObjectSetProperty(ctx, info, k_port, jsc.JSValueMakeNumber(ctx, @floatFromInt(port)), jsc.kJSPropertyAttributeNone, null);
    const host_z = allocator.dupeZ(u8, host) catch return null;
    defer allocator.free(host_z);
    const host_js = jsc.JSStringCreateWithUTF8CString(host_z.ptr);
    defer jsc.JSStringRelease(host_js);
    _ = jsc.JSObjectSetProperty(ctx, info, k_host, jsc.JSValueMakeString(ctx, host_js), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, info, k_hostname, jsc.JSValueMakeString(ctx, host_js), jsc.kJSPropertyAttributeNone, null);
    if (is_tls) {
        const k_protocol = jsc.JSStringCreateWithUTF8CString("protocol");
        defer jsc.JSStringRelease(k_protocol);
        const https_js = jsc.JSStringCreateWithUTF8CString("https");
        defer jsc.JSStringRelease(https_js);
        _ = jsc.JSObjectSetProperty(ctx, info, k_protocol, jsc.JSValueMakeString(ctx, https_js), jsc.kJSPropertyAttributeNone, null);
    }
    return info;
}

/// WebSocket onMessage 回调的上下文：runFrameLoop/stepFrames 收到 (opcode, payload) 后调 JS onMessage(ws_obj, data)
const WsMessageCbContext = struct { jsc_ctx: jsc.JSContextRef, ws_obj: jsc.JSObjectRef, on_message_fn: jsc.JSValueRef };

/// JSC 回收 NoCopy TypedArray 时调用的空实现；payload 来自 frame_buf，由 runFrameLoop 复用，不释放
fn wsNoOpDeallocator(_: *anyopaque, _: ?*anyopaque) callconv(.c) void {}

/// 收到 text/binary 帧时调用：binary 零拷贝传 Uint8Array，text 一次拷贝转 UTF-8 字符串；生命周期约定见注释
fn wsOnMessageCallback(ctx: *anyopaque, opcode: ws_mod.Opcode, payload: []const u8) void {
    const c: *const WsMessageCbContext = @ptrCast(@alignCast(ctx));
    if (opcode == .binary) {
        // 00 §1.6：payload 指向 frame_buf，回调返回后才会 compact，故可 NoCopy 交给 JS；GC 时用 no-op 释放
        var exc: jsc.JSValueRef = undefined;
        const arr = jsc.JSObjectMakeTypedArrayWithBytesNoCopy(
            c.jsc_ctx,
            .Uint8Array,
            @ptrCast(@constCast(payload.ptr)),
            payload.len,
            wsNoOpDeallocator,
            null,
            @ptrCast(&exc),
        );
        if (arr == null) return;
        const args = [_]jsc.JSValueRef{ c.ws_obj, arr.? };
        _ = jsc.JSObjectCallAsFunction(c.jsc_ctx, @ptrCast(c.on_message_fn), null, 2, &args, null);
        return;
    }
    // text：JSC 需 null 结尾，一次拷贝到栈上并转字符串
    var buf: [65536]u8 = undefined;
    if (payload.len >= buf.len) return;
    @memcpy(buf[0..payload.len], payload);
    buf[payload.len] = 0;
    const js_str = jsc.JSStringCreateWithUTF8CString(@as([*]const u8, @ptrCast(&buf[0])));
    defer jsc.JSStringRelease(js_str);
    const str_val = jsc.JSValueMakeString(c.jsc_ctx, js_str);
    const args = [_]jsc.JSValueRef{ c.ws_obj, str_val };
    _ = jsc.JSObjectCallAsFunction(c.jsc_ctx, @ptrCast(c.on_message_fn), null, 2, &args, null);
}

/// WebSocket onError 回调的上下文：runFrameLoop 帧解析失败时调 JS onError(ws_obj, message)
const WsErrorCbContext = struct { jsc_ctx: jsc.JSContextRef, ws_obj: jsc.JSObjectRef, on_error_fn: jsc.JSValueRef };
fn wsOnErrorCallback(ctx: *anyopaque, message: []const u8) void {
    const c: *const WsErrorCbContext = @ptrCast(@alignCast(ctx));
    var buf: [512]u8 = undefined;
    const len = @min(message.len, buf.len - 1);
    @memcpy(buf[0..len], message[0..len]);
    buf[len] = 0;
    const js_str = jsc.JSStringCreateWithUTF8CString(@as([*]const u8, @ptrCast(&buf[0])));
    defer jsc.JSStringRelease(js_str);
    const str_val = jsc.JSValueMakeString(c.jsc_ctx, js_str);
    const args = [_]jsc.JSValueRef{ c.ws_obj, str_val };
    _ = jsc.JSObjectCallAsFunction(c.jsc_ctx, @ptrCast(c.on_error_fn), null, 2, &args, null);
}

/// ws.send(data) 的 C 回调：从 this 取 _wsId，查 registry 写帧
export fn wsSendCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const state = g_server_state orelse return jsc.JSValueMakeUndefined(ctx);
    if (g_ws_send_registry == null or argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const k_id = jsc.JSStringCreateWithUTF8CString("_wsId");
    defer jsc.JSStringRelease(k_id);
    const id_val = jsc.JSObjectGetProperty(ctx, this, k_id, null);
    const id_f = jsc.JSValueToNumber(ctx, id_val, null);
    if (id_f != id_f or id_f < 0) return jsc.JSValueMakeUndefined(ctx);
    const id: u32 = @intFromFloat(id_f);
    const entry = g_ws_send_registry.?.get(id) orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const js_str = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(js_str);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(js_str);
    if (max_sz == 0 or max_sz > state.config.ws_max_payload_size) return jsc.JSValueMakeUndefined(ctx);
    const payload_buf = allocator.alloc(u8, max_sz) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(payload_buf);
    const n = jsc.JSStringGetUTF8CString(js_str, payload_buf.ptr, max_sz);
    if (n == 0) return jsc.JSValueMakeUndefined(ctx);
    const payload = payload_buf[0 .. n - 1];
    const frame_buf_size = state.config.ws_max_payload_size + 14;
    const frame_buf = allocator.alloc(u8, frame_buf_size) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(frame_buf);
    const frame_len = ws_mod.buildFrame(frame_buf, .text, payload) catch return jsc.JSValueMakeUndefined(ctx);
    const slice = frame_buf[0..frame_len];
    switch (entry) {
        .fd => |fd| {
            if (state.plain_mux.conns.getPtr(fd)) |plain_conn| {
                plain_conn.write_buf.appendSlice(allocator, slice) catch return jsc.JSValueMakeUndefined(ctx);
            } else if (build_options.have_tls and state.tls_conns != null) {
                if (state.tls_conns.?.getPtr(fd)) |tls_conn| {
                    tls_conn.write_buf.appendSlice(allocator, slice) catch return jsc.JSValueMakeUndefined(ctx);
                } else {
                    return jsc.JSValueMakeUndefined(ctx);
                }
            } else {
                return jsc.JSValueMakeUndefined(ctx);
            }
        },
        .blocking => |b| b.write_fn(b.ctx, slice),
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// 构造传给 onOpen/onMessage/onClose 的 WS 对象：{ _wsId, send(data) }
fn makeWebSocketObject(ctx: jsc.JSContextRef, ws_id: u32) ?jsc.JSObjectRef {
    const ws_obj = jsc.JSObjectMake(ctx, null, null);
    const k_id = jsc.JSStringCreateWithUTF8CString("_wsId");
    defer jsc.JSStringRelease(k_id);
    _ = jsc.JSObjectSetProperty(ctx, ws_obj, k_id, jsc.JSValueMakeNumber(ctx, @floatFromInt(ws_id)), jsc.kJSPropertyAttributeNone, null);
    const k_send = jsc.JSStringCreateWithUTF8CString("send");
    defer jsc.JSStringRelease(k_send);
    const send_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_send, wsSendCallback);
    _ = jsc.JSObjectSetProperty(ctx, ws_obj, k_send, send_fn, jsc.kJSPropertyAttributeNone, null);
    return ws_obj;
}

/// sendH2ResponseToBuffer 的 void 包装，供 step_plain 回调使用（01 §1.2 Unmanaged）
fn sendH2ResponseToBufferVoid(
    write_buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    ctx: jsc.JSContextRef,
    stream_id: u31,
    handler_fn: jsc.JSValueRef,
    config: *const ServerConfig,
    compression_enabled: bool,
    error_callback: ?jsc.JSValueRef,
    parsed: *const ParsedRequest,
    response_ct_buf: *[1024]u8,
    response_body_buf: []u8,
) void {
    _ = connection.sendH2ResponseToBuffer(write_buf, allocator, ctx, stream_id, handler_fn, config, compression_enabled, error_callback, parsed, response_ct_buf, response_body_buf) catch {};
}

const step_plain_cb = step_plain.StepPlainCallbacks{
    .make_ws_obj = makeWebSocketObject,
    .is_h2c_upgrade = connection.isH2cUpgrade,
    .send_h2_response_to_buffer = sendH2ResponseToBufferVoid,
    .ws_on_message = wsOnMessageCallback,
    .ws_on_error = wsOnErrorCallback,
};

/// 对单条明文连接执行状态机一步；实现见 step_plain.zig，此处仅转发并传入 callbacks
fn stepPlainConn(
    state: *ServerState,
    allocator: std.mem.Allocator,
    ctx: jsc.JSContextRef,
    conn: *PlainConnState,
    iocp_opts: ?IocpStepOpts,
    fd: usize,
) MuxStepResult {
    return step_plain.stepPlainConn(state, allocator, ctx, conn, iocp_opts, fd, &step_plain_cb);
}

// 响应压缩：options.compression 时按 Accept-Encoding 优先 br、其次 gzip，写 Content-Encoding；小 body 不压缩，压缩后更大则用原文。

/// 明文连接处理：先 peek 24 字节，若为 HTTP/2 connection preface 则走 h2c prior knowledge；否则解析 HTTP，若 Upgrade: h2c 则回 101 再走 h2
/// initial_data 非 null 时表示多路复用 handoff：已读数据，用 PreReadReader 喂给首包解析，不再读 24 字节也不做 preface 检测
fn handleConnectionPlain(
    allocator: std.mem.Allocator,
    ctx: jsc.JSContextRef,
    stream: *std.Io.net.Stream,
    handler_fn: jsc.JSValueRef,
    config: *const ServerConfig,
    compression_enabled: bool,
    error_callback: ?jsc.JSValueRef,
    ws_options: ?WsOptions,
    ws_registry: *std.AutoHashMapUnmanaged(u32, WsSendEntry),
    next_ws_id: *u32,
    initial_data: ?[]const u8,
) !u32 {
    // 00 §1.6：读缓冲 64 字节对齐，供 parse/indexOfCrLfCrLf 与压缩路径
    // 00 §1.6 Lane 填充：多分配 64 字节供 parse 传 padded 切片
    const read_buf = allocator.alignedAlloc(u8, .@"64", 64 * 1024 + 64) catch return 0;
    defer allocator.free(read_buf);
    var response_ct_buf: [1024]u8 = undefined;
    const response_body_buf = allocator.alignedAlloc(u8, .@"64", connection.RESPONSE_BODY_BUF_SIZE) catch return 0;
    defer allocator.free(response_body_buf);
    var header_list = std.ArrayListUnmanaged(u8).initCapacity(allocator, 4096) catch return 0;
    defer header_list.deinit(allocator);
    var count: u32 = 0;
    var first_round = true;
    while (true) {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var parsed: ParsedRequest = undefined;
        if (first_round) {
            first_round = false;
            if (initial_data) |id| {
                var pre_reader = connection.PreReadReader(std.Io.net.Stream){ .prefix = id, .consumed = 0, .stream = stream };
                parsed = parse.parseHttpRequest(arena, &pre_reader, read_buf, config) catch |e| {
                    if (e == error.ConnectionClosed) return count;
                    if (e == error.BadRequest) {
                        try response.writeHttpResponse(arena, stream, config, 400, "Bad Request", null, null, "Invalid Content-Length or request", false, null);
                        return count;
                    }
                    if (e == error.RequestEntityTooLarge) {
                        try response.writeHttpResponse(arena, stream, config, 413, "Payload Too Large", null, null, "Request body exceeds configured limit", false, null);
                        return count;
                    }
                    return e;
                };
            } else {
                const io = libs_process.getProcessIo() orelse return count;
                var net_adapter = connection.NetStreamAdapter{ .stream = stream, .io = io };
                const nr = net_adapter.read(read_buf[0..24]) catch return count;
                if (nr < 24) return count;
                if (http2.eqlClientPreface(read_buf[0..24])) {
                    return connection.handleH2Connection(allocator, ctx, &net_adapter, handler_fn, config, compression_enabled, error_callback, true);
                }
                var pre_reader = connection.PreReadReader(connection.NetStreamAdapter){ .prefix = read_buf[0..24], .consumed = 0, .stream = &net_adapter };
                parsed = parse.parseHttpRequest(arena, &pre_reader, read_buf, config) catch |e| {
                    if (e == error.ConnectionClosed) return count;
                    if (e == error.BadRequest) {
                        try response.writeHttpResponse(arena, stream, config, 400, "Bad Request", null, null, "Invalid Content-Length or request", false, null);
                        return count;
                    }
                    if (e == error.RequestEntityTooLarge) {
                        try response.writeHttpResponse(arena, stream, config, 413, "Payload Too Large", null, null, "Request body exceeds configured limit", false, null);
                        return count;
                    }
                    return e;
                };
            }
        } else {
            const io = libs_process.getProcessIo() orelse return count;
            var net_adapter = connection.NetStreamAdapter{ .stream = stream, .io = io };
            parsed = parse.parseHttpRequest(arena, &net_adapter, read_buf, config) catch |e| {
                if (e == error.ConnectionClosed) return count;
                if (e == error.BadRequest) {
                    try response.writeHttpResponse(arena, stream, config, 400, "Bad Request", null, null, "Invalid Content-Length or request", false, null);
                    return count;
                }
                if (e == error.RequestEntityTooLarge) {
                    try response.writeHttpResponse(arena, stream, config, 413, "Payload Too Large", null, null, "Request body exceeds configured limit", false, null);
                    return count;
                }
                return e;
            };
        }
        if (ws_mod.isWebSocketUpgrade(parse.getHeader(parsed.headers_head, "connection"), parse.getHeader(parsed.headers_head, "upgrade")) and ws_options != null) {
            const key = parse.getHeader(parsed.headers_head, "sec-websocket-key") orelse {
                try response.writeHttpResponse(arena, stream, config, 400, "Bad Request", null, null, "Missing Sec-WebSocket-Key", false, null);
                return count;
            };
            const accept_key = ws_mod.computeAcceptKey(key) catch {
                try response.writeHttpResponse(arena, stream, config, 400, "Bad Request", null, null, "Invalid Sec-WebSocket-Key", false, null);
                return count;
            };
            try ws_mod.sendHandshake(stream, accept_key);
            const ws_id = next_ws_id.*;
            next_ws_id.* += 1;
            const write_entry: WsSendEntry = .{ .blocking = .{ .write_fn = wsWriteNet, .ctx = @ptrCast(@constCast(stream)) } };
            ws_registry.put(allocator, ws_id, write_entry) catch return count;
            defer _ = ws_registry.fetchRemove(ws_id);
            const ws_obj = makeWebSocketObject(ctx, ws_id) orelse return count;
            const opts = ws_options.?;
            if (opts.on_open) |on_open_fn| {
                const args = [_]jsc.JSValueRef{ws_obj};
                _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(on_open_fn), null, 1, &args, null);
            }
            const frame_buf = allocator.alignedAlloc(u8, .@"64", config.ws_frame_buffer_size) catch return count;
            defer allocator.free(frame_buf);
            const reader: ws_mod.Reader = .{ .ctx = @ptrCast(@constCast(stream)), .read_fn = wsReadNet };
            const writer: ws_mod.Writer = .{ .ctx = @ptrCast(@constCast(stream)), .send_fn = wsWriteNet };
            var cb_ctx = .{ .jsc_ctx = ctx, .ws_obj = ws_obj, .on_message_fn = opts.on_message };
            var err_ctx: WsErrorCbContext = undefined;
            if (opts.on_error) |on_err_fn| err_ctx = .{ .jsc_ctx = ctx, .ws_obj = ws_obj, .on_error_fn = on_err_fn };
            const on_err_cb = if (opts.on_error != null) wsOnErrorCallback else @as(?*const fn (*anyopaque, []const u8) void, null);
            const on_err_ctx_ptr = if (opts.on_error != null) @as(?*anyopaque, @ptrCast(&err_ctx)) else @as(?*anyopaque, null);
            ws_mod.runFrameLoop(reader, writer, frame_buf, wsOnMessageCallback, @ptrCast(&cb_ctx), on_err_cb, on_err_ctx_ptr);
            if (opts.on_close) |on_close_fn| {
                const args = [_]jsc.JSValueRef{ws_obj};
                _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(on_close_fn), null, 1, &args, null);
            }
            return count;
        }
        if (connection.isH2cUpgrade(parse.getHeader(parsed.headers_head, "connection"), parse.getHeader(parsed.headers_head, "upgrade"))) {
            const io = libs_process.getProcessIo() orelse return count;
            var net_adapter = connection.NetStreamAdapter{ .stream = stream, .io = io };
            try net_adapter.writeAll("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: h2c\r\n\r\n");
            return connection.handleH2Connection(allocator, ctx, &net_adapter, handler_fn, config, compression_enabled, error_callback, false);
        }
        const req_obj = request_js.makeRequestObject(ctx, arena, &parsed) orelse return count;
        const result = request_js.invokeHandlerWithOnError(ctx, handler_fn, req_obj, error_callback);
        if (!result.is_valid) {
            try response.writeHttpResponse(arena, stream, config, 500, "Internal Server Error", null, null, "", false, null);
            return count + 1;
        }
        const response_val = result.value;
        const status = response.getResponseStatus(ctx, response_val);
        const status_phrase = response.statusPhrase(status);
        const content_type = response.getResponseHeader(ctx, arena, response_val, "Content-Type", response_ct_buf[0..]);
        var response_body = response.getResponseBody(ctx, arena, response_val, response_body_buf) orelse "";
        var content_encoding: ?[]const u8 = null;
        if (compression_enabled and response_body.len > config.min_body_to_compress) {
            switch (parse.chooseAcceptEncoding(&parsed)) {
                .br => {
                    const br_slice = brotli.compressBrotli(arena, response_body) catch null;
                    if (br_slice) |s| if (s.len < response_body.len) {
                        content_encoding = "br";
                        response_body = s;
                    };
                },
                .gzip => {
                    const gz_slice = gzip_mod.compressGzip(arena, response_body) catch null;
                    if (gz_slice) |s| if (s.len < response_body.len) {
                        content_encoding = "gzip";
                        response_body = s;
                    };
                },
                .deflate => {
                    const def_slice = gzip_mod.compressDeflate(arena, response_body) catch null;
                    if (def_slice) |s| if (s.len < response_body.len) {
                        content_encoding = "deflate";
                        response_body = s;
                    };
                },
                .none => {},
            }
        }
        const use_keep_alive = !parse.clientWantsClose(&parsed);
        try response.writeHttpResponse(arena, stream, config, status, status_phrase, content_type, content_encoding, response_body, use_keep_alive, &header_list);
        count += 1;
        if (!use_keep_alive) return count;
    }
}

/// 是否 Upgrade: h2c（Connection 含 upgrade，Upgrade 含 h2c，不区分大小写）
/// 处理单连接：支持 keep-alive 时循环「读请求 → 解析 → handler → 写响应」；若首请求为 WebSocket Upgrade 则握手后走帧循环
/// stream 为 *std.Io.net.Stream 或 *tls.TlsStream；关闭由调用方负责
fn handleConnection(
    allocator: std.mem.Allocator,
    ctx: jsc.JSContextRef,
    stream: anytype,
    handler_fn: jsc.JSValueRef,
    config: *const ServerConfig,
    compression_enabled: bool,
    error_callback: ?jsc.JSValueRef,
    ws_options: ?WsOptions,
    ws_registry: *std.AutoHashMapUnmanaged(u32, WsSendEntry),
    next_ws_id: *u32,
) !u32 {
    // 连接内复用的读 buffer（规范 §1.2 禁止栈上 64KB，改为堆分配）
    // 00 §1.6：读缓冲 64 字节对齐，供 parse/indexOfCrLfCrLf 与压缩路径
    // 00 §1.6 Lane 填充：多分配 64 字节供 parse 传 padded 切片
    const read_buf = allocator.alignedAlloc(u8, .@"64", 64 * 1024 + 64) catch return 0;
    defer allocator.free(read_buf);
    var response_ct_buf: [1024]u8 = undefined;
    const response_body_buf = allocator.alignedAlloc(u8, .@"64", connection.RESPONSE_BODY_BUF_SIZE) catch return 0;
    defer allocator.free(response_body_buf);
    // keep-alive 连接上复用响应头 buffer，减少每请求分配（01 §1.2 Unmanaged）
    var header_list = std.ArrayListUnmanaged(u8).initCapacity(allocator, 4096) catch return 0;
    defer header_list.deinit(allocator);

    var count: u32 = 0;
    while (true) {
        // 每请求一个 arena，本请求内 header/body/响应/压缩结果一次性释放
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var parsed = parse.parseHttpRequest(arena, stream, read_buf, config) catch |e| {
            if (e == error.ConnectionClosed) return count;
            if (e == error.BadRequest) {
                try response.writeHttpResponse(arena, stream, config, 400, "Bad Request", null, null, "Invalid Content-Length or request", false, null);
                return count;
            }
            if (e == error.RequestEntityTooLarge) {
                try response.writeHttpResponse(arena, stream, config, 413, "Payload Too Large", null, null, "Request body exceeds configured limit", false, null);
                return count;
            }
            return e;
        };
        // WebSocket Upgrade：Connection: upgrade 且 Upgrade: websocket → 握手后走帧循环，与 HTTP 同端口
        if (ws_mod.isWebSocketUpgrade(parse.getHeader(parsed.headers_head, "connection"), parse.getHeader(parsed.headers_head, "upgrade")) and ws_options != null) {
            const key = parse.getHeader(parsed.headers_head, "sec-websocket-key") orelse {
                try response.writeHttpResponse(arena, stream, config, 400, "Bad Request", null, null, "Missing Sec-WebSocket-Key", false, null);
                return count;
            };
            const accept_key = ws_mod.computeAcceptKey(key) catch {
                try response.writeHttpResponse(arena, stream, config, 400, "Bad Request", null, null, "Invalid Sec-WebSocket-Key", false, null);
                return count;
            };
            try ws_mod.sendHandshake(stream, accept_key);

            const ws_id = next_ws_id.*;
            next_ws_id.* += 1;
            const write_entry: WsSendEntry = if (@TypeOf(stream) == *const std.Io.net.Stream) .{
                .blocking = .{ .write_fn = wsWriteNet, .ctx = @ptrCast(@constCast(stream)) },
            } else .{
                .blocking = .{ .write_fn = wsWriteTls, .ctx = @ptrCast(@constCast(stream)) },
            };
            ws_registry.put(allocator, ws_id, write_entry) catch return count;
            defer _ = ws_registry.fetchRemove(ws_id);

            const ws_obj = makeWebSocketObject(ctx, ws_id) orelse return count;
            const opts = ws_options.?;
            if (opts.on_open) |on_open_fn| {
                const args = [_]jsc.JSValueRef{ws_obj};
                _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(on_open_fn), null, 1, &args, null);
            }
            const frame_buf = allocator.alignedAlloc(u8, .@"64", config.ws_frame_buffer_size) catch return count;
            defer allocator.free(frame_buf);
            const reader: ws_mod.Reader = if (@TypeOf(stream) == *const std.Io.net.Stream)
                .{ .ctx = @ptrCast(@constCast(stream)), .read_fn = wsReadNet }
            else
                .{ .ctx = @ptrCast(@constCast(stream)), .read_fn = wsReadTls };
            const writer: ws_mod.Writer = if (@TypeOf(stream) == *const std.Io.net.Stream)
                .{ .ctx = @ptrCast(@constCast(stream)), .send_fn = wsWriteNet }
            else
                .{ .ctx = @ptrCast(@constCast(stream)), .send_fn = wsWriteTls };
            var cb_ctx = .{ .jsc_ctx = ctx, .ws_obj = ws_obj, .on_message_fn = opts.on_message };
            var err_ctx: WsErrorCbContext = undefined;
            if (opts.on_error) |on_err_fn| err_ctx = .{ .jsc_ctx = ctx, .ws_obj = ws_obj, .on_error_fn = on_err_fn };
            const on_err_cb = if (opts.on_error != null) wsOnErrorCallback else @as(?*const fn (*anyopaque, []const u8) void, null);
            const on_err_ctx_ptr = if (opts.on_error != null) @as(?*anyopaque, @ptrCast(&err_ctx)) else @as(?*anyopaque, null);
            ws_mod.runFrameLoop(reader, writer, frame_buf, wsOnMessageCallback, @ptrCast(&cb_ctx), on_err_cb, on_err_ctx_ptr);
            if (opts.on_close) |on_close_fn| {
                const args = [_]jsc.JSValueRef{ws_obj};
                _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(on_close_fn), null, 1, &args, null);
            }
            return count;
        }

        const req_obj = request_js.makeRequestObject(ctx, arena, &parsed) orelse return count;
        const result = request_js.invokeHandlerWithOnError(ctx, handler_fn, req_obj, error_callback);
        if (!result.is_valid) {
            try response.writeHttpResponse(arena, stream, config, 500, "Internal Server Error", null, null, "", false, null);
            return count + 1;
        }
        const response_val = result.value;
        const status = response.getResponseStatus(ctx, response_val);
        const content_type = response.getResponseHeader(ctx, arena, response_val, "Content-Type", response_ct_buf[0..]);
        const file_path = response.getResponseFilePath(ctx, arena, response_val);
        if (file_path) |path| {
            const status_phrase = response.statusPhrase(status);
            const use_keep_alive = !parse.clientWantsClose(&parsed);
            response.writeHttpResponseFromFile(arena, stream, config, status, status_phrase, content_type, path, use_keep_alive, &header_list) catch {
                try response.writeHttpResponse(arena, stream, config, 500, "Internal Server Error", null, null, "", false, null);
            };
            count += 1;
            if (!use_keep_alive) return count;
            continue;
        }
        const body = response.getResponseBody(ctx, arena, response_val, response_body_buf);

        const status_phrase = response.statusPhrase(status);
        var response_body = body orelse "";
        var content_encoding: ?[]const u8 = null;
        if (compression_enabled and response_body.len > config.min_body_to_compress) {
            switch (parse.chooseAcceptEncoding(&parsed)) {
                .br => {
                    const br_slice = brotli.compressBrotli(arena, response_body) catch null;
                    if (br_slice) |s| if (s.len < response_body.len) {
                        content_encoding = "br";
                        response_body = s;
                    };
                },
                .gzip => {
                    const gz_slice = gzip_mod.compressGzip(arena, response_body) catch null;
                    if (gz_slice) |s| if (s.len < response_body.len) {
                        content_encoding = "gzip";
                        response_body = s;
                    };
                },
                .deflate => {
                    const def_slice = gzip_mod.compressDeflate(arena, response_body) catch null;
                    if (def_slice) |s| if (s.len < response_body.len) {
                        content_encoding = "deflate";
                        response_body = s;
                    };
                },
                .none => {},
            }
        }
        const use_keep_alive = !parse.clientWantsClose(&parsed);
        try response.writeHttpResponse(arena, stream, config, status, status_phrase, content_type, content_encoding, response_body, use_keep_alive, &header_list);
        count += 1;
        if (!use_keep_alive) return count;
    }
}
