// server 子模块共用常量与平台开关（从 mod.zig 拆出，供 conn_state / state / mux / tick 等引用）
//
// 职责：DEFAULT_* 默认配置、IOCP/io_uring/epoll/kqueue 开关、IocpOpCtx；不依赖其他 server 子模块。

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

// ------------------------------------------------------------------------------
// 平台与 IOCP / io_uring
// ------------------------------------------------------------------------------

/// Windows 全 IOCP：accept + 连接 recv/send 均走完成端口，不再用 poll
pub const use_iocp_full = builtin.os.tag == .windows and build_options.use_iocp;
/// Windows + TLS + IOCP 时，TLS 握手与连接读写也走完成端口（BIO 模式）
pub const use_iocp_full_tls = builtin.os.tag == .windows and build_options.use_iocp and build_options.have_tls;

const win = std.os.windows;
/// 用于从 OVERLAPPED* 取回读/写标识；conn 由 getCompletion 的 completion_key（fd）查找
pub const IocpOpCtx = struct {
    overlapped: win.OVERLAPPED,
    is_write: bool,
};

/// Linux io_uring：poll_add 就绪检测（可选编译）
pub const use_io_uring = builtin.os.tag == .linux and build_options.use_io_uring;
/// Linux 且未启用 io_uring 时用 epoll
pub const use_epoll = builtin.os.tag == .linux and !use_io_uring;
/// macOS/BSD 用 kqueue
pub const use_kqueue = builtin.os.tag == .macos or builtin.os.tag == .freebsd or builtin.os.tag == .netbsd or builtin.os.tag == .openbsd;

// ------------------------------------------------------------------------------
// WebSocket / 缓冲
// ------------------------------------------------------------------------------

/// WebSocket 读缓冲大小（单连接）：一次可收更多帧，提高吞吐（当前固定，可扩展为 config 后按连接分配）
pub const WS_READ_BUF_SIZE = 128 * 1024;

// ------------------------------------------------------------------------------
// 默认配置（可被 ServerConfig / options 覆盖）
// ------------------------------------------------------------------------------

/// 仅当 body 长度超过此阈值时才尝试压缩（默认值，可被 ServerConfig 覆盖）
pub const DEFAULT_MIN_BODY_TO_COMPRESS = 256;
/// 请求 body 默认上限（1MB），可由 options.maxRequestBodySize 覆盖
pub const DEFAULT_MAX_REQUEST_BODY = 1024 * 1024;
/// 请求行与单行头长度上限（默认值，可被 ServerConfig 覆盖）
pub const DEFAULT_MAX_REQUEST_LINE = 8192;
/// chunked 响应写块大小（默认值，可被 ServerConfig 覆盖）
pub const DEFAULT_CHUNKED_WRITE_CHUNK_SIZE = 32 * 1024;
/// 大 body 使用 chunked 的阈值（默认值，可被 ServerConfig 覆盖）
pub const DEFAULT_CHUNKED_RESPONSE_THRESHOLD = 64 * 1024;
/// Keep-Alive 默认超时秒数
pub const DEFAULT_KEEP_ALIVE_TIMEOUT_SEC = 5;
/// listen() 默认 kernel backlog（高并发调优：1024 利于 accept 排队）
pub const DEFAULT_LISTEN_BACKLOG = 1024;
/// cluster workers 不得超过「CPU 核数 × 此倍数」；避免进程数远大于核数导致调度与资源浪费
pub const WORKERS_MAX_MULTIPLIER: u32 = 4;
/// workers 绝对上限：getCpuCount() 异常或核数极大时的兜底，防止进程数爆炸（fd/内存/调度）
pub const WORKERS_ABSOLUTE_MAX: u32 = 1024;
/// 单进程内 I/O 线程数上限（每线程一环 + 亲和性）；cluster 下每个 worker 进程独立受此上限约束
pub const MAX_IO_THREADS: u32 = 64;
/// 每 I/O 线程投递至 JS 的完成项槽位数（RingBuffer 容量）；须 ≥ max_completions
pub const IO_THREAD_COMPLETION_SLOTS: usize = 2048;
/// 每 I/O 线程从 JS 接收的 work 槽位数（submitRecv/submitSend）
pub const IO_THREAD_WORK_SLOTS: usize = 2048;
/// 单次 poll 最多返回的完成项数量（默认，可被 options.maxCompletions 覆盖；高吞吐调优）
pub const DEFAULT_MAX_COMPLETIONS: usize = 512;

/// 每 tick 最多 accept 的连接数（默认，可被 options.maxAcceptPerTick 覆盖；高吞吐调优）
pub const DEFAULT_MAX_ACCEPT_PER_TICK: u32 = 64;
/// WebSocket 每 tick 每连接最大写出字节数（默认，可被 options.webSocket.maxWritePerTick 覆盖）
pub const DEFAULT_WS_MAX_WRITE_PER_TICK: usize = 128 * 1024;
/// 连接读缓冲默认大小（可被 options.readBufferSize 覆盖）
pub const DEFAULT_READ_BUFFER_SIZE: usize = 64 * 1024;
/// write_buf / header_list 初始容量默认（可被 options.writeBufInitialCapacity / headerListInitialCapacity 覆盖）
pub const DEFAULT_WRITE_BUF_INITIAL_CAPACITY: usize = 4096;
/// WebSocket 读缓冲默认（可被 options.webSocket.readBufferSize 覆盖）
pub const DEFAULT_WS_READ_BUFFER_SIZE: usize = 128 * 1024;
/// ws.send 单次 payload 上限默认（可被 options.webSocket.maxPayloadSize 覆盖）
pub const DEFAULT_WS_MAX_PAYLOAD_SIZE: usize = 64 * 1024;
/// handoff 路径 runFrameLoop 帧缓冲默认（可被 options.webSocket.frameBufferSize 覆盖）
pub const DEFAULT_WS_FRAME_BUFFER_SIZE: usize = 64 * 1024;
