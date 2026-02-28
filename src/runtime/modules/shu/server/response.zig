// HTTP 响应构建与写出：statusPhrase、getResponse*、writeHttpResponse、sendfile 等
// 供 mod.zig / conn / h2 等调用；文件→网络零拷贝统一走 io_core.sendFile，避免与 io_core 重复实现
//
// 响应头优化：Date 按秒缓存，避免每请求格式化；Server 头支持 config.server_header 或默认 "Shu" 预编码写入。

const std = @import("std");
const jsc = @import("jsc");
const types = @import("types.zig");
const builtin = @import("builtin");
const io_core = @import("io_core");
const epoch = std.time.epoch;

/// 当前平台是否支持 io_core.sendFile（Linux/Darwin/BSD/Windows）；comptime 分派
const sendfile_platform_ok = builtin.os.tag == .linux or builtin.os.tag == .macos or builtin.os.tag == .freebsd or builtin.os.tag == .netbsd or builtin.os.tag == .openbsd or builtin.os.tag == .windows;
/// 是否用 writev 合并头+体（POSIX 有 writev，Windows 无）；comptime 分派
const use_writev_for_body = builtin.os.tag != .windows;

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
    const sec = std.time.timestamp();
    if (sec != date_cache_sec) {
        date_cache_sec = sec;
        const slice = formatHttpDate(sec, &date_cache_buf);
        date_cache_len = slice.len;
        return slice;
    }
    return date_cache_buf[0..date_cache_len];
}

/// 默认 Server 头预编码（无自定义时使用，避免每请求拼接）
const DEFAULT_SERVER_HEADER = "Server: Shu\r\n";

/// 从 JS 响应对象读取 status，默认 200
pub fn getResponseStatus(ctx: jsc.JSContextRef, response_obj: jsc.JSValueRef) u16 {
    const k = jsc.JSStringCreateWithUTF8CString("status");
    defer jsc.JSStringRelease(k);
    const obj = @as(jsc.JSObjectRef, @ptrCast(response_obj));
    const v = jsc.JSObjectGetProperty(ctx, obj, k, null);
    const n = jsc.JSValueToNumber(ctx, v, null);
    if (n != n or n < 100 or n > 599) return 200;
    return @intFromFloat(n);
}

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

/// 从 JS 响应对象读取 filePath（可选）。若存在则表示 body 由该文件零拷贝发送（sendfile）
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

/// 从 JS 响应对象读取 body 字符串。若提供 reuse_buf 且长度够用则写入其中并返回切片
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

