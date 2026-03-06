//! SIMD 向量化字节流扫描与协议解析（simd_scan.zig）
//!
//! 职责：
//!   - 提供基于 Zig 0.16 `@Vector` 的高性能字节查找与模式匹配。
//!   - 为 HTTP、WebSocket 等协议解析提供极致性能的底层扫描器。
//!
//! 极致压榨亮点：
//!   1. **零成本位图生成**：利用 `std.meta.Int` 与 `@bitCast` 直接将向量比较结果转为整数掩码，生成 `PMOVMSKB` 等原生 SIMD 指令。
//!   2. **车道填充（Lane Padding）**：通过在缓冲区末尾预留 64 字节零填充，实现「盲读」扫描，消除处理尾部零碎字节的分支预测失败（00 §1.6）。
//!   3. **指令级并行查找**：内置 `indexOfCrLfCrLf` 等组合扫描器，通过一次内存加载并发检测多个字节模式。
//!   4. **对齐内存优化**：所有扫描操作均假设或要求 SIMD 宽度对齐，显著提升内存带宽利用率。
//!   5. **无分支边界检查**：在热路径中强制使用 `@setRuntimeSafety(false)` 并通过填充层确保指针访问安全。
//!
//! 适用规范：
//!   - 遵循 00 §2.4（SIMD 向量化）、§7.1（Lane 填充）。
//!
//! [Borrows] 仅返回输入缓冲区的偏移量或切片，无需 free。

const std = @import("std");
const builtin = @import("builtin");

/// 向量宽度（字节）；按目标架构在编译期选择，x86 用 32（AVX2 友好），ARM 等用 16（00 §1.6）
const VECTOR_LANES = switch (builtin.cpu.arch) {
    .x86_64, .x86 => 32,
    .aarch64, .arm => 16,
    else => 16,
};

// Hot-path
/// 在块内查找第一个指定字符 c 的位置；返回偏移或 block.len
pub fn findChar(block: []const u8, c: u8) usize {
    @setRuntimeSafety(false);
    const n = block.len;
    if (n == 0) return 0;
    
    var i: usize = 0;
    const vc: @Vector(VECTOR_LANES, u8) = @splat(c);
    const T = std.meta.Int(.unsigned, VECTOR_LANES);

    while (i + VECTOR_LANES <= n) {
        const v: @Vector(VECTOR_LANES, u8) = block[i..][0..VECTOR_LANES].*;
        const mask = v == vc;
        const bitmap = @as(T, @bitCast(mask));
        if (bitmap != 0) return i + @ctz(bitmap);
        i += VECTOR_LANES;
    }
    while (i < n) : (i += 1) {
        if (block[i] == c) return i;
    }
    return n;
}

// Hot-path
/// 在块内查找第一个指定两个字符之一（c1 或 c2）的位置；返回偏移或 block.len
pub fn findAnyTwo(block: []const u8, c1: u8, c2: u8) usize {
    @setRuntimeSafety(false);
    const n = block.len;
    if (n == 0) return 0;
    
    var i: usize = 0;
    const vc1: @Vector(VECTOR_LANES, u8) = @splat(c1);
    const vc2: @Vector(VECTOR_LANES, u8) = @splat(c2);
    const T = std.meta.Int(.unsigned, VECTOR_LANES);

    while (i + VECTOR_LANES <= n) {
        const v: @Vector(VECTOR_LANES, u8) = block[i..][0..VECTOR_LANES].*;
        const mask: @Vector(VECTOR_LANES, bool) = (v == vc1) | (v == vc2);
        const bitmap = @as(T, @bitCast(mask));
        if (bitmap != 0) return i + @ctz(bitmap);
        i += VECTOR_LANES;
    }
    while (i < n) : (i += 1) {
        if (block[i] == c1 or block[i] == c2) return i;
    }
    return n;
}

