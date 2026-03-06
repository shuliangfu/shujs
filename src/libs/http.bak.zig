//! io_core 统一 HTTP 客户端（http.zig）
//!
//! 本模块为 io_core 的网络出口，提供同步 HTTP 请求能力，供 package/registry、JSR、shu:fetch 等调用。
//! 支持所有常用 HTTP 方法（GET/HEAD/POST/PUT/PATCH/DELETE/OPTIONS）、自定义请求头、请求体。
//!
//! ## 设计
//!
//! - **仅 Zig 路径**：使用 `std.http.Client` 发请求，无 libcurl 依赖。ReadFailed 或 2xx 空 body 时在模块内有限次数 Zig 重试，仍失败则返回 error.HttpFailed / error.ReadFailed。
//! - **超时**：当前 Zig 标准库请求无超时选项，RequestOptions.timeout_sec 保留为 API 兼容、暂不生效。
//! - **Content-Encoding 与 chunked**：Zig 标准库在 receiveHead 时若为 `Content-Encoding: br` 会返回 HttpContentEncodingUnsupported；对 Keep-Alive + chunked 的读取存在已知问题（ziglang/zig#15710 等）。本模块分两路：**有 Content-Length** 时读固定长度 raw body 再整块解压；**无 Content-Length（chunked，如 jsr.io）** 时流式读，有 gzip/deflate 则用 `readerDecompressing` 边读边解压，避免先整段读 chunked 再解压。对可能回 br 或需稳定复用的请求（如 JSR meta）仍可传 accept_encoding = "identity"，使服务端回 Content-Length 走固定长度路径。
//!
//! ## 公开 API
//!
//! - **request(allocator, url, RequestOptions) !Response**
//!   发起任意方法的 HTTP 请求，返回 status、status_text、body。调用方用 **freeResponse(allocator, &resp)** 释放 body 与可分配的 status_text。
//! - **get(allocator, url, GetOptions) ![]const u8**
//!   便捷 GET：仅返回响应体，非 2xx 时返回 `error.BadStatus`。调用方 free 返回的切片。
//! - **getWithClient(client, allocator, url, GetOptions) ![]const u8**
//!   使用已有 std.http.Client 做 GET，便于连接复用。调用方 free 返回的切片。
//! - **Method**：GET / HEAD / POST / PUT / PATCH / DELETE / OPTIONS。
//! - **Header**：`{ name, value }`，用于 RequestOptions.headers 或 GetOptions.extra_headers。
//! - **RequestOptions**：method、body、max_response_bytes、timeout_sec、user_agent、headers。
//! - **GetOptions**：accept、max_bytes、timeout_sec、user_agent、extra_headers（内部转成 RequestOptions 调用 request）。
//! - **Response**：status、status_text、status_text_is_allocated（仅 true 时需 free status_text）、body；**freeResponse(allocator, &resp)** 统一释放。
//!
//! ## 内存约定
//!
//! - 所有返回的 `[]const u8`（Response.body、get() 的返回值）均由**调用方** free；Response.status_text 仅当 status_text_is_allocated 为 true 时需 free，否则为静态字符串。可用 freeResponse(allocator, &resp) 统一释放 body 与可分配的 status_text。
//! - 请求体 `RequestOptions.body` 由调用方在调用期间保持有效，本模块不持有、不 free。
//!
//! ## 错误
//!
//! - `error.InvalidUrl`：URL 解析失败。
//! - `error.BadStatus`：HTTP 状态非 2xx（get() 专用）。
//! - `error.HttpFailed`：网络/HTTP 请求失败（如读失败、连接断开等），经重试后仍失败时返回。
//! - `error.ReadFailed`：读响应体失败（未重试或重试前即返回）。
//! - `error.ResponseTooLarge`：响应体超过 max_response_bytes。
//! - `error.WriteFailed`：写请求体失败。
//!
//! ## 调试
//!
//! 设置 **SHU_DEBUG_HTTP=1** 时，向 stderr 打印空 body、ReadFailed、ResponseTooLarge 等调试信息。
//!
//! ## 示例
//!
//!   const body = try io_core.http.get(allocator, "https://example.com", .{ .accept = "application/json", .timeout_sec = 30 });
//!   defer allocator.free(body);
//!
//!   var headers = [_]io_core.http.Header{ .{ .name = "Accept", .value = "application/json" } };
//!   const resp = try io_core.http.request(allocator, url, .{ .method = .POST, .body = payload, .headers = &headers });
//!   defer io_core.http.freeResponse(allocator, &resp);

