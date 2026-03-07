//! HTTP/2 客户端：TLS ALPN h2 协商后发 GET 请求，读响应头与 body；供 http.zig 在 https 时自动探测（ALPN 为 h2 则用 HTTP/2，否则回退 HTTP/1.1）。
//! 依赖 tls（TlsClientContext、TlsStream）、http2（帧与 HPACK）、libs_process（getProcessIo）。

const std = @import("std");
const libs_process = @import("libs_process");
const tls = @import("tls");
const http2 = @import("http2");

/// 与 http.zig Response 兼容的返回值；调用方负责 free body 与 status_text（当 status_text_is_allocated 时）。
pub const H2Response = struct {
    status: u16 = 0,
    status_text: []const u8 = "",
    status_text_is_allocated: bool = false,
    body: []const u8 = "",
    content_encoding: ?[]const u8 = null,
};

/// 未启用 TLS 或 ALPN 未协商为 h2 时返回，调用方应回退到 HTTP/1.1。
pub const Http2NotAvailable = error{Http2NotAvailable};

/// 从 options.method 取方法名字符串（与 http.zig Method 枚举一致）
fn methodToString(method: anytype) []const u8 {
    return @tagName(method);
}

/// [Allocates] 当 ALPN 为 h2 时走 HTTP/2：preface、SETTINGS、HEADERS（GET）、读响应 HEADERS+DATA，返回 H2Response。调用方 free body 与可分配的 status_text。
/// 若 ALPN 非 h2 或连接失败则返回 error.Http2NotAvailable，由 http.zig 回退 HTTP/1.1。
pub fn requestViaH2(
    allocator: std.mem.Allocator,
    url: []const u8,
    options: anytype,
) (Http2NotAvailable || std.mem.Allocator.Error || std.Uri.ParseError || error{
    TlsHandshakeFailed,
    TlsReadFailed,
    TlsWriteFailed,
    ConnectionClosed,
    FrameTooLarge,
    InvalidHpack,
    InvalidHuffman,
    NeedMore,
    TooManyHeaders,
    BufferTooSmall,
    InvalidUrl,
})!H2Response {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    if (!std.mem.eql(u8, uri.scheme, "https")) return error.Http2NotAvailable;

    const io = libs_process.getProcessIo() orelse return error.Http2NotAvailable;
    const host = uri.host orelse return error.InvalidUrl;
    var host_buf: [256]u8 = undefined;
    const host_slice = host.toRaw(&host_buf) catch host_buf[0..0];
    if (host_slice.len == 0) return error.InvalidUrl;

    const port: u16 = @intCast(uri.port orelse 443);
    var path_buf: [4096]u8 = undefined;
    var path_len: usize = 0;
    // toRaw 写入 path_buf 并返回其切片，path_slice 与 path_buf 重叠，禁止 @memcpy
    const path_slice = uri.path.toRaw(path_buf[0..]) catch path_buf[0..0];
    if (path_slice.len > 0) {
        path_len = path_slice.len;
    } else {
        path_buf[0] = '/';
        path_len = 1;
    }
    if (uri.query) |q| {
        var q_buf: [2048]u8 = undefined;
        const q_raw = q.toRaw(&q_buf) catch q_buf[0..0];
        if (q_raw.len > 0 and path_len + 1 + q_raw.len <= path_buf.len) {
            path_buf[path_len] = '?';
            @memcpy(path_buf[path_len + 1 ..][0..q_raw.len], q_raw);
            path_len += 1 + q_raw.len;
        }
    }
    const path_for_h2 = path_buf[0..path_len];

    var client_ctx = tls.TlsClientContext.create(allocator, null, true) orelse return error.Http2NotAvailable;
    defer client_ctx.destroy();

    const addr = std.Io.net.IpAddress.resolve(io, host_slice, port) catch return error.Http2NotAvailable;
    var tcp_stream = std.Io.net.IpAddress.connect(addr, io, .{ .mode = .stream }) catch return error.Http2NotAvailable;
    var tls_stream = tls.TlsStream.connect(tcp_stream, &client_ctx, host_slice, allocator) catch {
        tcp_stream.close(io);
        return error.Http2NotAvailable;
    };
    defer tls_stream.close(io);

    var alpn_buf: [8]u8 = undefined;
    const alpn = tls_stream.getAlpnSelected(&alpn_buf) orelse return error.Http2NotAvailable;
    if (!std.mem.eql(u8, alpn, "h2")) return error.Http2NotAvailable;

    // 发送客户端 preface（24 字节）+ SETTINGS（空）
    try tls_stream.writeAll(http2.CLIENT_PREFACE);
    try http2.sendServerPreface(&tls_stream);

    const method_str = methodToString(options.method);
    var authority_buf: [320]u8 = undefined;
    const authority = if (port == 443)
        host_slice
    else
        (std.fmt.bufPrint(&authority_buf, "{s}:{d}", .{ host_slice, port }) catch host_slice);

    var hpack_buf: [1024]u8 = undefined;
    const hpack_len = http2.encodeRequestHeaders(&hpack_buf, method_str, path_for_h2, "https", authority) catch return error.BufferTooSmall;
    try http2.writeFrame(&tls_stream, .headers, http2.FLAG_END_HEADERS | http2.FLAG_END_STREAM, 1, hpack_buf[0..hpack_len]);

    var frame_buf: [65536]u8 = undefined;
    var body_list = std.ArrayListUnmanaged(u8).empty;
    defer body_list.deinit(allocator);
    var status: u16 = 200;
    var status_text: []const u8 = "OK";
    var status_allocated: bool = false;
    errdefer if (status_allocated) allocator.free(status_text);

    while (true) {
        const frame = http2.readOneFrame(&tls_stream, &frame_buf) catch return error.ConnectionClosed;
        if (frame == null) break;

        const f = frame.?;
        switch (f.header.type) {
            .settings => {
                if (f.header.flags & http2.FLAG_ACK == 0) try http2.sendSettingsAck(&tls_stream);
            },
            .headers, .continuation => {
                if (f.header.stream_id != 1) continue;
                const block = http2.headersFramePayloadToBlock(f.payload, f.header.flags);
                var headers = std.ArrayListUnmanaged(http2.HeaderEntry).empty;
                defer headers.deinit(allocator);
                try headers.ensureTotalCapacity(allocator, http2.MAX_H2_HEADERS);
                try http2.decodeHpackBlock(allocator, block, &headers);
                for (headers.items) |h| {
                    if (std.mem.eql(u8, h.name, ":status")) {
                        status = std.fmt.parseInt(u16, h.value, 10) catch 200;
                        status_text = statusCodeToStatic(status);
                        status_allocated = false;
                    }
                }
                if (f.header.flags & http2.FLAG_END_STREAM != 0) break;
            },
            .data => {
                if (f.header.stream_id == 1) {
                    try body_list.appendSlice(allocator, f.payload);
                    if (f.header.flags & http2.FLAG_END_STREAM != 0) break;
                }
            },
            .goaway => break,
            else => {},
        }
    }

    const body = try body_list.toOwnedSlice(allocator);
    return .{
        .status = status,
        .status_text = status_text,
        .status_text_is_allocated = status_allocated,
        .body = body,
        .content_encoding = null,
    };
}

fn statusCodeToStatic(code: u16) []const u8 {
    return switch (code) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        409 => "Conflict",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        else => "Unknown",
    };
}
