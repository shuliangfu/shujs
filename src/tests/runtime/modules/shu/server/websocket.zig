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
