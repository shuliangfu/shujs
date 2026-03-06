// 明文连接状态机一步：stepPlainConn（从 mod.zig 拆出）
//
// 职责：对单条明文连接执行非阻塞读/写的一步，返回 MuxStepResult。
// 依赖：state、conn_state、types、parse、response、http2、ws_mod、request_js；通过 StepPlainCallbacks 接收 makeWebSocketObject、isH2cUpgrade、sendH2ResponseToBuffer 与 WS 回调，避免依赖 mod。

const std = @import("std");
const jsc = @import("jsc");
const types = @import("types.zig");
const parse = @import("parse.zig");
const response = @import("response.zig");
const http2 = @import("http2.zig");
const ws_mod = @import("websocket.zig");
const request_js = @import("request_js.zig");
const state_mod = @import("state.zig");
const conn_state = @import("conn_state.zig");
const shu_zlib = @import("../zlib/mod.zig");

const errors = @import("errors");
const libs_process = @import("libs_process");
const ServerState = state_mod.ServerState;
const PlainConnState = conn_state.PlainConnState;
const MuxStepResult = conn_state.MuxStepResult;
const IocpStepOpts = conn_state.IocpStepOpts;
const H2StreamEntry = conn_state.H2StreamEntry;
const ServerConfig = types.ServerConfig;
const ParsedRequest = types.ParsedRequest;

const brotli = shu_zlib;
const gzip_mod = shu_zlib;

/// 响应 body 复用 buffer 大小（与 connection.RESPONSE_BODY_BUF_SIZE 一致；规范 §1.2 禁止栈上 256KB）；step_tls 复用
pub const RESPONSE_BODY_BUF_SIZE = 256 * 1024;

/// 与 mod 中布局一致，供传入的 ws_on_message / ws_on_error 回调使用
pub const WsMessageCbContext = struct { jsc_ctx: jsc.JSContextRef, ws_obj: jsc.JSObjectRef, on_message_fn: jsc.JSValueRef };
/// 与 mod 中布局一致
pub const WsErrorCbContext = struct { jsc_ctx: jsc.JSContextRef, ws_obj: jsc.JSObjectRef, on_error_fn: jsc.JSValueRef };

/// stepPlainConn 所需的外部回调（由 mod 提供实现，避免循环依赖）
pub const StepPlainCallbacks = struct {
    make_ws_obj: *const fn (jsc.JSContextRef, u32) ?jsc.JSObjectRef,
    is_h2c_upgrade: *const fn (?[]const u8, ?[]const u8) bool,
    send_h2_response_to_buffer: *const fn (
        *std.ArrayListUnmanaged(u8),
        std.mem.Allocator,
        jsc.JSContextRef,
        u31,
        jsc.JSValueRef,
        *const ServerConfig,
        bool,
        ?jsc.JSValueRef,
        *const ParsedRequest,
        *[1024]u8,
        []u8,
    ) void,
    ws_on_message: *const fn (*anyopaque, ws_mod.Opcode, []const u8) void,
    ws_on_error: *const fn (*anyopaque, []const u8) void,
};

