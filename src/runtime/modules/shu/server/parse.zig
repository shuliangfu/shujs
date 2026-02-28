// HTTP 请求解析：getHeader、parseHttpRequest、chunked、tryParseHeadersFromBuffer 等
// 供 mod.zig / conn / h2 等调用；与 io_core.simd_scan 统一：头部边界查找使用 simd_scan.indexOfCrLfCrLf

const std = @import("std");
const types = @import("types.zig");
const io_core = @import("io_core");

// ------------------------------------------------------------------------------
// 热路径头值匹配用 comptime 常量（§2.1 固定串比较）
// ------------------------------------------------------------------------------
const CANDIDATE_CLOSE: []const u8 = "close";
const CANDIDATE_BR: []const u8 = "br";
const CANDIDATE_GZIP: []const u8 = "gzip";
const CANDIDATE_DEFLATE: []const u8 = "deflate";
const CANDIDATE_CHUNKED: []const u8 = "chunked";

/// 已知头名单次扫描：在 head 中找 "\r\n" + name（不区分大小写） + ": "，返回冒号后的值切片；无 splitScalar（§2.1 快路径）
fn getHeaderByKnownName(head: []const u8, name: []const u8) ?[]const u8 {
    const prefix_len = 2 + name.len + 2; // "\r\n" + name + ": "
    var i: usize = 0;
    while (i + prefix_len <= head.len) {
        if (head[i] == '\r' and head[i + 1] == '\n' and std.ascii.eqlIgnoreCase(head[i + 2 .. i + 2 + name.len], name) and head[i + 2 + name.len] == ':' and head[i + 2 + name.len + 1] == ' ') {
            var end = i + prefix_len;
            while (end < head.len and head[end] != '\r' and head[end] != '\n') end += 1;
            return std.mem.trim(u8, head[i + prefix_len .. end], " \t\r");
        }
        i += 1;
    }
    return null;
}

/// 在原始头部块 head 上按名查找头值（不区分大小写），返回指向 head 内的切片，零拷贝；首行可为请求行（无 ": " 则跳过）
/// 热路径常用头名走单次扫描快路径（§2.1）
pub fn getHeader(head: []const u8, name: []const u8) ?[]const u8 {
    switch (name.len) {
        7 => if (std.mem.eql(u8, name, "upgrade")) return getHeaderByKnownName(head, "upgrade"),
        10 => if (std.mem.eql(u8, name, "connection")) return getHeaderByKnownName(head, "connection"),
        14 => if (std.mem.eql(u8, name, "content-length")) return getHeaderByKnownName(head, "content-length"),
        16 => if (std.mem.eql(u8, name, "accept-encoding")) return getHeaderByKnownName(head, "accept-encoding"),
        17 => if (std.mem.eql(u8, name, "transfer-encoding")) return getHeaderByKnownName(head, "transfer-encoding"),
        18 => if (std.mem.eql(u8, name, "sec-websocket-key")) return getHeaderByKnownName(head, "sec-websocket-key"),
        20 => if (std.mem.eql(u8, name, "sec-websocket-accept")) return getHeaderByKnownName(head, "sec-websocket-accept"),
        else => {},
    }
    var line_it = std.mem.splitScalar(u8, head, '\n');
    while (line_it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, "\r");
        if (trimmed.len == 0) continue;
        const colon = std.mem.indexOf(u8, trimmed, ": ") orelse continue;
        const key = std.mem.trim(u8, trimmed[0..colon], " \t");
        if (key.len != name.len) continue;
        var j: usize = 0;
        while (j < key.len) : (j += 1) {
            const c = key[j];
            const n = name[j];
            if (c >= 'A' and c <= 'Z') {
                if (c + 32 != n) break;
            } else if (n >= 'A' and n <= 'Z') {
                if (c != n + 32) break;
            } else if (c != n) break;
        } else {
            return std.mem.trim(u8, trimmed[colon + 2 ..], " \t\r");
        }
    }
    return null;
}

/// 逐行遍历原始头部块，跳过首行（请求行），每行按 ": " 拆成 name/value；供 request_js 等复用，与 getHeader 解析策略统一（§2.1）
pub fn iterHeaderLines(head: []const u8) struct {
    pos: usize = 0,
    head: []const u8,
    pub fn next(self: *@This()) ?struct { name: []const u8, value: []const u8 } {
        if (self.pos >= self.head.len) return null;
        const line_end = std.mem.indexOfScalarPos(u8, self.head, self.pos, '\n') orelse self.head.len;
        const line = self.head[self.pos..line_end];
        self.pos = if (line_end < self.head.len) line_end + 1 else self.head.len;
        const trimmed = std.mem.trim(u8, line, "\r");
        if (trimmed.len == 0) return self.next();
        const colon = std.mem.indexOf(u8, trimmed, ": ") orelse return self.next();
        const name = std.mem.trim(u8, trimmed[0..colon], " \t");
        const value = std.mem.trim(u8, trimmed[colon + 2 ..], " \t\r");
        return .{ .name = name, .value = value };
    }
} {
    return .{ .head = head };
}

