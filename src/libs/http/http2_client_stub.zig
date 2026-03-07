//! HTTP/2 客户端占位：当 have_tls 为 false 时使用，requestViaH2 直接返回 Http2NotAvailable，由 http.zig 回退到 HTTP/1.1。

const std = @import("std");

/// 与 http.zig Response 兼容的返回值；stub 不分配，仅类型占位。
pub const H2Response = struct {
    status: u16 = 0,
    status_text: []const u8 = "",
    status_text_is_allocated: bool = false,
    body: []const u8 = "",
    content_encoding: ?[]const u8 = null,
};

/// 未启用 TLS 或 ALPN 未协商为 h2 时返回，调用方应回退到 HTTP/1.1。
pub const Http2NotAvailable = error{Http2NotAvailable};

/// [Stub] 始终返回 error.Http2NotAvailable；供 have_tls=false 时 http.zig 统一调用并回退 HTTP/1.1。
pub fn requestViaH2(allocator: std.mem.Allocator, url: []const u8, options: anytype) Http2NotAvailable!H2Response {
    _ = allocator;
    _ = url;
    _ = options;
    return error.Http2NotAvailable;
}
