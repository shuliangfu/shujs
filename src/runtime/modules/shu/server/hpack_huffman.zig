// HPACK Huffman 解码：RFC 7541 Appendix B 码表，用于解码请求头中的 Huffman 编码字面量

const std = @import("std");

/// RFC 7541 / nghttp2 的 Huffman 符号表：257 项（0-255 为字节，256 为 EOS），左对齐 32 位 code
pub const HUFF_SYM = [257]struct { nbits: u5, code: u32 }{
    .{ .nbits = 13, .code = 0xffc00000 }, .{ .nbits = 23, .code = 0xffffb000 }, .{ .nbits = 28, .code = 0xfffffe20 }, .{ .nbits = 28, .code = 0xfffffe30 },
    .{ .nbits = 28, .code = 0xfffffe40 }, .{ .nbits = 28, .code = 0xfffffe50 }, .{ .nbits = 28, .code = 0xfffffe60 }, .{ .nbits = 28, .code = 0xfffffe70 },
    .{ .nbits = 28, .code = 0xfffffe80 }, .{ .nbits = 24, .code = 0xffffea00 }, .{ .nbits = 30, .code = 0xfffffff0 }, .{ .nbits = 28, .code = 0xfffffe90 },
    .{ .nbits = 28, .code = 0xfffffea0 }, .{ .nbits = 30, .code = 0xfffffff4 }, .{ .nbits = 28, .code = 0xfffffeb0 }, .{ .nbits = 28, .code = 0xfffffec0 },
    .{ .nbits = 28, .code = 0xfffffed0 }, .{ .nbits = 28, .code = 0xfffffee0 }, .{ .nbits = 28, .code = 0xfffffef0 }, .{ .nbits = 28, .code = 0xffffff00 },
    .{ .nbits = 28, .code = 0xffffff10 }, .{ .nbits = 28, .code = 0xffffff20 }, .{ .nbits = 30, .code = 0xfffffff8 }, .{ .nbits = 28, .code = 0xffffff30 },
    .{ .nbits = 28, .code = 0xffffff40 }, .{ .nbits = 28, .code = 0xffffff50 }, .{ .nbits = 28, .code = 0xffffff60 }, .{ .nbits = 28, .code = 0xffffff70 },
    .{ .nbits = 28, .code = 0xffffff80 }, .{ .nbits = 28, .code = 0xffffff90 }, .{ .nbits = 28, .code = 0xffffffa0 }, .{ .nbits = 28, .code = 0xffffffb0 },
    .{ .nbits = 6, .code = 0x50000000 },  .{ .nbits = 10, .code = 0xfe000000 }, .{ .nbits = 10, .code = 0xfe400000 }, .{ .nbits = 12, .code = 0xffa00000 },
    .{ .nbits = 13, .code = 0xffc80000 }, .{ .nbits = 6, .code = 0x54000000 },  .{ .nbits = 8, .code = 0xf8000000 },  .{ .nbits = 11, .code = 0xff400000 },
    .{ .nbits = 10, .code = 0xfe800000 }, .{ .nbits = 10, .code = 0xfec00000 }, .{ .nbits = 8, .code = 0xf9000000 },  .{ .nbits = 11, .code = 0xff600000 },
    .{ .nbits = 8, .code = 0xfa000000 },  .{ .nbits = 6, .code = 0x58000000 },  .{ .nbits = 6, .code = 0x5c000000 },  .{ .nbits = 6, .code = 0x60000000 },
    .{ .nbits = 5, .code = 0x0 },          .{ .nbits = 5, .code = 0x8000000 },   .{ .nbits = 5, .code = 0x10000000 },  .{ .nbits = 6, .code = 0x64000000 },
    .{ .nbits = 6, .code = 0x68000000 },  .{ .nbits = 6, .code = 0x6c000000 },  .{ .nbits = 6, .code = 0x70000000 },  .{ .nbits = 6, .code = 0x74000000 },
    .{ .nbits = 6, .code = 0x78000000 },  .{ .nbits = 6, .code = 0x7c000000 },  .{ .nbits = 7, .code = 0xb8000000 },  .{ .nbits = 8, .code = 0xfb000000 },
    .{ .nbits = 15, .code = 0xfff80000 }, .{ .nbits = 6, .code = 0x80000000 },  .{ .nbits = 12, .code = 0xffb00000 }, .{ .nbits = 10, .code = 0xff000000 },
    .{ .nbits = 13, .code = 0xffd00000 }, .{ .nbits = 6, .code = 0x84000000 },  .{ .nbits = 7, .code = 0xba000000 },  .{ .nbits = 7, .code = 0xbc000000 },
    .{ .nbits = 7, .code = 0xbe000000 },  .{ .nbits = 7, .code = 0xc0000000 },  .{ .nbits = 7, .code = 0xc2000000 },  .{ .nbits = 7, .code = 0xc4000000 },
    .{ .nbits = 7, .code = 0xc6000000 },  .{ .nbits = 7, .code = 0xc8000000 },  .{ .nbits = 7, .code = 0xca000000 },  .{ .nbits = 7, .code = 0xcc000000 },
    .{ .nbits = 7, .code = 0xce000000 },  .{ .nbits = 7, .code = 0xd0000000 },  .{ .nbits = 7, .code = 0xd2000000 },  .{ .nbits = 7, .code = 0xd4000000 },
    .{ .nbits = 7, .code = 0xd6000000 },  .{ .nbits = 7, .code = 0xd8000000 },  .{ .nbits = 7, .code = 0xda000000 },  .{ .nbits = 7, .code = 0xdc000000 },
    .{ .nbits = 7, .code = 0xde000000 },  .{ .nbits = 7, .code = 0xe0000000 },  .{ .nbits = 7, .code = 0xe2000000 },  .{ .nbits = 7, .code = 0xe4000000 },
    .{ .nbits = 8, .code = 0xfc000000 },  .{ .nbits = 7, .code = 0xe6000000 },  .{ .nbits = 8, .code = 0xfd000000 },  .{ .nbits = 13, .code = 0xffd80000 },
    .{ .nbits = 19, .code = 0xfffe0000 }, .{ .nbits = 13, .code = 0xffe00000 }, .{ .nbits = 14, .code = 0xfff00000 }, .{ .nbits = 6, .code = 0x88000000 },
    .{ .nbits = 15, .code = 0xfffa0000 }, .{ .nbits = 5, .code = 0x18000000 },  .{ .nbits = 6, .code = 0x8c000000 }, .{ .nbits = 5, .code = 0x20000000 },
    .{ .nbits = 6, .code = 0x90000000 },  .{ .nbits = 5, .code = 0x28000000 },  .{ .nbits = 6, .code = 0x94000000 }, .{ .nbits = 6, .code = 0x98000000 },
    .{ .nbits = 6, .code = 0x9c000000 },  .{ .nbits = 5, .code = 0x30000000 },  .{ .nbits = 7, .code = 0xe8000000 },  .{ .nbits = 7, .code = 0xea000000 },
    .{ .nbits = 6, .code = 0xa0000000 }, .{ .nbits = 6, .code = 0xa4000000 }, .{ .nbits = 6, .code = 0xa8000000 }, .{ .nbits = 5, .code = 0x38000000 },
    .{ .nbits = 6, .code = 0xac000000 }, .{ .nbits = 7, .code = 0xec000000 },  .{ .nbits = 6, .code = 0xb0000000 }, .{ .nbits = 5, .code = 0x40000000 },
    .{ .nbits = 5, .code = 0x48000000 }, .{ .nbits = 6, .code = 0xb4000000 }, .{ .nbits = 7, .code = 0xee000000 },  .{ .nbits = 7, .code = 0xf0000000 },
    .{ .nbits = 7, .code = 0xf2000000 }, .{ .nbits = 7, .code = 0xf4000000 }, .{ .nbits = 7, .code = 0xf6000000 }, .{ .nbits = 15, .code = 0xfffc0000 },
    .{ .nbits = 11, .code = 0xff800000 }, .{ .nbits = 14, .code = 0xfff40000 }, .{ .nbits = 13, .code = 0xffe80000 }, .{ .nbits = 28, .code = 0xffffffc0 },
    .{ .nbits = 20, .code = 0xfffe6000 }, .{ .nbits = 22, .code = 0xffff4800 }, .{ .nbits = 20, .code = 0xfffe7000 }, .{ .nbits = 20, .code = 0xfffe8000 },
    .{ .nbits = 22, .code = 0xffff4c00 }, .{ .nbits = 22, .code = 0xffff5000 }, .{ .nbits = 22, .code = 0xffff5400 }, .{ .nbits = 23, .code = 0xffffb200 },
    .{ .nbits = 22, .code = 0xffff5800 }, .{ .nbits = 23, .code = 0xffffb400 }, .{ .nbits = 23, .code = 0xffffb600 }, .{ .nbits = 23, .code = 0xffffb800 },
    .{ .nbits = 23, .code = 0xffffba00 }, .{ .nbits = 23, .code = 0xffffbc00 }, .{ .nbits = 24, .code = 0xffffeb00 }, .{ .nbits = 23, .code = 0xffffbe00 },
    .{ .nbits = 24, .code = 0xffffec00 }, .{ .nbits = 24, .code = 0xffffed00 }, .{ .nbits = 22, .code = 0xffff5c00 }, .{ .nbits = 23, .code = 0xffffc000 },
    .{ .nbits = 24, .code = 0xffffee00 }, .{ .nbits = 23, .code = 0xffffc200 }, .{ .nbits = 23, .code = 0xffffc400 }, .{ .nbits = 23, .code = 0xffffc600 },
    .{ .nbits = 23, .code = 0xffffc800 }, .{ .nbits = 21, .code = 0xfffee000 }, .{ .nbits = 22, .code = 0xffff6000 }, .{ .nbits = 23, .code = 0xffffca00 },
    .{ .nbits = 22, .code = 0xffff6400 }, .{ .nbits = 23, .code = 0xffffcc00 }, .{ .nbits = 23, .code = 0xffffce00 }, .{ .nbits = 24, .code = 0xffffef00 },
    .{ .nbits = 22, .code = 0xffff6800 }, .{ .nbits = 21, .code = 0xfffee800 }, .{ .nbits = 20, .code = 0xfffe9000 }, .{ .nbits = 22, .code = 0xffff6c00 },
    .{ .nbits = 22, .code = 0xffff7000 }, .{ .nbits = 23, .code = 0xffffd000 }, .{ .nbits = 23, .code = 0xffffd200 }, .{ .nbits = 21, .code = 0xfffef000 },
    .{ .nbits = 23, .code = 0xffffd400 }, .{ .nbits = 22, .code = 0xffff7400 }, .{ .nbits = 22, .code = 0xffff7800 }, .{ .nbits = 24, .code = 0xfffff000 },
    .{ .nbits = 21, .code = 0xfffef800 }, .{ .nbits = 22, .code = 0xffff7c00 }, .{ .nbits = 23, .code = 0xffffd600 }, .{ .nbits = 23, .code = 0xffffd800 },
    .{ .nbits = 21, .code = 0xffff0000 }, .{ .nbits = 21, .code = 0xffff0800 }, .{ .nbits = 22, .code = 0xffff8000 }, .{ .nbits = 21, .code = 0xffff1000 },
    .{ .nbits = 23, .code = 0xffffda00 }, .{ .nbits = 22, .code = 0xffff8400 }, .{ .nbits = 23, .code = 0xffffdc00 }, .{ .nbits = 23, .code = 0xffffde00 },
    .{ .nbits = 20, .code = 0xfffea000 }, .{ .nbits = 22, .code = 0xffff8800 }, .{ .nbits = 22, .code = 0xffff8c00 }, .{ .nbits = 22, .code = 0xffff9000 },
    .{ .nbits = 23, .code = 0xffffe000 }, .{ .nbits = 22, .code = 0xffff9400 }, .{ .nbits = 22, .code = 0xffff9800 }, .{ .nbits = 23, .code = 0xffffe200 },
    .{ .nbits = 26, .code = 0xfffff800 }, .{ .nbits = 26, .code = 0xfffff840 }, .{ .nbits = 20, .code = 0xfffeb000 }, .{ .nbits = 19, .code = 0xfffe2000 },
    .{ .nbits = 22, .code = 0xffff9c00 }, .{ .nbits = 23, .code = 0xffffe400 }, .{ .nbits = 22, .code = 0xffffa000 }, .{ .nbits = 25, .code = 0xfffff600 },
    .{ .nbits = 26, .code = 0xfffff880 }, .{ .nbits = 26, .code = 0xfffff8c0 }, .{ .nbits = 26, .code = 0xfffff900 }, .{ .nbits = 27, .code = 0xfffffbc0 },
    .{ .nbits = 27, .code = 0xfffffbe0 }, .{ .nbits = 26, .code = 0xfffff940 }, .{ .nbits = 24, .code = 0xfffff100 }, .{ .nbits = 25, .code = 0xfffff680 },
    .{ .nbits = 19, .code = 0xfffe4000 }, .{ .nbits = 21, .code = 0xffff1800 }, .{ .nbits = 26, .code = 0xfffff980 }, .{ .nbits = 27, .code = 0xfffffc00 },
    .{ .nbits = 27, .code = 0xfffffc20 }, .{ .nbits = 26, .code = 0xfffff9c0 }, .{ .nbits = 27, .code = 0xfffffc40 }, .{ .nbits = 24, .code = 0xfffff200 },
    .{ .nbits = 21, .code = 0xffff2000 }, .{ .nbits = 21, .code = 0xffff2800 }, .{ .nbits = 26, .code = 0xfffffa00 }, .{ .nbits = 26, .code = 0xfffffa40 },
    .{ .nbits = 28, .code = 0xffffffd0 }, .{ .nbits = 27, .code = 0xfffffc60 }, .{ .nbits = 27, .code = 0xfffffc80 }, .{ .nbits = 27, .code = 0xfffffca0 },
    .{ .nbits = 20, .code = 0xfffec000 }, .{ .nbits = 24, .code = 0xfffff300 }, .{ .nbits = 20, .code = 0xfffed000 }, .{ .nbits = 21, .code = 0xffff3000 },
    .{ .nbits = 22, .code = 0xffffa400 }, .{ .nbits = 21, .code = 0xffff3800 }, .{ .nbits = 21, .code = 0xffff4000 }, .{ .nbits = 23, .code = 0xffffe600 },
    .{ .nbits = 22, .code = 0xffffa800 }, .{ .nbits = 22, .code = 0xffffac00 }, .{ .nbits = 25, .code = 0xfffff700 }, .{ .nbits = 25, .code = 0xfffff780 },
    .{ .nbits = 24, .code = 0xfffff400 }, .{ .nbits = 24, .code = 0xfffff500 }, .{ .nbits = 26, .code = 0xfffffa80 }, .{ .nbits = 23, .code = 0xffffe800 },
    .{ .nbits = 26, .code = 0xfffffac0 }, .{ .nbits = 27, .code = 0xfffffcc0 }, .{ .nbits = 26, .code = 0xfffffb00 }, .{ .nbits = 26, .code = 0xfffffb40 },
    .{ .nbits = 27, .code = 0xfffffce0 }, .{ .nbits = 27, .code = 0xfffffd00 }, .{ .nbits = 27, .code = 0xfffffd20 }, .{ .nbits = 27, .code = 0xfffffd40 },
    .{ .nbits = 27, .code = 0xfffffd60 }, .{ .nbits = 28, .code = 0xffffffe0 }, .{ .nbits = 27, .code = 0xfffffd80 }, .{ .nbits = 27, .code = 0xfffffda0 },
    .{ .nbits = 27, .code = 0xfffffdc0 }, .{ .nbits = 27, .code = 0xfffffde0 }, .{ .nbits = 27, .code = 0xfffffe00 }, .{ .nbits = 26, .code = 0xfffffb80 },
    .{ .nbits = 30, .code = 0xfffffffc }, // EOS (symbol 256)
};

