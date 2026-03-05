// 连接与多路复用相关状态与枚举（从 mod.zig 拆出）
//
// 职责：MuxConnPhase、H2StreamEntry、PlainConnState、TlsPendingEntry、TlsConnState、MuxStepResult、IocpStepOpts。
// 依赖：types、constants、build_options、tls、http2。

const std = @import("std");
const build_options = @import("build_options");
const errors = @import("errors");
const libs_process = @import("libs_process");
const tls = @import("tls");
const http2 = @import("http2.zig");
const types = @import("types.zig");
const constants = @import("constants.zig");

const ServerConfig = types.ServerConfig;
const ParsedRequest = types.ParsedRequest;
const ChunkedParseState = types.ChunkedParseState;

const use_iocp_full = constants.use_iocp_full;
const use_iocp_full_tls = constants.use_iocp_full_tls;
const IocpOpCtx = constants.IocpOpCtx;

/// TLS IOCP 用 raw 缓冲大小（规范 §1.2 禁止栈上 16KB×2，改为堆分配）
pub const TLS_RAW_BUF_SIZE = 16 * 1024;

// ------------------------------------------------------------------------------
// 多路复用连接阶段与 HTTP/2 流
// ------------------------------------------------------------------------------

/// 多路复用连接状态机：读头 → 读 body → 调 handler → 写响应；支持 keep-alive 时复位到读头；WebSocket 不 handoff，走 ws_handshake_writing → ws_frames；h2c 不 handoff，走 h2c_writing_101 → h2c_wait_preface → h2_send_preface → h2_frames
pub const MuxConnPhase = enum {
    reading_preface,
    reading_headers,
    reading_body,
    responding,
    writing,
    ws_handshake_writing,
    ws_frames,
    h2c_writing_101,
    h2c_wait_preface,
    h2_send_preface,
    h2_frames,
    reading_chunked_body,
};

/// HTTP/2 单流状态（多路复用内非阻塞用），与 handleH2Connection 内 streams 表项一致；headers 用 ArrayListUnmanaged 预分配 MAX_H2_HEADERS 容量，decode 时封顶不扩容（01 §1.2）
pub const H2StreamEntry = struct {
    arena: std.heap.ArenaAllocator,
    headers_list: std.ArrayListUnmanaged(http2.HeaderEntry),
    method: []const u8,
    path: []const u8,
    body: std.ArrayListUnmanaged(u8),
    end_stream: bool,
    /// 释放本流占用的 arena、headers_list、body；由调用方在 remove 流时调用
    pub fn deinitEntry(self: *H2StreamEntry, allocator: std.mem.Allocator) void {
        self.headers_list.deinit(allocator);
        self.body.deinit(allocator);
        self.arena.deinit();
    }
};

// ------------------------------------------------------------------------------
// 明文连接状态
// ------------------------------------------------------------------------------

