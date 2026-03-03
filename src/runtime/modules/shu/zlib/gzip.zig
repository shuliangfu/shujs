// Gzip/deflate 压缩与解压：压缩用 deps/comprezz 纯 Zig，解压用 std.compress.flate
// 供 Shu.server、shu:zlib / node:zlib 与 package 下载（Content-Encoding: gzip）解压共用；调用方负责 free 返回的 slice

const std = @import("std");
const comprezz = @import("comprezz");

/// 使用 Comprezz 将 input 压缩为 gzip 格式。
/// 调用方必须对返回的 slice 调用 allocator.free()。
/// 若 input 为空或压缩失败则返回 error。
pub fn compressGzip(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (input.len == 0) return error.EmptyInput;
    const max_out = input.len * 2 + 1024;
    const out_buf = allocator.alloc(u8, max_out) catch return error.OutOfMemory;
    errdefer allocator.free(out_buf);

    var input_reader = std.Io.Reader.fixed(input);
    var out_writer = std.Io.Writer.fixed(out_buf);
    try comprezz.compress(&input_reader, &out_writer, .{ .level = .default });
    try out_writer.flush();

    const written = out_writer.end;
    const result = try allocator.dupe(u8, out_buf[0..written]);
    allocator.free(out_buf);
    return result;
}

/// 使用 Comprezz 将 input 压缩为 raw deflate（无 zlib 头尾）
/// 调用方必须对返回的 slice 调用 allocator.free()
pub fn compressDeflate(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (input.len == 0) return error.EmptyInput;
    const max_out = input.len * 2 + 1024;
    const out_buf = allocator.alloc(u8, max_out) catch return error.OutOfMemory;
    errdefer allocator.free(out_buf);

    var input_reader = std.Io.Reader.fixed(input);
    var out_writer = std.Io.Writer.fixed(out_buf);
    try comprezz.deflateCompress(.raw, &input_reader, &out_writer, .{ .level = .default });
    try out_writer.flush();

    const written = out_writer.end;
    const result = try allocator.dupe(u8, out_buf[0..written]);
    allocator.free(out_buf);
    return result;
}

/// 使用 std.compress.flate 将 gzip 格式的 input 解压为原始字节。
/// 调用方必须对返回的 slice 调用 allocator.free()。
/// 供 shu:zlib 与 package 下载（Content-Encoding: gzip）解压使用；与 install 中 tgz 解压一致。
/// 传空 buffer 给 init 以走 direct_vtable，否则 stream() 会写内部 buffer 且恒返回 0。
pub fn decompressGzip(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (input.len == 0) return error.EmptyInput;
    var in_reader = std.Io.Reader.fixed(input);
    var dec = std.compress.flate.Decompress.init(&in_reader, .gzip, &[0]u8{});
    var list = std.ArrayList(u8).initCapacity(allocator, 65536) catch return error.OutOfMemory;
    defer list.deinit(allocator);
    var buf: [8192]u8 = undefined;
    while (true) {
        var w = std.Io.Writer.fixed(buf[0..]);
        const n = dec.reader.stream(&w, .limited(buf.len)) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        if (n == 0) break;
        list.appendSlice(allocator, buf[0..n]) catch return error.OutOfMemory;
    }
    return list.toOwnedSlice(allocator);
}

/// 使用 std.compress.flate 将 zlib 格式的 input 解压为原始字节（HTTP Content-Encoding: deflate 为 zlib 格式）。
/// 调用方必须对返回的 slice 调用 allocator.free()。
/// 供 shu:zlib 与 package 下载（Content-Encoding: deflate）解压使用。
/// 传空 buffer 给 init 以走 direct_vtable，否则 stream() 会写内部 buffer 且恒返回 0。
pub fn decompressDeflate(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    if (input.len == 0) return error.EmptyInput;
    var in_reader = std.Io.Reader.fixed(input);
    var dec = std.compress.flate.Decompress.init(&in_reader, .zlib, &[0]u8{});
    var list = std.ArrayList(u8).initCapacity(allocator, 65536) catch return error.OutOfMemory;
    defer list.deinit(allocator);
    var buf: [8192]u8 = undefined;
    while (true) {
        var w = std.Io.Writer.fixed(buf[0..]);
        const n = dec.reader.stream(&w, .limited(buf.len)) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        if (n == 0) break;
        list.appendSlice(allocator, buf[0..n]) catch return error.OutOfMemory;
    }
    return list.toOwnedSlice(allocator);
}