/// 判断请求头是否要求关闭连接：Connection 值中包含 "close"（不区分大小写）即视为关闭；使用 comptime 常量长度
pub fn clientWantsClose(parsed: *const types.ParsedRequest) bool {
    const v = getHeader(parsed.headers_head, "connection") orelse return false;
    if (v.len < CANDIDATE_CLOSE.len) return false;
    var i: usize = 0;
    while (i <= v.len - CANDIDATE_CLOSE.len) {
        if (std.ascii.eqlIgnoreCase(v[i .. i + CANDIDATE_CLOSE.len], CANDIDATE_CLOSE)) return true;
        i += 1;
    }
    return false;
}

/// 按优先级选出的压缩方式：br > gzip > deflate，一次解析 Accept-Encoding；使用 comptime 常量匹配
pub fn chooseAcceptEncoding(parsed: *const types.ParsedRequest) enum { br, gzip, deflate, none } {
    const v = getHeader(parsed.headers_head, "accept-encoding") orelse return .none;
    if (v.len < CANDIDATE_BR.len) return .none;
    var i: usize = 0;
    while (i < v.len) {
        while (i < v.len and (v[i] == ' ' or v[i] == ',' or v[i] == ';')) i += 1;
        if (i >= v.len) break;
        if (i <= v.len - CANDIDATE_BR.len and std.ascii.eqlIgnoreCase(v[i .. i + CANDIDATE_BR.len], CANDIDATE_BR)) return .br;
        if (i <= v.len - CANDIDATE_GZIP.len and std.ascii.eqlIgnoreCase(v[i .. i + CANDIDATE_GZIP.len], CANDIDATE_GZIP)) return .gzip;
        if (i <= v.len - CANDIDATE_DEFLATE.len and std.ascii.eqlIgnoreCase(v[i .. i + CANDIDATE_DEFLATE.len], CANDIDATE_DEFLATE)) {
            if (i + CANDIDATE_DEFLATE.len >= v.len or v[i + CANDIDATE_DEFLATE.len] == ' ' or v[i + CANDIDATE_DEFLATE.len] == ',' or v[i + CANDIDATE_DEFLATE.len] == ';' or v[i + CANDIDATE_DEFLATE.len] == '\t')
                return .deflate;
        }
        while (i < v.len and v[i] != ',' and v[i] != ';') i += 1;
    }
    return .none;
}

/// Transfer-Encoding 头是否包含 chunked（不区分大小写；用于请求体解析）；使用 comptime 常量
pub fn transferEncodingChunked(header_value: []const u8) bool {
    if (header_value.len < CANDIDATE_CHUNKED.len) return false;
    var i: usize = 0;
    while (i <= header_value.len - CANDIDATE_CHUNKED.len) {
        if (std.ascii.eqlIgnoreCase(header_value[i .. i + CANDIDATE_CHUNKED.len], CANDIDATE_CHUNKED)) return true;
        i += 1;
    }
    return false;
}