// Hot-path
/// [Extreme Performance] 盲读版本：要求 block 后面至少有 VECTOR_LANES 字节的有效/安全内存（即使超出了 block.len）
/// 由调用方保证内存安全（00 §1.6 Lane 填充）。此版本极大减少边界检查分支，使代码执行流接近直线。
pub fn findCrLfPadded(block: []const u8) usize {
    @setRuntimeSafety(false);
    var i: usize = 0;
    const n = block.len;
    const T = std.meta.Int(.unsigned, VECTOR_LANES);
    const cr: @Vector(VECTOR_LANES, u8) = @splat(0x0D);
    const lf: @Vector(VECTOR_LANES, u8) = @splat(0x0A);
    
    // 盲读主循环：只要 i < n 就可以直接加载一整条向量（00 §1.6 Lane 填充）
    while (i < n) {
        const v: @Vector(VECTOR_LANES, u8) = block.ptr[i..][0..VECTOR_LANES].*;
        const mask: @Vector(VECTOR_LANES, bool) = (v == cr) | (v == lf);
        const bitmap = @as(T, @bitCast(mask));
        if (bitmap != 0) {
            const pos = @ctz(bitmap);
            const absolute = i + pos;
            return if (absolute < n) absolute else n;
        }
        i += VECTOR_LANES;
    }
    return n;
}

// Hot-path
/// 在块内查找第一个 \r (0x0D) 或 \n (0x0A) 的位置；块长度可小于 VECTOR_LANES，未读部分不访问
/// 返回：相对 block 的偏移（0..block.len），若未找到则返回 block.len
pub fn findCrLfInBlock(block: []const u8) usize {
    @setRuntimeSafety(false);
    const n = block.len;
    if (n == 0) return 0;
    
    var i: usize = 0;
    const cr: @Vector(VECTOR_LANES, u8) = @splat(0x0D);
    const lf: @Vector(VECTOR_LANES, u8) = @splat(0x0A);
    const T = std.meta.Int(.unsigned, VECTOR_LANES);

    while (i + VECTOR_LANES <= n) {
        const v: @Vector(VECTOR_LANES, u8) = block[i..][0..VECTOR_LANES].*;
        const mask: @Vector(VECTOR_LANES, bool) = (v == cr) | (v == lf);
        const bitmap = @as(T, @bitCast(mask));
        if (bitmap != 0) return i + @ctz(bitmap);
        i += VECTOR_LANES;
    }
    while (i < n) : (i += 1) {
        const c = block[i];
        if (c == '\r' or c == '\n') return i;
    }
    return n;
}

// Hot-path
/// 在恰好 VECTOR_LANES 字节的块内，用 @Vector 比较得到 \r 或 \n 的掩码，返回第一个匹配位置（未找到返回 VECTOR_LANES）
/// 极致压榨：利用 Zig 0.16 对 bool 向量 @bitCast 为整数的特性，生成 0 开销位图
pub fn scanCrLfMask(block: *const [VECTOR_LANES]u8) usize {
    @setRuntimeSafety(false);
    const v: @Vector(VECTOR_LANES, u8) = block.*;
    const cr: @Vector(VECTOR_LANES, u8) = @splat(0x0D);
    const lf: @Vector(VECTOR_LANES, u8) = @splat(0x0A);
    const mask: @Vector(VECTOR_LANES, bool) = (v == cr) | (v == lf);
    
    const T = std.meta.Int(.unsigned, VECTOR_LANES);
    const bitmap = @as(T, @bitCast(mask));
    
    if (bitmap == 0) return VECTOR_LANES;
    return @ctz(bitmap);
}

