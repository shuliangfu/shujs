//! io_core 统一 HTTP 客户端（http.zig）
//!
//! 本模块为 io_core 的网络出口，提供同步 HTTP 请求能力，供 package/registry、JSR、shu:fetch 等调用。
//! 支持所有常用 HTTP 方法（GET/HEAD/POST/PUT/PATCH/DELETE/OPTIONS）、自定义请求头、请求体与超时。
//!
//! ## 设计
//!
//! - **对外只暴露 Zig 路径**：默认使用 `std.http.Client` 发请求；Zig 路径失败（ReadFailed、2xx 但 body 为空）时在**本模块内部**自动回退到 libcurl 重试，调用方无需感知。
//! - **libcurl 仅作内部回退**：不对外提供 CurlClient / getWithCurlClient 等接口；需超时（request/get 的 timeout_sec > 0）时仍走 libcurl 以支持 CURLOPT_TIMEOUT。
//! - **构建依赖**：使用本模块需链接 libcurl（build.zig 中 `linkSystemLibrary("curl")`），系统需已安装 libcurl-dev / curl-devel。
//!
//! ## 公开 API
//!
//! - **request(allocator, url, RequestOptions) !Response**
//!   发起任意方法的 HTTP 请求，返回 status、status_text、body。默认 Zig 路径，失败时内部回退 libcurl。调用方负责 free `response.body` 与 `response.status_text`。
//! - **get(allocator, url, GetOptions) ![]const u8**
//!   便捷 GET：仅返回响应体，非 2xx 时返回 `error.BadStatus`。调用方 free 返回的切片。
//! - **getWithClient(client, allocator, url, GetOptions) ![]const u8**
//!   使用已有 std.http.Client 做 GET，便于连接复用；Zig 失败时内部回退 libcurl。调用方 free 返回的切片。
//! - **Method**：GET / HEAD / POST / PUT / PATCH / DELETE / OPTIONS。
//! - **Header**：`{ name, value }`，用于 RequestOptions.headers 或 GetOptions.extra_headers。
//! - **RequestOptions**：method、body、max_response_bytes、timeout_sec、user_agent、headers。
//! - **GetOptions**：accept、max_bytes、timeout_sec、user_agent、extra_headers（内部转成 RequestOptions 调用 request）。
//! - **Response**：status (u16)、status_text ([]const u8)、body ([]const u8)。
//!
//! ## 内存约定
//!
//! - 所有返回的 `[]const u8`（Response.body、Response.status_text、get() 的返回值）均由**调用方**使用传入的 allocator 或约定方式 free。
//! - 请求体 `RequestOptions.body` 由调用方在调用期间保持有效，本模块不持有、不 free。
//!
//! ## 错误
//!
//! - `error.InvalidUrl`：URL 解析失败。
//! - `error.BadStatus`：HTTP 状态非 2xx（get() 专用）。
//! - `error.CurlFailed`：libcurl 执行失败（如网络不可达、超时、TLS 错误等）。
//! - `error.ResponseTooLarge`：响应体超过 max_response_bytes。
//! - `error.WriteFailed`：Zig 路径写请求体失败。
//!
//! ## 测试 libcurl 回退路径
//!
//! 设置环境变量 **SHU_HTTP_FORCE_CURL=1** 后，所有请求将跳过 Zig 路径、直接走 libcurl，用于验证回退路径是否正常。例如：`SHU_HTTP_FORCE_CURL=1 shu install` 或 `SHU_HTTP_FORCE_CURL=1 shu add lodash`。
//! 设置 **SHU_DEBUG_HTTP=1** 时，除打印失败 URL/错误外，会开启 libcurl 的 CURLOPT_VERBOSE，将连接/TLS/耗时等调试信息输出到 stderr，便于排查超时(code 28)或 SSL(code 35) 等问题。
//!
//! ## 示例
//!
//!   const body = try io_core.http.get(allocator, "https://example.com", .{ .accept = "application/json", .timeout_sec = 30 });
//!   defer allocator.free(body);
//!
//!   var headers = [_]io_core.http.Header{ .{ .name = "Accept", .value = "application/json" } };
//!   const resp = try io_core.http.request(allocator, url, .{ .method = .POST, .body = payload, .headers = &headers });
//!   defer allocator.free(resp.body);
//!   defer allocator.free(resp.status_text);

const std = @import("std");
const builtin = @import("builtin");
const file = @import("file.zig");
const shu_zlib = @import("shu_zlib");

