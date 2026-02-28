// WebSocket 服务端协议层（RFC 6455）：Upgrade 识别、握手、帧解析与组帧
//
// 职责
// -----
// - 与 HTTP 同端口：通过 Connection/Upgrade 头判断是否为 WebSocket，非 Upgrade 请求由上层走普通 HTTP handler。
// - 握手：根据 Sec-WebSocket-Key 计算 Sec-WebSocket-Accept，生成 101 响应（可写 stream 或追加到 buffer）。
// - 帧：解析/组帧（含 mask 解码）、text/binary/ping/pong/close 处理；本模块不持有 socket，I/O 由上层通过回调或 buffer 提供。
//
// 两种使用方式
// ------------
// 1. 非阻塞（多路复用 / io_core 路径）：
//    - 上层用 io_core 的 recv 完成把数据写入连接 buffer，再调用 stepFrames(buf, out_frames, ...)。
//    - stepFrames 只做内存内解析与组帧，不执行任何 read/write；写出由上层通过 io_core 的 submitSend 发送 out_frames。
//    - 调用方：step_plain.zig / step_tls.zig 在 ws_frames 阶段调用 stepFrames。
//
// 2. 阻塞（handoff 单连接路径）：
//    - runFrameLoop(reader, writer, frame_buf, ...) 内部 while(true) 调用 reader.read_fn 读数据，解析后通过 writer.send_fn 写回。
//    - 若 read_fn 为 stream.read()，则在无数据时阻塞；仅用于 handleConnectionPlain / handleConnection 的单连接处理路径。
//
// 依赖
// ----
// 仅 std；无 jsc、无 server 其它子模块。

const std = @import("std");

/// RFC 6455 握手用魔串
const WS_ACCEPT_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// 判断是否为 WebSocket Upgrade 请求：Connection 含 upgrade 且 Upgrade 含 websocket（不区分大小写）
pub fn isWebSocketUpgrade(connection_header: ?[]const u8, upgrade_header: ?[]const u8) bool {
    const conn = connection_header orelse return false;
    const up = upgrade_header orelse return false;
    return headerValueContains(conn, "upgrade") and headerValueContains(up, "websocket");
}

/// 判断 value 中是否包含 token（不区分大小写），供 Upgrade 等头判断
pub fn headerValueContains(value: []const u8, token: []const u8) bool {
    if (value.len < token.len) return false;
    var i: usize = 0;
    while (i <= value.len - token.len) {
        const slice = value[i..][0..token.len];
        var match = true;
        for (token, slice) |t, v| {
            const tc = if (t >= 'a' and t <= 'z') t - 32 else t;
            const vc = if (v >= 'a' and v <= 'z') v - 32 else v;
            if (tc != vc) {
                match = false;
                break;
            }
        }
        if (match) return true;
        i += 1;
    }
    return false;
}

/// 根据客户端 Sec-WebSocket-Key 计算 Sec-WebSocket-Accept（SHA1 + base64，RFC 6455）
pub fn computeAcceptKey(key: []const u8) ![28]u8 {
    var input_buf: [256]u8 = undefined;
    if (key.len + WS_ACCEPT_GUID.len > input_buf.len) return error.InvalidKey;
    @memcpy(input_buf[0..key.len], key);
    @memcpy(input_buf[key.len..][0..WS_ACCEPT_GUID.len], WS_ACCEPT_GUID);
    const input = input_buf[0 .. key.len + WS_ACCEPT_GUID.len];

    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(input, &hash, .{});

    var out: [28]u8 = undefined;
    const enc = std.base64.standard.Encoder;
    _ = enc.encode(&out, &hash);
    return out;
}

/// 发送 101 Switching Protocols 与 Sec-WebSocket-Accept，完成握手
pub fn sendHandshake(stream: anytype, accept_key: [28]u8) !void {
    try stream.writeAll("HTTP/1.1 101 Switching Protocols\r\n");
    try stream.writeAll("Upgrade: websocket\r\n");
    try stream.writeAll("Connection: Upgrade\r\n");
    try stream.writeAll("Sec-WebSocket-Accept: ");
    try stream.writeAll(&accept_key);
    try stream.writeAll("\r\n\r\n");
}

