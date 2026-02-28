// Gzip/deflate 压缩：使用 deps/comprezz 纯 Zig 实现
// 供 Shu.server 与 shu:zlib / node:zlib 共用；调用方负责 free 返回的 slice

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
