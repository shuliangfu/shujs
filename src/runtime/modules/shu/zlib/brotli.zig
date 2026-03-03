// Brotli 压缩与解压：调用 deps/brotli C API（encode + decode）
// 供 Shu.server、shu:zlib / node:zlib 与 package 下载 br 解压共用；调用方负责 free 返回的 slice

const std = @import("std");

const c = @cImport({
    @cInclude("brotli/encode.h");
    @cInclude("brotli/decode.h");
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

/// 使用 Brotli 将 br 格式的 input 解压为原始字节。
/// 调用方必须对返回的 slice 调用 allocator.free()。
/// 供 shu:zlib 与 package 下载（Content-Encoding: br）解压使用。
pub fn decompressBrotli(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (input.len == 0) return error.EmptyInput;
    const state = c.BrotliDecoderCreateInstance(null, null, null) orelse return error.OutOfMemory;
    defer c.BrotliDecoderDestroyInstance(state);

    const chunk_size = 64 * 1024;
    var out_chunk: [chunk_size]u8 = undefined;
    var list = std.ArrayList(u8).initCapacity(allocator, chunk_size) catch return error.OutOfMemory;
    defer list.deinit(allocator);

    var available_in: usize = input.len;
    var next_in: [*c]const u8 = input.ptr;
    while (true) {
        var available_out: usize = chunk_size;
        var next_out: [*c]u8 = out_chunk[0..].ptr;
        var total_out: usize = 0;
        const result = c.BrotliDecoderDecompressStream(
            state,
            &available_in,
            &next_in,
            &available_out,
            &next_out,
            &total_out,
        );
        if (total_out > 0) {
            const written = chunk_size - available_out;
            list.appendSlice(allocator, out_chunk[0..written]) catch return error.OutOfMemory;
        }
        switch (result) {
            c.BROTLI_DECODER_RESULT_SUCCESS => break,
            c.BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT => break,
            c.BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT => continue,
            c.BROTLI_DECODER_RESULT_ERROR => return error.BrotliDecompressFailed,
            else => return error.BrotliDecompressFailed,
        }
    }
    return list.toOwnedSlice(allocator);
}