/// 将 101 握手响应追加到 out（非阻塞路径用，不写 stream）
pub fn appendHandshakeTo(out: *std.ArrayList(u8), accept_key: [28]u8, allocator: std.mem.Allocator) !void {
    try out.appendSlice(allocator, "HTTP/1.1 101 Switching Protocols\r\n");
    try out.appendSlice(allocator, "Upgrade: websocket\r\n");
    try out.appendSlice(allocator, "Connection: Upgrade\r\n");
    try out.appendSlice(allocator, "Sec-WebSocket-Accept: ");
    try out.appendSlice(allocator, &accept_key);
    try out.appendSlice(allocator, "\r\n\r\n");
}

/// WebSocket 帧 opcode（RFC 6455 5.2）
pub const Opcode = enum(u4) {
    continuation = 0,
    text = 1,
    binary = 2,
    close = 8,
    ping = 9,
    pong = 10,
};

/// 解析一帧：返回 opcode 与 payload（payload 可能指向 buf，调用方勿长期持有）
/// buf 为可写，用于客户端 mask 原地解码；若需要更多数据则返回 error.NeedMore
pub fn parseFrame(buf: []u8) !struct { opcode: Opcode, payload: []const u8, consumed: usize } {
    if (buf.len < 2) return error.NeedMore;
    const fin = (buf[0] & 0x80) != 0;
    _ = fin;
    const opcode_raw = buf[0] & 0x0F;
    const opcode = @as(Opcode, @enumFromInt(opcode_raw));
    const masked = (buf[1] & 0x80) != 0;
    var payload_len: u64 = buf[1] & 0x7F;
    var header_len: usize = 2;
    if (payload_len == 126) {
        if (buf.len < 4) return error.NeedMore;
        payload_len = std.mem.readInt(u16, buf[2..4], .big);
        header_len = 4;
    } else if (payload_len == 127) {
        if (buf.len < 10) return error.NeedMore;
        payload_len = std.mem.readInt(u64, buf[2..10], .big);
        header_len = 10;
    }
    const mask_key_len: usize = if (masked) 4 else 0;
    if (buf.len < header_len + mask_key_len + payload_len) return error.NeedMore;
    const payload_start = header_len + mask_key_len;
    const payload = buf[payload_start..][0..payload_len];
    if (masked) {
        const key = buf[header_len..][0..4];
        for (payload, 0..) |*b, i| {
            b.* ^= key[i % 4];
        }
    }
    return .{
        .opcode = opcode,
        .payload = payload,
        .consumed = header_len + mask_key_len + payload_len,
    };
}

/// 组一帧（服务端不发 mask）：opcode + payload，写入 out_buf，返回写入长度
pub fn buildFrame(out_buf: []u8, opcode: Opcode, payload: []const u8) !usize {
    if (out_buf.len < 2) return error.BufferTooSmall;
    out_buf[0] = 0x80 | @as(u8, @intFromEnum(opcode));
    var pos: usize = 2;
    if (payload.len < 126) {
        out_buf[1] = @intCast(payload.len);
    } else if (payload.len < 65536) {
        if (out_buf.len < 4) return error.BufferTooSmall;
        out_buf[1] = 126;
        std.mem.writeInt(u16, out_buf[2..4], @intCast(payload.len), .big);
        pos = 4;
    } else {
        if (out_buf.len < 10) return error.BufferTooSmall;
        out_buf[1] = 127;
        std.mem.writeInt(u64, out_buf[2..10], payload.len, .big);
        pos = 10;
    }
    if (out_buf.len < pos + payload.len) return error.BufferTooSmall;
    @memcpy(out_buf[pos..][0..payload.len], payload);
    return pos + payload.len;
}

/// 组一帧并带 mask（RFC 6455 客户端必须 mask）：opcode + 4 字节 mask key + 异或后的 payload，写入 out_buf，返回写入长度
pub fn buildFrameMasked(out_buf: []u8, opcode: Opcode, payload: []const u8, mask_key: [4]u8) !usize {
    if (out_buf.len < 2) return error.BufferTooSmall;
    out_buf[0] = 0x80 | @as(u8, @intFromEnum(opcode));
    var pos: usize = 2;
    if (payload.len < 126) {
        out_buf[1] = 0x80 | @as(u8, @intCast(payload.len));
        pos = 2;
    } else if (payload.len < 65536) {
        if (out_buf.len < 4) return error.BufferTooSmall;
        out_buf[1] = 0x80 | 126;
        std.mem.writeInt(u16, out_buf[2..4], @intCast(payload.len), .big);
        pos = 4;
    } else {
        if (out_buf.len < 10) return error.BufferTooSmall;
        out_buf[1] = 0x80 | 127;
        std.mem.writeInt(u64, out_buf[2..10], payload.len, .big);
        pos = 10;
    }
    if (out_buf.len < pos + 4 + payload.len) return error.BufferTooSmall;
    @memcpy(out_buf[pos..][0..4], &mask_key);
    pos += 4;
    for (payload, 0..) |b, i| {
        out_buf[pos + i] = b ^ mask_key[i % 4];
    }
    return pos + payload.len;
}

