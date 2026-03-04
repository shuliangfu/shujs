// SIMD 向量化扫描：供 HTTP 等协议解析器参考，一次处理 16/32 字节定位 \r / \n，避免逐字节状态机成为瓶颈。
//
// 用法：在拿到 Completion.buffer_ptr[0..len] 后，可先调用 findCrLfInBlock 或 scanCrLfMask 快速定位行边界，
// 再只做零拷贝 slice 引用，不 memcpy。详见 docs/IO_CORE_ROADMAP.md。
//
// 性能（00 §1.6）：为最佳性能，建议传入来自 BufferPool、64 字节对齐且长度≥VECTOR_LANES 的块；
// 若调用方保证块末尾有 64 字节 padding，解析器可盲读、无标量 tail，分支预测错误率为 0。

const std = @import("std");
const builtin = @import("builtin");

/// 向量宽度（字节）；按目标架构在编译期选择，x86 用 32（AVX2 友好），ARM 等用 16（00 §1.6）
const VECTOR_LANES = switch (builtin.cpu.arch) {
    .x86_64, .x86 => 32,
    .aarch64, .arm => 16,
    else => 16,
};

// Hot-path
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

// Hot-path
/// 在恰好 VECTOR_LANES 字节的块内，用 @Vector 比较得到 \r 或 \n 的掩码，返回第一个匹配位置（未找到返回 VECTOR_LANES）
/// 用位图 + @ctz 替代逐 lane 循环，减少分支（00 §2.4、审计 §5）
fn scanCrLfMask(block: *const [VECTOR_LANES]u8) usize {
    const vec = block.*;
    const v: @Vector(VECTOR_LANES, u8) = vec;
    const cr: @Vector(VECTOR_LANES, u8) = @splat(0x0D);
    const lf: @Vector(VECTOR_LANES, u8) = @splat(0x0A);
    const eq_cr = v == cr;
    const eq_lf = v == lf;
    const mask = eq_cr or eq_lf;
    const one_v: @Vector(VECTOR_LANES, u8) = @as(@Vector(VECTOR_LANES, u8), @splat(@as(u8, 1)));
    const zero_v: @Vector(VECTOR_LANES, u8) = @as(@Vector(VECTOR_LANES, u8), @splat(@as(u8, 0)));
    const bits: @Vector(VECTOR_LANES, u8) = @select(u8, mask, one_v, zero_v);
    const bits_u32: @Vector(VECTOR_LANES, u32) = @as(@Vector(VECTOR_LANES, u32), bits);
    const powers = comptime blk: {
        var p: [VECTOR_LANES]u32 = undefined;
        for (0..VECTOR_LANES) |i| {
            p[i] = @as(u32, 1) << @intCast(i);
        }
        break :blk p;
    };
    const powers_v: @Vector(VECTOR_LANES, u32) = powers[0..].*;
    const bitmap = @reduce(.Add, bits_u32 * powers_v);
    if (bitmap == 0) return VECTOR_LANES;
    return @ctz(bitmap);
}

// Hot-path
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