/// 常用 status 对应短语（RFC 与常见用法）
pub fn statusPhrase(status: u16) []const u8 {
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

/// 零拷贝发送文件到 socket：stream 为 *std.net.Stream 且平台在 io_core 支持范围内时调用 io_core.sendFile（含 Windows TransmitFile），否则回退为分块 read+write
/// 回退路径 buffer 大小（无 sendfile 时 read+write 循环；规范 §1.2 禁止栈上 64KB）
const SENDFILE_FALLBACK_BUF_SIZE = 64 * 1024;

/// 将文件内容写入 stream；支持 sendfile 的平台零拷贝，否则按块 read+write。allocator 用于回退路径的块 buffer，调用方负责传入。
pub fn sendfileToStream(allocator: std.mem.Allocator, stream: anytype, file: std.fs.File, file_size: u64) !void {
    if (file_size == 0) return;
    if (@TypeOf(stream) == *std.net.Stream and sendfile_platform_ok) {
        io_core.sendFile(stream.*, file, 0, file_size) catch |e| {
            return switch (e) {
                io_core.SendFileError.FileRead => error.FileRead,
                io_core.SendFileError.SocketWrite => error.SocketWrite,
                else => error.SendfileFailed,
            };
        };
        return;
    }
    const buf = allocator.alloc(u8, SENDFILE_FALLBACK_BUF_SIZE) catch return error.OutOfMemory;
    defer allocator.free(buf);
    var remaining = file_size;
    while (remaining > 0) {
        const to_read = @min(buf.len, remaining);
        const n = file.read(buf[0..to_read]) catch return error.FileRead;
        if (n == 0) break;
        try stream.writeAll(buf[0..n]);
        remaining -= n;
    }
}

/// 从文件路径写 HTTP 响应（零拷贝 body：POSIX 下用 sendfile）。不压缩；Content-Length 为文件大小。
pub fn writeHttpResponseFromFile(
    allocator: std.mem.Allocator,
    stream: anytype,
    config: *const types.ServerConfig,
    status: u16,
    phrase: []const u8,
    content_type: ?[]const u8,
    path: []const u8,
    use_keep_alive: bool,
    header_buf: ?*std.ArrayList(u8),
) !void {
    const file = std.fs.openFileAbsolute(path, .{}) catch blk: {
        break :blk std.fs.cwd().openFile(path, .{}) catch {
            try writeHttpResponse(allocator, stream, config, 404, "Not Found", null, null, "Not Found", false, header_buf);
            return error.FileNotFound;
        };
    };
    defer file.close();
    const stat = file.stat() catch return error.BadPath;
    if (stat.kind != .file) {
        try writeHttpResponse(allocator, stream, config, 400, "Bad Request", null, null, "Not a file", false, header_buf);
        return;
    }
    const file_size = stat.size;
    const list = if (header_buf) |buf| blk: {
        buf.clearRetainingCapacity();
        break :blk buf;
    } else blk: {
        var new_list = std.ArrayList(u8).initCapacity(allocator, 4096) catch return error.OutOfMemory;
        break :blk &new_list;
    };
    defer if (header_buf == null) list.deinit(allocator);
    const w = list.writer(allocator);
    try w.print("HTTP/1.1 {d} {s}\r\n", .{ status, phrase });
    if (content_type) |ct| try w.print("Content-Type: {s}\r\n", .{ct});
    try w.print("Content-Length: {d}\r\n", .{file_size});
    if (use_keep_alive and config.keep_alive_timeout_sec > 0) {
        try w.print("Connection: keep-alive\r\nKeep-Alive: timeout={d}\r\n\r\n", .{config.keep_alive_timeout_sec});
    } else if (use_keep_alive) {
        try w.writeAll("Connection: keep-alive\r\n\r\n");
    } else {
        try w.writeAll("Connection: close\r\n\r\n");
    }
    try stream.writeAll(list.items);
    try sendfileToStream(allocator, stream, file, file_size);
}

/// 写 HTTP 响应：状态行 + 可选 Content-Type / Content-Encoding + Connection + body
/// stream 需具备 writeAll()；非 chunked 且为 *std.net.Stream 时 POSIX 下用 writev 合并写头+body
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
    header_buf: ?*std.ArrayList(u8),
) !void {
    const list = if (header_buf) |buf| blk: {
        buf.clearRetainingCapacity();
        break :blk buf;
    } else blk: {
        var new_list = std.ArrayList(u8).initCapacity(allocator, 4096) catch return error.OutOfMemory;
        break :blk &new_list;
    };
    defer if (header_buf == null) list.deinit(allocator);
    const w = list.writer(allocator);
    try w.print("HTTP/1.1 {d} {s}\r\n", .{ status, phrase });
    try w.print("Date: {s}\r\n", .{getCachedDateHeader()});
    if (config.server_header) |v| try w.print("Server: {s}\r\n", .{v}) else try w.writeAll(DEFAULT_SERVER_HEADER);
    if (content_type) |ct| {
        try w.print("Content-Type: {s}\r\n", .{ct});
    }
    if (content_encoding) |ce| {
        try w.print("Content-Encoding: {s}\r\n", .{ce});
    }
    const use_chunked = body.len > config.chunked_response_threshold;
    if (use_chunked) {
        try w.writeAll("Transfer-Encoding: chunked\r\n");
    } else {
        try w.print("Content-Length: {d}\r\n", .{body.len});
    }
    if (use_keep_alive and config.keep_alive_timeout_sec > 0) {
        try w.print("Connection: keep-alive\r\nKeep-Alive: timeout={d}\r\n\r\n", .{config.keep_alive_timeout_sec});
    } else if (use_keep_alive) {
        try w.writeAll("Connection: keep-alive\r\n\r\n");
    } else {
        try w.writeAll("Connection: close\r\n\r\n");
    }
    if (!use_chunked and use_writev_for_body and @TypeOf(stream) == *std.net.Stream) {
        const fd = stream.handle;
        var iov = [2]std.posix.iovec_const{
            .{ .base = list.items.ptr, .len = list.items.len },
            .{ .base = body.ptr, .len = body.len },
        };
        const n = std.posix.writev(fd, iov[0..]) catch {
            try stream.writeAll(list.items);
            try stream.writeAll(body);
            return;
        };
        const total = list.items.len + body.len;
        if (n == total) return;
        if (n < list.items.len) {
            try stream.writeAll(list.items[n..]);
            try stream.writeAll(body);
        } else if (n < total) {
            try stream.writeAll(body[n - list.items.len ..]);
        }
        return;
    }
    try stream.writeAll(list.items);
    if (use_chunked) {
        try writeChunkedBody(stream, body, config.chunked_write_chunk_size);
    } else {
        try stream.writeAll(body);
    }
}