/// 将明文字节流按 RFC 7541 HPACK Huffman 编码到 dst，返回写入的字节数；编码后通常可减带宽
/// 若 dst 不足则返回 error.BufferTooSmall；编码末尾带 EOS 并按规范填充至字节边界
pub fn encodeHuffmanToBuffer(dst: []u8, input: []const u8) !usize {
    var bit_buffer: u64 = 0;
    var bit_count: usize = 0;
    var out_pos: usize = 0;
    for (input) |b| {
        const sym = HUFF_SYM[b];
        if (sym.nbits == 0) return error.InvalidHuffman;
        const shift = @as(usize, 32) - @as(usize, sym.nbits);
        const code: u32 = if (shift >= 32) 0 else sym.code >> @as(u5, @intCast(shift));
        bit_buffer = (bit_buffer << sym.nbits) | code;
        bit_count += sym.nbits;
        while (bit_count >= 8) {
            if (out_pos >= dst.len) return error.BufferTooSmall;
            bit_count -= 8;
            const sh: u6 = @intCast(bit_count);
            dst[out_pos] = @as(u8, @truncate(bit_buffer >> sh));
            out_pos += 1;
            bit_buffer &= (@as(u64, 1) << sh) - 1;
        }
    }
    // EOS (symbol 256)
    const eos = HUFF_SYM[256];
    const eos_shift = @as(usize, 32) - @as(usize, eos.nbits);
    const eos_code: u32 = if (eos_shift >= 32) 0 else eos.code >> @as(u5, @intCast(eos_shift));
    bit_buffer = (bit_buffer << eos.nbits) | eos_code;
    bit_count += eos.nbits;
    while (bit_count >= 8) {
        if (out_pos >= dst.len) return error.BufferTooSmall;
        bit_count -= 8;
        const sh: u6 = @intCast(bit_count);
        dst[out_pos] = @as(u8, @truncate(bit_buffer >> sh));
        out_pos += 1;
        bit_buffer &= (@as(u64, 1) << sh) - 1;
    }
    if (bit_count > 0) {
        const pad_bits: u4 = @intCast(8 - bit_count);
        bit_buffer = (bit_buffer << pad_bits) | (@as(u64, 1) << pad_bits) - 1;
        if (out_pos >= dst.len) return error.BufferTooSmall;
        dst[out_pos] = @as(u8, @truncate(bit_buffer));
        out_pos += 1;
    }
    return out_pos;
}

