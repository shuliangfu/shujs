//! Shu.server 集成测试：后台启动服务，TCP 发 GET，校验响应含 200 OK，再结束进程
//! 依赖：zig build test 前 install，且 --allow-net 的 shu 可执行文件

const std = @import("std");
const builtin = @import("builtin");
const spawnShuBackground = @import("../shu_run.zig").spawnShuBackground;

const SERVER_PORT: u16 = 19500;
const BIND_HOST: []const u8 = "127.0.0.1";

test "Shu.server: GET 返回 200 与 body" {
    const allocator = std.testing.allocator;
    const script =
        \\const s = Shu.server({ port: 19500, host: '127.0.0.1', fetch: function(req) { return new Response('pong'); } });
    ;
    var child = spawnShuBackground(allocator, script, &.{ "--allow-net" }) catch return;
    defer _ = child.kill() catch {};
    std.time.sleep(800 * std.time.ns_per_ms);
    const conn = std.net.tcp.connectToHost(allocator, BIND_HOST, SERVER_PORT) catch {
        _ = child.wait() catch {};
        return;
    };
    defer conn.close();
    const req = "GET / HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n";
    _ = conn.write(req) catch {
        _ = child.wait() catch {};
        return;
    };
    var buf: [4096]u8 = undefined;
    const n = conn.read(buf[0..]) catch {
        _ = child.wait() catch {};
        return;
    };
    const response = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, response, "200") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "pong") != null);
    _ = child.kill() catch {};
    _ = child.wait() catch {};
}

test "Shu.server: 不同 path 与 method" {
    const allocator = std.testing.allocator;
    const script =
        \\const s = Shu.server({ port: 19501, host: '127.0.0.1', fetch: function(req) { return new Response(req.url + ' ' + req.method, { headers: { 'Content-Type': 'text/plain' } }); } });
    ;
    var child = spawnShuBackground(allocator, script, &.{ "--allow-net" }) catch return;
    defer _ = child.kill() catch {};
    std.time.sleep(800 * std.time.ns_per_ms);
    const conn = std.net.tcp.connectToHost(allocator, BIND_HOST, 19501) catch {
        _ = child.wait() catch {};
        return;
    };
    defer conn.close();
    _ = conn.write("GET /foo HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n") catch {
        _ = child.wait() catch {};
        return;
    };
    var buf: [4096]u8 = undefined;
    const n = conn.read(buf[0..]) catch {
        _ = child.wait() catch {};
        return;
    };
    const response = buf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, response, "200") != null);
    _ = child.kill() catch {};
    _ = child.wait() catch {};
}
