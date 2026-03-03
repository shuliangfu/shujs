// 连接处理：PreReadReader、PreReadTlsStream、isH2cUpgrade、handleH2Connection、sendH2*（从 mod.zig 拆出）
//
// 职责：h2c 检测、HTTP/2 连接与帧处理、H2 响应/错误写入、带前缀的 Reader/TlsStream。
// 依赖：types、parse、response、http2、request_js、ws_mod、tls、shu_zlib。

const std = @import("std");
const jsc = @import("jsc");
const build_options = @import("build_options");
const types = @import("types.zig");
const parse = @import("parse.zig");
const response = @import("response.zig");
const http2 = @import("http2.zig");
const request_js = @import("request_js.zig");
const ws_mod = @import("websocket.zig");
const tls = @import("tls");
const shu_zlib = @import("../zlib/mod.zig");

const ServerConfig = types.ServerConfig;
const ParsedRequest = types.ParsedRequest;

/// 响应 body 复用 buffer 最小长度（规范 §1.2 禁止栈上 256KB，改为堆/池后由此常量统一）
pub const RESPONSE_BODY_BUF_SIZE = 256 * 1024;

const brotli = shu_zlib;
const gzip_mod = shu_zlib;

// ------------------------------------------------------------------------------
// 带前缀的 Reader / TLS 流
// ------------------------------------------------------------------------------

/// 带前缀的 Reader：先返回 prefix 内容，再从 underlying 读；用于 h2c prior 时把已读 24 字节喂给 HTTP 解析
pub fn PreReadReader(comptime StreamT: type) type {
    return struct {
        prefix: []const u8,
        consumed: usize,
        stream: *StreamT,
        const Self = @This();
        pub fn read(self: *Self, buf: []u8) !usize {
            const avail = self.prefix.len -| self.consumed;
            if (avail > 0) {
                const n = @min(avail, buf.len);
                @memcpy(buf[0..n], self.prefix[self.consumed..][0..n]);
                self.consumed += n;
                return n;
            }
            return self.stream.read(buf);
        }
    };
}

/// TLS handoff 时带已读前缀的流：read 先返回 prefix 再读 stream，writeAll 转发到 stream
pub const PreReadTlsStream = if (build_options.have_tls) struct {
    prefix: []const u8,
    consumed: usize,
    stream: *tls.TlsStream,
    pub fn read(self: *@This(), buf: []u8) !usize {
        const avail = self.prefix.len -| self.consumed;
        if (avail > 0) {
            const n = @min(avail, buf.len);
            @memcpy(buf[0..n], self.prefix[self.consumed..][0..n]);
            self.consumed += n;
            return n;
        }
        return self.stream.read(buf);
    }
    pub fn writeAll(self: *@This(), buf: []const u8) !void {
        return self.stream.writeAll(buf);
    }
} else void;

// ------------------------------------------------------------------------------
// h2c 检测
// ------------------------------------------------------------------------------

/// 是否 Upgrade: h2c（Connection 含 upgrade，Upgrade 含 h2c，不区分大小写）
pub fn isH2cUpgrade(connection_header: ?[]const u8, upgrade_header: ?[]const u8) bool {
    const conn = connection_header orelse return false;
    const up = upgrade_header orelse return false;
    return ws_mod.headerValueContains(conn, "upgrade") and ws_mod.headerValueContains(up, "h2c");
}

// ------------------------------------------------------------------------------
// HTTP/2 错误帧
// ------------------------------------------------------------------------------

/// 向流写入 H2 错误帧（HEADERS + 空 DATA，END_STREAM）
pub fn sendH2Error(s: anytype, stream_id: u31, status: u16) !void {
    var hdr_block: [64]u8 = undefined;
    const block_len = http2.encodeResponseHeaders(&hdr_block, status, null, 0, null) catch return;
    try http2.writeFrame(s, .headers, http2.FLAG_END_HEADERS, stream_id, hdr_block[0..block_len]);
    try http2.writeFrame(s, .data, http2.FLAG_END_STREAM, stream_id, &[_]u8{});
}

