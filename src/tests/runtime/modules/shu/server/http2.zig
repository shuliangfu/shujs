// http2 单元测试：帧头解析、帧缓冲解析、帧组装（从 server/http2.zig 迁入）
// 被测模块：src/runtime/modules/shu/server/http2.zig（入口在 src/ 故可直接路径导入）
const std = @import("std");
const http2 = @import("../../../../../runtime/modules/shu/server/http2.zig");

test "parseFrameHeader: 9 字节帧头" {
    var buf: [9]u8 = undefined;
    buf[0] = 0;
    buf[1] = 0;
    buf[2] = 5;
    buf[3] = @intFromEnum(http2.FrameType.data);
    buf[4] = http2.FLAG_END_STREAM;
    buf[5] = 0;
    buf[6] = 0;
    buf[7] = 0;
    buf[8] = 1;
    const h = try http2.parseFrameHeader(&buf);
    try std.testing.expect(h.length == 5);
    try std.testing.expect(h.type == .data);
    try std.testing.expect(h.flags == http2.FLAG_END_STREAM);
    try std.testing.expect(h.stream_id == 1);
}

test "parseFrameHeader: NeedMore 不足 9 字节" {
    const buf: [4]u8 = .{ 0, 0, 0, 0 };
    const r = http2.parseFrameHeader(&buf);
    try std.testing.expectError(error.NeedMore, r);
}

test "parseOneFrameFromBuffer: 完整一帧" {
    var buf: [32]u8 = undefined;
    buf[0] = 0;
    buf[1] = 0;
    buf[2] = 3;
    buf[3] = @intFromEnum(http2.FrameType.ping);
    buf[4] = 0;
    buf[5] = 0;
    buf[6] = 0;
    buf[7] = 0;
    buf[8] = 0;
    buf[9] = 0x01;
    buf[10] = 0x02;
    buf[11] = 0x03;
    const result = try http2.parseOneFrameFromBuffer(&buf, 16384);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.header.type == .ping);
    try std.testing.expect(result.?.header.length == 3);
    try std.testing.expect(result.?.payload.len == 3);
    try std.testing.expect(result.?.consumed == 12);
}

test "parseOneFrameFromBuffer: 不足一帧返回 null" {
    const buf: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
    const result = try http2.parseOneFrameFromBuffer(&buf, 16384);
    try std.testing.expect(result == null);
}

test "parseOneFrameFromBuffer: FrameTooLarge" {
    var buf: [20]u8 = undefined;
    buf[0] = 0;
    buf[1] = 0xFF;
    buf[2] = 0xFF;
    buf[3] = @intFromEnum(http2.FrameType.data);
    buf[4] = 0;
    buf[5] = 0;
    buf[6] = 0;
    buf[7] = 0;
    buf[8] = 1;
    @memset(buf[9..], 0);
    const result = http2.parseOneFrameFromBuffer(&buf, 100);
    try std.testing.expectError(error.FrameTooLarge, result);
}

test "appendFrameTo / parseFrameHeader: 往返" {
    var list = try std.ArrayList(u8).initCapacity(std.testing.allocator, 32);
    defer list.deinit(std.testing.allocator);
    try http2.appendFrameTo(&list, std.testing.allocator, .settings, http2.FLAG_ACK, 0, &[_]u8{});
    try std.testing.expect(list.items.len >= 9);
    const h = try http2.parseFrameHeader(list.items[0..9]);
    try std.testing.expect(h.type == .settings);
    try std.testing.expect(h.flags == http2.FLAG_ACK);
    try std.testing.expect(h.stream_id == 0);
    try std.testing.expect(h.length == 0);
}

test "CLIENT_PREFACE 长度 24" {
    try std.testing.expect(http2.CLIENT_PREFACE.len == 24);
}

test "appendServerPrefaceTo: 生成 SETTINGS 帧" {
    var list = try std.ArrayList(u8).initCapacity(std.testing.allocator, 32);
    defer list.deinit(std.testing.allocator);
    try http2.appendServerPrefaceTo(&list, std.testing.allocator);
    try std.testing.expect(list.items.len >= 9);
    const h = try http2.parseFrameHeader(list.items[0..9]);
    try std.testing.expect(h.type == .settings);
    try std.testing.expect(h.length == 0);
}

test "appendSettingsAckTo: 生成 SETTINGS ACK" {
    var list = try std.ArrayList(u8).initCapacity(std.testing.allocator, 32);
    defer list.deinit(std.testing.allocator);
    try http2.appendSettingsAckTo(&list, std.testing.allocator);
    try std.testing.expect(list.items.len >= 9);
    const h = try http2.parseFrameHeader(list.items[0..9]);
    try std.testing.expect(h.type == .settings);
    try std.testing.expect(h.flags == http2.FLAG_ACK);
}

test "encodeResponseHeaders: 200 无 content-type" {
    var buf: [128]u8 = undefined;
    const n = try http2.encodeResponseHeaders(&buf, 200, null, null, null);
    try std.testing.expect(n > 0);
    try std.testing.expect(n <= buf.len);
}

test "encodeResponseHeaders: 404 带 content-type" {
    var buf: [256]u8 = undefined;
    const n = try http2.encodeResponseHeaders(&buf, 404, "text/plain", 0, null);
    try std.testing.expect(n > 0);
}

test "encodeResponseHeaders: 200 带 content-length 与 content-encoding" {
    var buf: [256]u8 = undefined;
    const n = try http2.encodeResponseHeaders(&buf, 200, "application/json", 42, "br");
    try std.testing.expect(n > 0);
}
