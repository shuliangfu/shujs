//! 仅解压 API（gzip / deflate / brotli），无 jsc/common 依赖，供 build 注册为 shu_zlib 全局模块，io_core/http 等可 @import("shu_zlib") 做 raw_body 自动解压。
//! 本文件自包含：gzip/deflate 用 std.compress.flate，brotli 用 cImport 仅 decode，不 import 同目录 brotli.zig，避免同一文件归属 root 与 shu_zlib 两模块冲突。

const std = @import("std");

const c = @cImport({
    @cInclude("brotli/decode.h");
});

/// 是否开启 gzip 解压调试：环境变量 SHU_DEBUG_GZIP 非空且非 "0" 时向 stderr 打印每次 stream() 的字节数与总字节、错误信息。用于排查 npmmirror tgz InvalidGzip。
fn debugGzipEnabled() bool {
    const v = std.c.getenv("SHU_DEBUG_GZIP") orelse return false;
    return v[0] != 0 and v[0] != '0';
}

/// 向 stderr 打印一行调试信息，仅当 SHU_DEBUG_GZIP 开启时调用；msg 与 fmt 需包含换行。
fn debugGzipLog(comptime fmt: []const u8, args: anytype) void {
    if (!debugGzipEnabled()) return;
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    fbs.writer().print("[shu_zlib gzip] " ++ fmt, args) catch return;
    const slice = fbs.getWritten();
    _ = std.posix.write(2, slice) catch {};
}

/// 带位置的 std.Io.Reader 包装：从 slice[pos..] 读并推进 pos，用于多 member gzip 时统计本 member 消费字节数。
/// 通过 @fieldParentPtr 从 *Reader 取回 *SliceReaderState，满足 flate.Decompress 要求的 *std.Io.Reader 类型。
/// 必须提供足够大的 buf 给 reader.buffer，否则 flate 内部 peek/fill 会触发 rebase，defaultRebase 断言 buffer.len - seek >= capacity。
const SliceReaderState = struct {
    reader: std.Io.Reader,
    slice: []const u8,
    pos: usize,
    /// 供 reader.buffer 使用，满足 fill/rebase 对 buffer 容量的要求（flate 会 peek 若干字节；256KB 避免大 tgz 时 rebase 容量不足）
    buf: [256 * 1024]u8 = undefined,

    const Reader = std.Io.Reader;
    const Limit = std.Io.Limit;

    fn streamImpl(r: *Reader, w: *std.Io.Writer, limit: Limit) Reader.StreamError!usize {
        const self = @as(*SliceReaderState, @ptrFromInt(@intFromPtr(r) - @offsetOf(SliceReaderState, "reader")));
        const avail = self.slice.len -| self.pos;
        const n = limit.minInt(avail);
        if (n == 0) return 0;
        const written = try w.write(self.slice[self.pos..][0..n]);
        self.pos += written;
        return written;
    }

    const vtable: Reader.VTable = .{
        .stream = streamImpl,
        .discard = Reader.defaultDiscard,
        .readVec = Reader.defaultReadVec,
        .rebase = Reader.defaultRebase,
    };

    fn makeReader(state: *SliceReaderState) Reader {
        return .{
            .vtable = &vtable,
            .buffer = state.buf[0..],
            .seek = 0,
            .end = 0,
        };
    }
};

/// 使用 std.compress.flate 将 gzip 格式的 input 解压为原始字节。支持多 member（多个 gzip 流首尾相接），
/// 常见于部分 npm 镜像的 tgz。用 SliceReaderState 按 member 追踪消费字节数；传空 buffer 走 direct_vtable，
/// 用 Allocating writer 一次性 stream(.unlimited)，避免每 8KB 换 Writer 导致 deflate 回退引用无历史而 ReadFailed。
/// 调用方必须对返回的 slice 调用 allocator.free()。
pub fn decompressGzip(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (input.len == 0) return error.EmptyInput;
    const debug = debugGzipEnabled();
    if (debug) debugGzipLog("input.len={}\n", .{input.len});

    var list = std.ArrayList(u8).initCapacity(allocator, if (input.len > 65536) input.len * 2 else 65536) catch return error.OutOfMemory;
    defer list.deinit(allocator);

    var state = SliceReaderState{ .reader = undefined, .slice = input, .pos = 0 };
    state.reader = state.makeReader();
    while (state.pos + 10 <= state.slice.len and state.slice[state.pos] == 0x1f and state.slice[state.pos + 1] == 0x8b) {
        var dec = std.compress.flate.Decompress.init(&state.reader, .gzip, &[0]u8{});
        var out = std.Io.Writer.Allocating.init(allocator);
        defer out.deinit();
        _ = dec.reader.stream(&out.writer, .unlimited) catch |e| {
            if (debug) debugGzipLog("stream error={s}\n", .{@errorName(e)});
            return e;
        };
        const written = out.written();
        if (written.len > 0) {
            list.appendSlice(allocator, written) catch return error.OutOfMemory;
        }
        if (debug) debugGzipLog("member done total={}\n", .{written.len});
    }
    if (debug) debugGzipLog("done total={}\n", .{list.items.len});
    return list.toOwnedSlice(allocator);
}

/// 使用 std.compress.flate 将 zlib 格式的 input 解压为原始字节（HTTP Content-Encoding: deflate 多为 zlib 格式）。调用方必须对返回的 slice 调用 allocator.free()。
/// 与 decompressGzip 一致：空 buffer + Allocating writer 一次性 stream(.unlimited)。
pub fn decompressDeflate(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (input.len == 0) return error.EmptyInput;
    var in_reader = std.Io.Reader.fixed(input);
    var dec = std.compress.flate.Decompress.init(&in_reader, .zlib, &[0]u8{});
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    _ = try dec.reader.stream(&out.writer, .unlimited);
    return allocator.dupe(u8, out.written());
}

// -----------------------------------------------------------------------------
// Brotli（本文件内 cImport 仅 decode，与 brotli.zig 解压逻辑一致）
// -----------------------------------------------------------------------------

/// 使用 Brotli 将 br 格式的 input 解压为原始字节。调用方必须对返回的 slice 调用 allocator.free()。
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