const std = @import("std");
const file = @import("file.zig");
const libs_process = @import("libs_process");
const shu_zlib = @import("shu_zlib");

// -----------------------------------------------------------------------------
// 类型与选项
// -----------------------------------------------------------------------------

/// 单条 HTTP 头
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// 支持的 HTTP 方法，与 std.http.Method 对齐便于转发
pub const Method = enum {
    GET,
    HEAD,
    POST,
    PUT,
    PATCH,
    DELETE,
    OPTIONS,
};

fn toStdMethod(m: Method) std.http.Method {
    return switch (m) {
        .GET => .GET,
        .HEAD => .HEAD,
        .POST => .POST,
        .PUT => .PUT,
        .PATCH => .PATCH,
        .DELETE => .DELETE,
        .OPTIONS => .OPTIONS,
    };
}

/// 通用请求选项，供 request() 与 shu:fetch 使用
pub const RequestOptions = struct {
    method: Method = .GET,
    /// 请求体；POST/PUT/PATCH 时使用，GET/HEAD 等忽略
    body: ?[]const u8 = null,
    /// 响应体最大字节数；默认 2GB，与 GetOptions 一致
    max_response_bytes: usize = 2 * 1024 * 1024 * 1024,
    /// 超时（秒）。保留 API 兼容，当前 Zig 路径未实现请求超时。
    timeout_sec: u32 = 0,
    /// User-Agent，null 时用默认
    user_agent: ?[]const u8 = null,
    /// Accept-Encoding；null 时用 "gzip, deflate"。设为 "identity" 可避免解压（JSR JSON 在连接复用下 gzip 易 ReadFailed）。
    accept_encoding: ?[]const u8 = null,
    /// 为 true 时不解压响应，仅通过 HTTP 头发送 options.accept_encoding，并解析响应头 Content-Encoding 填入 Response.content_encoding；供 tarball 下载后自行解压。
    raw_body: bool = false,
    /// 仅当 raw_body 时有效：为 true 时不调用 decompressResponseBodyIfNeeded，返回的 body 为服务端原始压缩字节（如 gzip）。供 downloadToPath 写 .tgz 文件，后续由 extractTarballToDir 做 gzip 解压；为 false 时 raw_body 请求会在本模块内解压后返回。
    keep_compressed: bool = false,
    /// 所有请求头（含 Accept、Content-Type 等），按需传入
    headers: []const Header = &.{},
};

/// 响应：status 为状态码，status_text 为原因短语，body 为响应体。raw_body 时 content_encoding 为响应头值（如 "br"、"gzip"）。调用方 free body；仅当 status_text_is_allocated 为 true 时需 free status_text，否则为静态常量（见 freeResponse）。
pub const Response = struct {
    status: u16,
    status_text: []const u8,
    /// 为 true 时 status_text 由 allocator 分配，调用方须 free；为 false 时指向模块内静态字符串，不得 free
    status_text_is_allocated: bool = false,
    body: []const u8,
    content_encoding: ?[]const u8 = null,
};

/// GET 专用选项，供 get() 与 registry/JSR 使用；内部转成 RequestOptions。默认 2GB，与 registry 一致，避免未显式传 max_bytes 时误触 ResponseTooLarge。
pub const GetOptions = struct {
    accept: []const u8 = "application/json",
    max_bytes: usize = 2 * 1024 * 1024 * 1024,
    timeout_sec: u32 = 0,
    user_agent: ?[]const u8 = null,
    /// 同 RequestOptions.accept_encoding；JSR 请求建议 "identity" 避免 gzip 解压在坏连接上 ReadFailed
    accept_encoding: ?[]const u8 = null,
    /// 同 RequestOptions.raw_body；tarball 下载时 true，拿原始 body 与 Content-Encoding 后自行解压
    raw_body: bool = false,
    /// 同 RequestOptions.keep_compressed；tarball 下载到路径时 true，返回 gzip 原始字节以便写入 .tgz 后由 extract 解压
    keep_compressed: bool = false,
    extra_headers: []const Header = &.{},
};