// Hot-path
/// [Extreme Performance] indexOfCrLfCrLf 的盲读版本
/// 要求 buf 后面有至少 VECTOR_LANES + 4 字节的安全读取区域（00 §1.6 Lane 填充）。
pub fn indexOfCrLfCrLfPadded(buf: []const u8) ?usize {
    @setRuntimeSafety(false);
    const n = buf.len;
    if (n < 4) return null;
    
    var i: usize = 0;
    const cr: @Vector(VECTOR_LANES, u8) = @splat(0x0D);
    const lf: @Vector(VECTOR_LANES, u8) = @splat(0x0A);
    const T = std.meta.Int(.unsigned, VECTOR_LANES);

    while (i < n - 3) {
        // 直接盲读 VECTOR_LANES 长度，利用 Lane 填充消除边界分支
        const v0: @Vector(VECTOR_LANES, u8) = buf.ptr[i..][0..VECTOR_LANES].*;
        const v1: @Vector(VECTOR_LANES, u8) = buf.ptr[i + 1 ..][0..VECTOR_LANES].*;
        const v2: @Vector(VECTOR_LANES, u8) = buf.ptr[i + 2 ..][0..VECTOR_LANES].*;
        const v3: @Vector(VECTOR_LANES, u8) = buf.ptr[i + 3 ..][0..VECTOR_LANES].*;
        
        const mask: @Vector(VECTOR_LANES, bool) = (v0 == cr) & (v1 == lf) & (v2 == cr) & (v3 == lf);
        const bitmap = @as(T, @bitCast(mask));
        
        if (bitmap != 0) {
            const pos = @ctz(bitmap);
            const absolute = i + pos;
            return if (absolute <= n - 4) absolute else null;
        }
        i += VECTOR_LANES;
    }
    return null;
}

// Hot-path
/// 在 buf 中查找 "\r\n\r\n" 的偏移；用 16/32 字节向量批量比较并位掩码过滤，消除逐字节分支。
/// 最佳性能建议：buf 长度≥VECTOR_LANES 且 64 字节对齐（00 §1.6）。
pub fn indexOfCrLfCrLf(buf: []const u8) ?usize {
    @setRuntimeSafety(false);
    const n = buf.len;
    if (n < 4) return null;
    const pattern = [_]u8{ '\r', '\n', '\r', '\n' };
    
    var i: usize = 0;
    const cr: @Vector(VECTOR_LANES, u8) = @splat(pattern[0]);
    const lf: @Vector(VECTOR_LANES, u8) = @splat(pattern[1]);
    const T = std.meta.Int(.unsigned, VECTOR_LANES);

    // 向量化主循环
    while (i + VECTOR_LANES + 3 <= n) {
        const v0: @Vector(VECTOR_LANES, u8) = buf[i..][0..VECTOR_LANES].*;
        const v1: @Vector(VECTOR_LANES, u8) = buf[i + 1 ..][0..VECTOR_LANES].*;
        const v2: @Vector(VECTOR_LANES, u8) = buf[i + 2 ..][0..VECTOR_LANES].*;
        const v3: @Vector(VECTOR_LANES, u8) = buf[i + 3 ..][0..VECTOR_LANES].*;
        
        // 核心：四字节对齐匹配掩码
        const mask: @Vector(VECTOR_LANES, bool) = (v0 == cr) & (v1 == lf) & (v2 == cr) & (v3 == lf);
        const bitmap = @as(T, @bitCast(mask));
        
        if (bitmap != 0) {
            return i + @ctz(bitmap);
        }
        i += VECTOR_LANES;
    }
    
    // 尾部标量处理
    while (i + 4 <= n) : (i += 1) {
        if (std.mem.eql(u8, buf[i..][0..4], &pattern)) return i;
    }
    return null;
}

test "findChar / findAnyTwo" {
    try std.testing.expect(findChar("abc:def", ':') == 3);
    try std.testing.expect(findAnyTwo("abc:def\n", ':', '\n') == 3);
    try std.testing.expect(findAnyTwo("abcdef\n", ':', '\n') == 6);
}

test "findCrLfPadded" {
    const data = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n" ** 2;
    try std.testing.expect(findCrLfPadded(data[0..14]) == 14);
    try std.testing.expect(findCrLfPadded(data[0..16]) == 14);
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
