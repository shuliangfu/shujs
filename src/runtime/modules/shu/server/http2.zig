// HTTP/2 服务端：TLS ALPN h2 或 h2c；帧解析（SETTINGS/HEADERS/DATA 等）与流状态；与现有 handler 对接
// RFC 7540 (HTTP/2) + RFC 7541 (HPACK)

const std = @import("std");
const hpack_huffman = @import("hpack_huffman");

/// HPACK 解码后的单条头部，供 decodeHpackBlock / h2HeadersToParsed 使用
pub const HeaderEntry = struct { name: []const u8, value: []const u8 };

/// H2 单流最大头部条数（§1.3 BoundedArray 固定上限，避免 ArrayList 扩容与 allocator 热路径）
pub const MAX_H2_HEADERS = 64;

/// 客户端连接 preface 魔串（24 字节），h2/h2c 连接建立后客户端必须先发
pub const CLIENT_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

/// 24 字节与 CLIENT_PREFACE 按 3×u64 比较，避免 std.mem.eql 分支（00 §2.1）。buf.len >= 24 时调用；调用方保证 buf.ptr 至少 8 字节对齐（如 read_buf 为 align(64)）。
pub inline fn eqlClientPreface(buf: []const u8) bool {
    if (buf.len < 24) return false;
    const p = @as([*]align(8) const u8, @alignCast(buf.ptr));
    const a = @as(*const [3]u64, @ptrCast(p)).*;
    const q = @as([*]align(8) const u8, @alignCast(CLIENT_PREFACE[0..24].ptr));
    const b = @as(*const [3]u64, @ptrCast(q)).*;
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2];
}

/// 伪头 ":method" 用 u64 前缀比较（00 §2.1）
pub inline fn h2PseudoMethod(name: []const u8) bool {
    return name.len == 7 and h2NamePrefix(name) == h2Prefix8(":method");
}
/// 伪头 ":path" 用 u64 前缀比较（00 §2.1）
pub inline fn h2PseudoPath(name: []const u8) bool {
    return name.len == 5 and h2NamePrefix(name) == h2Prefix8(":path");
}

/// 帧类型（RFC 7540 6）
pub const FrameType = enum(u8) {
    data = 0,
    headers = 1,
    priority = 2,
    rst_stream = 3,
    settings = 4,
    push_promise = 5,
    ping = 6,
    goaway = 7,
    window_update = 8,
    continuation = 9,
};

/// 常用标志位
pub const FLAG_END_STREAM: u8 = 0x01;
pub const FLAG_END_HEADERS: u8 = 0x04;
pub const FLAG_ACK: u8 = 0x01; // SETTINGS 用

/// 帧头：9 字节 = 24bit 长度 + 8bit 类型 + 8bit 标志 + 31bit 流 id（高 1 位保留）
pub const FrameHeader = struct {
    length: u24,
    type: FrameType,
    flags: u8,
    stream_id: u31,
};

/// 从至少 9 字节的 buf 解析帧头
pub fn parseFrameHeader(buf: []const u8) !FrameHeader {
    if (buf.len < 9) return error.NeedMore;
    const length = @as(u24, buf[0]) << 16 | @as(u24, buf[1]) << 8 | buf[2];
    const type_byte = buf[3];
    const flags = buf[4];
    const stream_id = @as(u32, buf[5]) << 24 | @as(u32, buf[6]) << 16 | @as(u32, buf[7]) << 8 | buf[8];
    return .{
        .length = length,
        .type = @enumFromInt(type_byte),
        .flags = flags,
        .stream_id = @truncate(stream_id),
    };
}

/// 写一帧：9 字节头 + payload；stream 需实现 writeAll
pub fn writeFrame(stream: anytype, frame_type: FrameType, flags: u8, stream_id: u31, payload: []const u8) !void {
    var hdr: [9]u8 = undefined;
    const len: u24 = @intCast(payload.len);
    hdr[0] = @as(u8, @truncate(len >> 16));
    hdr[1] = @as(u8, @truncate(len >> 8));
    hdr[2] = @as(u8, @truncate(len));
    hdr[3] = @intFromEnum(frame_type);
    hdr[4] = flags;
    hdr[5] = @as(u8, @truncate(stream_id >> 24));
    hdr[6] = @as(u8, @truncate(stream_id >> 16));
    hdr[7] = @as(u8, @truncate(stream_id >> 8));
    hdr[8] = @as(u8, @truncate(stream_id));
    try stream.writeAll(&hdr);
    if (payload.len > 0) try stream.writeAll(payload);
}