const default_user_agent = "shu/1.0 (http client)";

/// tarball 下载专用选项：未传的用默认值，传了则覆盖。默认 accept "*/*"、accept_encoding "br, gzip, deflate"、raw_body true，由本模块按 Content-Encoding 自动解压。
pub const TarballGetOptions = struct {
    accept: ?[]const u8 = null,
    accept_encoding: ?[]const u8 = null,
    raw_body: ?bool = null,
    max_bytes: usize = 50 * 1024 * 1024,
    timeout_sec: u32 = 60,
    user_agent: ?[]const u8 = null,
};

const tarball_default_accept = "*/*";
/// 请求 gzip 以减小下载体积、加快下载；body 在 HTTP 层解压后返回 tar 写入 .tgz，解压结果为 0 字节时不替换 body、原样写入由 extract 处理。
const tarball_default_accept_encoding = "gzip";

// -----------------------------------------------------------------------------
// 公开 API
// -----------------------------------------------------------------------------

/// ReadFailed 或 2xx 空 body 时 Zig 路径最大重试次数（每次间隔 1 秒），用于连接瞬断等场景。
const read_failed_retries = 3;

/// 释放 request/get 返回的 [Allocates] 资源：body 与（当 status_text_is_allocated 时）status_text；供调用方统一释放，避免漏放或误 free 静态 status_text。
pub fn freeResponse(allocator: std.mem.Allocator, resp: *const Response) void {
    allocator.free(resp.body);
    if (resp.status_text_is_allocated) allocator.free(resp.status_text);
}

/// [Allocates] 同步发起任意方法的 HTTP 请求，返回完整响应。调用方用 freeResponse(allocator, &resp) 释放。
/// ReadFailed 或 GET 返回 2xx 但 body 为空时，用 Zig 路径重试最多 read_failed_retries 次，仍失败则返回 error.HttpFailed。
pub fn request(allocator: std.mem.Allocator, url: []const u8, options: RequestOptions) !Response {
    var last_err: anyerror = error.ReadFailed;
    for (0..read_failed_retries + 1) |i| {
        if (i > 0) {
            const proc_io = libs_process.getProcessIo();
            if (proc_io) |io| std.Io.sleep(io, std.Io.Duration.fromSeconds(1), .awake) catch {};
        }
        const resp = requestViaZig(allocator, url, options) catch |e| {
            last_err = e;
            continue;
        };
        if (resp.body.len == 0 and options.method == .GET) {
            freeResponse(allocator, &resp);
            last_err = error.ReadFailed;
            continue;
        }
        return resp;
    }
    return if (last_err == error.ReadFailed) error.HttpFailed else last_err;
}

/// [Allocates] 便捷 GET：仅返回响应体，非 2xx 时返回 error.BadStatus。调用方 free 返回的切片。
pub fn get(allocator: std.mem.Allocator, url: []const u8, options: GetOptions) ![]const u8 {
    var headers: [16]Header = undefined;
    var n: usize = 0;
    headers[n] = .{ .name = "Accept", .value = options.accept };
    n += 1;
    for (options.extra_headers) |h| {
        if (n >= headers.len) break;
        headers[n] = h;
        n += 1;
    }
    const resp = try request(allocator, url, .{
        .method = .GET,
        .max_response_bytes = options.max_bytes,
        .timeout_sec = options.timeout_sec,
        .user_agent = options.user_agent,
        .accept_encoding = options.accept_encoding,
        .headers = headers[0..n],
    });
    if (resp.status < 200 or resp.status >= 300) {
        freeResponse(allocator, &resp);
        return error.BadStatus;
    }
    if (resp.status_text_is_allocated) allocator.free(resp.status_text);
    return resp.body;
}

