//! Shu.server 集成测试：后台启动服务，TCP 发请求，校验响应；覆盖 ServerConfig 各项配置。
//! 依赖：zig build test 前 install，且需 --allow-net 的 shu 可执行文件。
//! 每用例使用独立端口（19500～19509）避免并行或残留占用。
//!
//! 覆盖的 ServerConfig / options：
//!   - port, host, fetch（基础）
//!   - maxRequestLineLength → 400 Bad Request
//!   - maxRequestBodySize → 413 Payload Too Large
//!   - server → 自定义 Server 头
//!   - compression: false
//!   - listenBacklog, keepAliveTimeout, readBufferSize, writeBufInitialCapacity, pollIdleMs（选项接受）
//!   - fetch 返回 404、POST 带 body

const std = @import("std");
const spawnShuBackground = @import("../shu_run.zig").spawnShuBackground;

const BIND_HOST: []const u8 = "127.0.0.1";
const STARTUP_MS: u64 = 800;

/// 后台启动 shu -e "script"（带 extra_args），等待 STARTUP_MS，连接 port，发送 request，读满 buf 后关闭并 kill 子进程；返回读到的字节数，连接失败返回 0（调用方可 skip）。
fn request(
    allocator: std.mem.Allocator,
    port: u16,
    script: []const u8,
    extra_args: []const []const u8,
    request_bytes: []const u8,
    response_buf: []u8,
) usize {
    var child = spawnShuBackground(allocator, script, extra_args) catch return 0;
    defer _ = child.kill() catch {};
    std.time.sleep(STARTUP_MS * std.time.ns_per_ms);
    const conn = std.net.tcp.connectToHost(allocator, BIND_HOST, port) catch {
        _ = child.wait() catch {};
        return 0;
    };
    defer conn.close();
    _ = conn.write(request_bytes) catch {
        _ = child.wait() catch {};
        return 0;
    };
    const n = conn.read(response_buf) catch {
        _ = child.wait() catch {};
        return 0;
    };
    _ = child.kill() catch {};
    _ = child.wait() catch {};
    return n;
}

/// 是否在 response 中包含子串（不区分大小写找 status 行时用）
fn responseContains(response: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, response, needle) != null;
}

// ---------------------------------------------------------------------------
// 基础：port / host / fetch
// ---------------------------------------------------------------------------

test "Shu.server: GET 返回 200 与 body" {
    const allocator = std.testing.allocator;
    const script =
        \\const s = Shu.server({ port: 19500, host: '127.0.0.1', fetch: function(req) { return new Response('pong'); } });
    ;
    var buf: [4096]u8 = undefined;
    const n = request(allocator, 19500, script, &.{"--allow-net"}, "GET / HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n", &buf);
    try std.testing.expect(n > 0);
    const response = buf[0..n];
    try std.testing.expect(responseContains(response, "200"));
    try std.testing.expect(responseContains(response, "OK"));
    try std.testing.expect(responseContains(response, "pong"));
}

test "Shu.server: 不同 path 与 method" {
    const allocator = std.testing.allocator;
    const script =
        \\const s = Shu.server({ port: 19501, host: '127.0.0.1', fetch: function(req) { return new Response(req.url + ' ' + req.method, { headers: { 'Content-Type': 'text/plain' } }); } });
    ;
    var buf: [4096]u8 = undefined;
    const n = request(allocator, 19501, script, &.{"--allow-net"}, "GET /foo HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n", &buf);
    try std.testing.expect(n > 0);
    try std.testing.expect(responseContains(buf[0..n], "200"));
}

// ---------------------------------------------------------------------------
// ServerConfig: maxRequestLineLength → 400 Bad Request
// ---------------------------------------------------------------------------

test "Shu.server: maxRequestLineLength 超长请求行返回 400" {
    const allocator = std.testing.allocator;
    // 请求行限制 50；"GET /" + 50 个 a + " HTTP/1.0" 远超 50 字符
    const script =
        \\const s = Shu.server({ port: 19502, host: '127.0.0.1', maxRequestLineLength: 50, fetch: function(req) { return new Response('ok'); } });
    ;
    var path: [60]u8 = undefined;
    path[0] = '/';
    for (path[1..51]) |*c| c.* = 'a';
    var req_buf: [256]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n", .{path[0..50]}) catch return;
    var buf: [4096]u8 = undefined;
    const n = request(allocator, 19502, script, &.{"--allow-net"}, req, &buf);
    try std.testing.expect(n > 0);
    const response = buf[0..n];
    try std.testing.expect(responseContains(response, "400"));
    try std.testing.expect(responseContains(response, "Bad Request"));
}

// ---------------------------------------------------------------------------
// ServerConfig: maxRequestBodySize → 413 Payload Too Large
// ---------------------------------------------------------------------------