/// 读满 len 字节到 buf，返回是否读满；reader 需实现 read
pub fn readExact(reader: anytype, buf: []u8, len: usize) !bool {
    if (len > buf.len) return error.BufferTooSmall;
    var got: usize = 0;
    while (got < len) {
        const n = reader.read(buf[got..len]) catch return error.ConnectionClosed;
        if (n == 0) return false;
        got += n;
    }
    return true;
}

/// 读一帧：先读 9 字节头，再读 payload；frame_buf 需至少 9 + max_frame_size
/// 返回 payload 在 frame_buf 中的切片（frame_buf[9..9+header.length]），以及 header
pub fn readOneFrame(reader: anytype, frame_buf: []u8) !?struct { header: FrameHeader, payload: []const u8 } {
    const ok = readExact(reader, frame_buf, 9) catch return error.ConnectionClosed;
    if (!ok) return null;
    const header = try parseFrameHeader(frame_buf[0..9]);
    if (header.length > frame_buf.len - 9) return error.FrameTooLarge;
    const payload_ok = readExact(reader, frame_buf[9..], header.length) catch return error.ConnectionClosed;
    if (!payload_ok) return null;
    return .{ .header = header, .payload = frame_buf[9..][0..header.length] };
}

/// 从缓冲区解析一帧（非阻塞用）：buf 为已读入的 H2 数据，若不足一帧返回 null（NeedMore）
/// 返回 header、payload（指向 buf 内切片）、consumed（消费字节数）；payload 在调用方移位 buf 前有效
/// max_payload_len 为单帧 payload 上限（如 16384），超则返回 error.FrameTooLarge
pub fn parseOneFrameFromBuffer(buf: []const u8, max_payload_len: usize) !?struct {
    header: FrameHeader,
    payload: []const u8,
    consumed: usize,
} {
    if (buf.len < 9) return null;
    const header = try parseFrameHeader(buf[0..9]);
    if (header.length > max_payload_len) return error.FrameTooLarge;
    if (buf.len < 9 + header.length) return null;
    const payload = buf[9..][0..header.length];
    return .{ .header = header, .payload = payload, .consumed = 9 + header.length };
}

/// 将一帧（9 字节头 + payload）追加到 out，供非阻塞写时复用 write_buf（01 §1.2 使用 Unmanaged 以省 allocator 存储）
pub fn appendFrameTo(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, frame_type: FrameType, flags: u8, stream_id: u31, payload: []const u8) !void {
    var hdr: [9]u8 = undefined;
    const len: u24 = @intCast(payload.len);
    hdr[0] = @as(u8, @truncate(len >> 16));
    hdr[1] = @as(u8, @truncate(len >> 8));
    hdr[2] = @as(u8, @truncate(len));
    hdr[3] = @intFromEnum(frame_type);
    hdr[4] = flags;
    hdr[5] = @as(u8, @truncate(stream_id >> 24));
    hdr[6] = @as(u8, @truncate(stream_id >> 16));
    hdr[7] = @as(u8, @truncate(stream_id >> 8));
    hdr[8] = @as(u8, @truncate(stream_id));
    try out.appendSlice(allocator, &hdr);
    if (payload.len > 0) try out.appendSlice(allocator, payload);
}

/// 将服务端 SETTINGS（空 payload）追加到 out
pub fn appendServerPrefaceTo(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
    try appendFrameTo(out, allocator, .settings, 0, 0, &[_]u8{});
}

/// 将 SETTINGS ACK 追加到 out
pub fn appendSettingsAckTo(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
    try appendFrameTo(out, allocator, .settings, FLAG_ACK, 0, &[_]u8{});
}