/// 按 chunked 格式写 body：每块 hex(len)\r\n + 数据 + \r\n，结尾 0\r\n\r\n
pub fn writeChunkedBody(stream: anytype, body: []const u8, chunk_size: usize) !void {
    var pos: usize = 0;
    while (pos < body.len) {
        const take = @min(chunk_size, body.len - pos);
        const slice = body[pos .. pos + take];
        pos += take;
        var buf: [32]u8 = undefined;
        const hex_slice = std.fmt.bufPrint(&buf, "{x}", .{take}) catch buf[0..0];
        try stream.writeAll(hex_slice);
        try stream.writeAll("\r\n");
        try stream.writeAll(slice);
        try stream.writeAll("\r\n");
    }
    try stream.writeAll("0\r\n\r\n");
}

/// 将完整 HTTP 响应（状态行 + 头 + body）追加到 out，供 I/O 多路复用时先写入 buffer 再非阻塞写出
pub fn writeHttpResponseToBuffer(
    allocator: std.mem.Allocator,
    config: *const types.ServerConfig,
    status: u16,
    phrase: []const u8,
    content_type: ?[]const u8,
    content_encoding: ?[]const u8,
    body: []const u8,
    use_keep_alive: bool,
    out: *std.ArrayList(u8),
) !void {
    const w = out.writer(allocator);
    try w.print("HTTP/1.1 {d} {s}\r\n", .{ status, phrase });
    try w.print("Date: {s}\r\n", .{getCachedDateHeader()});
    if (config.server_header) |v| try w.print("Server: {s}\r\n", .{v}) else try w.writeAll(DEFAULT_SERVER_HEADER);
    if (content_type) |ct| try w.print("Content-Type: {s}\r\n", .{ct});
    if (content_encoding) |ce| try w.print("Content-Encoding: {s}\r\n", .{ce});
    const use_chunked = body.len > config.chunked_response_threshold;
    if (use_chunked) {
        try w.writeAll("Transfer-Encoding: chunked\r\n");
    } else {
        try w.print("Content-Length: {d}\r\n", .{body.len});
    }
    if (use_keep_alive and config.keep_alive_timeout_sec > 0) {
        try w.print("Connection: keep-alive\r\nKeep-Alive: timeout={d}\r\n\r\n", .{config.keep_alive_timeout_sec});
    } else if (use_keep_alive) {
        try w.writeAll("Connection: keep-alive\r\n\r\n");
    } else {
        try w.writeAll("Connection: close\r\n\r\n");
    }
    if (!use_chunked) {
        try out.appendSlice(allocator, body);
    } else {
        var pos: usize = 0;
        const chunk_size = config.chunked_write_chunk_size;
        while (pos < body.len) {
            const take = @min(chunk_size, body.len - pos);
            const slice = body[pos .. pos + take];
            pos += take;
            var buf: [32]u8 = undefined;
            const hex_slice = std.fmt.bufPrint(&buf, "{x}", .{take}) catch buf[0..0];
            try out.appendSlice(allocator, hex_slice);
            try out.appendSlice(allocator, "\r\n");
            try out.appendSlice(allocator, slice);
            try out.appendSlice(allocator, "\r\n");
        }
        try out.appendSlice(allocator, "0\r\n\r\n");
    }
}
