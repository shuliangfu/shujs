// Node 式 fork IPC：length-prefix 协议（4 字节大端长度 + 消息体）
// 父子进程通过 stdin/stdout 收发 JSON 字符串

const std = @import("std");

/// 单条消息最大长度（避免恶意子进程发巨大包）
const max_message_len: u32 = 1024 * 1024;

/// 将一条消息按协议写入 stream（4 字节大端长度 + body）；stream 需实现 writeAll(buf) !void
pub fn writeMessage(stream: anytype, msg: []const u8) !void {
    if (msg.len > max_message_len) return error.MessageTooLong;
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(msg.len), .big);
    try stream.writeAll(&len_buf);
    try stream.writeAll(msg);
}

/// 从 stream 读一条消息；stream 需实现 read(buf) !usize；返回的切片由调用方 free；EOF 或错误时返回 null
pub fn readMessage(allocator: std.mem.Allocator, stream: anytype) !?[]u8 {
    var len_buf: [4]u8 = undefined;
    var got: usize = 0;
    while (got < 4) {
        const n = stream.read(len_buf[got..]) catch return null;
        if (n == 0) return null;
        got += n;
    }
    const len = std.mem.readInt(u32, &len_buf, .big);
    if (len > max_message_len) return error.MessageTooLong;
    const buf = allocator.alloc(u8, len) catch return null;
    errdefer allocator.free(buf);
    got = 0;
    while (got < len) {
        const n = stream.read(buf[got..]) catch {
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