/// 将 PING ACK（payload 前 8 字节）追加到 out
pub fn appendPingAckTo(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, payload: []const u8) !void {
    var reply: [8]u8 = [_]u8{0} ** 8;
    if (payload.len >= 8) @memcpy(reply[0..], payload[0..8]);
    try appendFrameTo(out, allocator, .ping, FLAG_ACK, 0, &reply);
}

/// 将 RST_STREAM 帧追加到 out
pub fn appendRstStreamTo(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, stream_id: u31, error_code: u32) !void {
    var payload: [4]u8 = undefined;
    payload[0] = @as(u8, @truncate(error_code >> 24));
    payload[1] = @as(u8, @truncate(error_code >> 16));
    payload[2] = @as(u8, @truncate(error_code >> 8));
    payload[3] = @as(u8, @truncate(error_code));
    try appendFrameTo(out, allocator, .rst_stream, 0, stream_id, &payload);
}

/// 服务端连接 preface：发送 SETTINGS（空）表示支持 h2
pub fn sendServerPreface(stream: anytype) !void {
    try writeFrame(stream, .settings, 0, 0, &[_]u8{});
}

/// 对客户端 SETTINGS 回 ACK（payload 为空）
pub fn sendSettingsAck(stream: anytype) !void {
    try writeFrame(stream, .settings, FLAG_ACK, 0, &[_]u8{});
}

/// 对 PING 回 PONG（原样回 payload 前 8 字节）
pub fn sendPingAck(stream: anytype, payload: []const u8) !void {
    const reply = if (payload.len >= 8) payload[0..8] else &[_]u8{0} ** 8;
    try writeFrame(stream, .ping, FLAG_ACK, 0, reply);
}

/// 发送 RST_STREAM 帧（payload 为 4 字节大端 error_code，如 7 REFUSED_STREAM）
pub fn sendRstStream(stream: anytype, stream_id: u31, error_code: u32) !void {
    var payload: [4]u8 = undefined;
    payload[0] = @as(u8, @truncate(error_code >> 24));
    payload[1] = @as(u8, @truncate(error_code >> 16));
    payload[2] = @as(u8, @truncate(error_code >> 8));
    payload[3] = @as(u8, @truncate(error_code));
    try writeFrame(stream, .rst_stream, 0, stream_id, &payload);
}