/// 单条明文连接的状态与缓冲；phase 驱动 stepPlainConn 的状态机（01 §1.2 持久化容器用 ArrayListUnmanaged）
/// read_buf 64 字节对齐，供 libs_io.simd_scan.indexOfCrLfCrLf 与协议解析 @Vector 使用（00 §1.6）
pub const PlainConnState = struct {
    stream: std.Io.net.Stream,
    read_buf: []align(64) u8,
    read_len: usize,
    phase: MuxConnPhase,
    arena: ?std.heap.ArenaAllocator,
    parsed: ?ParsedRequest,
    body: ?[]const u8,
    body_buf: ?[]u8,
    body_len_want: usize,
    body_start: usize,
    write_buf: std.ArrayListUnmanaged(u8),
    write_off: usize,
    header_list: std.ArrayListUnmanaged(u8),
    use_keep_alive: bool,
    consumed: usize,
    ws_id: u32,
    /// io_threads > 1 时表示本连接所属 I/O 线程索引，用于 tick 向对应 ring_from_js 投递 submitRecv/submitSend
    io_thread_id: u32 = 0,
    /// 00 §1.6：WebSocket 帧解析/掩码用 64 字节对齐，利于 @Vector 与 SIMD
    ws_read_buf: ?[]align(64) u8 = null,
    ws_read_len: usize = 0,
    h2_streams: ?std.AutoHashMapUnmanaged(u31, H2StreamEntry),
    chunked_body_buf: ?std.ArrayListUnmanaged(u8),
    chunked_parse_state: ChunkedParseState,
    chunked_consumed: usize,
    read_op_ctx: if (use_iocp_full) IocpOpCtx else void,
    write_op_ctx: if (use_iocp_full) IocpOpCtx else void,

    /// 释放连接资源；close_stream 为 true 时关闭底层 stream。0.16：stream.close(io)
    // Hot-path
    pub fn deinit(self: *PlainConnState, allocator: std.mem.Allocator, close_stream: bool) void {
        if (close_stream) if (libs_process.getProcessIo()) |io| self.stream.close(io);
        allocator.free(self.read_buf);
        if (self.ws_read_buf) |b| allocator.free(b);
        if (self.arena) |*a| a.deinit();
        if (self.body_buf) |b| allocator.free(b);
        if (self.h2_streams) |*map| {
            var it = map.iterator();
            while (it.next()) |e| e.value_ptr.deinitEntry(allocator);
            map.deinit(allocator);
        }
        if (self.chunked_body_buf) |*list| list.deinit(allocator);
        self.write_buf.deinit(allocator);
        self.header_list.deinit(allocator);
    }

    /// 初始化连接状态；config 提供 read_buffer_size、write_buf/header_list 初始容量；initial_data 非 null 时为首包（如 io_core 首包），会拷贝进 read_buf
    pub fn init(allocator: std.mem.Allocator, stream: std.Io.net.Stream, config: *const ServerConfig, initial_data: ?[]const u8) !PlainConnState {
        // 00 §1.6 Lane 填充：多分配 64 字节，解析时末尾清零供 indexOfCrLfCrLf SIMD 无尾部分支
        const read_buf = allocator.alignedAlloc(u8, .@"64", config.read_buffer_size + 64) catch return error.OutOfMemory;
        var read_len: usize = 0;
        if (initial_data) |d| {
            const copy_len = @min(d.len, read_buf.len - 64);
            @memcpy(read_buf[0..copy_len], d[0..copy_len]);
            read_len = copy_len;
        }
        return .{
            .stream = stream,
            .read_buf = read_buf,
            .read_len = read_len,
            .phase = .reading_preface,
            .arena = null,
            .parsed = null,
            .body = null,
            .body_buf = null,
            .body_len_want = 0,
            .body_start = 0,
            .write_buf = std.ArrayListUnmanaged(u8).initCapacity(allocator, config.write_buf_initial_capacity) catch {
                allocator.free(read_buf);
                return error.OutOfMemory;
            },
            .write_off = 0,
            .header_list = std.ArrayListUnmanaged(u8).initCapacity(allocator, config.header_list_initial_capacity) catch {
                allocator.free(read_buf);
                return error.OutOfMemory;
            },
            .use_keep_alive = false,
            .consumed = 0,
            .ws_id = 0,
            .ws_read_buf = null,
            .ws_read_len = 0,
            .h2_streams = null,
            .chunked_body_buf = null,
            .chunked_parse_state = .reading_size_line,
            .chunked_consumed = 0,
            .read_op_ctx = if (use_iocp_full) .{
                .overlapped = .{ .Internal = 0, .InternalHigh = 0, .Union = .{ .Pointer = null }, .hEvent = null },
                .is_write = false,
            } else {},
            .write_op_ctx = if (use_iocp_full) .{
                .overlapped = .{ .Internal = 0, .InternalHigh = 0, .Union = .{ .Pointer = null }, .hEvent = null },
                .is_write = true,
            } else {},
        };
    }
};

// ------------------------------------------------------------------------------
// TLS 握手中条目与已握手连接状态
// ------------------------------------------------------------------------------

/// TLS 非阻塞握手中单条：C 层 pending 与底层 stream；Windows TLS 全 IOCP 时使用 BIO 模式；raw 缓冲 64 字节对齐堆分配（00 §1.6、§1.2）
pub const TlsPendingEntry = if (build_options.have_tls) struct {
    pending: tls.TlsPending,
    stream: std.Io.net.Stream,
    /// io_threads > 1 时表示本连接所属 I/O 线程索引
    io_thread_id: u32 = 0,
    read_op_ctx: if (use_iocp_full_tls) IocpOpCtx else void,
    write_op_ctx: if (use_iocp_full_tls) IocpOpCtx else void,
    raw_recv_buf: if (use_iocp_full_tls) []align(64) u8 else void,
    raw_send_buf: if (use_iocp_full_tls) []align(64) u8 else void,

    /// 释放 raw 缓冲；在 remove 前或 shutdown 时调用（不修改 self，仅 free 持有的 slice）
    pub fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
        if (use_iocp_full_tls) {
            allocator.free(self.raw_recv_buf);
            allocator.free(self.raw_send_buf);
        }
    }
} else void;