// ------------------------------------------------------------------------------
// HTTP/2 响应（流式写出）
// ------------------------------------------------------------------------------

/// 对单个 H2 请求调 handler 并写回 HEADERS + DATA；stream 需具备 writeAll
pub fn sendH2Response(
    allocator: std.mem.Allocator,
    ctx: jsc.JSContextRef,
    stream: anytype,
    stream_id: u31,
    handler_fn: jsc.JSValueRef,
    config: *const ServerConfig,
    compression_enabled: bool,
    error_callback: ?jsc.JSValueRef,
    parsed: *const ParsedRequest,
    response_ct_buf: *[1024]u8,
    response_body_buf: []u8,
) !u32 {
    std.debug.assert(response_body_buf.len >= RESPONSE_BODY_BUF_SIZE);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const req_obj = request_js.makeRequestObject(ctx, arena, parsed) orelse {
        try sendH2Error(stream, stream_id, 500);
        return 1;
    };
    const result = request_js.invokeHandlerWithOnError(ctx, handler_fn, req_obj, error_callback);
    if (!result.is_valid) {
        try sendH2Error(stream, stream_id, 500);
        return 1;
    }
    const response_val = result.value;
    const status = response.getResponseStatus(ctx, response_val);
    const content_type = response.getResponseHeader(ctx, arena, response_val, "Content-Type", response_ct_buf[0..]);
    var response_body = response.getResponseBody(ctx, arena, response_val, response_body_buf) orelse "";
    var content_encoding: ?[]const u8 = null;
    if (compression_enabled and response_body.len > config.min_body_to_compress) {
        switch (parse.chooseAcceptEncoding(parsed)) {
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
    var hdr_block: [1024]u8 = undefined;
    const ct_slice = content_type orelse "application/octet-stream";
    const block_len = http2.encodeResponseHeaders(&hdr_block, status, ct_slice, response_body.len, content_encoding) catch {
        try sendH2Error(stream, stream_id, 500);
        return 1;
    };
    try http2.writeFrame(stream, .headers, http2.FLAG_END_HEADERS, stream_id, hdr_block[0..block_len]);
    if (response_body.len > 0) {
        try http2.writeFrame(stream, .data, http2.FLAG_END_STREAM, stream_id, response_body);
    } else {
        try http2.writeFrame(stream, .data, http2.FLAG_END_STREAM, stream_id, &[_]u8{});
    }
    return 1;
}

// ------------------------------------------------------------------------------
// HTTP/2 响应写入 buffer（多路复用内非阻塞用）
// ------------------------------------------------------------------------------

/// 与 sendH2Response 逻辑一致，但将 HEADERS + DATA 帧追加到 write_buf，供多路复用内非阻塞写出
pub fn sendH2ResponseToBuffer(
    write_buf: *std.ArrayList(u8),
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
) !u32 {
    std.debug.assert(response_body_buf.len >= RESPONSE_BODY_BUF_SIZE);
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const req_obj = request_js.makeRequestObject(ctx, arena, parsed) orelse {
        var hdr_block: [64]u8 = undefined;
        const block_len = http2.encodeResponseHeaders(&hdr_block, 500, null, 0, null) catch return 0;
        try http2.appendFrameTo(write_buf, allocator, .headers, http2.FLAG_END_HEADERS, stream_id, hdr_block[0..block_len]);
        try http2.appendFrameTo(write_buf, allocator, .data, http2.FLAG_END_STREAM, stream_id, &[_]u8{});
        return 1;
    };
    const result = request_js.invokeHandlerWithOnError(ctx, handler_fn, req_obj, error_callback);
    if (!result.is_valid) {
        var hdr_block: [64]u8 = undefined;
        const block_len = http2.encodeResponseHeaders(&hdr_block, 500, null, 0, null) catch return 0;
        try http2.appendFrameTo(write_buf, allocator, .headers, http2.FLAG_END_HEADERS, stream_id, hdr_block[0..block_len]);
        try http2.appendFrameTo(write_buf, allocator, .data, http2.FLAG_END_STREAM, stream_id, &[_]u8{});
        return 1;
    }
    const response_val = result.value;
    const status = response.getResponseStatus(ctx, response_val);
    const content_type = response.getResponseHeader(ctx, arena, response_val, "Content-Type", response_ct_buf[0..]);
    var response_body = response.getResponseBody(ctx, arena, response_val, response_body_buf) orelse "";
    var content_encoding: ?[]const u8 = null;
    if (compression_enabled and response_body.len > config.min_body_to_compress) {
        switch (parse.chooseAcceptEncoding(parsed)) {
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
    var hdr_block: [1024]u8 = undefined;
    const ct_slice = content_type orelse "application/octet-stream";
    const block_len = http2.encodeResponseHeaders(&hdr_block, status, ct_slice, response_body.len, content_encoding) catch {
        var err_block: [64]u8 = undefined;
        const el = http2.encodeResponseHeaders(&err_block, 500, null, 0, null) catch return 0;
        try http2.appendFrameTo(write_buf, allocator, .headers, http2.FLAG_END_HEADERS, stream_id, err_block[0..el]);
        try http2.appendFrameTo(write_buf, allocator, .data, http2.FLAG_END_STREAM, stream_id, &[_]u8{});
        return 1;
    };
    try http2.appendFrameTo(write_buf, allocator, .headers, http2.FLAG_END_HEADERS, stream_id, hdr_block[0..block_len]);
    if (response_body.len > 0) {
        try http2.appendFrameTo(write_buf, allocator, .data, http2.FLAG_END_STREAM, stream_id, response_body);
    } else {
        try http2.appendFrameTo(write_buf, allocator, .data, http2.FLAG_END_STREAM, stream_id, &[_]u8{});
    }
    return 1;
}

// ------------------------------------------------------------------------------
// HTTP/2 连接处理
// ------------------------------------------------------------------------------

/// HTTP/2 连接处理：ALPN h2 或 h2c 时进入；skip_preface 为 true 表示 prior knowledge 已消费 preface，否则先读 24 字节再发 SETTINGS
pub fn handleH2Connection(
    allocator: std.mem.Allocator,
    ctx: jsc.JSContextRef,
    stream: anytype,
    handler_fn: jsc.JSValueRef,
    config: *const ServerConfig,
    compression_enabled: bool,
    error_callback: ?jsc.JSValueRef,
    skip_preface: bool,
) !u32 {
    if (!skip_preface) {
        var preface_buf: [24]u8 = undefined;
        const ok = http2.readExact(stream, &preface_buf, 24) catch return 0;
        if (!ok) return 0;
    }
    try http2.sendServerPreface(stream);
    var frame_buf: [9 + 16384]u8 = undefined;
    var streams = std.AutoHashMap(u31, struct {
        arena: std.heap.ArenaAllocator,
        headers_list: std.ArrayList(http2.HeaderEntry),
        method: []const u8,
        path: []const u8,
        body: std.ArrayList(u8),
        end_stream: bool,
    }).init(allocator);
    defer {
        var it = streams.iterator();
        while (it.next()) |e| {
            e.value_ptr.arena.deinit();
            e.value_ptr.headers_list.deinit(allocator);
            e.value_ptr.body.deinit(allocator);
        }
        streams.deinit();
    }
    var count: u32 = 0;
    var response_ct_buf: [1024]u8 = undefined;
    // 大 buffer 堆分配，避免栈上 256KB（规范 §1.2）
    const response_body_buf = allocator.alloc(u8, RESPONSE_BODY_BUF_SIZE) catch return count;
    defer allocator.free(response_body_buf);
    while (true) {
        const frame = http2.readOneFrame(stream, &frame_buf) catch return count;
        if (frame == null) break;
        const f = frame.?;
        switch (f.header.type) {
            .settings => {
                if (f.header.flags & http2.FLAG_ACK == 0) try http2.sendSettingsAck(stream);
            },
            .ping => {
                if (f.header.flags & http2.FLAG_ACK == 0) try http2.sendPingAck(stream, f.payload);
            },
            .goaway => break,
            .headers => {
                const stream_id = f.header.stream_id;
                if (stream_id == 0) continue;
                const block = http2.headersFramePayloadToBlock(f.payload, f.header.flags);
                var arena_state = std.heap.ArenaAllocator.init(allocator);
                errdefer arena_state.deinit();
                const arena = arena_state.allocator();
                var headers_list = try std.ArrayList(http2.HeaderEntry).initCapacity(allocator, http2.MAX_H2_HEADERS);
                http2.decodeHpackBlockCapped(arena, block, &headers_list, http2.MAX_H2_HEADERS) catch continue;
                var method: []const u8 = "";
                var path: []const u8 = "";
                for (headers_list.items) |h| {
                    if (std.mem.eql(u8, h.name, ":method")) method = h.value else if (std.mem.eql(u8, h.name, ":path")) path = h.value;
                }
                if (method.len == 0) method = "GET";
                if (path.len == 0) path = "/";
                try streams.put(stream_id, .{
                    .arena = arena_state,
                    .headers_list = headers_list,
                    .method = method,
                    .path = path,
                    .body = try std.ArrayList(u8).initCapacity(allocator, 0),
                    .end_stream = (f.header.flags & http2.FLAG_END_STREAM) != 0,
                });
                if (f.header.flags & http2.FLAG_END_STREAM != 0) {
                    const entry = streams.getPtr(stream_id).?;
                    var head_list = std.ArrayList(u8).initCapacity(entry.arena.allocator(), 512) catch return count;
                    const arena_al = entry.arena.allocator();
                    for (entry.headers_list.items) |h| {
                        head_list.appendSlice(arena_al, h.name) catch return count;
                        head_list.appendSlice(arena_al, ": ") catch return count;
                        head_list.appendSlice(arena_al, h.value) catch return count;
                        head_list.append(arena_al, '\n') catch return count;
                    }
                    const headers_head = head_list.toOwnedSlice(arena_al) catch return count;
                    var parsed = ParsedRequest{
                        .method = entry.method,
                        .path = entry.path,
                        .headers_head = headers_head,
                        .body = if (entry.body.items.len > 0) entry.body.items else null,
                    };
                    count += try sendH2Response(allocator, ctx, stream, stream_id, handler_fn, config, compression_enabled, error_callback, &parsed, &response_ct_buf, response_body_buf);
                    entry.headers_list.deinit(allocator);
                    entry.arena.deinit();
                    entry.body.deinit(allocator);
                    _ = streams.remove(stream_id);
                }
            },
            .data => {
                const stream_id = f.header.stream_id;
                const entry = streams.getPtr(stream_id) orelse continue;
                if (entry.body.items.len + f.payload.len > config.max_request_body) {
                    try http2.sendRstStream(stream, stream_id, 7);
                    entry.headers_list.deinit(allocator);
                    entry.arena.deinit();
                    entry.body.deinit(allocator);
                    _ = streams.remove(stream_id);
                    continue;
                }
                entry.body.appendSlice(allocator, f.payload) catch continue;
                if (f.header.flags & http2.FLAG_END_STREAM != 0) {
                    var head_list = std.ArrayList(u8).initCapacity(entry.arena.allocator(), 512) catch return count;
                    const arena_al = entry.arena.allocator();
                    for (entry.headers_list.items) |h| {
                        head_list.appendSlice(arena_al, h.name) catch return count;
                        head_list.appendSlice(arena_al, ": ") catch return count;
                        head_list.appendSlice(arena_al, h.value) catch return count;
                        head_list.append(arena_al, '\n') catch return count;
                    }
                    const headers_head = head_list.toOwnedSlice(arena_al) catch return count;
                    var parsed = ParsedRequest{
                        .method = entry.method,
                        .path = entry.path,
                        .headers_head = headers_head,
                        .body = if (entry.body.items.len > 0) entry.body.items else null,
                    };
                    count += try sendH2Response(allocator, ctx, stream, stream_id, handler_fn, config, compression_enabled, error_callback, &parsed, &response_ct_buf, response_body_buf);
                    entry.headers_list.deinit(allocator);
                    entry.arena.deinit();
                    entry.body.deinit(allocator);
                    _ = streams.remove(stream_id);
                }
            },
            else => {},
        }
    }
    return count;
}