/// HPACK：最小解码，仅支持静态表 + 字面量（无 Huffman）的头部块，供请求头构建
/// 输出到 allocator 的 ArrayListUnmanaged(HeaderEntry)；块数据为 payload（01 §1.2）
pub fn decodeHpackBlock(allocator: std.mem.Allocator, block: []const u8, out_headers: *std.ArrayListUnmanaged(HeaderEntry)) !void {
    // RFC 7541 Appendix A 静态表完整 61 条：索引 1..61 → (name, value)。规范中 :status 仅 8–14（200/204/206/304/400/404/500），
    // 无 201/302/503 等；这些由客户端以字面量发送，走下方 Literal 分支即可解码。
    const static_entries = [_][]const u8{
        "", // 1 :authority
        "GET", "POST", "/", "/index.html", "http", "https", // 2-7
        "200", "204", "206", "304", "400", "404", "500", // 8-14 :status（RFC 仅此 7 个）
        "", "", "gzip, deflate", "", "", "", "", "", "", "", "", "", "", "", "", // 15-30
        "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", // 31-46
        "", "", "", "", "", "", "", "", "", "", "", "", "", "", "", // 47-61
    };
    const static_names = [_][]const u8{
        ":authority",          ":method",         ":method",         ":path",               ":path",             ":scheme",                     ":scheme",
        ":status",             ":status",         ":status",         ":status",             ":status",           ":status",                     ":status",
        "accept-charset",      "accept-encoding", "accept-language", "accept-ranges",       "accept",            "access-control-allow-origin", "age",
        "allow",               "authorization",   "cache-control",   "content-disposition", "content-encoding",  "content-language",            "content-length",
        "content-location",    "content-range",   "content-type",    "cookie",              "date",              "etag",                        "expect",
        "expires",             "from",            "host",            "if-match",            "if-modified-since", "if-none-match",               "if-range",
        "if-unmodified-since", "last-modified",   "link",            "location",            "max-forwards",      "proxy-authenticate",          "proxy-authorization",
        "range",               "referer",         "refresh",         "retry-after",         "server",            "set-cookie",                  "strict-transport-security",
        "transfer-encoding",   "user-agent",      "vary",            "via",                 "www-authenticate",
    };
    var i: usize = 0;
    while (i < block.len) {
        const first = block[i];
        i += 1;
        if (first & 0x80 != 0) {
            // Indexed: 7-bit 索引（可能多字节）
            var index: u32 = @as(u32, first & 0x7F);
            if (index < 128) {
                if (index == 0) return error.InvalidHpack;
                if (index <= static_names.len and index <= static_entries.len) {
                    const name = static_names[index - 1];
                    const value = if (index - 1 < static_entries.len) static_entries[index - 1] else "";
                    try out_headers.append(allocator, .{ .name = name, .value = value });
                }
                continue;
            }
            var shift: u32 = 7;
            while (i < block.len) {
                const b = block[i];
                i += 1;
                index += @as(u32, b & 0x7F) << @intCast(shift);
                if (b & 0x80 == 0) break;
                shift += 7;
            }
            if (index <= 61) {
                // 仅处理小索引，其余跳过
                if (index <= static_names.len) {
                    try out_headers.append(allocator, .{ .name = static_names[index - 1], .value = if (index - 1 < static_entries.len) static_entries[index - 1] else "" });
                }
            }
            continue;
        }
        if (first & 0x40 != 0) {
            // Literal with indexing: 6-bit name index
            const name_idx: u32 = @as(u32, first & 0x3F);
            if (name_idx == 0) {
                if (i >= block.len) return error.NeedMore;
                const h = block[i];
                i += 1;
                const name_huffman = (h & 0x80) != 0;
                var name_len: u32 = @as(u32, h & 0x7F);
                if (name_len > 127) {
                    var shift: u32 = 7;
                    while (i < block.len) {
                        const b = block[i];
                        i += 1;
                        name_len += @as(u32, b & 0x7F) << @intCast(shift);
                        if (b & 0x80 == 0) break;
                        shift += 7;
                    }
                }
                if (i + name_len > block.len) return error.NeedMore;
                const name = if (name_huffman) try hpack_huffman.decodeHuffman(allocator, block[i..][0..name_len]) else block[i..][0..name_len];
                i += name_len;
                if (i >= block.len) return error.NeedMore;
                const vl = block[i];
                i += 1;
                const value_huffman = (vl & 0x80) != 0;
                var value_len: u32 = @as(u32, vl & 0x7F);
                if (value_len > 127) {
                    var shift: u32 = 7;
                    while (i < block.len) {
                        const b = block[i];
                        i += 1;
                        value_len += @as(u32, b & 0x7F) << @intCast(shift);
                        if (b & 0x80 == 0) break;
                        shift += 7;
                    }
                }
                if (i + value_len > block.len) return error.NeedMore;
                const value = if (value_huffman) try hpack_huffman.decodeHuffman(allocator, block[i..][0..value_len]) else block[i..][0..value_len];
                i += value_len;
                try out_headers.append(allocator, .{ .name = name, .value = value });
                continue;
            }
            if (name_idx <= static_names.len and i < block.len) {
                const name = static_names[name_idx - 1];
                const vl = block[i];
                i += 1;
                const value_huffman = (vl & 0x80) != 0;
                var value_len: u32 = @as(u32, vl & 0x7F);
                if (value_len > 127) {
                    var shift: u32 = 7;
                    while (i < block.len) {
                        const b = block[i];
                        i += 1;
                        value_len += @as(u32, b & 0x7F) << @intCast(shift);
                        if (b & 0x80 == 0) break;
                        shift += 7;
                    }
                }
                if (i + value_len > block.len) return error.NeedMore;
                const value = if (value_huffman) try hpack_huffman.decodeHuffman(allocator, block[i..][0..value_len]) else block[i..][0..value_len];
                i += value_len;
                try out_headers.append(allocator, .{ .name = name, .value = value });
            }
            continue;
        }
        if (first & 0x20 != 0 or first & 0x10 != 0) {
            // Literal without indexing / never indexed：4-bit 名索引，然后值
            const name_idx = first & 0x0F;
            if (name_idx > 0 and name_idx <= static_names.len and i < block.len) {
                const name = static_names[name_idx - 1];
                const vl = block[i];
                i += 1;
                const value_huffman = (vl & 0x80) != 0;
                var value_len: u32 = @as(u32, vl & 0x7F);
                if (value_len > 127) {
                    var shift: u32 = 7;
                    while (i < block.len) {
                        const b = block[i];
                        i += 1;
                        value_len += @as(u32, b & 0x7F) << @intCast(shift);
                        if (b & 0x80 == 0) break;
                        shift += 7;
                    }
                }
                if (i + value_len > block.len) return error.NeedMore;
                const value = if (value_huffman) try hpack_huffman.decodeHuffman(allocator, block[i..][0..value_len]) else block[i..][0..value_len];
                i += value_len;
                try out_headers.append(allocator, .{ .name = name, .value = value });
            }
            continue;
        }
        // 0x00: literal without indexing, 0 name index → 名与值均为字面量，略过
        if (first == 0) {
            if (i >= block.len) break;
            var name_len: u32 = @as(u32, block[i] & 0x7F);
            i += 1;
            if (name_len > 127) {
                var shift: u32 = 7;
                while (i < block.len) {
                    const b = block[i];
                    i += 1;
                    name_len += @as(u32, b & 0x7F) << @intCast(shift);
                    if (b & 0x80 == 0) break;
                    shift += 7;
                }
            }
            if (i + name_len > block.len) return error.NeedMore;
            i += name_len;
            if (i >= block.len) return error.NeedMore;
            var value_len: u32 = @as(u32, block[i] & 0x7F);
            i += 1;
            if (value_len > 127) {
                var shift: u32 = 7;
                while (i < block.len) {
                    const b = block[i];
                    i += 1;
                    value_len += @as(u32, b & 0x7F) << @intCast(shift);
                    if (b & 0x80 == 0) break;
                    shift += 7;
                }
            }
            if (i + value_len > block.len) return error.NeedMore;
            i += value_len;
        }
    }
}