test "Shu.server: maxRequestBodySize 超限返回 413" {
    const allocator = std.testing.allocator;
    const script =
        \\const s = Shu.server({ port: 19503, host: '127.0.0.1', maxRequestBodySize: 10, fetch: function(req) { return new Response('ok'); } });
    ;
    const body = "0123456789abcdefghij";
    var req_buf: [128]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "POST / HTTP/1.0\r\nHost: 127.0.0.1\r\nContent-Length: 20\r\n\r\n{s}", .{body}) catch return;
    var buf: [4096]u8 = undefined;
    const n = request(allocator, 19503, script, &.{"--allow-net"}, req, &buf);
    try std.testing.expect(n > 0);
    const response = buf[0..n];
    try std.testing.expect(responseContains(response, "413"));
    try std.testing.expect(responseContains(response, "Payload Too Large"));
}

// ---------------------------------------------------------------------------
// ServerConfig: server → 自定义 Server 头
// ---------------------------------------------------------------------------

test "Shu.server: options.server 自定义 Server 头" {
    const allocator = std.testing.allocator;
    const script =
        \\const s = Shu.server({ port: 19504, host: '127.0.0.1', server: 'MyApp/1.0', fetch: function(req) { return new Response(''); } });
    ;
    var buf: [4096]u8 = undefined;
    const n = request(allocator, 19504, script, &.{"--allow-net"}, "GET / HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n", &buf);
    try std.testing.expect(n > 0);
    try std.testing.expect(responseContains(buf[0..n], "Server: MyApp/1.0"));
}

// ---------------------------------------------------------------------------
// fetch 返回 404
// ---------------------------------------------------------------------------

test "Shu.server: fetch 返回 404" {
    const allocator = std.testing.allocator;
    const script =
        \\const s = Shu.server({ port: 19505, host: '127.0.0.1', fetch: function(req) { return new Response('gone', { status: 404 }); } });
    ;
    var buf: [4096]u8 = undefined;
    const n = request(allocator, 19505, script, &.{"--allow-net"}, "GET / HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n", &buf);
    try std.testing.expect(n > 0);
    const response = buf[0..n];
    try std.testing.expect(responseContains(response, "404"));
    try std.testing.expect(responseContains(response, "Not Found"));
}

// ---------------------------------------------------------------------------
// ServerConfig: compression 关闭（仅确认选项生效、请求正常）
// ---------------------------------------------------------------------------

test "Shu.server: compression: false 正常响应" {
    const allocator = std.testing.allocator;
    const script =
        \\const s = Shu.server({ port: 19506, host: '127.0.0.1', compression: false, fetch: function(req) { return new Response('no-compress'); } });
    ;
    var buf: [4096]u8 = undefined;
    const n = request(allocator, 19506, script, &.{"--allow-net"}, "GET / HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n", &buf);
    try std.testing.expect(n > 0);
    try std.testing.expect(responseContains(buf[0..n], "200"));
    try std.testing.expect(responseContains(buf[0..n], "no-compress"));
}

// ---------------------------------------------------------------------------
// ServerConfig: listenBacklog（仅确认选项接受、能监听）
// ---------------------------------------------------------------------------

test "Shu.server: listenBacklog 选项接受" {
    const allocator = std.testing.allocator;
    const script =
        \\const s = Shu.server({ port: 19507, host: '127.0.0.1', listenBacklog: 4, fetch: function(req) { return new Response('ok'); } });
    ;
    var buf: [4096]u8 = undefined;
    const n = request(allocator, 19507, script, &.{"--allow-net"}, "GET / HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n", &buf);
    try std.testing.expect(n > 0);
    try std.testing.expect(responseContains(buf[0..n], "200"));
}

// ---------------------------------------------------------------------------
// ServerConfig: keepAliveTimeout、readBufferSize、writeBufInitialCapacity、pollIdleMs（仅确认选项接受）
// ---------------------------------------------------------------------------

test "Shu.server: keepAliveTimeout / readBufferSize / pollIdleMs 选项接受" {
    const allocator = std.testing.allocator;
    const script =
        \\const s = Shu.server({ port: 19508, host: '127.0.0.1', keepAliveTimeout: 2, readBufferSize: 8192, writeBufInitialCapacity: 2048, pollIdleMs: 50, fetch: function(req) { return new Response('ok'); } });
    ;
    var buf: [4096]u8 = undefined;
    const n = request(allocator, 19508, script, &.{"--allow-net"}, "GET / HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n", &buf);
    try std.testing.expect(n > 0);
    try std.testing.expect(responseContains(buf[0..n], "200"));
}

// ---------------------------------------------------------------------------
// POST 带小 body，fetch 正常返回
// ---------------------------------------------------------------------------

test "Shu.server: POST 带 body 返回 200" {
    const allocator = std.testing.allocator;
    const script =
        \\const s = Shu.server({ port: 19509, host: '127.0.0.1', fetch: function(req) { return new Response(req.method + ':ok'); } });
    ;
    const req = "POST / HTTP/1.0\r\nHost: 127.0.0.1\r\nContent-Length: 5\r\n\r\nhello";
    var buf: [4096]u8 = undefined;
    const n = request(allocator, 19509, script, &.{"--allow-net"}, req, &buf);
    try std.testing.expect(n > 0);
    const response = buf[0..n];
    try std.testing.expect(responseContains(response, "200"));
    try std.testing.expect(responseContains(response, "POST:ok"));
}
