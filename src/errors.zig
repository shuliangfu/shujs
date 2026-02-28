// 错误码与文档链接，供 CLI/runtime/transpiler 等统一报错
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1
// Zig 0.15.2：stderr 使用 std.fs.File.stderr().writer(...)

const std = @import("std");

/// 统一错误码（后续按模块扩展）
pub const Code = enum(u16) {
    unknown = 0,
    permission_denied = 1,
    file_not_found = 2,
    parse_error = 3,
    type_error = 4,
    _,
};

/// 错误详情：码 + 消息 + 可选文档链接
pub const Diagnostic = struct {
    code: Code = .unknown,
    message: []const u8,
    doc_url: ?[]const u8 = null,

    /// 格式化为一行文本写入 writer（含换行）
    pub fn format(self: Diagnostic, writer: anytype) !void {
        try writer.print("[{s}] {s}", .{ @tagName(self.code), self.message });
        if (self.doc_url) |url| {
            try writer.print(" 文档: {s}", .{url});
        }
        try writer.writeAll("\n");
    }
};

/// 将 Diagnostic 输出到 stderr（Zig 0.15.2 使用 std.fs.File.stderr().writer）
pub fn reportToStderr(d: Diagnostic) !void {
    var buf: [512]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    const out = &w.interface;
    try d.format(out);
    try out.flush();
}

/// 返回错误码对应的文档 URL（若有）
pub fn docUrl(code: Code) ?[]const u8 {
    _ = code;
    return null; // TODO: 按码返回文档链接
}