/// 当 SHU_DEBUG_HTTP 非空且 raw_body 为空时，向 stderr 打印 url、status、content_encoding、content_length，便于区分「服务端返回空」与「Zig 路径未读到 body」。开头 \n 避免与进度条同显时接在同一行。
fn debugLogEmptyRawBody(url: []const u8, status: u16, content_encoding: std.http.ContentEncoding, content_length: ?u64) void {
    const env = std.c.getenv("SHU_DEBUG_HTTP") orelse return;
    if (std.mem.span(env).len == 0) return;
    const io = libs_process.getProcessIo() orelse return;
    var buf: [512]u8 = undefined;
    var w = std.Io.File.Writer.init(std.Io.File.stderr(), io, &buf);
    w.interface.print("\n[shu http debug] empty raw_body url={s} status={d} content_encoding={s} content_length={?d}\n", .{
        url,
        status,
        @tagName(content_encoding),
        content_length,
    }) catch return;
    w.flush() catch return;
}

/// 当 SHU_DEBUG_HTTP 非空且读 body 失败时，向 stderr 打印 url、错误名与可选 reason（path=zig 表示 Zig 路径；reason=empty_raw_body 表示头有 Content-Length 但读到 0 字节）。开头 \n 避免与进度条同显时接在同一行。
fn debugLogReadFailed(url: []const u8, read_err: anyerror, reason: ?[]const u8) void {
    const env = std.c.getenv("SHU_DEBUG_HTTP") orelse return;
    if (std.mem.span(env).len == 0) return;
    const io = libs_process.getProcessIo() orelse return;
    var buf: [640]u8 = undefined;
    var w = std.Io.File.Writer.init(std.Io.File.stderr(), io, &buf);
    if (reason) |r| {
        w.interface.print("\n[shu http] read failed url={s} error={s} path=zig reason={s}\n", .{ url, @errorName(read_err), r }) catch return;
    } else {
        w.interface.print("\n[shu http] read failed url={s} error={s} path=zig\n", .{ url, @errorName(read_err) }) catch return;
    }
    w.flush() catch return;
}

/// 当 SHU_DEBUG_HTTP 非空且触发 ResponseTooLarge 时，向 stderr 打印 url 与 max_response_bytes，便于定位是哪个请求、用的哪个 limit。开头 \n 避免与进度条同显时接在同一行。
fn debugLogResponseTooLarge(url: []const u8, max_response_bytes: usize) void {
    const env = std.c.getenv("SHU_DEBUG_HTTP") orelse return;
    if (std.mem.span(env).len == 0) return;
    const io = libs_process.getProcessIo() orelse return;
    var buf: [512]u8 = undefined;
    var w = std.Io.File.Writer.init(std.Io.File.stderr(), io, &buf);
    w.interface.print("\n[shu http] ResponseTooLarge url={s} limit={d}\n", .{ url, max_response_bytes }) catch return;
    w.flush() catch return;
}

/// 当 SHU_DEBUG_HTTP 非空时，向 stderr 打印响应头（status + 逐条 Header），便于排查 Content-Encoding 等。在调用 reader() 之前调用，避免 head 被 invalidate。
fn debugLogResponseHeaders(url: []const u8, status: u16, head: std.http.Client.Response.Head) void {
    const env = std.c.getenv("SHU_DEBUG_HTTP") orelse return;
    if (std.mem.span(env).len == 0) return;
    const io = libs_process.getProcessIo() orelse return;
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.Writer.init(std.Io.File.stderr(), io, &buf);
    w.interface.print("\n[shu http] response headers url={s} status={d}\n", .{ url, status }) catch return;
    var it = head.iterateHeaders();
    while (it.next()) |header| {
        w.interface.print("  {s}: {s}\n", .{ header.name, header.value }) catch return;
    }
    w.flush() catch return;
}