/// 读接口：read_ctx + read_fn 抽象流读取（返回读到的字节数，0 表示关闭）
pub const Reader = struct {
    ctx: *anyopaque,
    read_fn: *const fn (*anyopaque, []u8) usize,
};
/// 写接口：send_ctx + send_fn 抽象帧发送
pub const Writer = struct {
    ctx: *anyopaque,
    send_fn: *const fn (*anyopaque, []const u8) void,
};

/// 步进式帧处理（非阻塞）：从 buf 解析所有完整帧，回调 on_message，pong/close 追加到 out_frames
/// 返回消费字节数、是否收到 close、是否解析错误（解析错误时已调 on_error_cb）
pub fn stepFrames(
    buf: []const u8,
    out_frames: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    on_message_cb: *const fn (*anyopaque, []const u8) void,
    on_message_ctx: *anyopaque,
    on_error_cb: ?*const fn (*anyopaque, []const u8) void,
    on_error_ctx: ?*anyopaque,
) struct { consumed: usize, close_requested: bool, parse_error: bool } {
    var consumed: usize = 0;
    var mutable_buf = buf;
    while (mutable_buf.len >= 2) {
        const parsed = parseFrame(@constCast(mutable_buf)) catch |e| {
            if (e == error.NeedMore) break;
            if (on_error_cb) |cb| {
                if (on_error_ctx) |ctx| cb(ctx, "WebSocket frame parse error");
            }
            return .{ .consumed = consumed, .close_requested = false, .parse_error = true };
        };
        consumed += parsed.consumed;
        mutable_buf = mutable_buf[parsed.consumed..];
        switch (parsed.opcode) {
            .text, .binary => on_message_cb(on_message_ctx, parsed.payload),
            .ping => {
                var pong_buf: [128]u8 = undefined;
                const len = buildFrame(&pong_buf, .pong, parsed.payload) catch continue;
                out_frames.appendSlice(allocator, pong_buf[0..len]) catch {};
            },
            .close => {
                var close_buf: [8]u8 = undefined;
                const len = buildFrame(&close_buf, .close, &[_]u8{}) catch 2;
                out_frames.appendSlice(allocator, close_buf[0..len]) catch {};
                return .{ .consumed = consumed, .close_requested = true, .parse_error = false };
            },
            .pong, .continuation => {},
        }
    }
    return .{ .consumed = consumed, .close_requested = false, .parse_error = false };
}

/// 帧循环：读帧，text/binary 调 on_message(ws_obj, payload)，ping 回 pong，close 回 close 并退出
/// 可选 on_error_cb(ctx, message)：帧解析失败或异常断开时调用，然后退出
pub fn runFrameLoop(
    reader: Reader,
    writer: Writer,
    frame_buf: []u8,
    on_message_cb: *const fn (*anyopaque, []const u8) void,
    on_message_ctx: *anyopaque,
    on_error_cb: ?*const fn (*anyopaque, []const u8) void,
    on_error_ctx: ?*anyopaque,
) void {
    var buf_len: usize = 0;
    while (true) {
        if (buf_len < frame_buf.len) {
            const n = reader.read_fn(reader.ctx, frame_buf[buf_len..]);
            if (n == 0) break;
            buf_len += n;
        }
        const parsed = parseFrame(frame_buf[0..buf_len]) catch |e| {
            if (e == error.NeedMore) {
                if (buf_len == frame_buf.len) {
                    buf_len = 0;
                    continue;
                }
                break;
            }
            // 帧解析失败（非法帧等）：若有 on_error 则回调后退出
            if (on_error_cb) |cb| {
                if (on_error_ctx) |ctx| {
                    const msg = "WebSocket frame parse error";
                    cb(ctx, msg);
                }
            }
            break;
        };
        buf_len -= parsed.consumed;
        if (buf_len > 0) @memcpy(frame_buf[0..buf_len], frame_buf[parsed.consumed..][0..buf_len]);

        switch (parsed.opcode) {
            .text, .binary => on_message_cb(on_message_ctx, parsed.payload),
            .ping => {
                var pong_buf: [128]u8 = undefined;
                const len = buildFrame(&pong_buf, .pong, parsed.payload) catch continue;
                writer.send_fn(writer.ctx, pong_buf[0..len]);
            },
            .close => {
                var close_buf: [8]u8 = undefined;
                const len = buildFrame(&close_buf, .close, &[_]u8{}) catch 2;
                writer.send_fn(writer.ctx, close_buf[0..len]);
                break;
            },
            .pong, .continuation => {},
        }
    }
}

