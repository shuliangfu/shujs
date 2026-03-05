// HTTP 响应构建与写出：statusPhrase、getResponse*、writeHttpResponse、sendfile 等
// 供 mod.zig / conn / h2 等调用；文件→网络零拷贝统一走 libs_io.sendFile，避免与 io_core 重复实现
//
// 响应头优化：Date 按秒缓存，避免每请求格式化；Server 头支持 config.server_header 或默认 "Shu" 预编码写入。

const std = @import("std");
const jsc = @import("jsc");
const types = @import("types.zig");
const builtin = @import("builtin");
const libs_io = @import("libs_io");
const errors = @import("errors");
const libs_process = @import("libs_process");
const epoch = std.time.epoch;

/// 当前平台是否支持 libs_io.sendFile（Linux/Darwin/BSD/Windows）；comptime 分派
const sendfile_platform_ok = builtin.os.tag == .linux or builtin.os.tag == .macos or builtin.os.tag == .freebsd or builtin.os.tag == .netbsd or builtin.os.tag == .openbsd or builtin.os.tag == .windows;
/// 是否用 writev 合并头+体（POSIX 有 writev，Windows 无）；comptime 分派
const use_writev_for_body = builtin.os.tag != .windows;

/// 热路径 writeHttpResponseToBuffer 窄化错误集，利于跳转表与分支预测（01 §2.1）
pub const ResponseBufferError = error{
    BufferTooSmall,
    OutOfMemory,
};

/// sendfileToStream 窄化错误集（01 §2.1）；含 TLS 回退路径的 TlsWriteFailed
pub const SendfileStreamError = error{
    FileRead,
    SocketWrite,
    SendfileFailed,
    OutOfMemory,
    TlsWriteFailed,
};

/// writeHttpResponseFromFile 窄化错误集（01 §2.1）
pub const WriteResponseFromFileError = SendfileStreamError || error{
    NoProcessIo,
    FileNotFound,
    BadPath,
    BufferTooSmall,
};

/// writeHttpResponse / writeChunkedBody 窄化错误集（01 §2.1）；头缓冲与写出统一收口，利于热路径跳转表
pub const WriteResponseError = error{
    OutOfMemory,
    BufferTooSmall,
    NoProcessIo,
    SocketWrite,
};

// ------------------------------------------------------------------------------
// Date 头秒级缓存（RFC 7231 IMF-fixdate：Sun, 06 Nov 1994 08:49:37 GMT）
// ------------------------------------------------------------------------------

const WEEKDAY_NAMES = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const MONTH_NAMES = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

/// 星期序：1970-01-01 为周四，(day+4)%7 得 0=Thu,1=Fri,…,6=Wed；WEEKDAY_NAMES 为 [Sun,Mon,Tue,Wed,Thu,Fri,Sat]，故 (day+4)%7 对应 index 4,5,6,0,1,2,3
const WEEKDAY_INDEX: [7]usize = .{ 4, 5, 6, 0, 1, 2, 3 };