/// HPACK 解码写入 out_headers，且不超过 max_headers 条（超过返回 error.TooManyHeaders）；调用方 initCapacity(allocator, max_headers) 可避免扩容（01 §1.2）
/// 静态表与 decodeHpackBlock 一致（RFC 7541 Appendix A 完整 61 条）
pub fn decodeHpackBlockCapped(allocator: std.mem.Allocator, block: []const u8, out_headers: *std.ArrayListUnmanaged(HeaderEntry), max_headers: usize) !void {
    const static_entries = [_][]const u8{
        "",    "GET", "POST",          "/",   "/index.html", "http", "https",
        "200", "204", "206",           "304", "400",         "404",  "500",
        "",    "",    "gzip, deflate", "",    "",            "",     "",
        "",    "",    "",              "",    "",            "",     "",
        "",    "",    "",              "",    "",            "",     "",
        "",    "",    "",              "",    "",            "",     "",
        "",    "",    "",              "",    "",            "",     "",
        "",    "",    "",              "",    "",            "",     "",
        "",    "",    "",              "",
    };
    const static_names = [_][]const u8{
        ":authority",          ":method",         ":method",         ":path",               ":path",             ":scheme",                     ":scheme",
        ":status",             ":status",         ":status",         ":status",             ":status",           ":status",                     ":status",
        "accept-charset",      "accept-encoding", "accept-language", "accept-ranges",       "accept",            "access-control-allow-origin", "age",
        "allow",               "authorization",   "cache-control",   "content-disposition", "content-encoding",  "content-language",            "content-length",
        "content-location",    "content-range",   "content-type",    "cookie",              "date",              "etag",                        "expect",
        "expires",             "from",            "host",            "if-match",            "if-modified-since", "if-none-match",               "if-range",
        "if-unmodified-since", "last-modified",   "link",            "location",            "max-forwards",      "proxy-authenticate",          "proxy-authorization",
        "range",               "referer",         "refresh",         "retry-after",         "server",            "set-cookie",                  "strict-transport-security",
        "transfer-encoding",   "user-agent",      "vary",            "via",                 "www-authenticate",
    };
    var i: usize = 0;
    while (i < block.len) {
        const first = block[i];
        i += 1;
        if (first & 0x80 != 0) {
            var index: u32 = @as(u32, first & 0x7F);
            if (index < 128) {
                if (index == 0) return error.InvalidHpack;
                if (index <= static_names.len and index <= static_entries.len) {
                    if (out_headers.items.len >= max_headers) return error.TooManyHeaders;
                    try out_headers.append(allocator, .{ .name = static_names[index - 1], .value = if (index - 1 < static_entries.len) static_entries[index - 1] else "" });
                }
                continue;
            }
            var shift: u32 = 7;
            while (i < block.len) {
                const b = block[i];
                i += 1;
                index += @as(u32, b & 0x7F) << @intCast(shift);
                if (b & 0x80 == 0) break;
                shift += 7;
            }
            if (index <= 61 and index <= static_names.len) {
                if (out_headers.items.len >= max_headers) return error.TooManyHeaders;
                try out_headers.append(allocator, .{ .name = static_names[index - 1], .value = if (index - 1 < static_entries.len) static_entries[index - 1] else "" });
            }
            continue;
        }
        if (first & 0x40 != 0) {
            const name_idx: u32 = @as(u32, first & 0x3F);
            if (name_idx == 0) {
                if (i >= block.len) return error.NeedMore;
                const h = block[i];
                i += 1;
                const name_huffman = (h & 0x80) != 0;
                var name_len: u32 = @as(u32, h & 0x7F);
                if (name_len > 127) {
                    var shift: u32 = 7;
                    while (i < block.len) {
                        const b = block[i];
                        i += 1;
                        name_len += @as(u32, b & 0x7F) << @intCast(shift);
                        if (b & 0x80 == 0) break;
                        shift += 7;
                    }
                }
                if (i + name_len > block.len) return error.NeedMore;
                const name = if (name_huffman) try hpack_huffman.decodeHuffman(allocator, block[i..][0..name_len]) else block[i..][0..name_len];
                i += name_len;
                if (i >= block.len) return error.NeedMore;
                const vl = block[i];
                i += 1;
                const value_huffman = (vl & 0x80) != 0;
                var value_len: u32 = @as(u32, vl & 0x7F);
                if (value_len > 127) {
                    var shift: u32 = 7;
                    while (i < block.len) {
                        const b = block[i];
                        i += 1;
                        value_len += @as(u32, b & 0x7F) << @intCast(shift);
                        if (b & 0x80 == 0) break;
                        shift += 7;
                    }
                }
                if (i + value_len > block.len) return error.NeedMore;
                const value = if (value_huffman) try hpack_huffman.decodeHuffman(allocator, block[i..][0..value_len]) else block[i..][0..value_len];
                i += value_len;
                if (out_headers.items.len >= max_headers) return error.TooManyHeaders;
                try out_headers.append(allocator, .{ .name = name, .value = value });
                continue;
            }
            if (name_idx <= static_names.len and i < block.len) {
                const name = static_names[name_idx - 1];
                const vl = block[i];
                i += 1;
                const value_huffman = (vl & 0x80) != 0;
                var value_len: u32 = @as(u32, vl & 0x7F);
                if (value_len > 127) {
                    var shift: u32 = 7;
                    while (i < block.len) {
                        const b = block[i];
                        i += 1;
                        value_len += @as(u32, b & 0x7F) << @intCast(shift);
                        if (b & 0x80 == 0) break;
                        shift += 7;
                    }
                }
                if (i + value_len > block.len) return error.NeedMore;
                const value = if (value_huffman) try hpack_huffman.decodeHuffman(allocator, block[i..][0..value_len]) else block[i..][0..value_len];
                i += value_len;
                if (out_headers.items.len >= max_headers) return error.TooManyHeaders;
                try out_headers.append(allocator, .{ .name = name, .value = value });
            }
            continue;
        }
        if (first & 0x20 != 0 or first & 0x10 != 0) {
            const name_idx = first & 0x0F;
            if (name_idx > 0 and name_idx <= static_names.len and i < block.len) {
                const name = static_names[name_idx - 1];
                const vl = block[i];
                i += 1;
                var value_len: u32 = @as(u32, vl & 0x7F);
                if (value_len > 127) {
                    var shift: u32 = 7;
                    while (i < block.len) {
                        const b = block[i];
                        i += 1;
                        value_len += @as(u32, b & 0x7F) << @intCast(shift);
                        if (b & 0x80 == 0) break;
                        shift += 7;
                    }
                }
                if (i + value_len > block.len) return error.NeedMore;
                const value = if (vl & 0x80 != 0) try hpack_huffman.decodeHuffman(allocator, block[i..][0..value_len]) else block[i..][0..value_len];
                i += value_len;
                if (out_headers.items.len >= max_headers) return error.TooManyHeaders;
                try out_headers.append(allocator, .{ .name = name, .value = value });
            }
            continue;
        }
        if (first == 0) {
            if (i >= block.len) break;
            var name_len: u32 = @as(u32, block[i] & 0x7F);
            i += 1;
            if (name_len > 127) {
                var shift: u32 = 7;
                while (i < block.len) {
                    const b = block[i];
                    i += 1;
                    name_len += @as(u32, b & 0x7F) << @intCast(shift);
                    if (b & 0x80 == 0) break;
                    shift += 7;
                }
            }
            if (i + name_len > block.len) return error.NeedMore;
            i += name_len;
            if (i >= block.len) return error.NeedMore;
            var value_len: u32 = @as(u32, block[i] & 0x7F);
            i += 1;
            if (value_len > 127) {
                var shift: u32 = 7;
                while (i < block.len) {
                    const b = block[i];
                    i += 1;
                    value_len += @as(u32, b & 0x7F) << @intCast(shift);
                    if (b & 0x80 == 0) break;
                    shift += 7;
                }
            }
            if (i + value_len > block.len) return error.NeedMore;
            i += value_len;
        }
    }
}

