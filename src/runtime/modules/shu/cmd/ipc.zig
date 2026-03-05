// Node 式 fork IPC：length-prefix 协议（4 字节大端长度 + 消息体）
// 父子进程通过 stdin/stdout 收发 JSON 字符串
// 0.16：使用 std.Io + File.reader/File.writer 的 readVec/writeVec

const std = @import("std");

/// 单条消息最大长度（避免恶意子进程发巨大包）
const max_message_len: u32 = 1024 * 1024;

/// 将一条消息按协议写入 file（4 字节大端长度 + body）。调用方需传入 io（如 libs_process.getProcessIo()）。
pub fn writeMessage(io: std.Io, file: std.Io.File, msg: []const u8) !void {
    if (msg.len > max_message_len) return error.MessageTooLong;
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(msg.len), .big);
    var wbuf: [512]u8 = undefined;
    var w = file.writer(io, &wbuf);
    _ = try std.Io.Writer.writeVec(&w.interface, &.{&len_buf});
    _ = try std.Io.Writer.writeVec(&w.interface, &.{msg});
    try w.interface.flush();
}

/// 从 file 读一条消息；返回的切片由调用方 free；EOF 或错误时返回 null。调用方需传入 io。
pub fn readMessage(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File) !?[]u8 {
    var rbuf: [512]u8 = undefined;
    var r = file.reader(io, &rbuf);
    var len_buf: [4]u8 = undefined;
    var got: usize = 0;
    while (got < 4) {
        var dest: [1][]u8 = .{len_buf[got..]};
        const n = std.Io.Reader.readVec(&r.interface, &dest) catch return null;
        if (n == 0) return null;
        got += n;
    }
    const len = std.mem.readInt(u32, &len_buf, .big);
    if (len > max_message_len) return error.MessageTooLong;
    const buf = allocator.alloc(u8, len) catch return null;
    errdefer allocator.free(buf);
    got = 0;
    while (got < len) {
        var dest: [1][]u8 = .{buf[got..]};
        const n = std.Io.Reader.readVec(&r.interface, &dest) catch {
            allocator.free(buf);
            return null;
        };
        if (n == 0) {
            allocator.free(buf);
            return null;
        }
        got += n;
    }
    return buf;
}