/// 将 epoch 秒转为 HTTP-date 写入 buf，返回有效切片；buf 至少 32 字节。使用 std.time.epoch 纯 Zig 实现，不依赖 libc gmtime
fn formatHttpDate(epoch_sec: i64, buf: *[64]u8) []const u8 {
    if (epoch_sec < 0) return buf[0..0];
    const secs = @as(u64, @intCast(epoch_sec));
    const epoch_seconds = epoch.EpochSeconds{ .secs = secs };
    const epoch_day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const wday = WEEKDAY_INDEX[(epoch_day.day + 4) % 7];
    const mon: usize = @intFromEnum(month_day.month) - 1; // Month 为 1..12
    const len = (std.fmt.bufPrint(buf, "{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        WEEKDAY_NAMES[wday],
        month_day.day_index + 1, // day_index 0-based
        MONTH_NAMES[mon],
        year_day.year,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch return buf[0..0]).len;
    return buf[0..len];
}

/// 秒级缓存：同一秒内多次调用返回同一切片，避免重复格式化
var date_cache_sec: i64 = -1;
var date_cache_buf: [64]u8 = undefined;
var date_cache_len: usize = 0;

/// 返回当前时间的 HTTP Date 头值（带秒级缓存）；用于响应头 "Date: {slice}\r\n"
fn getCachedDateHeader() []const u8 {
    const io = libs_process.getProcessIo() orelse return date_cache_buf[0..date_cache_len];
    const sec = @divTrunc(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds, std.time.ns_per_s);
    if (sec != date_cache_sec) {
        date_cache_sec = @as(i64, @intCast(sec));
        const slice = formatHttpDate(@as(i64, @intCast(sec)), &date_cache_buf);
        date_cache_len = slice.len;
        return slice;
    }
    return date_cache_buf[0..date_cache_len];
}

/// 默认 Server 头预编码（无自定义时使用，避免每请求拼接）
const DEFAULT_SERVER_HEADER = "Server: Shu\r\n";

/// 从 JS 响应对象读取 status，默认 200。00 §5.2 热路径内联。
pub inline fn getResponseStatus(ctx: jsc.JSContextRef, response_obj: jsc.JSValueRef) u16 {
    const k = jsc.JSStringCreateWithUTF8CString("status");
    defer jsc.JSStringRelease(k);
    const obj = @as(jsc.JSObjectRef, @ptrCast(response_obj));
    const v = jsc.JSObjectGetProperty(ctx, obj, k, null);
    const n = jsc.JSValueToNumber(ctx, v, null);
    if (n != n or n < 100 or n > 599) return 200;
    return @intFromFloat(n);
}

/// [Allocates] 或 [Borrows]：若 reuse_buf 够用则返回其切片（调用方勿 free）；否则从 allocator 分配，调用方负责 free。
/// 从 JS 响应对象读取单个头（如 "Content-Type"）。若提供 reuse_buf 且长度够用则写入其中并返回切片，否则从 allocator 分配
pub fn getResponseHeader(
    ctx: jsc.JSContextRef,
    allocator: std.mem.Allocator,
    response_obj: jsc.JSValueRef,
    name: [*]const u8,
    reuse_buf: ?[]u8,
) ?[]const u8 {
    const k_headers = jsc.JSStringCreateWithUTF8CString("headers");
    defer jsc.JSStringRelease(k_headers);
    const obj = @as(jsc.JSObjectRef, @ptrCast(response_obj));
    const headers_val = jsc.JSObjectGetProperty(ctx, obj, k_headers, null);
    if (jsc.JSValueToObject(ctx, headers_val, null) == null) return null;
    const k_name = jsc.JSStringCreateWithUTF8CString(name);
    defer jsc.JSStringRelease(k_name);
    const v = jsc.JSObjectGetProperty(ctx, @as(jsc.JSObjectRef, @ptrCast(headers_val)), k_name, null);
    if (jsc.JSValueIsUndefined(ctx, v)) return null;
    const js_str = jsc.JSValueToStringCopy(ctx, v, null);
    defer jsc.JSStringRelease(js_str);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(js_str);
    if (max_sz == 0 or max_sz > 1024) return null;
    const buf = if (reuse_buf != null and reuse_buf.?.len >= max_sz)
        reuse_buf.?
    else
        allocator.alloc(u8, max_sz) catch return null;
    const n = jsc.JSStringGetUTF8CString(js_str, buf.ptr, max_sz);
    if (n == 0) {
        if (reuse_buf == null or buf.ptr != reuse_buf.?.ptr) allocator.free(buf);
        return null;
    }
    return buf[0 .. n - 1];
}

/// [Allocates] 调用方负责 free 返回的切片。从 JS 响应对象读取 filePath（可选）。若存在则表示 body 由该文件零拷贝发送（sendfile）
pub fn getResponseFilePath(
    ctx: jsc.JSContextRef,
    allocator: std.mem.Allocator,
    response_obj: jsc.JSValueRef,
) ?[]const u8 {
    const k = jsc.JSStringCreateWithUTF8CString("filePath");
    defer jsc.JSStringRelease(k);
    const obj = @as(jsc.JSObjectRef, @ptrCast(response_obj));
    const v = jsc.JSObjectGetProperty(ctx, obj, k, null);
    if (jsc.JSValueIsUndefined(ctx, v)) return null;
    const js_str = jsc.JSValueToStringCopy(ctx, v, null);
    defer jsc.JSStringRelease(js_str);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(js_str);
    if (max_sz == 0 or max_sz > 4096) return null;
    const buf = allocator.alloc(u8, max_sz) catch return null;
    const n = jsc.JSStringGetUTF8CString(js_str, buf.ptr, max_sz);
    if (n == 0) {
        allocator.free(buf);
        return null;
    }
    return buf[0 .. n - 1];
}

/// [Allocates] 或 [Borrows]：若 reuse_buf 够用则返回其切片（勿 free）；否则从 allocator 分配，调用方负责 free。从 JS 响应对象读取 body 字符串。
pub fn getResponseBody(
    ctx: jsc.JSContextRef,
    allocator: std.mem.Allocator,
    response_obj: jsc.JSValueRef,
    reuse_buf: ?[]u8,
) ?[]const u8 {
    const k_body = jsc.JSStringCreateWithUTF8CString("body");
    defer jsc.JSStringRelease(k_body);
    const obj = @as(jsc.JSObjectRef, @ptrCast(response_obj));
    const v = jsc.JSObjectGetProperty(ctx, obj, k_body, null);
    if (jsc.JSValueIsUndefined(ctx, v)) return null;
    const js_str = jsc.JSValueToStringCopy(ctx, v, null);
    defer jsc.JSStringRelease(js_str);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(js_str);
    if (max_sz == 0) return null;
    const buf = if (reuse_buf != null and reuse_buf.?.len >= max_sz)
        reuse_buf.?
    else
        allocator.alloc(u8, max_sz) catch return null;
    const n = jsc.JSStringGetUTF8CString(js_str, buf.ptr, max_sz);
    if (n == 0) {
        if (reuse_buf == null or buf.ptr != reuse_buf.?.ptr) allocator.free(buf);
        return null;
    }
    return buf[0 .. n - 1];
}

/// 常用 status 对应短语（RFC 与常见用法）。00 §5.2 热路径内联。
pub inline fn statusPhrase(status: u16) []const u8 {
    return switch (status) {
        100 => "Continue",
        101 => "Switching Protocols",
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        303 => "See Other",
        304 => "Not Modified",
        307 => "Temporary Redirect",
        308 => "Permanent Redirect",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        409 => "Conflict",
        413 => "Payload Too Large",
        422 => "Unprocessable Entity",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        else => "Unknown",
    };
}

/// 零拷贝发送文件到 socket：stream 为 *std.Io.net.Stream 且平台支持时调用 libs_io.sendFile，否则回退为分块 read+write。0.16：支持 std.Io.File，需传入 io。
/// 回退路径 buffer 大小（无 sendfile 时 read+write 循环；规范 §1.2 禁止栈上 64KB）；00 §1.6 对齐分配
const SENDFILE_FALLBACK_BUF_SIZE = 64 * 1024;

/// 将文件内容写入 stream；支持 sendfile 时零拷贝，否则按块 read+write。file 可为 std.Io.File（0.16）或 std.fs.File；传 io 供 Io.File 与 stream.writer 使用。
// Hot-path
pub fn sendfileToStream(allocator: std.mem.Allocator, stream: anytype, file: anytype, file_size: u64, io: std.Io) SendfileStreamError!void {
    if (file_size == 0) return;
    if (@TypeOf(stream) == *std.Io.net.Stream and sendfile_platform_ok) {
        if (@TypeOf(file) == std.Io.File) {
            const fs_file = std.fs.File{ .handle = file.handle };
            libs_io.sendFile(stream.*, fs_file, 0, file_size) catch |e| {
                return switch (e) {
                    libs_io.SendFileError.FileRead => error.FileRead,
                    libs_io.SendFileError.SocketWrite => error.SocketWrite,
                    else => error.SendfileFailed,
                };
            };
            return;
        }
        libs_io.sendFile(stream.*, file, 0, file_size) catch |e| {
            return switch (e) {
                libs_io.SendFileError.FileRead => error.FileRead,
                libs_io.SendFileError.SocketWrite => error.SocketWrite,
                else => error.SendfileFailed,
            };
        };
        return;
    }
    if (@TypeOf(file) == std.Io.File) {
        var rbuf: [SENDFILE_FALLBACK_BUF_SIZE]u8 = undefined;
        var r = file.reader(io, &rbuf);
        if (@TypeOf(stream) == *std.Io.net.Stream) {
            var wbuf: [8192]u8 = undefined;
            var w = stream.writer(io, &wbuf);
            var remaining = file_size;
            while (remaining > 0) {
                const to_read = @min(rbuf.len, remaining);
                var dest = [1][]u8{rbuf[0..to_read]};
                const n = std.Io.Reader.readVec(&r.interface, &dest) catch return error.FileRead;
                if (n == 0) break;
                _ = std.Io.Writer.writeVec(&w.interface, &.{rbuf[0..n]}) catch return error.SocketWrite;
                try w.interface.flush();
                remaining -= n;
            }
        } else {
            var remaining = file_size;
            while (remaining > 0) {
                const to_read = @min(rbuf.len, remaining);
                var dest = [1][]u8{rbuf[0..to_read]};
                const n = std.Io.Reader.readVec(&r.interface, &dest) catch return error.FileRead;
                if (n == 0) break;
                try stream.writeAll(rbuf[0..n]);
                remaining -= n;
            }
        }
        return;
    }
    const buf = allocator.alignedAlloc(u8, .@"64", SENDFILE_FALLBACK_BUF_SIZE) catch return error.OutOfMemory;
    defer allocator.free(buf);
    var remaining = file_size;
    while (remaining > 0) {
        const to_read = @min(buf.len, remaining);
        const n = file.read(buf[0..to_read]) catch return error.FileRead;
        if (n == 0) break;
        var wbuf: [8192]u8 = undefined;
        var w = stream.writer(io, &wbuf);
        _ = std.Io.Writer.writeVec(&w.interface, &.{buf[0..n]}) catch return error.SocketWrite;
        try w.interface.flush();
        remaining -= n;
    }
}

/// 从文件路径写 HTTP 响应（零拷贝 body：POSIX 下用 sendfile）。不压缩；Content-Length 为文件大小。0.16：经 io_core 打开文件，file.close(io)。
// Hot-path
pub fn writeHttpResponseFromFile(
    allocator: std.mem.Allocator,
    stream: anytype,
    config: *const types.ServerConfig,
    status: u16,
    phrase: []const u8,
    content_type: ?[]const u8,
    path: []const u8,
    use_keep_alive: bool,
    header_buf: ?*std.ArrayListUnmanaged(u8),
) WriteResponseFromFileError!void {
    const io = libs_process.getProcessIo() orelse return error.NoProcessIo;
    const file = libs_io.openFileAbsolute(path, .{ .mode = .read_only }) catch blk: {
        var cwd_dir = libs_io.openDirCwd(".", .{}) catch {
            try writeHttpResponse(allocator, stream, config, 404, "Not Found", null, null, "Not Found", false, header_buf);
            return error.FileNotFound;
        };
        defer cwd_dir.close(io);
        break :blk cwd_dir.openFile(io, path, .{}) catch {
            try writeHttpResponse(allocator, stream, config, 404, "Not Found", null, null, "Not Found", false, header_buf);
            return error.FileNotFound;
        };
    };
    defer file.close(io);
    const stat = file.stat(io) catch return error.BadPath;
    if (stat.kind != .file) {
        try writeHttpResponse(allocator, stream, config, 400, "Bad Request", null, null, "Not a file", false, header_buf);
        return;
    }
    const file_size = stat.size;
    const list = if (header_buf) |buf| blk: {
        buf.clearRetainingCapacity();
        break :blk buf;
    } else blk: {
        var new_list = std.ArrayListUnmanaged(u8).initCapacity(allocator, 4096) catch return error.OutOfMemory;
        break :blk &new_list;
    };
    defer if (header_buf == null) list.deinit(allocator);
    // 0.16：与 writeHttpResponse 一致，用 bufPrint + ensureUnusedCapacity 拼装头
    var line_buf: [256]u8 = undefined;
    var part = std.fmt.bufPrint(&line_buf, "HTTP/1.1 {d} {s}\r\n", .{ status, phrase }) catch return error.BufferTooSmall;
    try list.ensureUnusedCapacity(allocator, part.len);
    list.appendSliceAssumeCapacity(part);
    if (content_type) |ct| {
        part = std.fmt.bufPrint(&line_buf, "Content-Type: {s}\r\n", .{ct}) catch return error.BufferTooSmall;
        try list.ensureUnusedCapacity(allocator, part.len);
        list.appendSliceAssumeCapacity(part);
    }
    part = std.fmt.bufPrint(&line_buf, "Content-Length: {d}\r\n", .{file_size}) catch return error.BufferTooSmall;
    try list.ensureUnusedCapacity(allocator, part.len);
    list.appendSliceAssumeCapacity(part);
    if (use_keep_alive and config.keep_alive_timeout_sec > 0) {
        part = std.fmt.bufPrint(&line_buf, "Connection: keep-alive\r\nKeep-Alive: timeout={d}\r\n\r\n", .{config.keep_alive_timeout_sec}) catch return error.BufferTooSmall;
        try list.ensureUnusedCapacity(allocator, part.len);
        list.appendSliceAssumeCapacity(part);
    } else if (use_keep_alive) {
        const ka = "Connection: keep-alive\r\n\r\n";
        try list.ensureUnusedCapacity(allocator, ka.len);
        list.appendSliceAssumeCapacity(ka);
    } else {
        const close_hdr = "Connection: close\r\n\r\n";
        try list.ensureUnusedCapacity(allocator, close_hdr.len);
        list.appendSliceAssumeCapacity(close_hdr);
    }
    if (@TypeOf(stream) == *std.Io.net.Stream) {
        var wbuf: [8192]u8 = undefined;
        var w = stream.writer(io, &wbuf);
        _ = std.Io.Writer.writeVec(&w.interface, &.{list.items}) catch return error.SocketWrite;
        w.interface.flush() catch return error.SocketWrite;
    } else {
        stream.writeAll(list.items) catch return error.SocketWrite;
    }
    try sendfileToStream(allocator, stream, file, file_size, io);
}

/// 写 HTTP 响应：状态行 + 可选 Content-Type / Content-Encoding + Connection + body
/// stream 需具备 writeAll()；非 chunked 且为 *std.net.Stream 时 POSIX 下用 writev 合并写头+body
// Hot-path
pub fn writeHttpResponse(
    allocator: std.mem.Allocator,
    stream: anytype,
    config: *const types.ServerConfig,
    status: u16,
    phrase: []const u8,
    content_type: ?[]const u8,
    content_encoding: ?[]const u8,
    body: []const u8,
    use_keep_alive: bool,
    header_buf: ?*std.ArrayListUnmanaged(u8),
) WriteResponseError!void {
    const list = if (header_buf) |buf| blk: {
        buf.clearRetainingCapacity();
        break :blk buf;
    } else blk: {
        var new_list = std.ArrayListUnmanaged(u8).initCapacity(allocator, 4096) catch return error.OutOfMemory;
        break :blk &new_list;
    };
    defer if (header_buf == null) list.deinit(allocator);
    // 0.16：ArrayListUnmanaged 用 bufPrint + ensureUnusedCapacity + appendSliceAssumeCapacity 拼装头；part 为 []u8，传 part.len 给 ensureUnusedCapacity
    var line_buf: [512]u8 = undefined;
    var part = std.fmt.bufPrint(&line_buf, "HTTP/1.1 {d} {s}\r\n", .{ status, phrase }) catch return error.BufferTooSmall;
    try list.ensureUnusedCapacity(allocator, part.len);
    list.appendSliceAssumeCapacity(part);
    part = std.fmt.bufPrint(&line_buf, "Date: {s}\r\n", .{getCachedDateHeader()}) catch return error.BufferTooSmall;
    try list.ensureUnusedCapacity(allocator, part.len);
    list.appendSliceAssumeCapacity(part);
    if (config.server_header) |v| {
        part = std.fmt.bufPrint(&line_buf, "Server: {s}\r\n", .{v}) catch return error.BufferTooSmall;
        try list.ensureUnusedCapacity(allocator, part.len);
        list.appendSliceAssumeCapacity(part);
    } else {
        try list.ensureUnusedCapacity(allocator, DEFAULT_SERVER_HEADER.len);
        list.appendSliceAssumeCapacity(DEFAULT_SERVER_HEADER);
    }
    if (content_type) |ct| {
        part = std.fmt.bufPrint(&line_buf, "Content-Type: {s}\r\n", .{ct}) catch return error.BufferTooSmall;
        try list.ensureUnusedCapacity(allocator, part.len);
        list.appendSliceAssumeCapacity(part);
    }
    if (content_encoding) |ce| {
        part = std.fmt.bufPrint(&line_buf, "Content-Encoding: {s}\r\n", .{ce}) catch return error.BufferTooSmall;
        try list.ensureUnusedCapacity(allocator, part.len);
        list.appendSliceAssumeCapacity(part);
    }
    const use_chunked = body.len > config.chunked_response_threshold;
    if (use_chunked) {
        const chunked_hdr = "Transfer-Encoding: chunked\r\n";
        try list.ensureUnusedCapacity(allocator, chunked_hdr.len);
        list.appendSliceAssumeCapacity(chunked_hdr);
    } else {
        part = std.fmt.bufPrint(&line_buf, "Content-Length: {d}\r\n", .{body.len}) catch return error.BufferTooSmall;
        try list.ensureUnusedCapacity(allocator, part.len);
        list.appendSliceAssumeCapacity(part);
    }
    if (use_keep_alive and config.keep_alive_timeout_sec > 0) {
        part = std.fmt.bufPrint(&line_buf, "Connection: keep-alive\r\nKeep-Alive: timeout={d}\r\n\r\n", .{config.keep_alive_timeout_sec}) catch return error.BufferTooSmall;
        try list.ensureUnusedCapacity(allocator, part.len);
        list.appendSliceAssumeCapacity(part);
    } else if (use_keep_alive) {
        const ka = "Connection: keep-alive\r\n\r\n";
        try list.ensureUnusedCapacity(allocator, ka.len);
        list.appendSliceAssumeCapacity(ka);
    } else {
        const close_hdr = "Connection: close\r\n\r\n";
        try list.ensureUnusedCapacity(allocator, close_hdr.len);
        list.appendSliceAssumeCapacity(close_hdr);
    }
    const is_net_stream = @TypeOf(stream) == *std.Io.net.Stream;
    if (!use_chunked and use_writev_for_body and is_net_stream) {
        const fd = stream.socket.handle;
        var iov = [2]std.posix.iovec_const{
            .{ .base = list.items.ptr, .len = list.items.len },
            .{ .base = body.ptr, .len = body.len },
        };
        const n_written_raw = std.c.writev(fd, iov[0..].ptr, @as(c_int, @intCast(iov.len)));
        if (n_written_raw < 0) {
            const process_io = libs_process.getProcessIo() orelse return error.NoProcessIo;
            var wbuf: [8192]u8 = undefined;
            var w = stream.writer(process_io, &wbuf);
            _ = std.Io.Writer.writeVec(&w.interface, &.{ list.items, body }) catch return error.SocketWrite;
            w.interface.flush() catch return error.SocketWrite;
            return;
        }
        const n_written = @as(usize, @intCast(n_written_raw));
        const total = list.items.len + body.len;
        if (n_written == total) return;
        if (n_written < list.items.len) {
            const process_io = libs_process.getProcessIo() orelse return error.NoProcessIo;
            var wbuf: [8192]u8 = undefined;
            var w = stream.writer(process_io, &wbuf);
            _ = std.Io.Writer.writeVec(&w.interface, &.{ list.items[n_written..], body }) catch return error.SocketWrite;
            w.interface.flush() catch return error.SocketWrite;
        } else if (n_written < total) {
            const process_io = libs_process.getProcessIo() orelse return error.NoProcessIo;
            var wbuf: [8192]u8 = undefined;
            var w = stream.writer(process_io, &wbuf);
            _ = std.Io.Writer.writeVec(&w.interface, &.{body[n_written - list.items.len ..]}) catch return error.SocketWrite;
            w.interface.flush() catch return error.SocketWrite;
        }
        return;
    }
    const process_io = libs_process.getProcessIo() orelse return error.NoProcessIo;
    if (is_net_stream) {
        var wbuf: [8192]u8 = undefined;
        var w = stream.writer(process_io, &wbuf);
        _ = std.Io.Writer.writeVec(&w.interface, &.{list.items}) catch return error.SocketWrite;
        w.interface.flush() catch return error.SocketWrite;
        if (use_chunked) {
            try writeChunkedBody(stream, body, config.chunked_write_chunk_size);
        } else {
            _ = std.Io.Writer.writeVec(&w.interface, &.{body}) catch return error.SocketWrite;
            w.interface.flush() catch return error.SocketWrite;
        }
    } else {
        stream.writeAll(list.items) catch return error.SocketWrite;
        if (use_chunked) {
            try writeChunkedBody(stream, body, config.chunked_write_chunk_size);
        } else {
            stream.writeAll(body) catch return error.SocketWrite;
        }
    }
}

/// 按 chunked 格式写 body：每块 hex(len)\r\n + 数据 + \r\n，结尾 0\r\n\r\n。0.16：*std.Io.net.Stream 用 writer+writeVec，其他类型用 writeAll。
pub fn writeChunkedBody(stream: anytype, body: []const u8, chunk_size: usize) WriteResponseError!void {
    const process_io = libs_process.getProcessIo() orelse return error.NoProcessIo;
    if (@TypeOf(stream) == *std.Io.net.Stream) {
        var wbuf: [256]u8 = undefined;
        var w = stream.writer(process_io, &wbuf);
        var pos: usize = 0;
        while (pos < body.len) {
            const take = @min(chunk_size, body.len - pos);
            const slice = body[pos .. pos + take];
            pos += take;
            var buf: [32]u8 = undefined;
            const hex_slice = std.fmt.bufPrint(&buf, "{x}\r\n", .{take}) catch buf[0..0];
            _ = std.Io.Writer.writeVec(&w.interface, &.{ hex_slice, slice, "\r\n" }) catch return error.SocketWrite;
            w.interface.flush() catch return error.SocketWrite;
        }
        _ = std.Io.Writer.writeVec(&w.interface, &.{"0\r\n\r\n"}) catch return error.SocketWrite;
        w.interface.flush() catch return error.SocketWrite;
        return;
    }
    var pos: usize = 0;
    while (pos < body.len) {
        const take = @min(chunk_size, body.len - pos);
        const slice = body[pos .. pos + take];
        pos += take;
        var buf: [32]u8 = undefined;
        const hex_slice = std.fmt.bufPrint(&buf, "{x}", .{take}) catch buf[0..0];
        stream.writeAll(hex_slice) catch return error.SocketWrite;
        stream.writeAll("\r\n") catch return error.SocketWrite;
        stream.writeAll(slice) catch return error.SocketWrite;
        stream.writeAll("\r\n") catch return error.SocketWrite;
    }
    stream.writeAll("0\r\n\r\n") catch return error.SocketWrite;
}

/// 将完整 HTTP 响应（状态行 + 头 + body）追加到 out，供 I/O 多路复用时先写入 buffer 再非阻塞写出。0.16：用 bufPrint + ensureUnusedCapacity + appendSliceAssumeCapacity；窄化错误集（ResponseBufferError）利于热路径跳转表（01 §2.1）
// Hot-path
pub fn writeHttpResponseToBuffer(
    allocator: std.mem.Allocator,
    config: *const types.ServerConfig,
    status: u16,
    phrase: []const u8,
    content_type: ?[]const u8,
    content_encoding: ?[]const u8,
    body: []const u8,
    use_keep_alive: bool,
    out: *std.ArrayListUnmanaged(u8),
) ResponseBufferError!void {
    var line_buf: [256]u8 = undefined;
    var part = std.fmt.bufPrint(&line_buf, "HTTP/1.1 {d} {s}\r\n", .{ status, phrase }) catch return error.BufferTooSmall;
    out.ensureUnusedCapacity(allocator, part.len) catch return error.OutOfMemory;
    out.appendSliceAssumeCapacity(part);
    part = std.fmt.bufPrint(&line_buf, "Date: {s}\r\n", .{getCachedDateHeader()}) catch return error.BufferTooSmall;
    out.ensureUnusedCapacity(allocator, part.len) catch return error.OutOfMemory;
    out.appendSliceAssumeCapacity(part);
    if (config.server_header) |v| {
        part = std.fmt.bufPrint(&line_buf, "Server: {s}\r\n", .{v}) catch return error.BufferTooSmall;
        out.ensureUnusedCapacity(allocator, part.len) catch return error.OutOfMemory;
        out.appendSliceAssumeCapacity(part);
    } else {
        out.ensureUnusedCapacity(allocator, DEFAULT_SERVER_HEADER.len) catch return error.OutOfMemory;
        out.appendSliceAssumeCapacity(DEFAULT_SERVER_HEADER);
    }
    if (content_type) |ct| {
        part = std.fmt.bufPrint(&line_buf, "Content-Type: {s}\r\n", .{ct}) catch return error.BufferTooSmall;
        out.ensureUnusedCapacity(allocator, part.len) catch return error.OutOfMemory;
        out.appendSliceAssumeCapacity(part);
    }
    if (content_encoding) |ce| {
        part = std.fmt.bufPrint(&line_buf, "Content-Encoding: {s}\r\n", .{ce}) catch return error.BufferTooSmall;
        out.ensureUnusedCapacity(allocator, part.len) catch return error.OutOfMemory;
        out.appendSliceAssumeCapacity(part);
    }
    const use_chunked = body.len > config.chunked_response_threshold;
    if (use_chunked) {
        out.appendSlice(allocator, "Transfer-Encoding: chunked\r\n") catch return error.OutOfMemory;
    } else {
        part = std.fmt.bufPrint(&line_buf, "Content-Length: {d}\r\n", .{body.len}) catch return error.BufferTooSmall;
        out.ensureUnusedCapacity(allocator, part.len) catch return error.OutOfMemory;
        out.appendSliceAssumeCapacity(part);
    }
    if (use_keep_alive and config.keep_alive_timeout_sec > 0) {
        part = std.fmt.bufPrint(&line_buf, "Connection: keep-alive\r\nKeep-Alive: timeout={d}\r\n\r\n", .{config.keep_alive_timeout_sec}) catch return error.BufferTooSmall;
        out.ensureUnusedCapacity(allocator, part.len) catch return error.OutOfMemory;
        out.appendSliceAssumeCapacity(part);
    } else if (use_keep_alive) {
        out.appendSlice(allocator, "Connection: keep-alive\r\n\r\n") catch return error.OutOfMemory;
    } else {
        out.appendSlice(allocator, "Connection: close\r\n\r\n") catch return error.OutOfMemory;
    }
    if (!use_chunked) {
        out.appendSlice(allocator, body) catch return error.OutOfMemory;
    } else {
        var pos: usize = 0;
        const chunk_size = config.chunked_write_chunk_size;
        while (pos < body.len) {
            const take = @min(chunk_size, body.len - pos);
            const slice = body[pos .. pos + take];
            pos += take;
            var buf: [32]u8 = undefined;
            const hex_slice = std.fmt.bufPrint(&buf, "{x}", .{take}) catch buf[0..0];
            out.appendSlice(allocator, hex_slice) catch return error.OutOfMemory;
            out.appendSlice(allocator, "\r\n") catch return error.OutOfMemory;
            out.appendSlice(allocator, slice) catch return error.OutOfMemory;
            out.appendSlice(allocator, "\r\n") catch return error.OutOfMemory;
        }
        out.appendSlice(allocator, "0\r\n\r\n") catch return error.OutOfMemory;
    }
}