/// HEADERS 帧 payload 中跳过 padding/priority 后返回 HPACK 块切片（RFC 7540 6.2）
pub fn headersFramePayloadToBlock(payload: []const u8, flags: u8) []const u8 {
    var off: usize = 0;
    if (flags & 0x08 != 0) { // PADDED
        if (payload.len > 0) off += 1;
    }
    if (off + 5 <= payload.len) {
        off += 5; // E stream dependency (4) + weight (1)，请求方向通常存在
    }
    return payload[off..];
}

/// 写一字面量值到 out[pos..]，可选 Huffman 编码（编码后更短且长度≤127 时使用）；返回写入长度
fn writeLiteralValue(out: []u8, pos: *usize, value: []const u8) !void {
    var enc_buf: [256]u8 = undefined;
    const enc_len = hpack_huffman.encodeHuffmanToBuffer(&enc_buf, value) catch 0;
    const use_huffman = (enc_len > 0 and enc_len < value.len and enc_len <= 127);
    const len_byte: u8 = if (use_huffman) @as(u8, 0x80) | @as(u8, @intCast(enc_len)) else @as(u8, @intCast(value.len));
    if (pos.* + 1 + (if (use_huffman) enc_len else value.len) > out.len) return error.BufferTooSmall;
    out[pos.*] = len_byte;
    pos.* += 1;
    if (use_huffman) {
        @memcpy(out[pos.*..][0..enc_len], enc_buf[0..enc_len]);
        pos.* += enc_len;
    } else {
        @memcpy(out[pos.*..][0..value.len], value);
        pos.* += value.len;
    }
}