/// 使用已有 Client 做 GET，便于同一 host 连接复用（Keep-Alive）。仅 Zig 路径；若 ReadFailed 或 2xx 空 body 则重试最多 read_failed_retries 次、每次间隔 1 秒，仍失败返回 error.HttpFailed。调用方负责 client 生命周期。
/// [Allocates] 使用已有 std.http.Client 做 GET；返回的 body 由调用方 free。重试时若上次为 ReadFailed 则改用一次性 Client 重试一次以换新连接。
pub fn getWithClient(client: *std.http.Client, allocator: std.mem.Allocator, url: []const u8, options: GetOptions) ![]const u8 {
    var headers: [16]Header = undefined;
    var n: usize = 0;
    headers[n] = .{ .name = "Accept", .value = options.accept };
    n += 1;
    for (options.extra_headers) |h| {
        if (n >= headers.len) break;
        headers[n] = h;
        n += 1;
    }
    const opts = RequestOptions{
        .method = .GET,
        .max_response_bytes = options.max_bytes,
        .timeout_sec = 0,
        .user_agent = options.user_agent,
        .accept_encoding = options.accept_encoding,
        .headers = headers[0..n],
    };
    var last_err: anyerror = error.HttpFailed;
    for (0..read_failed_retries + 1) |i| {
        if (i > 0) std.Io.sleep(client.io, std.Io.Duration.fromSeconds(1), .awake) catch {}; // 1s 间隔
        // 重试一律用同一 client，避免 ReadFailed 时新建 one-off Client 触发 connect() 内 proxy.host 未初始化野指针 segfault（gzip 时易触发 ReadFailed 故易进重试路径）。
        const resp = requestViaZigWithClient(client, allocator, url, opts) catch |e| {
            last_err = e;
            continue;
        };
        if (resp.status >= 200 and resp.status < 300 and resp.body.len == 0) {
            freeResponse(allocator, &resp);
            last_err = error.ReadFailed;
            continue;
        }
        if (resp.status < 200 or resp.status >= 300) {
            freeResponse(allocator, &resp);
            return error.BadStatus;
        }
        if (resp.status_text_is_allocated) allocator.free(resp.status_text);
        return resp.body;
    }
    // SHU_DEBUG_HTTP 时打印最终错误，便于区分 empty_raw_body_chunked、body_truncated、decompress 等
    if (std.c.getenv("SHU_DEBUG_HTTP")) |_| {
        var buf: [256]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "\n[shu http] after retries url={s} last_err={s}\n", .{ url, @errorName(last_err) })) |slice|
            _ = std.c.write(2, slice.ptr, slice.len)
        else |_| {}
    }
    return if (last_err == error.ReadFailed) error.HttpFailed else last_err;
}

// -----------------------------------------------------------------------------
// Zig 路径：完整方法 + 状态 + 响应体
// -----------------------------------------------------------------------------

fn requestViaZig(allocator: std.mem.Allocator, url: []const u8, options: RequestOptions) !Response {
    const io = libs_process.getProcessIo() orelse return error.ProcessIoNotSet;
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();
    return requestViaZigWithClient(&client, allocator, url, options);
}

// 每线程大缓冲区，避免 requestViaZigWithClient 栈上 64KB+32KB 导致栈溢出或递归/并发时压力过大；同步路径每线程单请求，无竞态。
threadlocal var tls_transfer_buf: [64 * 1024]u8 = undefined;
threadlocal var tls_decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;