const c = @cImport({
    @cInclude("curl/curl.h");
});

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
    /// 超时（秒）。0：先 Zig 再 libcurl 回退；>0：直接用 libcurl（CURLOPT_TIMEOUT），无子进程
    timeout_sec: u32 = 0,
    /// User-Agent，null 时用默认
    user_agent: ?[]const u8 = null,
    /// Accept-Encoding；null 时 Zig 路径用 "gzip, deflate"，libcurl 用默认。设为 "identity" 可避免解压（JSR JSON 在连接复用下 gzip 易 ReadFailed）。
    accept_encoding: ?[]const u8 = null,
    /// 为 true 时 libcurl 不自动解压（仅通过 HTTP 头发送 options.accept_encoding，不设 CURLOPT_ACCEPT_ENCODING），并解析响应头 Content-Encoding 填入 Response.content_encoding；供 tarball 下载后自行解压。
    raw_body: bool = false,
    /// 仅当 raw_body 且 libcurl 路径时有效：为 true 时不调用 decompressResponseBodyIfNeeded，返回的 body 为服务端原始压缩字节（如 gzip）。供 downloadToPath 写 .tgz 文件，后续由 extractTarballToDir 做 gzip 解压；为 false 时 raw_body 请求会在本模块内解压后返回。
    keep_compressed: bool = false,
    /// 所有请求头（含 Accept、Content-Type 等），按需传入
    headers: []const Header = &.{},
};

/// 响应：status 为状态码，status_text 为原因短语，body 为响应体。raw_body 时 content_encoding 为响应头值（如 "br"、"gzip"）。调用方 free body、status_text 与 content_encoding（若非 null）。
pub const Response = struct {
    status: u16,
    status_text: []const u8,
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

/// 当环境变量 SHU_HTTP_FORCE_CURL 非空时返回 true，用于测试或故障时强制走 libcurl。
fn forceCurl() bool {
    const v = std.posix.getenv("SHU_HTTP_FORCE_CURL") orelse return false;
    return v.len > 0;
}

/// 同步发起任意方法的 HTTP 请求，返回完整响应。调用方 free response.body 与 response.status_text。
/// Zig 路径返回 ReadFailed 时自动回退到 libcurl 一次，避免向调用方直接抛出 ReadFailed（install 等流程易因此终止）。
/// 若 SHU_HTTP_FORCE_CURL=1 则跳过 Zig、直接走 libcurl（用于验证回退路径）。
pub fn request(allocator: std.mem.Allocator, url: []const u8, options: RequestOptions) !Response {
    if (options.timeout_sec > 0) {
        return requestViaLibCurl(allocator, url, options);
    }
    if (forceCurl()) {
        var opts = options;
        opts.timeout_sec = if (options.timeout_sec > 0) options.timeout_sec else 60;
        return requestViaLibCurl(allocator, url, opts);
    }
    const resp = requestViaZig(allocator, url, options) catch |e| {
        if (e == error.ReadFailed) return requestViaLibCurl(allocator, url, options);
        return e;
    };
    if (resp.body.len == 0 and options.method == .GET) {
        allocator.free(resp.body);
        if (resp.status_text.len > 0) allocator.free(resp.status_text);
        return requestViaLibCurl(allocator, url, options);
    }
    return resp;
}

/// 便捷 GET：仅返回响应体，非 2xx 时返回 error.BadStatus。调用方 free 返回的切片。
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
        allocator.free(resp.body);
        allocator.free(resp.status_text);
        return error.BadStatus;
    }
    allocator.free(resp.status_text);
    return resp.body;
}

/// 当 SHU_DEBUG_HTTP 非空且 raw_body 为空时，向 stderr 打印 url、status、content_encoding、content_length，便于区分「服务端返回空」与「Zig 路径未读到 body」。开头 \n 避免与进度条同显时接在同一行。
fn debugLogEmptyRawBody(url: []const u8, status: u16, content_encoding: std.http.ContentEncoding, content_length: ?u64) void {
    const env = std.posix.getenv("SHU_DEBUG_HTTP") orelse return;
    if (env.len == 0) return;
    var buf: [512]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.print("\n[shu http debug] empty raw_body url={s} status={d} content_encoding={s} content_length={?d}\n", .{
        url,
        status,
        @tagName(content_encoding),
        content_length,
    }) catch return;
    w.interface.flush() catch return;
}

/// 当 SHU_DEBUG_HTTP 非空且读 body 失败时，向 stderr 打印 url、错误名与可选 reason（path=zig 表示 Zig 路径；reason=empty_raw_body 表示头有 Content-Length 但读到 0 字节）。开头 \n 避免与进度条同显时接在同一行。
fn debugLogReadFailed(url: []const u8, read_err: anyerror, reason: ?[]const u8) void {
    const env = std.posix.getenv("SHU_DEBUG_HTTP") orelse return;
    if (env.len == 0) return;
    var buf: [640]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    if (reason) |r| {
        w.interface.print("\n[shu http] read failed url={s} error={s} path=zig reason={s}\n", .{ url, @errorName(read_err), r }) catch return;
    } else {
        w.interface.print("\n[shu http] read failed url={s} error={s} path=zig\n", .{ url, @errorName(read_err) }) catch return;
    }
    w.interface.flush() catch return;
}

/// libcurl perform 失败时向 stderr 打印 url 与 CURLcode。探测请求（URL 含 /-/ping）失败不打印，避免用户误以为进度总数里包含探测请求、已完成与总数对不上。
/// 开头加 \n 避免与 CLI 进度条（stdout 无换行）同显时 stderr 接在同一行导致乱序。
fn debugLogCurlFailed(url: []const u8, code: c.CURLcode) void {
    if (std.mem.indexOf(u8, url, "/-/ping") != null) return;
    const msg = c.curl_easy_strerror(code);
    const msg_z: [*:0]const u8 = if (msg != null) msg else "?";
    var buf: [512]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.print("\n[shu http] curl failed url={s} code={d} ({s})\n", .{ url, code, std.mem.span(msg_z) }) catch return;
    w.interface.flush() catch return;
}