// ========== 单元测试：Upgrade 判断、Accept 计算、帧解析/组帧 ==========

test "isWebSocketUpgrade: 需要 connection 与 upgrade 头" {
    try std.testing.expect(!isWebSocketUpgrade(null, "websocket"));
    try std.testing.expect(!isWebSocketUpgrade("upgrade", null));
    try std.testing.expect(!isWebSocketUpgrade("keep-alive", "websocket"));
    try std.testing.expect(isWebSocketUpgrade("Upgrade", "websocket"));
    try std.testing.expect(isWebSocketUpgrade("Connection: Upgrade", "Upgrade: websocket"));
    try std.testing.expect(isWebSocketUpgrade("keep-alive, Upgrade", "WebSocket"));
}

test "headerValueContains: 不区分大小写" {
    try std.testing.expect(headerValueContains("upgrade", "upgrade"));
    try std.testing.expect(headerValueContains("Upgrade", "upgrade"));
    try std.testing.expect(headerValueContains("Upgrade", "Upgrade"));
    try std.testing.expect(!headerValueContains("keep-alive", "upgrade"));
    try std.testing.expect(headerValueContains("keep-alive, Upgrade", "upgrade"));
}

test "computeAcceptKey: RFC 6455 示例" {
    // RFC 6455 示例：key "dGhlIHNhbXBsZSBub25jZQ==" -> accept "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    const accept = try computeAcceptKey(key);
    const expected = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=";
    try std.testing.expectEqualStrings(expected, &accept);
}

test "parseFrame: 无 mask 短 payload" {
    var buf: [128]u8 = undefined;
    const payload: []const u8 = "hello";
    const n = try buildFrame(&buf, .text, payload);
    try std.testing.expect(n >= 2 + payload.len);
    const parsed = try parseFrame(buf[0..n]);
    try std.testing.expect(parsed.opcode == .text);
    try std.testing.expectEqualStrings(payload, parsed.payload);
    try std.testing.expect(parsed.consumed == n);
}

test "parseFrame: 带 mask 的客户端帧" {
    // 客户端发来的帧：fin=1, opcode=text, mask=1, payload_len=5, mask_key 4 字节 + payload
    var buf: [32]u8 = undefined;
    buf[0] = 0x81;
    buf[1] = 0x85;
    buf[2] = 0x37;
    buf[3] = 0xfa;
    buf[4] = 0x21;
    buf[5] = 0x3d;
    buf[6] = 0x7f;
    buf[7] = 0x9f;
    buf[8] = 0x4d;
    buf[9] = 0x51;
    buf[10] = 0x58;
    const parsed = try parseFrame(buf[0..11]);
    try std.testing.expect(parsed.opcode == .text);
    try std.testing.expect(parsed.payload.len == 5);
    try std.testing.expect(parsed.consumed == 11);
}

test "parseFrame: NeedMore 不足 2 字节" {
    var buf: [1]u8 = .{0x81};
    const r = parseFrame(&buf);
    try std.testing.expectError(error.NeedMore, r);
}

test "parseFrame: payload 126 扩展长度" {
    var buf: [256]u8 = undefined;
    var payload_buf: [200]u8 = undefined;
    @memset(&payload_buf, 0x41);
    const payload = payload_buf[0..130];
    const n = try buildFrame(&buf, .binary, payload);
    try std.testing.expect(n == 4 + 130);
    const parsed = try parseFrame(buf[0..n]);
    try std.testing.expect(parsed.opcode == .binary);
    try std.testing.expect(parsed.payload.len == 130);
    try std.testing.expect(parsed.consumed == n);
}

test "buildFrame: 空 payload" {
    var buf: [16]u8 = undefined;
    const n = try buildFrame(&buf, .close, &[_]u8{});
    try std.testing.expect(n == 2);
    try std.testing.expect(buf[0] == 0x80 | 8);
    try std.testing.expect(buf[1] == 0);
}

test "buildFrame: BufferTooSmall" {
    var buf: [1]u8 = undefined;
    const r = buildFrame(&buf, .text, "x");
    try std.testing.expectError(error.BufferTooSmall, r);
}