/// 从 buf 增量解析 chunked body，结果追加到 body_out；max_body 为 body 总长上限
/// 返回 null 表示需要更多数据；返回 .{ consumed, done } 表示本轮消费的字节数及是否解析完（含 trailer）
pub fn parseChunkedIncremental(
    buf: []const u8,
    body_out: *std.ArrayList(u8),
    max_body: usize,
    allocator: std.mem.Allocator,
    state: *types.ChunkedParseState,
) !?struct { consumed: usize, done: bool } {
    var pos: usize = 0;
    while (pos < buf.len) {
        switch (state.*) {
            .reading_size_line => {
                const line_end = std.mem.indexOfScalar(u8, buf[pos..], '\n') orelse return null;
                const line = buf[pos..][0 .. line_end + 1];
                pos += line.len;
                var line_trim = line;
                if (line_trim.len >= 1 and line_trim[line_trim.len - 1] == '\n') line_trim = line_trim[0 .. line_trim.len - 1];
                if (line_trim.len >= 1 and line_trim[line_trim.len - 1] == '\r') line_trim = line_trim[0 .. line_trim.len - 1];
                const chunk_size_str = if (std.mem.indexOf(u8, line_trim, ";")) |semi| line_trim[0..semi] else line_trim;
                const chunk_size = std.fmt.parseInt(usize, std.mem.trim(u8, chunk_size_str, " \t"), 16) catch return error.InvalidRequest;
                if (chunk_size == 0) {
                    var trailer_end = pos;
                    while (trailer_end < buf.len) {
                        const idx = std.mem.indexOfScalar(u8, buf[trailer_end..], '\n') orelse return null;
                        trailer_end += idx + 1;
                        if (idx == 0 or (idx == 1 and buf[trailer_end - 2] == '\r')) break;
                    }
                    return .{ .consumed = trailer_end, .done = true };
                }
                if (body_out.items.len + chunk_size > max_body) return error.RequestEntityTooLarge;
                state.* = .{ .reading_chunk_data = chunk_size };
            },
            .reading_chunk_data => |remaining| {
                const avail = buf.len - pos;
                if (avail < remaining) {
                    const take = avail;
                    body_out.appendSlice(allocator, buf[pos..][0..take]) catch return error.OutOfMemory;
                    state.* = .{ .reading_chunk_data = remaining - take };
                    return .{ .consumed = pos + take, .done = false };
                }
                body_out.appendSlice(allocator, buf[pos..][0..remaining]) catch return error.OutOfMemory;
                pos += remaining;
                if (pos + 2 > buf.len) return .{ .consumed = pos, .done = false };
                if (buf[pos] != '\r' or buf[pos + 1] != '\n') return error.InvalidRequest;
                pos += 2;
                state.* = .reading_size_line;
            },
        }
    }
    return null;
}