/// 编码响应头为 HPACK 块（字面量；值用 Huffman 编码以减带宽）：:status + content-type + content-length + 可选 content-encoding
pub fn encodeResponseHeaders(out: []u8, status: u16, content_type: ?[]const u8, content_length: ?usize, content_encoding: ?[]const u8) !usize {
    var pos: usize = 0;
    const status_str = switch (status) {
        200 => "200",
        201 => "201",
        204 => "204",
        400 => "400",
        404 => "404",
        500 => "500",
        else => "200",
    };
    if (pos + 2 > out.len) return error.BufferTooSmall;
    out[pos] = 0x08;
    pos += 1;
    try writeLiteralValue(out, &pos, status_str);
    if (content_type) |ct| {
        if (pos + 1 + "content-type".len + 1 > out.len) return error.BufferTooSmall;
        out[pos] = 0x00;
        pos += 1;
        out[pos] = @intCast("content-type".len);
        pos += 1;
        @memcpy(out[pos..][0.."content-type".len], "content-type");
        pos += "content-type".len;
        try writeLiteralValue(out, &pos, ct);
    }
    if (content_encoding) |ce| {
        if (pos + 1 + "content-encoding".len + 1 > out.len) return error.BufferTooSmall;
        out[pos] = 0x00;
        pos += 1;
        out[pos] = @intCast("content-encoding".len);
        pos += 1;
        @memcpy(out[pos..][0.."content-encoding".len], "content-encoding");
        pos += "content-encoding".len;
        try writeLiteralValue(out, &pos, ce);
    }
    if (content_length) |cl| {
        var cl_buf: [16]u8 = undefined;
        const cl_str = std.fmt.bufPrint(&cl_buf, "{d}", .{cl}) catch return error.BufferTooSmall;
        if (pos + 1 + "content-length".len + 1 > out.len) return error.BufferTooSmall;
        out[pos] = 0x00;
        pos += 1;
        out[pos] = @intCast("content-length".len);
        pos += 1;
        @memcpy(out[pos..][0.."content-length".len], "content-length");
        pos += "content-length".len;
        try writeLiteralValue(out, &pos, cl_str);
    }
    return pos;
}

