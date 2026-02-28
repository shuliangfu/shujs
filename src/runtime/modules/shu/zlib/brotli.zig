// Brotli 压缩：调用 deps/brotli C API
// 供 Shu.server 与 shu:zlib / node:zlib 共用；仅压缩，不解压；调用方负责 free 返回的 slice

const std = @import("std");

const c = @cImport({
    @cInclude("brotli/encode.h");
});

/// 使用 Brotli 将 input 压缩为 br 格式。
/// 调用方必须对返回的 slice 调用 allocator.free()。
pub fn compressBrotli(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (input.len == 0) return error.EmptyInput;
    const max_out = c.BrotliEncoderMaxCompressedSize(input.len);
    if (max_out == 0) return error.InputTooLarge;
    const out_buf = allocator.alloc(u8, max_out) catch return error.OutOfMemory;
    errdefer allocator.free(out_buf);
    var encoded_size: usize = max_out;
    const ok = c.BrotliEncoderCompress(
        c.BROTLI_DEFAULT_QUALITY,
        c.BROTLI_DEFAULT_WINDOW,
        c.BROTLI_MODE_GENERIC,
        input.len,
        input.ptr,
        &encoded_size,
        out_buf.ptr,
    );
    if (ok != c.BROTLI_TRUE) {
        allocator.free(out_buf);
        return error.CompressionFailed;
    }
    const result = try allocator.dupe(u8, out_buf[0..encoded_size]);
    allocator.free(out_buf);
    return result;
}