/// 从流中按 Transfer-Encoding: chunked 格式读取 body，返回组装后的 body（上限 max_body，由 options.maxRequestBodySize 配置）
pub fn readChunkedBody(
    allocator: std.mem.Allocator,
    reader: anytype,
    read_buf: []u8,
    body_start: usize,
    total_read: usize,
    max_body: usize,
) ![]const u8 {
    var result = std.ArrayList(u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
    errdefer result.deinit(allocator);
    var pos = body_start;
    var end = total_read;

    while (true) {
        var line_buf: [128]u8 = undefined;
        var line_len: usize = 0;
        while (line_len < line_buf.len) {
            if (pos >= end) {
                const n = reader.read(read_buf) catch return error.ConnectionClosed;
                end = n;
                pos = 0;
                if (n == 0) return error.InvalidRequest;
            }
            const b = read_buf[pos];
            pos += 1;
            if (b == '\n') {
                if (line_len > 0 and line_buf[line_len - 1] == '\r') line_len -= 1;
                break;
            }
            line_buf[line_len] = b;
            line_len += 1;
        }
        const line = line_buf[0..line_len];
        var chunk_size_str = line;
        if (std.mem.indexOf(u8, line, ";")) |semi| chunk_size_str = line[0..semi];
        const chunk_size = std.fmt.parseInt(usize, std.mem.trim(u8, chunk_size_str, " \t"), 16) catch return error.InvalidRequest;
        if (chunk_size == 0) {
            var empty_line = true;
            while (true) {
                if (pos >= end) {
                    const n = reader.read(read_buf) catch return error.ConnectionClosed;
                    end = n;
                    pos = 0;
                    if (n == 0) break;
                }
                const b = read_buf[pos];
                pos += 1;
                if (b == '\n') {
                    if (empty_line) break;
                    empty_line = true;
                } else if (b != '\r') {
                    empty_line = false;
                }
            }
            break;
        }
        if (result.items.len + chunk_size > max_body) return error.RequestEntityTooLarge;
        var to_read = chunk_size;
        while (to_read > 0) {
            if (pos >= end) {
                const n = reader.read(read_buf) catch return error.ConnectionClosed;
                end = n;
                pos = 0;
                if (n == 0) return error.InvalidRequest;
            }
            const avail = end - pos;
            const take = @min(avail, to_read);
            result.appendSlice(allocator, read_buf[pos .. pos + take]) catch return error.OutOfMemory;
            pos += take;
            to_read -= take;
        }
        if (pos >= end) {
            const n = reader.read(read_buf) catch return error.ConnectionClosed;
            end = n;
            pos = 0;
        }
        if (end >= 2 and pos + 2 <= end and read_buf[pos] == '\r' and read_buf[pos + 1] == '\n') {
            pos += 2;
        }
    }
    return result.toOwnedSlice(allocator);
}

/// 在 buf 中查找 "\r\n\r\n" 的偏移；统一使用 io_core.simd_scan 的向量化实现，与路线图「协议解析 SIMD 统一」一致
pub fn indexOfCrLfCrLf(buf: []const u8) ?usize {
    return io_core.simd_scan.indexOfCrLfCrLf(buf);
}

/// 仅从已有 buffer 解析请求头（不读 body）；用于 I/O 多路复用：若尚未出现 \r\n\r\n 则返回 NeedMore；会 dupe 头部到 request_allocator
pub fn tryParseHeadersFromBuffer(
    request_allocator: std.mem.Allocator,
    read_buf: []const u8,
    config: *const types.ServerConfig,
) error{ NeedMore, BadRequest, InvalidRequest, OutOfMemory }!struct { parsed: types.ParsedRequest, body_start: usize } {
    const idx = indexOfCrLfCrLf(read_buf) orelse return error.NeedMore;
    const head_only = read_buf[0..idx];
    if (head_only.len > config.max_request_line) return error.BadRequest;
    const head_owned = request_allocator.dupe(u8, head_only) catch return error.OutOfMemory;
    var line_it = std.mem.splitScalar(u8, head_owned, '\n');
    const first_line = line_it.next() orelse return error.InvalidRequest;
    const first_trim = std.mem.trim(u8, first_line, "\r");
    if (first_trim.len > config.max_request_line) return error.BadRequest;
    var first_words = std.mem.splitScalar(u8, first_trim, ' ');
    const method = first_words.next() orelse return error.InvalidRequest;
    const path = first_words.next() orelse return error.InvalidRequest;
    _ = first_words.next();
    return .{
        .parsed = .{ .method = method, .path = path, .headers_head = head_owned, .body = null },
        .body_start = idx + 4,
    };
}

/// 零拷贝版：从 read_buf 解析请求头，parsed.method / .path / .headers_head 均指向 read_buf 内切片，不做 dupe；调用方须保证 read_buf 在 parsed 使用期间有效（如至下一次 pollCompletions）
pub fn tryParseHeadersFromBufferZeroCopy(
    read_buf: []const u8,
    config: *const types.ServerConfig,
) error{ NeedMore, BadRequest, InvalidRequest }!struct { parsed: types.ParsedRequest, body_start: usize } {
    const idx = indexOfCrLfCrLf(read_buf) orelse return error.NeedMore;
    const head_only = read_buf[0..idx];
    if (head_only.len > config.max_request_line) return error.BadRequest;
    var line_it = std.mem.splitScalar(u8, head_only, '\n');
    const first_line = line_it.next() orelse return error.InvalidRequest;
    const first_trim = std.mem.trim(u8, first_line, "\r");
    if (first_trim.len > config.max_request_line) return error.BadRequest;
    var first_words = std.mem.splitScalar(u8, first_trim, ' ');
    const method = first_words.next() orelse return error.InvalidRequest;
    const path = first_words.next() orelse return error.InvalidRequest;
    _ = first_words.next();
    return .{
        .parsed = .{ .method = method, .path = path, .headers_head = head_only, .body = null },
        .body_start = idx + 4,
    };
}

/// 从流中读取并解析 HTTP 请求（请求行 + 头 + 可选 body）
/// 使用 read_buf 复用连接内读缓冲；头部零拷贝（method/path/headers_head 指向 read_buf），body 用 request_allocator；调用方须在下次覆盖 read_buf 前完成对 parsed 的使用。
pub fn parseHttpRequest(
    request_allocator: std.mem.Allocator,
    reader: anytype,
    read_buf: []u8,
    config: *const types.ServerConfig,
) !types.ParsedRequest {
    var total_read: usize = 0;
    const max = read_buf.len;

    while (total_read < max) {
        const n = reader.read(read_buf[total_read..]) catch return error.ConnectionClosed;
        if (n == 0) break;
        total_read += n;
        if (std.mem.indexOf(u8, read_buf[0..total_read], "\r\n\r\n")) |_| break;
    }
    const head_slice = read_buf[0..total_read];
    const zero_copy_result = tryParseHeadersFromBufferZeroCopy(head_slice, config) catch |e| {
        return switch (e) {
            error.NeedMore => error.InvalidRequest,
            error.BadRequest => error.BadRequest,
            error.InvalidRequest => error.InvalidRequest,
        };
    };
    const parsed = zero_copy_result.parsed;
    const body_start = zero_copy_result.body_start;

    var body: ?[]const u8 = null;
    const te_val = getHeader(parsed.headers_head, "transfer-encoding");
    const is_chunked = if (te_val) |v| transferEncodingChunked(v) else false;
    const content_length_val = getHeader(parsed.headers_head, "content-length");
    if (is_chunked) {
        body = readChunkedBody(request_allocator, reader, read_buf, body_start, total_read, config.max_request_body) catch |e| {
            if (e == error.RequestEntityTooLarge) return error.RequestEntityTooLarge;
            if (e == error.InvalidRequest) return error.BadRequest;
            return e;
        };
    } else if (content_length_val != null and body_start < total_read) {
        const cl_str = content_length_val.?;
        const cl = std.fmt.parseInt(usize, std.mem.trim(u8, cl_str, " \t"), 10) catch return error.BadRequest;
        if (cl > config.max_request_body) return error.RequestEntityTooLarge;
        if (cl > 0) {
            var body_buf = request_allocator.alloc(u8, cl) catch return error.OutOfMemory;
            const already = total_read - body_start;
            if (already >= cl) {
                @memcpy(body_buf[0..cl], read_buf[body_start..][0..cl]);
                body = body_buf;
            } else {
                @memcpy(body_buf[0..already], read_buf[body_start..]);
            }
            var to_read = if (already >= cl) 0 else cl - already;
            var written = already;
            while (to_read > 0) {
                const nr = reader.read(body_buf[written..]) catch break;
                if (nr == 0) break;
                written += nr;
                to_read -= nr;
            }
            if (written == cl) body = body_buf else request_allocator.free(body_buf);
        }
    } else if (content_length_val != null) {
        const cl_str = content_length_val.?;
        const cl = std.fmt.parseInt(usize, std.mem.trim(u8, cl_str, " \t"), 10) catch return error.BadRequest;
        if (cl > config.max_request_body) return error.RequestEntityTooLarge;
        if (cl > 0) {
            var body_buf = request_allocator.alloc(u8, cl) catch return error.OutOfMemory;
            var written: usize = 0;
            while (written < cl) {
                const nr = reader.read(body_buf[written..]) catch break;
                if (nr == 0) break;
                written += nr;
            }
            if (written == cl) body = body_buf else request_allocator.free(body_buf);
        }
    }

    return .{
        .method = parsed.method,
        .path = parsed.path,
        .headers_head = parsed.headers_head,
        .body = body,
    };
}

/// §5 从整块数据解析 HTTP 请求（请求行 + 头 + 可选 body），供上层已一次提供整块请求数据时使用，避免多次 reader.read。
/// data 须包含完整头部（含 \r\n\r\n）；若有 Content-Length，body 为零拷贝切片 data[body_start..][0..cl]，调用方须在 parsed 使用期间保持 data 有效。
/// 不支持 Transfer-Encoding: chunked（返回 ChunkedNotSupportedForSlice，调用方请用 parseHttpRequest 流式解析）。
pub fn parseHttpRequestFromSlice(
    request_allocator: std.mem.Allocator,
    data: []const u8,
    config: *const types.ServerConfig,
) error{ NeedMore, BadRequest, InvalidRequest, RequestEntityTooLarge, ChunkedNotSupportedForSlice }!types.ParsedRequest {
    const zero_copy_result = tryParseHeadersFromBufferZeroCopy(data, config) catch |e| {
        return switch (e) {
            error.NeedMore => error.NeedMore,
            error.BadRequest => error.BadRequest,
            error.InvalidRequest => error.InvalidRequest,
        };
    };
    const parsed = zero_copy_result.parsed;
    const body_start = zero_copy_result.body_start;

    const te_val = getHeader(parsed.headers_head, "transfer-encoding");
    const is_chunked = if (te_val) |v| transferEncodingChunked(v) else false;
    if (is_chunked) return error.ChunkedNotSupportedForSlice;

    const content_length_val = getHeader(parsed.headers_head, "content-length");
    var body: ?[]const u8 = null;
    if (content_length_val) |cl_str| {
        const cl = std.fmt.parseInt(usize, std.mem.trim(u8, cl_str, " \t"), 10) catch return error.BadRequest;
        if (cl > config.max_request_body) return error.RequestEntityTooLarge;
        if (cl > 0) {
            const available = if (body_start <= data.len) data.len - body_start else 0;
            if (available < cl) return error.NeedMore;
            body = data[body_start..][0..cl];
        }
    }

    _ = request_allocator;
    return .{
        .method = parsed.method,
        .path = parsed.path,
        .headers_head = parsed.headers_head,
        .body = body,
    };
}