/// 取 name 前 8 字节转 u64（不足零填充），用于与 comptime 常量一次整型比较（00 §2.1）
inline fn h2NamePrefix(name: []const u8) u64 {
    var buf: [8]u8 = [_]u8{0} ** 8;
    const n = @min(8, name.len);
    @memcpy(buf[0..n], name[0..n]);
    return @as(u64, @bitCast(buf));
}
/// comptime 字符串前 8 字节转 u64
inline fn h2Prefix8(comptime s: []const u8) u64 {
    var buf: [8]u8 = [_]u8{0} ** 8;
    const n = @min(8, s.len);
    for (s[0..n], buf[0..n]) |a, *b| b.* = a;
    return @as(u64, @bitCast(buf));
}

/// 从 HPACK 解码得到的头部列表中取 :method、:path、:scheme、:authority 及普通头，填到 ParsedRequest 兼容的 headers 表（小写 key）；接受 slice 以兼容 ArrayList 与 BoundedArray（§1.3）。伪头名用 u64 前缀比较（00 §2.1）。
pub fn h2HeadersToParsed(
    allocator: std.mem.Allocator,
    headers_slice: []const HeaderEntry,
    method: *[]const u8,
    path: *[]const u8,
    out_headers: *std.StringHashMap([]const u8),
) !void {
    for (headers_slice) |h| {
        if (h2PseudoMethod(h.name)) {
            method.* = try allocator.dupe(u8, h.value);
        } else if (h2PseudoPath(h.name)) {
            path.* = try allocator.dupe(u8, h.value);
        } else if ((h.name.len == 7 and h2NamePrefix(h.name) == h2Prefix8(":scheme")) or
            (h.name.len == 9 and h2NamePrefix(h.name) == h2Prefix8(":authori") and h.name[8] == 't'))
        {
            const k = try allocator.dupe(u8, h.name);
            const v = try allocator.dupe(u8, h.value);
            try out_headers.put(k, v);
        } else if (h.name.len > 0 and h.name[0] != ':') {
            const k = try allocator.dupe(u8, h.name);
            for (k) |*c| {
                if (c.* >= 'A' and c.* <= 'Z') c.* += 32;
            }
            const v = try allocator.dupe(u8, h.value);
            try out_headers.put(k, v);
        }
    }
    if (method.*.len == 0) method.* = "GET";
    if (path.*.len == 0) path.* = "/";
}

// 单元测试已迁至 src/tests/runtime/modules/shu/server/http2.zig