/// 对单条明文连接执行状态机一步（非阻塞读/写），返回下一步动作
/// handoff_plain 的切片指向 conn.read_buf，调用方必须先复制再 deinit(conn, false)
/// 当 iocp_opts 非 null 时：调用方已把 bytes 计入 read_len（from_read）或 write_off（from_write），此处只做状态推进
// Hot-path
pub fn stepPlainConn(
    state: *ServerState,
    allocator: std.mem.Allocator,
    ctx: jsc.JSContextRef,
    conn: *PlainConnState,
    iocp_opts: ?IocpStepOpts,
    fd: usize,
    cb: *const StepPlainCallbacks,
) MuxStepResult {
    switch (conn.phase) {
        .reading_preface => {
            if (iocp_opts != null) {
                if (conn.read_len < 24) return .continue_;
            } else {
                if (conn.read_len < 24) {
                    const io = libs_process.getProcessIo() orelse return .remove_and_close;
                    var io_buf: [4096]u8 = undefined;
                    var r = conn.stream.reader(io, &io_buf);
                    var dest = [1][]u8{conn.read_buf[conn.read_len..]};
                    const n = std.Io.Reader.readVec(&r.interface, &dest) catch |e| {
                        if (e == error.WouldBlock) return .continue_;
                        return .remove_and_close;
                    };
                    if (n == 0) return .remove_and_close;
                    conn.read_len += n;
                    if (conn.read_len < 24) return .continue_;
                }
            }
            if (http2.eqlClientPreface(conn.read_buf[0..24])) {
                conn.write_buf.shrinkRetainingCapacity(0);
                http2.appendServerPrefaceTo(&conn.write_buf, allocator) catch return .remove_and_close;
                conn.phase = .h2_send_preface;
                conn.write_off = 0;
                return .continue_;
            }
            conn.phase = .reading_headers;
            return .continue_;
        },
        .reading_headers => {
            if (iocp_opts == null) {
                const io = libs_process.getProcessIo() orelse return .remove_and_close;
                var io_buf: [4096]u8 = undefined;
                var r = conn.stream.reader(io, &io_buf);
                // 00 §1.6：不读入末尾 64 字节，保留给 Lane 填充
                const avail = conn.read_buf.len -| 64 -| conn.read_len;
                if (avail > 0) {
                    var dest = [1][]u8{conn.read_buf[conn.read_len..][0..avail]};
                    const n = std.Io.Reader.readVec(&r.interface, &dest) catch return .remove_and_close;
                    if (n == 0 and conn.read_len == 0) return .remove_and_close;
                    if (n > 0) conn.read_len += n;
                }
            }
            var arena = std.heap.ArenaAllocator.init(allocator);
            // 00 §1.6 Lane 填充：末尾 64 字节清零后传予 indexOfCrLfCrLf，消除 SIMD 尾部分支
            const head_slice: []const u8 = blk: {
                if (conn.read_len + 64 <= conn.read_buf.len) {
                    @memset(conn.read_buf[conn.read_len..][0..64], 0);
                    break :blk @as([*]const u8, @ptrCast(conn.read_buf.ptr))[0 .. conn.read_len + 64];
                }
                break :blk @as([*]const u8, @ptrCast(conn.read_buf.ptr))[0..conn.read_len];
            };
            const parsed_result = parse.tryParseHeadersFromBufferZeroCopy(head_slice, &state.config) catch |e| {
                arena.deinit();
                if (e == error.NeedMore) return .continue_;
                conn.arena = arena;
                conn.write_buf.shrinkRetainingCapacity(0);
                response.writeHttpResponseToBuffer(allocator, &state.config, 400, "Bad Request", null, null, "Invalid request", false, &conn.write_buf) catch {
                    conn.arena = null;
                    arena.deinit();
                    return .remove_and_close;
                };
                conn.phase = .writing;
                conn.write_off = 0;
                return .continue_;
            };
            conn.arena = arena;
            const parsed = parsed_result.parsed;
            conn.parsed = parsed;
            conn.body_start = parsed_result.body_start;
            const te_val = parse.getHeader(parsed.headers_head, "transfer-encoding");
            const is_chunked = if (te_val) |v| parse.transferEncodingChunked(v) else false;
            const upgrade = parse.getHeader(parsed.headers_head, "upgrade");
            const conn_hdr = parse.getHeader(parsed.headers_head, "connection");
            if (state.ws_options != null and ws_mod.isWebSocketUpgrade(conn_hdr, upgrade)) {
                const key = parse.getHeader(parsed.headers_head, "sec-websocket-key") orelse {
                    conn.write_buf.shrinkRetainingCapacity(0);
                    response.writeHttpResponseToBuffer(allocator, &state.config, 400, "Bad Request", null, null, "Missing Sec-WebSocket-Key", false, &conn.write_buf) catch return .remove_and_close;
                    conn.phase = .writing;
                    conn.write_off = 0;
                    return .continue_;
                };
                const accept_key = ws_mod.computeAcceptKey(key) catch {
                    conn.write_buf.shrinkRetainingCapacity(0);
                    response.writeHttpResponseToBuffer(allocator, &state.config, 400, "Bad Request", null, null, "Invalid Sec-WebSocket-Key", false, &conn.write_buf) catch return .remove_and_close;
                    conn.phase = .writing;
                    conn.write_off = 0;
                    return .continue_;
                };
                conn.write_buf.shrinkRetainingCapacity(0);
                ws_mod.appendHandshakeTo(&conn.write_buf, accept_key, allocator) catch return .remove_and_close;
                if (conn.ws_read_buf == null) {
                    conn.ws_read_buf = state.plain_mux.allocator.alignedAlloc(u8, .@"64", state.config.ws_read_buffer_size) catch return .remove_and_close;
                }
                conn.phase = .ws_handshake_writing;
                conn.write_off = 0;
                conn.ws_id = state.next_ws_id;
                state.next_ws_id += 1;
                _ = state.ws_registry.put(state.allocator, conn.ws_id, .{ .fd = fd }) catch {};
                if (cb.make_ws_obj(ctx, conn.ws_id)) |ws_obj| {
                    if (state.ws_options.?.on_open) |on_open_fn| {
                        const args = [_]jsc.JSValueRef{ws_obj};
                        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(on_open_fn), null, 1, &args, null);
                    }
                }
                return .continue_;
            }
            if (is_chunked) {
                conn.chunked_body_buf = std.ArrayListUnmanaged(u8).initCapacity(allocator, 0) catch return .remove_and_close;
                conn.chunked_parse_state = .reading_size_line;
                conn.chunked_consumed = 0;
                conn.phase = .reading_chunked_body;
                return .continue_;
            }
            if (cb.is_h2c_upgrade(conn_hdr, upgrade)) {
                conn.write_buf.shrinkRetainingCapacity(0);
                conn.write_buf.appendSlice(allocator, "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: h2c\r\n\r\n") catch return .remove_and_close;
                const body_start_val = conn.body_start;
                const rest = conn.read_len -| body_start_val;
                if (rest > 0 and rest <= conn.read_buf.len)
                    @memcpy(conn.read_buf[0..rest], conn.read_buf[body_start_val..][0..rest]);
                conn.read_len = rest;
                conn.phase = .h2c_writing_101;
                conn.write_off = 0;
                if (conn.arena) |*a| a.deinit();
                conn.arena = null;
                conn.parsed = null;
                conn.body = null;
                if (conn.body_buf) |b| allocator.free(b);
                conn.body_buf = null;
                return .continue_;
            }
            const cl_val = parse.getHeader(parsed.headers_head, "content-length");
            if (cl_val) |cl_str| {
                const cl = std.fmt.parseInt(usize, std.mem.trim(u8, cl_str, " \t"), 10) catch {
                    conn.write_buf.shrinkRetainingCapacity(0);
                    response.writeHttpResponseToBuffer(allocator, &state.config, 400, "Bad Request", null, null, "Invalid Content-Length", false, &conn.write_buf) catch return .remove_and_close;
                    conn.phase = .writing;
                    conn.write_off = 0;
                    return .continue_;
                };
                if (cl > state.config.max_request_body) {
                    conn.write_buf.shrinkRetainingCapacity(0);
                    response.writeHttpResponseToBuffer(allocator, &state.config, 413, "Payload Too Large", null, null, "Request body too large", false, &conn.write_buf) catch return .remove_and_close;
                    conn.phase = .writing;
                    conn.write_off = 0;
                    return .continue_;
                }
                conn.body_len_want = cl;
                var body_buf = allocator.alloc(u8, cl) catch return .remove_and_close;
                conn.body_buf = body_buf;
                const already = if (conn.read_len > conn.body_start + cl) cl else conn.read_len -| conn.body_start;
                @memcpy(body_buf[0..already], conn.read_buf[conn.body_start..][0..already]);
                if (already >= cl) {
                    conn.parsed.?.body = body_buf;
                    conn.phase = .responding;
                    return .continue_;
                }
                conn.phase = .reading_body;
                return .continue_;
            }
            conn.phase = .responding;
            return .continue_;
        },
        .reading_body => {
            const want = conn.body_len_want;
            if (iocp_opts == null) {
                const io = libs_process.getProcessIo() orelse return .remove_and_close;
                var io_buf: [4096]u8 = undefined;
                var r = conn.stream.reader(io, &io_buf);
                var dest = [1][]u8{conn.read_buf[conn.read_len..]};
                const n = std.Io.Reader.readVec(&r.interface, &dest) catch return .remove_and_close;
                if (n > 0) conn.read_len += n;
            }
            const have = conn.read_len -| conn.body_start;
            const filled = @min(want, have);
            if (conn.body_buf) |b| @memcpy(b[0..filled], conn.read_buf[conn.body_start..][0..filled]);
            if (filled >= want) {
                if (conn.body_buf) |b| conn.parsed.?.body = b;
                conn.phase = .responding;
            }
            return .continue_;
        },
        .reading_chunked_body => {
            if (iocp_opts == null) {
                const io = libs_process.getProcessIo() orelse return .remove_and_close;
                var io_buf: [4096]u8 = undefined;
                var r = conn.stream.reader(io, &io_buf);
                var dest = [1][]u8{conn.read_buf[conn.read_len..]};
                const n = std.Io.Reader.readVec(&r.interface, &dest) catch return .remove_and_close;
                if (n == 0 and conn.read_len == 0) return .remove_and_close;
                if (n > 0) conn.read_len += n;
            }
            const body_start = conn.body_start;
            const parse_from = body_start + conn.chunked_consumed;
            if (parse_from >= conn.read_len) return .continue_;
            const buf = conn.read_buf[parse_from..conn.read_len];
            var list = conn.chunked_body_buf orelse return .remove_and_close;
            const result = parse.parseChunkedIncremental(buf, &list, state.config.max_request_body, allocator, &conn.chunked_parse_state) catch |e| {
                if (e == error.RequestEntityTooLarge) {
                    conn.write_buf.shrinkRetainingCapacity(0);
                    response.writeHttpResponseToBuffer(allocator, &state.config, 413, "Payload Too Large", null, null, "Request body too large", false, &conn.write_buf) catch return .remove_and_close;
                    conn.phase = .writing;
                    conn.write_off = 0;
                    list.deinit(allocator);
                    conn.chunked_body_buf = null;
                    return .continue_;
                }
                conn.write_buf.shrinkRetainingCapacity(0);
                response.writeHttpResponseToBuffer(allocator, &state.config, 400, "Bad Request", null, null, "Invalid chunked body", false, &conn.write_buf) catch return .remove_and_close;
                conn.phase = .writing;
                conn.write_off = 0;
                list.deinit(allocator);
                conn.chunked_body_buf = null;
                return .continue_;
            };
            if (result == null) return .continue_;
            const r = result.?;
            conn.chunked_consumed += r.consumed;
            if (r.done) {
                const body_buf = list.toOwnedSlice(allocator) catch return .remove_and_close;
                conn.chunked_body_buf = null;
                conn.body_buf = body_buf;
                conn.parsed.?.body = body_buf;
                conn.consumed = body_start + conn.chunked_consumed;
                conn.phase = .responding;
            }
            return .continue_;
        },
        .responding => {
            const parsed = conn.parsed orelse return .remove_and_close;
            var response_ct_buf: [1024]u8 = undefined;
            const response_body_buf = allocator.alignedAlloc(u8, .@"64", RESPONSE_BODY_BUF_SIZE) catch return .remove_and_close;
            defer allocator.free(response_body_buf);
            conn.header_list.shrinkRetainingCapacity(0);
            const req_obj = request_js.makeRequestObject(ctx, conn.arena.?.allocator(), &parsed) orelse {
                conn.write_buf.shrinkRetainingCapacity(0);
                response.writeHttpResponseToBuffer(allocator, &state.config, 500, "Internal Server Error", null, null, "", false, &conn.write_buf) catch return .remove_and_close;
                conn.phase = .writing;
                conn.write_off = 0;
                return .continue_;
            };
            const result = request_js.invokeHandlerWithOnError(ctx, state.handler_fn, req_obj, state.error_callback);
            if (!result.is_valid) {
                conn.write_buf.shrinkRetainingCapacity(0);
                response.writeHttpResponseToBuffer(allocator, &state.config, 500, "Internal Server Error", null, null, "", false, &conn.write_buf) catch return .remove_and_close;
                conn.phase = .writing;
                conn.write_off = 0;
                return .continue_;
            }
            const status = response.getResponseStatus(ctx, result.value);
            const phrase = response.statusPhrase(status);
            const content_type = response.getResponseHeader(ctx, conn.arena.?.allocator(), result.value, "Content-Type", response_ct_buf[0..]);
            var response_body = response.getResponseBody(ctx, conn.arena.?.allocator(), result.value, response_body_buf) orelse "";
            var content_encoding: ?[]const u8 = null;
            if (state.compression_enabled and response_body.len > state.config.min_body_to_compress) {
                switch (parse.chooseAcceptEncoding(&parsed)) {
                    .br => {
                        const br_slice = brotli.compressBrotli(conn.arena.?.allocator(), response_body) catch null;
                        if (br_slice) |s| if (s.len < response_body.len) {
                            content_encoding = "br";
                            response_body = s;
                        };
                    },
                    .gzip => {
                        const gz_slice = gzip_mod.compressGzip(conn.arena.?.allocator(), response_body) catch null;
                        if (gz_slice) |s| if (s.len < response_body.len) {
                            content_encoding = "gzip";
                            response_body = s;
                        };
                    },
                    .deflate => {
                        const def_slice = gzip_mod.compressDeflate(conn.arena.?.allocator(), response_body) catch null;
                        if (def_slice) |s| if (s.len < response_body.len) {
                            content_encoding = "deflate";
                            response_body = s;
                        };
                    },
                    .none => {},
                }
            }
            const use_keep_alive = !parse.clientWantsClose(&parsed);
            conn.write_buf.shrinkRetainingCapacity(0);
            response.writeHttpResponseToBuffer(allocator, &state.config, status, phrase, content_type, content_encoding, response_body, use_keep_alive, &conn.write_buf) catch return .remove_and_close;
            conn.phase = .writing;
            conn.write_off = 0;
            conn.use_keep_alive = use_keep_alive;
            if (conn.body_len_want > 0) conn.consumed = conn.body_start + conn.body_len_want;
            return .continue_;
        },
        .writing => {
            const slice = conn.write_buf.items[conn.write_off..];
            if (slice.len == 0) {
                if (conn.use_keep_alive) {
                    const consumed = conn.consumed;
                    const rest = conn.read_len -| consumed;
                    if (rest > 0 and rest <= conn.read_buf.len) @memcpy(conn.read_buf[0..rest], conn.read_buf[consumed..][0..rest]);
                    conn.read_len = rest;
                    conn.phase = .reading_headers;
                    if (conn.arena) |*a| a.deinit();
                    conn.arena = null;
                    conn.parsed = null;
                    conn.body = null;
                    if (conn.body_buf) |b| allocator.free(b);
                    conn.body_buf = null;
                    conn.body_len_want = 0;
                    conn.body_start = 0;
                } else return .remove_and_close;
            } else {
                if (iocp_opts != null and iocp_opts.?.tag == .from_write) {} else {
                    const io = libs_process.getProcessIo() orelse return .remove_and_close;
                    var wbuf: [8192]u8 = undefined;
                    var w = conn.stream.writer(io, &wbuf);
                    const n = std.Io.Writer.writeVec(&w.interface, &.{slice}) catch return .remove_and_close;
                    w.interface.flush() catch return .remove_and_close;
                    conn.write_off += n;
                }
            }
            return .continue_;
        },
        .ws_handshake_writing => {
            const slice = conn.write_buf.items[conn.write_off..];
            if (slice.len == 0) {
                conn.phase = .ws_frames;
                conn.ws_read_len = 0;
                return .continue_;
            }
            if (iocp_opts != null and iocp_opts.?.tag == .from_write) {} else {
                const to_write = slice[0..@min(slice.len, state.config.ws_max_write_per_tick)];
                const io = libs_process.getProcessIo() orelse return .remove_and_close;
                var wbuf: [8192]u8 = undefined;
                var w = conn.stream.writer(io, &wbuf);
                const n = std.Io.Writer.writeVec(&w.interface, &.{to_write}) catch |e| {
                    if (e == error.WouldBlock) return .continue_;
                    return .remove_and_close;
                };
                w.interface.flush() catch return .remove_and_close;
                conn.write_off += n;
            }
            return .continue_;
        },
        .ws_frames => {
            const ws_buf = conn.ws_read_buf orelse return .remove_and_close;
            if (iocp_opts == null) {
                const io = libs_process.getProcessIo() orelse return .remove_and_close;
                var io_buf: [4096]u8 = undefined;
                var r = conn.stream.reader(io, &io_buf);
                var dest = [1][]u8{ws_buf[conn.ws_read_len..]};
                const n = std.Io.Reader.readVec(&r.interface, &dest) catch |e| {
                    if (e == error.WouldBlock) return .continue_;
                    return .remove_and_close;
                };
                if (n == 0 and conn.ws_read_len == 0) return .remove_and_close;
                if (n > 0) conn.ws_read_len += n;
            }
            const opts = state.ws_options orelse return .remove_and_close;
            const ws_obj_ptr = cb.make_ws_obj(ctx, conn.ws_id) orelse return .remove_and_close;
            var msg_ctx = WsMessageCbContext{ .jsc_ctx = ctx, .ws_obj = ws_obj_ptr, .on_message_fn = opts.on_message };
            const result = if (opts.on_error) |_| blk: {
                var err_ctx = WsErrorCbContext{ .jsc_ctx = ctx, .ws_obj = ws_obj_ptr, .on_error_fn = opts.on_error.? };
                break :blk ws_mod.stepFrames(
                    ws_buf[0..conn.ws_read_len],
                    &conn.write_buf,
                    allocator,
                    cb.ws_on_message,
                    @ptrCast(&msg_ctx),
                    cb.ws_on_error,
                    @ptrCast(&err_ctx),
                );
            } else ws_mod.stepFrames(
                ws_buf[0..conn.ws_read_len],
                &conn.write_buf,
                allocator,
                cb.ws_on_message,
                @ptrCast(&msg_ctx),
                null,
                null,
            );
            if (result.consumed > 0) {
                conn.ws_read_len -= result.consumed;
                if (conn.ws_read_len > 0)
                    @memcpy(ws_buf[0..conn.ws_read_len], ws_buf[result.consumed..][0..conn.ws_read_len]);
            }
            const write_slice = conn.write_buf.items[conn.write_off..];
            if (write_slice.len > 0 and iocp_opts == null) {
                const to_write = write_slice[0..@min(write_slice.len, state.config.ws_max_write_per_tick)];
                const io = libs_process.getProcessIo() orelse return .remove_and_close;
                var wbuf: [8192]u8 = undefined;
                var w = conn.stream.writer(io, &wbuf);
                const n = std.Io.Writer.writeVec(&w.interface, &.{to_write}) catch |e| {
                    if (e == error.WouldBlock) return .continue_;
                    return .remove_and_close;
                };
                w.interface.flush() catch return .remove_and_close;
                conn.write_off += n;
            }
            if (result.parse_error or result.close_requested) {
                _ = state.ws_registry.fetchRemove(conn.ws_id);
                if (opts.on_close) |on_close_fn| {
                    const args = [_]jsc.JSValueRef{ws_obj_ptr};
                    _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(on_close_fn), null, 1, &args, null);
                }
                return .remove_and_close;
            }
            return .continue_;
        },
        .h2c_writing_101 => {
            const slice = conn.write_buf.items[conn.write_off..];
            if (slice.len == 0) {
                conn.phase = .h2c_wait_preface;
                return .continue_;
            }
            if (iocp_opts != null and iocp_opts.?.tag == .from_write) {} else {
                const io = libs_process.getProcessIo() orelse return .remove_and_close;
                var wbuf: [8192]u8 = undefined;
                var w = conn.stream.writer(io, &wbuf);
                const n = std.Io.Writer.writeVec(&w.interface, &.{slice}) catch return .remove_and_close;
                w.interface.flush() catch return .remove_and_close;
                conn.write_off += n;
            }
            return .continue_;
        },
        .h2c_wait_preface => {
            if (conn.read_len < 24) {
                if (iocp_opts != null) return .continue_;
                const io = libs_process.getProcessIo() orelse return .remove_and_close;
                var io_buf: [4096]u8 = undefined;
                var r = conn.stream.reader(io, &io_buf);
                var dest = [1][]u8{conn.read_buf[conn.read_len..]};
                const n = std.Io.Reader.readVec(&r.interface, &dest) catch return .remove_and_close;
                if (n == 0 and conn.read_len == 0) return .remove_and_close;
                if (n > 0) conn.read_len += n;
                return .continue_;
            }
            if (!http2.eqlClientPreface(conn.read_buf[0..24])) return .remove_and_close;
            conn.write_buf.shrinkRetainingCapacity(0);
            http2.appendServerPrefaceTo(&conn.write_buf, allocator) catch return .remove_and_close;
            conn.phase = .h2_send_preface;
            conn.write_off = 0;
            const rest = conn.read_len - 24;
            if (rest > 0 and rest <= conn.read_buf.len) @memcpy(conn.read_buf[0..rest], conn.read_buf[24..][0..rest]);
            conn.read_len = rest;
            return .continue_;
        },
        .h2_send_preface => {
            const slice = conn.write_buf.items[conn.write_off..];
            if (slice.len == 0) {
                conn.phase = .h2_frames;
                conn.read_len = 0;
                conn.h2_streams = .{};
                return .continue_;
            }
            if (iocp_opts != null and iocp_opts.?.tag == .from_write) {} else {
                const io = libs_process.getProcessIo() orelse return .remove_and_close;
                var wbuf: [8192]u8 = undefined;
                var w = conn.stream.writer(io, &wbuf);
                const n = std.Io.Writer.writeVec(&w.interface, &.{slice}) catch return .remove_and_close;
                w.interface.flush() catch return .remove_and_close;
                conn.write_off += n;
            }
            return .continue_;
        },
        .h2_frames => {
            if (iocp_opts == null) {
                const io = libs_process.getProcessIo() orelse return .remove_and_close;
                var io_buf: [4096]u8 = undefined;
                var r = conn.stream.reader(io, &io_buf);
                var dest = [1][]u8{conn.read_buf[conn.read_len..]};
                const n = std.Io.Reader.readVec(&r.interface, &dest) catch return .remove_and_close;
                if (n == 0 and conn.read_len == 0) return .remove_and_close;
                if (n > 0) conn.read_len += n;
            }
            const frame = http2.parseOneFrameFromBuffer(conn.read_buf[0..conn.read_len], 16384) catch return .remove_and_close;
            if (frame == null) return .continue_;
            const f = frame.?;
            if (conn.h2_streams) |*streams| {
                switch (f.header.type) {
                    .settings => {
                        if (f.header.flags & http2.FLAG_ACK == 0) http2.appendSettingsAckTo(&conn.write_buf, allocator) catch return .remove_and_close;
                    },
                    .ping => {
                        if (f.header.flags & http2.FLAG_ACK == 0) http2.appendPingAckTo(&conn.write_buf, allocator, f.payload) catch return .remove_and_close;
                    },
                    .goaway => return .remove_and_close,
                    .headers => {
                        const stream_id = f.header.stream_id;
                        if (stream_id == 0) {} else {
                            const block = http2.headersFramePayloadToBlock(f.payload, f.header.flags);
                            var arena_state = std.heap.ArenaAllocator.init(allocator);
                            errdefer arena_state.deinit();
                            const arena = arena_state.allocator();
                            var headers_list = std.ArrayListUnmanaged(http2.HeaderEntry).initCapacity(allocator, http2.MAX_H2_HEADERS) catch return .remove_and_close;
                            http2.decodeHpackBlockCapped(arena, block, &headers_list, http2.MAX_H2_HEADERS) catch {
                                headers_list.deinit(allocator);
                                arena_state.deinit();
                                return .remove_and_close;
                            };
                            var method: []const u8 = "";
                            var path: []const u8 = "";
                            for (headers_list.items) |h| {
                                if (http2.h2PseudoMethod(h.name)) method = h.value else if (http2.h2PseudoPath(h.name)) path = h.value;
                            }
                            if (method.len == 0) method = "GET";
                            if (path.len == 0) path = "/";
                            var body_list = std.ArrayListUnmanaged(u8).initCapacity(allocator, 0) catch {
                                headers_list.deinit(allocator);
                                arena_state.deinit();
                                return .remove_and_close;
                            };
                            streams.put(allocator, stream_id, .{
                                .arena = arena_state,
                                .headers_list = headers_list,
                                .method = method,
                                .path = path,
                                .body = body_list,
                                .end_stream = (f.header.flags & http2.FLAG_END_STREAM) != 0,
                            }) catch {
                                body_list.deinit(allocator);
                                headers_list.deinit(allocator);
                                arena_state.deinit();
                                return .remove_and_close;
                            };
                            if (f.header.flags & http2.FLAG_END_STREAM != 0) {
                                const entry = streams.getPtr(stream_id).?;
                                var head_list = std.ArrayListUnmanaged(u8).initCapacity(entry.arena.allocator(), 512) catch return .remove_and_close;
                                const arena_al = entry.arena.allocator();
                                for (entry.headers_list.items) |h| {
                                    head_list.appendSlice(arena_al, h.name) catch return .remove_and_close;
                                    head_list.appendSlice(arena_al, ": ") catch return .remove_and_close;
                                    head_list.appendSlice(arena_al, h.value) catch return .remove_and_close;
                                    head_list.append(arena_al, '\n') catch return .remove_and_close;
                                }
                                const headers_head = head_list.toOwnedSlice(arena_al) catch return .remove_and_close;
                                var parsed = ParsedRequest{
                                    .method = entry.method,
                                    .path = entry.path,
                                    .headers_head = headers_head,
                                    .body = if (entry.body.items.len > 0) entry.body.items else null,
                                };
                                var response_ct_buf: [1024]u8 = undefined;
                                const response_body_buf = allocator.alignedAlloc(u8, .@"64", RESPONSE_BODY_BUF_SIZE) catch return .remove_and_close;
                                defer allocator.free(response_body_buf);
                                cb.send_h2_response_to_buffer(&conn.write_buf, allocator, ctx, stream_id, state.handler_fn, &state.config, state.compression_enabled, state.error_callback, &parsed, &response_ct_buf, response_body_buf);
                                entry.deinitEntry(allocator);
                                _ = streams.fetchRemove(stream_id);
                            }
                        }
                    },
                    .data => {
                        const stream_id = f.header.stream_id;
                        if (streams.getPtr(stream_id)) |e| {
                            if (e.body.items.len + f.payload.len > state.config.max_request_body) {
                                http2.appendRstStreamTo(&conn.write_buf, allocator, stream_id, 7) catch {};
                                e.deinitEntry(allocator);
                                _ = streams.fetchRemove(stream_id);
                            } else {
                                e.body.appendSlice(allocator, f.payload) catch {};
                                if (f.header.flags & http2.FLAG_END_STREAM != 0) {
                                    var head_list = std.ArrayListUnmanaged(u8).initCapacity(e.arena.allocator(), 512) catch return .remove_and_close;
                                    const arena_al = e.arena.allocator();
                                    for (e.headers_list.items) |h| {
                                        head_list.appendSlice(arena_al, h.name) catch return .remove_and_close;
                                        head_list.appendSlice(arena_al, ": ") catch return .remove_and_close;
                                        head_list.appendSlice(arena_al, h.value) catch return .remove_and_close;
                                        head_list.append(arena_al, '\n') catch return .remove_and_close;
                                    }
                                    const headers_head = head_list.toOwnedSlice(arena_al) catch return .remove_and_close;
                                    var parsed = ParsedRequest{
                                        .method = e.method,
                                        .path = e.path,
                                        .headers_head = headers_head,
                                        .body = if (e.body.items.len > 0) e.body.items else null,
                                    };
                                    var response_ct_buf: [1024]u8 = undefined;
                                    const response_body_buf = allocator.alignedAlloc(u8, .@"64", RESPONSE_BODY_BUF_SIZE) catch return .remove_and_close;
                                    defer allocator.free(response_body_buf);
                                    cb.send_h2_response_to_buffer(&conn.write_buf, allocator, ctx, stream_id, state.handler_fn, &state.config, state.compression_enabled, state.error_callback, &parsed, &response_ct_buf, response_body_buf);
                                    e.deinitEntry(allocator);
                                    _ = streams.fetchRemove(stream_id);
                                }
                            }
                        }
                    },
                    else => {},
                }
            } else return .remove_and_close;
            conn.read_len -= f.consumed;
            if (conn.read_len > 0) @memcpy(conn.read_buf[0..conn.read_len], conn.read_buf[f.consumed..][0..conn.read_len]);
            const write_slice = conn.write_buf.items[conn.write_off..];
            if (write_slice.len > 0 and iocp_opts == null) {
                const io = libs_process.getProcessIo() orelse return .remove_and_close;
                var wbuf: [8192]u8 = undefined;
                var w = conn.stream.writer(io, &wbuf);
                const n = std.Io.Writer.writeVec(&w.interface, &.{write_slice}) catch return .remove_and_close;
                w.interface.flush() catch return .remove_and_close;
                conn.write_off += n;
            }
            return .continue_;
        },
    }
}
