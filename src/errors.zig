// 错误码与文档链接，供 CLI/runtime/transpiler 等统一报错
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1
// Zig 0.16.0-dev：stderr 使用 std.Io；进程级 io 从 libs/process.zig 取。

const std = @import("std");
const libs_process = @import("libs_process");

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
            try writer.print(" Docs: {s}", .{url});
        }
        try writer.writeAll("\n");
    }
};

/// 将 Diagnostic 输出到 stderr（Zig 0.16 使用 std.Io；依赖 main 已调用 libs_process.setProcessIo(init.io)）
pub fn reportToStderr(d: Diagnostic) !void {
    const io = libs_process.getProcessIo() orelse return; // 未设置时静默跳过
    var buf: [512]u8 = undefined;
    var w = std.Io.File.Writer.init(std.Io.File.stderr(), io, &buf);
    try d.format(&w.interface);
    w.flush() catch {};
}

/// 判断引擎返回的 .stack 是否为有效多行栈（避免 JSC 在 native 抛错时返回 "@" 等无效内容）
fn isMeaningfulStack(stack: []const u8) bool {
    if (stack.len < 4) return false;
    if (std.mem.indexOf(u8, stack, "\n") != null) return true;
    if (std.mem.indexOf(u8, stack, " at ") != null) return true;
    return false;
}

/// 脚本异常上报参数：由 require 等从 JSC 异常对象提取后传入，errors 统一格式化并写 stderr。
pub const ScriptExceptionReport = struct {
    /// 入口或出错文件路径
    file_path: []const u8,
    /// 异常 message（或 String(exception)）
    message: []const u8,
    /// Error.stack 原始字符串（可为空；若无效则用 location 或 fallback）
    stack: ?[]const u8 = null,
    /// 无有效 stack 时使用的一行位置，如 "    at (file:21)"
    location: ?[]const u8 = null,
};

/// 将脚本异常统一格式化并输出到 stderr：首行 "file_path: message"，若有有效 stack 则追加多行栈，否则用 location 或 "(stack unavailable: ...)"。与 reportToStderr 共用同一 stderr 通道。
pub fn reportScriptExceptionToStderr(r: ScriptExceptionReport) !void {
    var buf: [5120]u8 = undefined; // 首行 + \n + 约 4K stack
    const first_line = std.fmt.bufPrint(buf[0..], "{s}: {s}", .{ r.file_path, r.message }) catch blk: {
        const fallback = std.fmt.bufPrint(buf[0..], "{s}: Script threw (message too long)", .{r.file_path}) catch buf[0..0];
        break :blk fallback;
    };
    var total_len = first_line.len;
    const stack = r.stack orelse "";
    const use_stack = stack.len > 0 and isMeaningfulStack(stack);
    if (use_stack) {
        if (total_len + 1 + stack.len <= buf.len) {
            buf[total_len] = '\n';
            total_len += 1;
            @memcpy(buf[total_len..][0..stack.len], stack);
            total_len += stack.len;
        } else if (total_len + 1 < buf.len) {
            buf[total_len] = '\n';
            total_len += 1;
            const trunc = "... (stack truncated)";
            const copy_len = buf.len - total_len - trunc.len - 1;
            if (copy_len > 0) {
                @memcpy(buf[total_len..][0..copy_len], stack[0..copy_len]);
                total_len += copy_len;
                @memcpy(buf[total_len..][0..trunc.len], trunc);
                total_len += trunc.len;
            }
        }
    } else if (r.location) |loc| {
        if (loc.len > 0 and total_len + 1 + loc.len <= buf.len) {
            buf[total_len] = '\n';
            total_len += 1;
            @memcpy(buf[total_len..][0..loc.len], loc);
            total_len += loc.len;
        }
    }
    if (!use_stack and (r.location == null or (r.location != null and r.location.?.len == 0)) and total_len + 1 < buf.len) {
        const fallback = "\n    (stack unavailable: error may have originated in native/builtin code)";
        const flen = fallback.len;
        if (total_len + 1 + flen <= buf.len) {
            buf[total_len] = '\n';
            total_len += 1;
            @memcpy(buf[total_len..][0..flen], fallback);
            total_len += flen;
        }
    }
    try reportToStderr(.{ .code = .unknown, .message = buf[0..total_len] });
}

/// 返回错误码对应的文档 URL（若有）
pub fn docUrl(code: Code) ?[]const u8 {
    _ = code;
    return null; // TODO: 按码返回文档链接
}