/// 使用已有 Client 发请求，不 deinit client，供连接复用。仅 Zig 路径。
/// Header 零拷贝：options.headers 与 std.http.Header 布局一致，直接 ptrCast 传入，最多 24 条；status_text 标准状态码用静态串；读体/解压用 TLS 大缓冲。
fn requestViaZigWithClient(client: *std.http.Client, allocator: std.mem.Allocator, url: []const u8, options: RequestOptions) !Response {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    const ua = options.user_agent orelse default_user_agent;
    const method = toStdMethod(options.method);

    // 单次遍历、零分配：Header 与 std.http.Header 布局一致，直接转成 std 切片传入，最多 24 条（与原先 extra_list 容量一致）
    const max_extra = @min(options.headers.len, 24);
    const extra_headers: []const std.http.Header = if (max_extra == 0)
        &[_]std.http.Header{}
    else
        @as([*]const std.http.Header, @ptrCast(options.headers.ptr))[0..max_extra];
    // Zig 路径仅支持 gzip/deflate，不支持 br；服务端若回 br 则 receiveHead 返回 HttpContentEncodingUnsupported，转为 ReadFailed。
    const enc = options.accept_encoding orelse "gzip, deflate";
    var req = client.request(method, uri, .{
        .redirect_behavior = std.http.Client.Request.RedirectBehavior.init(5),
        .headers = .{
            .user_agent = .{ .override = ua },
            .accept_encoding = .{ .override = enc },
        },
        .extra_headers = extra_headers,
    }) catch |e| return e;
    defer req.deinit();

    if (options.body) |body| {
        if (body.len > 0 and (method == .POST or method == .PUT or method == .PATCH)) {
            req.transfer_encoding = .{ .content_length = body.len };
            var buf: [8192]u8 = undefined;
            var bw = try req.sendBodyUnflushed(&buf);
            bw.writer.writeAll(body) catch return error.WriteFailed;
            try bw.end();
            try req.connection.?.flush();
        } else {
            try req.sendBodiless();
        }
    } else {
        try req.sendBodiless();
    }

    // 使用标准库 req.receiveHead() 保证 Request 内部状态（response_transfer_encoding/response_content_length）正确，body 才能被正确读取。不支持 br：服务端若回 Content-Encoding: br 则转为 ReadFailed。
    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch |e| {
        if (e == error.HttpContentEncodingUnsupported) return error.ReadFailed;
        return e;
    };
    while (response.head.status == .@"continue") {
        response = req.receiveHead(&redirect_buf) catch |e| {
            if (e == error.HttpContentEncodingUnsupported) return error.ReadFailed;
            return e;
        };
    }
    const status: u16 = @intFromEnum(response.head.status);
    const phrase = response.head.status.phrase();
    debugLogResponseHeaders(url, status, response.head);
    // 标准状态码（200/404 等）直接返回静态字符串，避免高并发安装时大量 dupe 造成碎片；仅非标状态码且服务端返回 phrase 时才 dupe
    const status_text: []const u8 = if (statusCodeHasStatic(status)) blk: {
        break :blk statusCodeToStatic(status);
    } else if (phrase) |p| blk: {
        break :blk allocator.dupe(u8, p) catch allocator.dupe(u8, "Unknown") catch return error.OutOfMemory;
    } else blk: {
        break :blk statusCodeToStatic(status); // "Unknown"
    };
    const status_text_is_allocated = !statusCodeHasStatic(status) and phrase != null;
    errdefer if (status_text_is_allocated) allocator.free(status_text);

    if (!method.responseHasBody()) {
        return .{
            .status = status,
            .status_text = status_text,
            .status_text_is_allocated = status_text_is_allocated,
            .body = try allocator.dupe(u8, ""),
        };
    }

    // 先取 content_encoding / content_length，再调 reader()（reader 会 invalidate response.head 的字符串）
    const content_encoding = response.head.content_encoding;
    const content_length = response.head.content_length;
    // 有 Content-Length 时读固定长度，再整块解压；chunked 时流式解压。大缓冲用 TLS 减轻栈压力（见 tls_transfer_buf / tls_decompress_buf）。
    var body: []const u8 = undefined;

    if (content_length != null) {
        // 有 Content-Length：读满 raw body 再按需解压（与 Zig Cookbook / 原逻辑一致）
        const raw_reader = response.reader(&tls_transfer_buf);
        const raw_body = raw_reader.allocRemaining(allocator, std.Io.Limit.limited(options.max_response_bytes)) catch |e| {
            if (e == error.StreamTooLong) {
                debugLogResponseTooLarge(url, options.max_response_bytes);
                return error.ResponseTooLarge;
            }
            debugLogReadFailed(url, e, "read");
            return e;
        };
        defer allocator.free(raw_body);
        if (raw_body.len == 0) {
            debugLogEmptyRawBody(url, status, content_encoding, content_length);
            debugLogReadFailed(url, error.ReadFailed, "empty_raw_body");
            return error.ReadFailed;
        }
        if (content_length) |expected| {
            if (raw_body.len < expected) {
                if (std.c.getenv("SHU_DEBUG_HTTP")) |_| {
                    var buf: [256]u8 = undefined;
                    if (std.fmt.bufPrint(&buf, "[shu http] body truncated url={s} expected={d} got={d}\n", .{ url, expected, raw_body.len })) |slice|
                        _ = std.c.write(2, slice.ptr, slice.len)
                    else |_| {}
                }
                debugLogReadFailed(url, error.ReadFailed, "body_truncated");
                return error.ReadFailed;
            }
        }
        body = switch (content_encoding) {
            .identity => try allocator.dupe(u8, raw_body),
            .gzip, .deflate => blk: {
                var in_reader = std.Io.Reader.fixed(raw_body);
                const container: std.compress.flate.Container = if (content_encoding == .gzip) .gzip else .zlib;
                var dec = std.compress.flate.Decompress.init(&in_reader, container, &tls_decompress_buf);
                break :blk file.readReaderUpTo(allocator, &dec.reader, options.max_response_bytes) catch |e| {
                    if (e == error.ResponseTooLarge) debugLogResponseTooLarge(url, options.max_response_bytes);
                    debugLogReadFailed(url, e, "decompress");
                    return e;
                };
            },
            .zstd => return error.UnsupportedCompressionMethod,
            .compress => return error.UnsupportedCompressionMethod,
        };
    } else {
        // 无 Content-Length（chunked）：流式读；有 gzip/deflate 时用 readerDecompressing 边读边解压，避免先整段读 chunked 再解压（JSR 常回 chunked+gzip）。
        if (content_encoding == .zstd or content_encoding == .compress) {
            return error.UnsupportedCompressionMethod;
        }
        if (content_encoding == .identity) {
            const raw_reader = response.reader(&tls_transfer_buf);
            body = raw_reader.allocRemaining(allocator, std.Io.Limit.limited(options.max_response_bytes)) catch |e| {
                if (e == error.StreamTooLong) {
                    debugLogResponseTooLarge(url, options.max_response_bytes);
                    return error.ResponseTooLarge;
                }
                debugLogReadFailed(url, e, "read");
                return e;
            };
            if (body.len == 0) {
                debugLogEmptyRawBody(url, status, content_encoding, content_length);
                debugLogReadFailed(url, error.ReadFailed, "empty_raw_body_chunked");
                return error.ReadFailed;
            }
        } else {
            var decompress: std.http.Decompress = undefined;
            const dec_reader = response.readerDecompressing(&tls_transfer_buf, &decompress, &tls_decompress_buf);
            body = dec_reader.allocRemaining(allocator, std.Io.Limit.limited(options.max_response_bytes)) catch |e| {
                if (e == error.StreamTooLong) {
                    debugLogResponseTooLarge(url, options.max_response_bytes);
                    return error.ResponseTooLarge;
                }
                debugLogReadFailed(url, e, "read_decompressing");
                return e;
            };
            if (body.len == 0) {
                debugLogEmptyRawBody(url, status, content_encoding, content_length);
                if (std.c.getenv("SHU_DEBUG_HTTP")) |_| {
                    var buf: [320]u8 = undefined;
                    if (std.fmt.bufPrint(&buf, "\n[shu http] chunked stream decompress read 0 bytes, url={s}\n", .{url})) |slice|
                        _ = std.c.write(2, slice.ptr, slice.len)
                    else |_| {}
                }
                debugLogReadFailed(url, error.ReadFailed, "empty_raw_body_chunked");
                return error.ReadFailed;
            }
        }
    }

    return .{
        .status = status,
        .status_text = status_text,
        .status_text_is_allocated = status_text_is_allocated,
        .body = body,
    };
}

