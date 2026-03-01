//! HPACK Huffman 单元测试：encodeHuffmanToBuffer、decodeHuffman 及往返
//! 被测模块：通过 build 提供的 hpack_huffman 模块（src/runtime/modules/shu/server/hpack_huffman.zig）

const std = @import("std");
const hpack_huffman = @import("hpack_huffman");

test "encodeHuffmanToBuffer: 空输入" {
    var buf: [32]u8 = undefined;
    const n = try hpack_huffman.encodeHuffmanToBuffer(&buf, "");
    try std.testing.expect(n > 0);
}

test "encodeHuffmanToBuffer: 短字符串" {
    var buf: [64]u8 = undefined;
    const n = try hpack_huffman.encodeHuffmanToBuffer(&buf, "hello");
    try std.testing.expect(n > 0);
    try std.testing.expect(n <= buf.len);
}

test "encodeHuffmanToBuffer: BufferTooSmall" {
    var buf: [1]u8 = undefined;
    const r = hpack_huffman.encodeHuffmanToBuffer(&buf, "hello world");
    try std.testing.expectError(error.BufferTooSmall, r);
}

test "decodeHuffman: 空编码" {
    const allocator = std.testing.allocator;
    var enc_buf: [32]u8 = undefined;
    const n = try hpack_huffman.encodeHuffmanToBuffer(&enc_buf, "");
    const dec = try hpack_huffman.decodeHuffman(allocator, enc_buf[0..n]);
    defer allocator.free(dec);
    try std.testing.expectEqualStrings("", dec);
}

test "decodeHuffman: 往返" {
    const allocator = std.testing.allocator;
    const input = "Accept-Encoding: gzip, deflate, br";
    var enc_buf: [128]u8 = undefined;
    const n = try hpack_huffman.encodeHuffmanToBuffer(&enc_buf, input);
    const dec = try hpack_huffman.decodeHuffman(allocator, enc_buf[0..n]);
    defer allocator.free(dec);
    try std.testing.expectEqualStrings(input, dec);
}

test "decodeHuffman: 长串往返" {
    const allocator = std.testing.allocator;
    var long: [256]u8 = undefined;
    for (0..256) |i| long[i] = @intCast(@min(i, 255));
    const input = long[0..];
    var enc_buf: [1024]u8 = undefined;
    const n = try hpack_huffman.encodeHuffmanToBuffer(&enc_buf, input);
    const dec = try hpack_huffman.decodeHuffman(allocator, enc_buf[0..n]);
    defer allocator.free(dec);
    try std.testing.expectEqualStrings(input, dec);
}

test "decodeHuffman: InvalidHuffman 非法字节" {
    const allocator = std.testing.allocator;
    const bad: [4]u8 = .{ 0xff, 0xff, 0xff, 0xff };
    const r = hpack_huffman.decodeHuffman(allocator, &bad);
    try std.testing.expectError(error.InvalidHuffman, r);
}
