// websocket 单元测试：Upgrade 判断、Accept 计算、帧解析/组帧（从 server/websocket.zig 迁入）
// 被测模块：src/runtime/modules/shu/server/websocket.zig
const std = @import("std");
const websocket = @import("../../../../../runtime/modules/shu/server/websocket.zig");

test "isWebSocketUpgrade: 需要 connection 与 upgrade 头" {
    try std.testing.expect(!websocket.isWebSocketUpgrade(null, "websocket"));
    try std.testing.expect(!websocket.isWebSocketUpgrade("upgrade", null));
    try std.testing.expect(!websocket.isWebSocketUpgrade("keep-alive", "websocket"));
    try std.testing.expect(websocket.isWebSocketUpgrade("Upgrade", "websocket"));
    try std.testing.expect(websocket.isWebSocketUpgrade("Connection: Upgrade", "Upgrade: websocket"));
    try std.testing.expect(websocket.isWebSocketUpgrade("keep-alive, Upgrade", "WebSocket"));
}

test "headerValueContains: 不区分大小写" {
    try std.testing.expect(websocket.headerValueContains("upgrade", "upgrade"));
    try std.testing.expect(websocket.headerValueContains("Upgrade", "upgrade"));
    try std.testing.expect(websocket.headerValueContains("Upgrade", "Upgrade"));
    try std.testing.expect(!websocket.headerValueContains("keep-alive", "upgrade"));
    try std.testing.expect(websocket.headerValueContains("keep-alive, Upgrade", "upgrade"));
}

test "computeAcceptKey: RFC 6455 示例" {
    const key = "dGhlIHNhbXBsZSBub25jZQ==";
    const accept = try websocket.computeAcceptKey(key);
    const expected = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=";
    try std.testing.expectEqualStrings(expected, &accept);
}

test "parseFrame: 无 mask 短 payload" {
    var buf: [128]u8 = undefined;
    const payload: []const u8 = "hello";
    const n = try websocket.buildFrame(&buf, .text, payload);
    try std.testing.expect(n >= 2 + payload.len);
    const parsed = try websocket.parseFrame(buf[0..n]);
    try std.testing.expect(parsed.opcode == .text);
    try std.testing.expectEqualStrings(payload, parsed.payload);
    try std.testing.expect(parsed.consumed == n);
}

test "parseFrame: 带 mask 的客户端帧" {
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
    const parsed = try websocket.parseFrame(buf[0..11]);
    try std.testing.expect(parsed.opcode == .text);
    try std.testing.expect(parsed.payload.len == 5);
    try std.testing.expect(parsed.consumed == 11);
}

test "parseFrame: NeedMore 不足 2 字节" {
    var buf: [1]u8 = .{0x81};
    const r = websocket.parseFrame(&buf);
    try std.testing.expectError(error.NeedMore, r);
}

test "parseFrame: payload 126 扩展长度" {
    var buf: [256]u8 = undefined;
    var payload_buf: [200]u8 = undefined;
    @memset(&payload_buf, 0x41);
    const payload = payload_buf[0..130];
    const n = try websocket.buildFrame(&buf, .binary, payload);
    try std.testing.expect(n == 4 + 130);
    const parsed = try websocket.parseFrame(buf[0..n]);
    try std.testing.expect(parsed.opcode == .binary);
    try std.testing.expect(parsed.payload.len == 130);
    try std.testing.expect(parsed.consumed == n);
}

test "buildFrame: 空 payload" {
    var buf: [16]u8 = undefined;
    const n = try websocket.buildFrame(&buf, .close, &[_]u8{});
    try std.testing.expect(n == 2);
    try std.testing.expect(buf[0] == 0x80 | 8);
    try std.testing.expect(buf[1] == 0);
}

test "buildFrame: BufferTooSmall" {
    var buf: [1]u8 = undefined;
    const r = websocket.buildFrame(&buf, .text, "x");
    try std.testing.expectError(error.BufferTooSmall, r);
}

// ---------- 边界：isWebSocketUpgrade / headerValueContains ----------
test "isWebSocketUpgrade: 空字符串不匹配" {
    try std.testing.expect(!websocket.isWebSocketUpgrade("", ""));
    try std.testing.expect(!websocket.isWebSocketUpgrade("Upgrade", ""));
}

test "headerValueContains: 空 value 或空 token" {
    try std.testing.expect(!websocket.headerValueContains("", "upgrade"));
    try std.testing.expect(websocket.headerValueContains("upgrade", ""));
}

// ---------- computeAcceptKey 边界 ----------
test "computeAcceptKey: 空 key 仍可计算" {
    const accept = try websocket.computeAcceptKey("");
    try std.testing.expect(accept.len == 28);
}

// ---------- buildFrameMasked 与往返 ----------
test "buildFrameMasked: 短 payload 往返" {
    var buf: [64]u8 = undefined;
    const payload = "masked";
    const mask: [4]u8 = .{ 0x12, 0x34, 0x56, 0x78 };
    const n = try websocket.buildFrameMasked(&buf, .text, payload, mask);
    try std.testing.expect(n >= 2 + 4 + payload.len);
    const parsed = try websocket.parseFrame(&buf);
    try std.testing.expect(parsed.opcode == .text);
    try std.testing.expect(parsed.payload.len == payload.len);
    try std.testing.expect(parsed.consumed == n);
}

test "buildFrameMasked: BufferTooSmall" {
    var buf: [1]u8 = undefined;
    const mask: [4]u8 = .{ 0, 0, 0, 0 };
    const r = websocket.buildFrameMasked(&buf, .text, "x", mask);
    try std.testing.expectError(error.BufferTooSmall, r);
}

// ---------- parseFrame 边界：126 需 4 字节、127 需 10 字节 ----------
test "parseFrame: 126 长度但不足 4 字节返回 NeedMore" {
    var buf: [3]u8 = .{ 0x82, 126, 0 };
    const r = websocket.parseFrame(&buf);
    try std.testing.expectError(error.NeedMore, r);
}

test "parseFrame: 127 扩展长度需 10 字节" {
    var buf: [20]u8 = undefined;
    buf[0] = 0x82;
    buf[1] = 127;
    std.mem.writeInt(u64, buf[2..10], 5, .big);
    buf[10] = 'h';
    buf[11] = 'i';
    buf[12] = '!';
    buf[13] = '!';
    buf[14] = '!';
    const r = websocket.parseFrame(buf[0..11]);
    try std.testing.expectError(error.NeedMore, r);
    const parsed = try websocket.parseFrame(buf[0..15]);
    try std.testing.expect(parsed.payload.len == 5);
    try std.testing.expect(parsed.consumed == 15);
}

// ---------- buildFrame 边界：125 vs 126 vs 127 ----------
test "buildFrame: payload 长度 125 用 1 字节长度" {
    var payload_buf: [125]u8 = undefined;
    @memset(&payload_buf, 0x61);
    var buf: [128]u8 = undefined;
    const n = try websocket.buildFrame(&buf, .binary, &payload_buf);
    try std.testing.expect(buf[1] == 125);
    try std.testing.expect(n == 2 + 125);
}

test "buildFrame: payload 长度 126 用扩展 2 字节" {
    var payload_buf: [126]u8 = undefined;
    @memset(&payload_buf, 0x61);
    var buf: [132]u8 = undefined;
    const n = try websocket.buildFrame(&buf, .binary, &payload_buf);
    try std.testing.expect(buf[1] == 126);
    try std.testing.expect(n == 4 + 126);
}