/// TLS 已握手连接的状态机：与 PlainConnState 同构，用 readNonblock/writeNonblock 驱动；WSS 同 WS 非阻塞多路复用
/// read_buf 64 字节对齐（00 §1.6），raw 缓冲同
pub const TlsConnState = if (build_options.have_tls) struct {
    stream: tls.TlsStream,
    read_buf: []align(64) u8,
    read_len: usize,
    phase: MuxConnPhase,
    arena: ?std.heap.ArenaAllocator,
    parsed: ?ParsedRequest,
    body: ?[]const u8,
    body_buf: ?[]u8,
    body_len_want: usize,
    body_start: usize,
    write_buf: std.ArrayListUnmanaged(u8),
    write_off: usize,
    header_list: std.ArrayListUnmanaged(u8),
    use_keep_alive: bool,
    consumed: usize,
    ws_id: u32,
    /// io_threads > 1 时表示本连接所属 I/O 线程索引
    io_thread_id: u32 = 0,
    /// 00 §1.6：WebSocket 帧解析/掩码用 64 字节对齐
    ws_read_buf: ?[]align(64) u8 = null,
    ws_read_len: usize = 0,
    h2_streams: ?std.AutoHashMapUnmanaged(u31, H2StreamEntry),
    chunked_body_buf: ?std.ArrayListUnmanaged(u8),
    chunked_parse_state: ChunkedParseState,
    chunked_consumed: usize,
    read_op_ctx: if (use_iocp_full_tls) IocpOpCtx else void,
    write_op_ctx: if (use_iocp_full_tls) IocpOpCtx else void,
    raw_recv_buf: if (use_iocp_full_tls) []align(64) u8 else void,
    raw_send_buf: if (use_iocp_full_tls) []align(64) u8 else void,

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator, close_stream: bool) void {
        if (close_stream) if (libs_process.getProcessIo()) |io| self.stream.close(io);
        allocator.free(self.read_buf);
        if (self.ws_read_buf) |b| allocator.free(b);
        if (self.arena) |*a| a.deinit();
        if (self.body_buf) |b| allocator.free(b);
        if (self.h2_streams) |*map| {
            var it = map.iterator();
            while (it.next()) |e| e.value_ptr.deinitEntry(allocator);
            map.deinit(allocator);
        }
        if (self.chunked_body_buf) |*list| list.deinit(allocator);
        self.write_buf.deinit(allocator);
        self.header_list.deinit(allocator);
        if (use_iocp_full_tls) {
            allocator.free(self.raw_recv_buf);
            allocator.free(self.raw_send_buf);
        }
    }

    pub fn init(allocator: std.mem.Allocator, stream: tls.TlsStream, config: *const ServerConfig) !@This() {
        // 00 §1.6 Lane 填充：多分配 64 字节
        const read_buf = allocator.alignedAlloc(u8, .@"64", config.read_buffer_size + 64) catch return error.OutOfMemory;
        errdefer allocator.free(read_buf);
        var raw_recv_buf: if (use_iocp_full_tls) []align(64) u8 else void = if (use_iocp_full_tls) undefined else {};
        var raw_send_buf: if (use_iocp_full_tls) []align(64) u8 else void = if (use_iocp_full_tls) undefined else {};
        if (use_iocp_full_tls) {
            raw_recv_buf = allocator.alignedAlloc(u8, .@"64", TLS_RAW_BUF_SIZE) catch return error.OutOfMemory;
            raw_send_buf = allocator.alignedAlloc(u8, .@"64", TLS_RAW_BUF_SIZE) catch {
                allocator.free(raw_recv_buf);
                return error.OutOfMemory;
            };
        }
        var write_buf = std.ArrayListUnmanaged(u8).initCapacity(allocator, config.write_buf_initial_capacity) catch {
            if (use_iocp_full_tls) {
                allocator.free(raw_recv_buf);
                allocator.free(raw_send_buf);
            }
            allocator.free(read_buf);
            return error.OutOfMemory;
        };
        const header_list = std.ArrayListUnmanaged(u8).initCapacity(allocator, config.header_list_initial_capacity) catch {
            if (use_iocp_full_tls) {
                allocator.free(raw_recv_buf);
                allocator.free(raw_send_buf);
            }
            write_buf.deinit(allocator);
            allocator.free(read_buf);
            return error.OutOfMemory;
        };
        return .{
            .stream = stream,
            .read_buf = read_buf,
            .read_len = 0,
            .phase = .reading_headers,
            .arena = null,
            .parsed = null,
            .body = null,
            .body_buf = null,
            .body_len_want = 0,
            .body_start = 0,
            .write_buf = write_buf,
            .write_off = 0,
            .header_list = header_list,
            .use_keep_alive = false,
            .consumed = 0,
            .ws_id = 0,
            .ws_read_buf = null,
            .ws_read_len = 0,
            .h2_streams = null,
            .chunked_body_buf = null,
            .chunked_parse_state = .reading_size_line,
            .chunked_consumed = 0,
            .read_op_ctx = if (use_iocp_full_tls) .{
                .overlapped = .{ .Internal = 0, .InternalHigh = 0, .Union = .{ .Pointer = null }, .hEvent = null },
                .is_write = false,
            } else {},
            .write_op_ctx = if (use_iocp_full_tls) .{
                .overlapped = .{ .Internal = 0, .InternalHigh = 0, .Union = .{ .Pointer = null }, .hEvent = null },
                .is_write = true,
            } else {},
            .raw_recv_buf = raw_recv_buf,
            .raw_send_buf = raw_send_buf,
        };
    }
} else void;

// ------------------------------------------------------------------------------
// step 返回值与 IOCP 选项
// ------------------------------------------------------------------------------

/// stepPlainConn / stepTlsConn 的返回：继续多路复用、移除并关闭、handoff 到阻塞处理等
pub const MuxStepResult = union(enum) {
    continue_,
    remove_and_close,
    handoff_plain: []const u8,
    handoff_h2,
};

/// IOCP 驱动时由完成回调注入的“刚读/刚写”字节数，step 内不执行实际 read/write
pub const IocpStepOpts = struct { tag: enum { from_read, from_write }, bytes: usize };