/// 当 SHU_DEBUG_HTTP 非空且触发 ResponseTooLarge 时，向 stderr 打印 url 与 max_response_bytes，便于定位是哪个请求、用的哪个 limit。开头 \n 避免与进度条同显时接在同一行。
fn debugLogResponseTooLarge(url: []const u8, max_response_bytes: usize) void {
    const env = std.posix.getenv("SHU_DEBUG_HTTP") orelse return;
    if (env.len == 0) return;
    var buf: [512]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    w.interface.print("\n[shu http] ResponseTooLarge url={s} limit={d}\n", .{ url, max_response_bytes }) catch return;
    w.interface.flush() catch return;
}

/// ReadFailed 时 libcurl 最大重试次数（每次间隔 1 秒，用于 JSR/高并发下连接被关等瞬断）
const read_failed_curl_retries = 3;

/// 使用已有 Client 做 GET，便于同一 host 连接复用（Keep-Alive）。仅走 Zig 路径、不设超时；若 2xx 且 body 为空或读 body 时 ReadFailed（连接复用导致连接被关常见于 JSR）则用 libcurl 重试最多 read_failed_curl_retries 次、每次间隔 1 秒。调用方负责 client 生命周期。SHU_HTTP_FORCE_CURL=1 时跳过 Zig、直接走 libcurl。
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
    const curl_opts: RequestOptions = .{
        .method = .GET,
        .max_response_bytes = options.max_bytes,
        .timeout_sec = 30,
        .user_agent = options.user_agent,
        .accept_encoding = options.accept_encoding,
        .headers = headers[0..n],
    };
    if (forceCurl()) {
        const resp = try requestViaLibCurl(allocator, url, curl_opts);
        if (resp.status < 200 or resp.status >= 300) {
            allocator.free(resp.body);
            allocator.free(resp.status_text);
            return error.BadStatus;
        }
        allocator.free(resp.status_text);
        return resp.body;
    }
    var resp = requestViaZigWithClient(client, allocator, url, opts) catch |e| {
        if (e == error.ReadFailed) {
            var last_err: anyerror = e;
            for (0..read_failed_curl_retries) |i| {
                if (i > 0) std.Thread.sleep(1_000_000_000); // 1s 间隔，避免瞬断后立即重试
                const fallback = requestViaLibCurl(allocator, url, curl_opts) catch |curl_e| {
                    last_err = curl_e;
                    continue;
                };
                if (fallback.status >= 200 and fallback.status < 300) {
                    allocator.free(fallback.status_text);
                    return fallback.body;
                }
                allocator.free(fallback.body);
                allocator.free(fallback.status_text);
                last_err = error.BadStatus;
            }
            // 保险：绝不向调用方返回 ReadFailed，避免 install 等流程直接终止；再试一次 libcurl 失败则改为 CurlFailed
            if (last_err == error.ReadFailed) {
                const final = requestViaLibCurl(allocator, url, curl_opts) catch return error.CurlFailed;
                if (final.status >= 200 and final.status < 300) {
                    allocator.free(final.status_text);
                    return final.body;
                }
                allocator.free(final.body);
                allocator.free(final.status_text);
                return error.BadStatus;
            }
            return last_err;
        }
        return e;
    };
    // 2xx 且 body 为空（Zig 路径常见于 Keep-Alive 复用导致连接被关）：用 libcurl 回退，失败则再试一次、间隔 1s，提高瞬断场景成功率
    if (resp.status >= 200 and resp.status < 300 and resp.body.len == 0) {
        allocator.free(resp.body);
        allocator.free(resp.status_text);
        resp = requestViaLibCurl(allocator, url, curl_opts) catch blk: {
            std.Thread.sleep(1_000_000_000);
            break :blk requestViaLibCurl(allocator, url, curl_opts) catch return error.CurlFailed;
        };
    }
    if (resp.status < 200 or resp.status >= 300) {
        allocator.free(resp.body);
        allocator.free(resp.status_text);
        return error.BadStatus;
    }
    allocator.free(resp.status_text);
    return resp.body;
}

/// 内部：使用已有 CurlClient 做 GET（libcurl 路径）；不对外暴露，仅保留供将来若有内部复用需求。调用方 free 返回的切片。
fn getWithCurlClient(curl_client: *CurlClient, allocator: std.mem.Allocator, url: []const u8, options: GetOptions) ![]const u8 {
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
        .timeout_sec = options.timeout_sec,
        .user_agent = options.user_agent,
        .accept_encoding = options.accept_encoding,
        .raw_body = options.raw_body,
        .keep_compressed = options.keep_compressed,
        .headers = headers[0..n],
    };
    const resp = requestViaLibCurlWithClient(curl_client, allocator, url, opts) catch |e| return e;
    if (resp.status < 200 or resp.status >= 300) {
        allocator.free(resp.body);
        allocator.free(resp.status_text);
        if (resp.content_encoding) |e| allocator.free(e);
        return error.BadStatus;
    }
    allocator.free(resp.status_text);
    if (resp.content_encoding) |e| allocator.free(e);
    return resp.body;
}

