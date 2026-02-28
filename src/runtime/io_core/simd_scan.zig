// SIMD 向量化扫描：供 HTTP 等协议解析器参考，一次处理 16/32 字节定位 \r / \n，避免逐字节状态机成为瓶颈。
//
// 用法：在拿到 Completion.buffer_ptr[0..len] 后，可先调用 findCrLfInBlock 或 scanCrLfMask 快速定位行边界，
// 再只做零拷贝 slice 引用，不 memcpy。详见 docs/IO_CORE_ROADMAP.md。

const std = @import("std");

/// 向量宽度（字节）；可按目标 CPU 改为 32（AVX2）
const VECTOR_LANES = 16;

/// 在块内查找第一个 \r (0x0D) 或 \n (0x0A) 的位置；块长度可小于 VECTOR_LANES，未读部分不访问
/// 返回：相对 block 的偏移（0..block.len），若未找到则返回 block.len
pub fn findCrLfInBlock(block: []const u8) usize {
    if (block.len == 0) return 0;
    const n = block.len;
    var i: usize = 0;
    while (i + VECTOR_LANES <= n) {
        const chunk = block[i..][0..VECTOR_LANES];
        const pos = scanCrLfMask(chunk);
        if (pos < VECTOR_LANES) return i + pos;
        i += VECTOR_LANES;
    }
    while (i < n) {
        const c = block[i];
        if (c == '\r' or c == '\n') return i;
        i += 1;
    }
    return n;
}

/// 在恰好 VECTOR_LANES 字节的块内，用 @Vector 比较得到 \r 或 \n 的掩码，返回第一个匹配位置（未找到返回 VECTOR_LANES）
fn scanCrLfMask(block: *const [VECTOR_LANES]u8) usize {
    const vec = block.*;
    const v: @Vector(VECTOR_LANES, u8) = vec;
    const cr: @Vector(VECTOR_LANES, u8) = @splat(0x0D);
    const lf: @Vector(VECTOR_LANES, u8) = @splat(0x0A);
    const eq_cr = v == cr;
    const eq_lf = v == lf;
    const mask = eq_cr or eq_lf;
    var j: usize = 0;
    while (j < VECTOR_LANES) : (j += 1) {
        if (mask[j]) return j;
    }
    return VECTOR_LANES;
}

/// 在 buf 中查找 "\r\n\r\n" 的偏移；用 16 字节向量批量比较，供 HTTP 头部边界定位（零拷贝解析用）
pub fn indexOfCrLfCrLf(buf: []const u8) ?usize {
    const pattern: @Vector(4, u8) = .{ '\r', '\n', '\r', '\n' };
    var i: usize = 0;
    while (i + 4 <= buf.len) {
        if (i + VECTOR_LANES <= buf.len) {
            var j = i;
            const end = i + 13;
            while (j < end) : (j += 1) {
                const window: @Vector(4, u8) = buf[j..][0..4].*;
                if (@reduce(.And, window == pattern)) return j;
            }
            i += 13;
            continue;
        }
        const window: @Vector(4, u8) = buf[i..][0..4].*;
        if (@reduce(.And, window == pattern)) return i;
        i += 1;
    }
    return null;
}

test "findCrLfInBlock" {
    try std.testing.expect(findCrLfInBlock("") == 0);
    try std.testing.expect(findCrLfInBlock("abc") == 3);
    try std.testing.expect(findCrLfInBlock("a\r\n") == 1);
    try std.testing.expect(findCrLfInBlock("GET / HTTP/1.1\r\n") == 14);
}

test "indexOfCrLfCrLf" {
    try std.testing.expect(indexOfCrLfCrLf("") == null);
    try std.testing.expect(indexOfCrLfCrLf("a\r\n\r\n") == 1);
    try std.testing.expect(indexOfCrLfCrLf("GET / HTTP/1.1\r\nHost: x\r\n\r\n") == 25);
}
