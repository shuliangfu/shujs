// 全局参数解析（如 --allow-net、--allow-read、--help 等）
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1
// Zig 0.15.2：无旧版 API，纯切片解析

const std = @import("std");

/// 解析后的权限与全局选项（供 runtime.permission 与子命令使用）
pub const ParsedArgs = struct {
    allow_net: bool = false,
    allow_read: bool = false,
    allow_env: bool = false,
    allow_write: bool = false,
    allow_exec: bool = false,
    /// 是否由用户传入 --help（主流程可据此打印用法后退出）
    help: bool = false,
};

/// 解析结果：全局选项 + 位置参数切片（指向原始 argv，不分配内存）
pub const ParseResult = struct {
    parsed: ParsedArgs,
    positional: []const []const u8,
};

/// 从命令行参数中解析全局选项，并分离出位置参数。
/// 从第一个不以 "--" 开头的参数起视为位置参数。
/// 典型用法：main 里取 args[2..] 传入（即去掉程序名与子命令）。
pub fn parse(args: []const []const u8) ParseResult {
    var result = ParsedArgs{};
    var i: usize = 0;
    while (i < args.len and args[i].len >= 2 and args[i][0] == '-' and args[i][1] == '-') : (i += 1) {
        if (std.mem.eql(u8, args[i], "--allow-net")) result.allow_net = true;
        if (std.mem.eql(u8, args[i], "--allow-read")) result.allow_read = true;
        if (std.mem.eql(u8, args[i], "--allow-env")) result.allow_env = true;
        if (std.mem.eql(u8, args[i], "--allow-write")) result.allow_write = true;
        if (std.mem.eql(u8, args[i], "--allow-exec")) result.allow_exec = true;
        if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) result.help = true;
    }
    return .{
        .parsed = result,
        .positional = args[i..],
    };
}