/// tarball 下载专用：默认 raw_body true、keep_compressed false，在 HTTP 层解压 gzip 后返回 tar 字节，写入 .tgz 文件后由 extractRawTarFromSlice 解析，避免镜像 gzip 与本地流式解压不兼容。调用方 free 返回的切片。
fn getTarballWithCurlClient(curl_client: *CurlClient, allocator: std.mem.Allocator, url: []const u8, options: TarballGetOptions) ![]const u8 {
    return getWithCurlClient(curl_client, allocator, url, .{
        .accept = options.accept orelse tarball_default_accept,
        .accept_encoding = options.accept_encoding orelse tarball_default_accept_encoding,
        .raw_body = options.raw_body orelse true,
        .keep_compressed = false,
        .max_bytes = options.max_bytes,
        .timeout_sec = options.timeout_sec,
        .user_agent = options.user_agent,
    });
}

/// 内部：使用已有 CurlClient 做 GET 并返回完整 Response；不对外暴露。
fn getWithCurlClientResponse(curl_client: *CurlClient, allocator: std.mem.Allocator, url: []const u8, options: GetOptions) !Response {
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
        .timeout_sec = options.timeout_sec,
        .user_agent = options.user_agent,
        .accept_encoding = options.accept_encoding,
        .raw_body = options.raw_body,
        .keep_compressed = options.keep_compressed,
        .headers = headers[0..n],
    };
    return requestViaLibCurlWithClient(curl_client, allocator, url, opts);
}

// -----------------------------------------------------------------------------
// Zig 路径：完整方法 + 状态 + 响应体
// -----------------------------------------------------------------------------

fn requestViaZig(allocator: std.mem.Allocator, url: []const u8, options: RequestOptions) !Response {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();
    return requestViaZigWithClient(&client, allocator, url, options);
}