/// 将 HPACK Huffman 编码的字节流解码为明文；调用方负责 free 返回的切片
pub fn decodeHuffman(allocator: std.mem.Allocator, encoded: []const u8) ![]const u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, encoded.len);
    errdefer out.deinit(allocator);
    var buffer: u32 = 0;
    var bits_in_buffer: u32 = 0;
    var input_pos: usize = 0;
    while (true) {
        while (bits_in_buffer < 30 and input_pos < encoded.len) {
            buffer = (buffer << 8) | encoded[input_pos];
            input_pos += 1;
            bits_in_buffer += 8;
        }
        if (bits_in_buffer < 5) break;
        var found = false;
        for (HUFF_SYM, 0..) |sym, idx| {
            if (sym.nbits == 0 or sym.nbits > bits_in_buffer) continue;
            const shift_val: u6 = 32 - @as(u6, sym.nbits);
            if (shift_val > 31) continue;
            const shift: u5 = @intCast(shift_val);
            if ((buffer >> shift) == (sym.code >> shift)) {
                if (idx == 256) return out.toOwnedSlice(allocator);
                out.append(allocator, @intCast(idx)) catch return error.OutOfMemory;
                buffer <<= @intCast(sym.nbits);
                bits_in_buffer -= sym.nbits;
                found = true;
                break;
            }
        }
        if (!found) return error.InvalidHuffman;
    }
    return out.toOwnedSlice(allocator);
}
