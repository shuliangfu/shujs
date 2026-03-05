//! libs_io.simd_scan 单元测试：findCrLfInBlock、indexOfCrLfCrLf（与 src/libs/simd_scan.zig 行为一致）
//! 通过 libs_io 引用，避免同一文件归属 root 与 libs_io 冲突。

const std = @import("std");
const libs_io = @import("libs_io");
const simd_scan = libs_io.simd_scan;

test "simd_scan.findCrLfInBlock: empty" {
    try std.testing.expect(simd_scan.findCrLfInBlock("") == 0);
}

test "simd_scan.findCrLfInBlock: no crlf" {
    try std.testing.expect(simd_scan.findCrLfInBlock("abc") == 3);
}

test "simd_scan.findCrLfInBlock: first char cr" {
    try std.testing.expect(simd_scan.findCrLfInBlock("a\r\n") == 1);
}

test "simd_scan.findCrLfInBlock: request line" {
    try std.testing.expect(simd_scan.findCrLfInBlock("GET / HTTP/1.1\r\n") == 14);
}

test "simd_scan.indexOfCrLfCrLf: empty" {
    try std.testing.expect(simd_scan.indexOfCrLfCrLf("") == null);
}

test "simd_scan.indexOfCrLfCrLf: double crlf" {
    try std.testing.expect(simd_scan.indexOfCrLfCrLf("a\r\n\r\n") == 1);
}

test "simd_scan.indexOfCrLfCrLf: headers end" {
    try std.testing.expect(simd_scan.indexOfCrLfCrLf("GET / HTTP/1.1\r\nHost: x\r\n\r\n") == 25);
}