/// 使用已有 Client 发请求，不 deinit client，供连接复用。仅 Zig 路径。
fn requestViaZigWithClient(client: *std.http.Client, allocator: std.mem.Allocator, url: []const u8, options: RequestOptions) !Response {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    const ua = options.user_agent orelse default_user_agent;
    const method = toStdMethod(options.method);

    var extra_list: [24]std.http.Header = undefined;
    var n_extra: usize = 0;
    for (options.headers) |h| {
        if (n_extra >= extra_list.len) break;
        extra_list[n_extra] = .{ .name = h.name, .value = h.value };
        n_extra += 1;
    }
    // Zig 路径仅支持 gzip/deflate，不支持 br；Accept-Encoding 固定为 gzip, deflate，服务端若回 br 则 receiveHead 返回 HttpContentEncodingUnsupported，转为 ReadFailed 走 libcurl。
    const enc = options.accept_encoding orelse "gzip, deflate";
    var req = client.request(method, uri, .{
        .redirect_behavior = std.http.Client.Request.RedirectBehavior.init(5),
        .headers = .{
            .user_agent = .{ .override = ua },
            .accept_encoding = .{ .override = enc },
        },
        .extra_headers = extra_list[0..n_extra],
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

    // 使用标准库 req.receiveHead() 保证 Request 内部状态（response_transfer_encoding/response_content_length）正确，body 才能被正确读取。不支持 br：服务端若回 Content-Encoding: br 则转为 ReadFailed 走 libcurl。
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
    // 始终用 allocator 分配，便于 errdefer 统一释放；dupe 失败时退化为 "Unknown" 再 dupe，仍失败则返回 OOM
    const status_text = if (phrase) |p|
        (allocator.dupe(u8, p) catch allocator.dupe(u8, "Unknown") catch return error.OutOfMemory)
    else
        (allocator.dupe(u8, statusCodeToStatic(status)) catch allocator.dupe(u8, "Unknown") catch return error.OutOfMemory);
    errdefer allocator.free(status_text);

    if (!method.responseHasBody()) {
        return .{
            .status = status,
            .status_text = status_text,
            .body = try allocator.dupe(u8, ""),
        };
    }

    // 先取 content_encoding / content_length，再调 reader()（reader 会 invalidate response.head 的字符串）
    const content_encoding = response.head.content_encoding;
    const content_length = response.head.content_length;
    // 使用 allocRemaining 读 body，与 Zig Cookbook / fetch 一致；readReaderUpTo 在首读返回 0 时误当 EOF 会得到空 body（连接复用下常见），allocRemaining 会读到 EndOfStream 或 limit。
    var transfer_buf: [64 * 1024]u8 = undefined;
    const raw_reader = response.reader(&transfer_buf);
    const raw_body = raw_reader.allocRemaining(allocator, std.io.Limit.limited(options.max_response_bytes)) catch |e| {
        if (e == error.StreamTooLong) {
            debugLogResponseTooLarge(url, options.max_response_bytes);
            return error.ResponseTooLarge;
        }
        debugLogReadFailed(url, e, "read");
        return e;
    };
    defer allocator.free(raw_body);
    // 连接复用下常出现：头里有 Content-Length 但读到的 body 为 0 字节（连接已坏）。视为 ReadFailed，让 getWithClient 走 3 次 libcurl 重试。
    if (raw_body.len == 0) {
        const expected_len = content_length orelse 0;
        if (expected_len > 0) {
            debugLogEmptyRawBody(url, status, content_encoding, content_length);
            debugLogReadFailed(url, error.ReadFailed, "empty_raw_body");
            return error.ReadFailed;
        }
        debugLogEmptyRawBody(url, status, content_encoding, content_length);
    }
    // 有 Content-Length 时若读到的字节数不足，说明连接提前关闭或串数据，body 会被截断（如 registry JSON 不完整导致 InvalidRegistryResponse）。视为 ReadFailed 以便重试。
    if (content_length) |expected| {
        if (raw_body.len < expected) {
            if (std.posix.getenv("SHU_DEBUG_HTTP")) |_| {
                var buf: [256]u8 = undefined;
                var fbs = std.io.fixedBufferStream(&buf);
                fbs.writer().print("[shu http] body truncated url={s} expected={d} got={d}\n", .{ url, expected, raw_body.len }) catch {};
                _ = std.posix.write(2, fbs.getWritten()) catch {};
            }
            debugLogReadFailed(url, error.ReadFailed, "body_truncated");
            return error.ReadFailed;
        }
    }

    // Zig 路径仅解压 gzip/deflate（std.compress.flate）；br 由 receiveHead 返回 HttpContentEncodingUnsupported 已转为 ReadFailed 走 libcurl。
    const body = switch (content_encoding) {
        .identity => try allocator.dupe(u8, raw_body),
        .gzip, .deflate => blk: {
            // 与 install 中 tgz 解压一致：用 std.compress.flate.Decompress 解压，避免 readerDecompressing 在连接复用下返回空；HTTP deflate 用 zlib 格式。
            var in_reader = std.io.Reader.fixed(raw_body);
            var dec_buf: [std.compress.flate.max_window_len]u8 = undefined;
            const container: std.compress.flate.Container = if (content_encoding == .gzip) .gzip else .zlib;
            var dec = std.compress.flate.Decompress.init(&in_reader, container, &dec_buf);
            break :blk file.readReaderUpTo(allocator, &dec.reader, options.max_response_bytes) catch |e| {
                if (e == error.ResponseTooLarge) debugLogResponseTooLarge(url, options.max_response_bytes);
                debugLogReadFailed(url, e, "decompress");
                return e;
            };
        },
        .zstd => return error.UnsupportedCompressionMethod,
        .compress => return error.UnsupportedCompressionMethod,
    };
    return .{
        .status = status,
        .status_text = status_text,
        .body = body,
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

// -----------------------------------------------------------------------------
// libcurl 路径：进程内 C 库，支持 CURLOPT_TIMEOUT，无子进程；支持 CurlClient 连接复用
// -----------------------------------------------------------------------------

/// 进程级只执行一次 curl_global_init，避免每次请求重复初始化（SSL/协议表等开销大且非线程安全）。由 main 启动时调用，或首次使用 libcurl 时惰性调用。
pub fn ensureCurlGlobalInit() void {
    curl_global_mutex.lock();
    defer curl_global_mutex.unlock();
    if (!curl_global_done) {
        _ = c.curl_global_init(c.CURL_GLOBAL_DEFAULT);
        curl_global_done = true;
    }
}

var curl_global_mutex: std.Thread.Mutex = .{};
var curl_global_done: bool = false;

const LibCurlWriteContext = struct {
    list: std.ArrayList(u8),
    allocator: std.mem.Allocator,
    max_bytes: usize,
    /// 由 header 回调解析得到时，首包写入前 ensureTotalCapacity 以减重分配与拷贝
    content_length: ?usize = null,
};

fn curlWriteCallback(ptr: [*]const u8, size: usize, nmemb: usize, userdata: ?*anyopaque) callconv(.c) usize {
    const ctx = @as(*LibCurlWriteContext, @ptrCast(@alignCast(userdata orelse return 0)));
    const chunk = size * nmemb;
    if (chunk == 0) return 0;
    const remain = ctx.max_bytes - ctx.list.items.len;
    if (remain == 0) return 0;
    // Content-Length 已知且为首包时预分配，减少 ArrayList 多次扩容与拷贝
    if (ctx.list.items.len == 0) {
        if (ctx.content_length) |cl| {
            if (cl <= ctx.max_bytes)
                ctx.list.ensureTotalCapacity(ctx.allocator, cl) catch {};
        }
    }
    const to_append = @min(chunk, remain);
    ctx.list.appendSlice(ctx.allocator, ptr[0..to_append]) catch return 0;
    return to_append;
}

/// 仅解析 Content-Length 响应头并写入 *?usize，不分配；供 requestViaLibCurl 预分配 body 缓冲。
fn curlContentLengthHeaderCallback(ptr: [*]const u8, size: usize, nmemb: usize, userdata: ?*anyopaque) callconv(.c) usize {
    const out = @as(*?usize, @ptrCast(@alignCast(userdata orelse return size * nmemb)));
    if (out.* != null) return size * nmemb;
    const n = size * nmemb;
    if (n < 16) return n;
    const line = ptr[0..n];
    const prefix = "Content-Length:";
    if (line.len >= prefix.len and std.ascii.eqlIgnoreCase(line[0..prefix.len], prefix)) {
        const rest = std.mem.trim(u8, line[prefix.len..], " \t\r\n");
        out.* = std.fmt.parseInt(usize, rest, 10) catch null;
    }
    return n;
}

/// 单缓冲构建 curl_slist：所有 "Name: Value\0" 写入 buf，避免每头 allocPrint+dupeZ 双重分配。调用方在 perform 后负责 buf.deinit(allocator) 与 slist_free_all。
fn buildCurlHeaderSlist(allocator: std.mem.Allocator, ua: []const u8, accept_encoding: ?[]const u8, headers: []const Header) !struct { slist: ?*c.curl_slist, buf: std.ArrayList(u8) } {
    var buf = std.ArrayList(u8).initCapacity(allocator, 512) catch return error.OutOfMemory;
    var starts = std.ArrayList(usize).initCapacity(allocator, headers.len + 2) catch return error.OutOfMemory;
    defer starts.deinit(allocator);

    // User-Agent：直接 append 字符串 + \0，避免 default 时也 allocPrint
    try starts.append(allocator, buf.items.len);
    try buf.appendSlice(allocator, "User-Agent: ");
    try buf.appendSlice(allocator, ua);
    try buf.append(allocator, 0);

    if (accept_encoding) |enc| {
        try starts.append(allocator, buf.items.len);
        try buf.appendSlice(allocator, "Accept-Encoding: ");
        try buf.appendSlice(allocator, enc);
        try buf.append(allocator, 0);
    }
    for (headers) |h| {
        try starts.append(allocator, buf.items.len);
        try buf.appendSlice(allocator, h.name);
        try buf.appendSlice(allocator, ": ");
        try buf.appendSlice(allocator, h.value);
        try buf.append(allocator, 0);
    }

    var slist: ?*c.curl_slist = null;
    for (starts.items) |start| {
        const new_slist = c.curl_slist_append(slist, buf.items.ptr + start);
        if (new_slist == null) {
            if (slist) |s| c.curl_slist_free_all(s);
            return error.OutOfMemory;
        }
        slist = new_slist;
    }
    return .{ .slist = slist, .buf = buf };
}

/// raw_body 时从响应头解析 Content-Encoding、Content-Length（用于截断校验）。
const LibCurlHeaderContext = struct {
    allocator: std.mem.Allocator,
    content_encoding: ?[]const u8 = null,
    content_length: ?usize = null,
};

fn curlHeaderCallback(ptr: [*]const u8, size: usize, nmemb: usize, userdata: ?*anyopaque) callconv(.c) usize {
    const ctx = @as(*LibCurlHeaderContext, @ptrCast(@alignCast(userdata orelse return 0)));
    const n = size * nmemb;
    if (n < 14) return n;
    const line = ptr[0..n];
    if (ctx.content_encoding == null and n >= 16) {
        const enc_prefix = "Content-Encoding:";
        if (line.len >= enc_prefix.len and std.ascii.eqlIgnoreCase(line[0..enc_prefix.len], enc_prefix)) {
            var rest = line[enc_prefix.len..];
            rest = std.mem.trim(u8, rest, " \t\r\n");
            if (rest.len > 0) {
                ctx.content_encoding = ctx.allocator.dupe(u8, rest) catch return n;
            }
        }
    }
    const len_prefix = "Content-Length:";
    if (line.len >= len_prefix.len and std.ascii.eqlIgnoreCase(line[0..len_prefix.len], len_prefix)) {
        const rest = std.mem.trim(u8, line[len_prefix.len..], " \t\r\n");
        ctx.content_length = std.fmt.parseInt(usize, rest, 10) catch null;
    }
    return n;
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
    if (std.posix.getenv("SHU_DEBUG_HTTP")) |_| {} else return;
    var buf: [128]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    fbs.writer().print("[shu http] decompress enc={s} before={d} after={d}\n", .{ enc, before, after }) catch return;
    _ = std.posix.write(2, fbs.getWritten()) catch {};
}

/// 内部：可复用的 libcurl easy 句柄，不对外暴露；Zig 失败回退使用 requestViaLibCurl（单次请求），不依赖本类型。
const CurlClient = struct {
    easy: ?*c.CURL = null,

    /// 创建并持有 libcurl easy 句柄；依赖进程级 ensureCurlGlobalInit（main 或首次使用时已初始化）。
    fn init() CurlClient {
        ensureCurlGlobalInit();
        const easy = c.curl_easy_init();
        return .{ .easy = easy };
    }

    /// 释放 easy 句柄；不调用 curl_global_cleanup。
    fn deinit(self: *CurlClient) void {
        if (self.easy) |e| {
            c.curl_easy_cleanup(e);
            self.easy = null;
        }
    }
};

/// 使用已有 CurlClient 发请求，复用连接；每次调用会设置 URL/headers/write 等并 perform，不销毁 easy。
fn requestViaLibCurlWithClient(curl_client: *CurlClient, allocator: std.mem.Allocator, url: []const u8, options: RequestOptions) !Response {
    const easy = curl_client.easy orelse return error.CurlFailed;
    const url_z = try allocator.dupeZ(u8, url);
    defer allocator.free(url_z);
    const ua = options.user_agent orelse default_user_agent;

    var write_ctx = LibCurlWriteContext{
        .list = std.ArrayList(u8).initCapacity(allocator, 65536) catch return error.OutOfMemory,
        .allocator = allocator,
        .max_bytes = options.max_response_bytes,
    };
    defer write_ctx.list.deinit(allocator);

    var slist_ctx = buildCurlHeaderSlist(allocator, ua, options.accept_encoding, options.headers) catch return error.OutOfMemory;
    defer slist_ctx.buf.deinit(allocator);
    defer if (slist_ctx.slist) |s| c.curl_slist_free_all(s);

    _ = c.curl_easy_setopt(easy, c.CURLOPT_URL, url_z.ptr);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
    if (options.timeout_sec > 0) {
        _ = c.curl_easy_setopt(easy, c.CURLOPT_TIMEOUT, options.timeout_sec);
        _ = c.curl_easy_setopt(easy, c.CURLOPT_CONNECTTIMEOUT, @as(c_long, 10));
    }
    // SHU_DEBUG_HTTP 时开启 libcurl 详细日志到 stderr，便于排查超时/SSL
    if (std.posix.getenv("SHU_DEBUG_HTTP")) |e| {
        if (e.len > 0) _ = c.curl_easy_setopt(easy, c.CURLOPT_VERBOSE, @as(c_long, 1));
    }
    _ = c.curl_easy_setopt(easy, c.CURLOPT_HTTPHEADER, slist_ctx.slist);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_WRITEFUNCTION, curlWriteCallback);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_WRITEDATA, &write_ctx);

    var resp_header_ctx = LibCurlHeaderContext{ .allocator = allocator };
    // raw_body 时：解析 Content-Encoding 响应头；不设 CURLOPT_ACCEPT_ENCODING 以便请求头 Accept-Encoding 照常发送；
    // 显式关闭 curl 对响应的解压，保证拿到原始 gzip 字节写回 .tgz。
    if (options.raw_body) {
        _ = c.curl_easy_setopt(easy, c.CURLOPT_HEADERFUNCTION, curlHeaderCallback);
        _ = c.curl_easy_setopt(easy, c.CURLOPT_HEADERDATA, &resp_header_ctx);
        _ = c.curl_easy_setopt(easy, c.CURLOPT_HTTP_CONTENT_DECODING, @as(c_long, 0));
    }

    switch (options.method) {
        .GET => _ = c.curl_easy_setopt(easy, c.CURLOPT_HTTPGET, @as(c_long, 1)),
        .HEAD => {
            _ = c.curl_easy_setopt(easy, c.CURLOPT_HTTPGET, @as(c_long, 1));
            _ = c.curl_easy_setopt(easy, c.CURLOPT_NOBODY, @as(c_long, 1));
        },
        .POST => {
            _ = c.curl_easy_setopt(easy, c.CURLOPT_POST, @as(c_long, 1));
            if (options.body) |body| {
                if (body.len > 0) {
                    _ = c.curl_easy_setopt(easy, c.CURLOPT_POSTFIELDS, body.ptr);
                    _ = c.curl_easy_setopt(easy, c.CURLOPT_POSTFIELDSIZE, body.len);
                }
            }
        },
        .PUT, .PATCH, .DELETE, .OPTIONS => {
            const method_str: [*:0]const u8 = switch (options.method) {
                .PUT => "PUT",
                .PATCH => "PATCH",
                .DELETE => "DELETE",
                .OPTIONS => "OPTIONS",
                else => unreachable,
            };
            _ = c.curl_easy_setopt(easy, c.CURLOPT_CUSTOMREQUEST, method_str);
            if (options.body) |body| {
                if (body.len > 0) {
                    _ = c.curl_easy_setopt(easy, c.CURLOPT_POSTFIELDS, body.ptr);
                    _ = c.curl_easy_setopt(easy, c.CURLOPT_POSTFIELDSIZE, body.len);
                }
            }
        },
    }

    const res = c.curl_easy_perform(easy);
    var code: c_long = 0;
    _ = c.curl_easy_getinfo(easy, c.CURLINFO_RESPONSE_CODE, &code);
    const status: u16 = @intCast(code);

    if (res != c.CURLE_OK and res != c.CURLE_WRITE_ERROR) {
        debugLogCurlFailed(url, res);
        return error.CurlFailed;
    }

    const body = write_ctx.list.toOwnedSlice(allocator) catch return error.OutOfMemory;
    if (options.raw_body and resp_header_ctx.content_length != null and body.len < resp_header_ctx.content_length.?) {
        allocator.free(body);
        if (std.posix.getenv("SHU_DEBUG_HTTP")) |_| {
            var buf: [256]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            fbs.writer().print("[shu http] body truncated (curl) url={s} expected={d} got={d}\n", .{
                url,
                resp_header_ctx.content_length.?,
                body.len,
            }) catch {};
            _ = std.posix.write(2, fbs.getWritten()) catch {};
        }
        return error.ReadFailed;
    }
    const status_text = try allocator.dupe(u8, statusCodeToStatic(status));
    var resp: Response = .{
        .status = status,
        .status_text = status_text,
        .body = body,
        .content_encoding = resp_header_ctx.content_encoding,
    };
    if (options.raw_body and !options.keep_compressed) {
        try decompressResponseBodyIfNeeded(allocator, &resp);
    }
    return resp;
}

fn requestViaLibCurl(allocator: std.mem.Allocator, url: []const u8, options: RequestOptions) !Response {
    ensureCurlGlobalInit();

    const url_z = try allocator.dupeZ(u8, url);
    defer allocator.free(url_z);
    const ua = options.user_agent orelse default_user_agent;

    const easy = c.curl_easy_init() orelse return error.CurlFailed;
    defer c.curl_easy_cleanup(easy);

    var write_ctx = LibCurlWriteContext{
        .list = std.ArrayList(u8).initCapacity(allocator, 65536) catch return error.OutOfMemory,
        .allocator = allocator,
        .max_bytes = options.max_response_bytes,
    };
    defer write_ctx.list.deinit(allocator);

    var header_ctx = buildCurlHeaderSlist(allocator, ua, options.accept_encoding, options.headers) catch return error.OutOfMemory;
    defer header_ctx.buf.deinit(allocator);
    defer if (header_ctx.slist) |s| c.curl_slist_free_all(s);

    _ = c.curl_easy_setopt(easy, c.CURLOPT_URL, url_z.ptr);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
    if (options.timeout_sec > 0) {
        _ = c.curl_easy_setopt(easy, c.CURLOPT_TIMEOUT, options.timeout_sec);
        _ = c.curl_easy_setopt(easy, c.CURLOPT_CONNECTTIMEOUT, @as(c_long, 10));
    }
    // SHU_DEBUG_HTTP 时开启 libcurl 详细日志到 stderr，便于排查超时/SSL
    if (std.posix.getenv("SHU_DEBUG_HTTP")) |e| {
        if (e.len > 0) _ = c.curl_easy_setopt(easy, c.CURLOPT_VERBOSE, @as(c_long, 1));
    }
    _ = c.curl_easy_setopt(easy, c.CURLOPT_HTTPHEADER, header_ctx.slist);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_HEADERFUNCTION, curlContentLengthHeaderCallback);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_HEADERDATA, &write_ctx.content_length);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_WRITEFUNCTION, curlWriteCallback);
    _ = c.curl_easy_setopt(easy, c.CURLOPT_WRITEDATA, &write_ctx);

    switch (options.method) {
        .GET => _ = c.curl_easy_setopt(easy, c.CURLOPT_HTTPGET, @as(c_long, 1)),
        .HEAD => {
            _ = c.curl_easy_setopt(easy, c.CURLOPT_HTTPGET, @as(c_long, 1));
            _ = c.curl_easy_setopt(easy, c.CURLOPT_NOBODY, @as(c_long, 1));
        },
        .POST => {
            _ = c.curl_easy_setopt(easy, c.CURLOPT_POST, @as(c_long, 1));
            if (options.body) |body| {
                if (body.len > 0) {
                    _ = c.curl_easy_setopt(easy, c.CURLOPT_POSTFIELDS, body.ptr);
                    _ = c.curl_easy_setopt(easy, c.CURLOPT_POSTFIELDSIZE, body.len);
                }
            }
        },
        .PUT, .PATCH, .DELETE, .OPTIONS => {
            const method_str: [*:0]const u8 = switch (options.method) {
                .PUT => "PUT",
                .PATCH => "PATCH",
                .DELETE => "DELETE",
                .OPTIONS => "OPTIONS",
                else => unreachable,
            };
            _ = c.curl_easy_setopt(easy, c.CURLOPT_CUSTOMREQUEST, method_str);
            if (options.body) |body| {
                if (body.len > 0) {
                    _ = c.curl_easy_setopt(easy, c.CURLOPT_POSTFIELDS, body.ptr);
                    _ = c.curl_easy_setopt(easy, c.CURLOPT_POSTFIELDSIZE, body.len);
                }
            }
        },
    }

    const res = c.curl_easy_perform(easy);
    var code: c_long = 0;
    _ = c.curl_easy_getinfo(easy, c.CURLINFO_RESPONSE_CODE, &code);
    const status: u16 = @intCast(code);

    if (res != c.CURLE_OK and res != c.CURLE_WRITE_ERROR) {
        debugLogCurlFailed(url, res);
        return error.CurlFailed;
    }

    const body = write_ctx.list.toOwnedSlice(allocator) catch return error.OutOfMemory;
    const status_text = try allocator.dupe(u8, statusCodeToStatic(status));
    return .{
        .status = status,
        .status_text = status_text,
        .body = body,
    };
}