/// 是否为 statusCodeToStatic 覆盖的标准状态码（200/404 等）；用于 status_text 静态引用优化，仅非标码才 dupe。
fn statusCodeHasStatic(code: u16) bool {
    return switch (code) {
        200, 201, 204, 301, 302, 304, 400, 401, 403, 404, 405, 408, 409, 500, 502, 503 => true,
        else => false,
    };
}

fn statusCodeToStatic(code: u16) []const u8 {
    return switch (code) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        409 => "Conflict",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        else => "Unknown",
    };
}

/// 取 Content-Encoding 第一个编码（如 "gzip, deflate" -> "gzip"），trim 后返回其切片；不分配内存。
fn firstContentEncoding(enc: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, enc, " \t\r\n");
    if (std.mem.indexOf(u8, trimmed, ",")) |i| {
        return std.mem.trim(u8, trimmed[0..i], " \t");
    }
    return trimmed;
}

/// Gzip 魔术字节：1f 8b，用于无 Content-Encoding 时按 body 内容判断是否 gzip。
const gzip_magic: [2]u8 = .{ 0x1f, 0x8b };

/// 当 resp.content_encoding 为 br/gzip/deflate 时，用 shu_zlib 解压 resp.body 并替换为解压结果；
/// 若 content_encoding 为空但 body 以 gzip magic (1f 8b) 开头，也按 gzip 解压（兼容不返回 Content-Encoding 的镜像）。
/// 释放原 body 与 content_encoding。支持 "gzip, deflate" 等只取第一项。供 raw_body 请求返回前自动解压，调用方拿到的即为解压后 body。
/// 解压失败则返回错误，不写错误数据。SHU_DEBUG_HTTP 非空时打印 content_encoding 与 body 大小便于调试。
fn decompressResponseBodyIfNeeded(allocator: std.mem.Allocator, resp: *Response) !void {
    const body_before = resp.body.len;
    const enc_raw = resp.content_encoding;
    resp.content_encoding = null;
    const enc = if (enc_raw) |raw| blk: {
        const e = firstContentEncoding(raw);
        allocator.free(raw);
        break :blk e;
    } else "";
    // 有 Content-Encoding 时按头解压
    if (enc.len > 0) {
        if (std.ascii.eqlIgnoreCase(enc, "br")) {
            const out = try shu_zlib.decompressBrotli(allocator, resp.body);
            allocator.free(resp.body);
            resp.body = out;
            debugLogDecompress("br", body_before, resp.body.len);
            return;
        }
        if (std.ascii.eqlIgnoreCase(enc, "gzip")) {
            const out = try shu_zlib.decompressGzip(allocator, resp.body);
            if (out.len == 0) {
                allocator.free(out);
                return;
            }
            allocator.free(resp.body);
            resp.body = out;
            debugLogDecompress("gzip", body_before, resp.body.len);
            return;
        }
        if (std.ascii.eqlIgnoreCase(enc, "deflate")) {
            const out = try shu_zlib.decompressDeflate(allocator, resp.body);
            allocator.free(resp.body);
            resp.body = out;
            debugLogDecompress("deflate", body_before, resp.body.len);
            return;
        }
        return;
    }
    // 无 Content-Encoding：若 body 以 gzip magic 开头则按 gzip 解压（常见于 npm 镜像 tarball）；解压结果为 0 字节时不替换，原样写回 .tgz 由 extract 流式解压
    if (resp.body.len >= gzip_magic.len and std.mem.eql(u8, resp.body[0..gzip_magic.len], &gzip_magic)) {
        const out = try shu_zlib.decompressGzip(allocator, resp.body);
        if (out.len > 0) {
            allocator.free(resp.body);
            resp.body = out;
            debugLogDecompress("gzip (magic)", body_before, resp.body.len);
        } else {
            allocator.free(out);
        }
    }
}

fn debugLogDecompress(enc: []const u8, before: usize, after: usize) void {
    if (std.c.getenv("SHU_DEBUG_HTTP")) |_| {} else return;
    var buf: [128]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "[shu http] decompress enc={s} before={d} after={d}\n", .{ enc, before, after })) |slice|
        _ = std.c.write(2, slice.ptr, slice.len)
    else |_| {}
}
