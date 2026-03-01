//! 全局命令行参数解析（cli/args.zig）
//!
//! 职责
//!   - 从 argv 中解析全局选项与位置参数，供 main 与各子命令使用。
//!   - 权限标志与 Deno 对齐：--allow-net、--allow-read、--allow-env、--allow-write、--allow-run、
//!     --allow-hrtime、--allow-ffi；--allow-all / --all / -A 表示开启全部权限。
//!   - 全局选项：--help/-h、--version/-v 及上述权限；从第一个非选项参数起视为位置参数。
//!
//! 主要 API
//!   - parse(args)：返回 ParseResult（parsed: ParsedArgs, positional: []const []const u8）。
//!   - ParsedArgs：各 allow_*、help 等字段；位置参数不分配内存，指向原始 argv 切片。
//!
//! 约定
//!   - 短选项仅识别 -A（全部权限）、-h（help）；其他以 "--" 开头的长选项解析。
//!   - Zig 0.15.2：纯切片解析，无旧版 API。
//!
//! 参考：SHU_RUNTIME_ANALYSIS.md 6.1

const std = @import("std");

/// 解析后的权限与全局选项（供 runtime 与子命令使用，与 Deno 对齐：--allow-run、--allow-hrtime、--allow-ffi）
pub const ParsedArgs = struct {
    /// 网络访问，对应 --allow-net
    allow_net: bool = false,
    /// 文件系统读，对应 --allow-read
    allow_read: bool = false,
    /// 环境变量访问，对应 --allow-env
    allow_env: bool = false,
    /// 文件系统写，对应 --allow-write
    allow_write: bool = false,
    /// 子进程执行（Shu.system.exec/run/spawn），对应 --allow-run
    allow_run: bool = false,
    /// 高精度时间（如 performance.now()），对应 --allow-hrtime；当前未强制校验，预留与 Deno 一致
    allow_hrtime: bool = false,
    /// 动态库加载（FFI），对应 --allow-ffi；当前未实现 FFI，预留与 Deno 一致
    allow_ffi: bool = false,
    /// 是否由用户传入 --help（主流程可据此打印用法后退出）
    help: bool = false,
};

/// 解析结果：全局选项 + 位置参数切片（指向原始 argv，不分配内存）
pub const ParseResult = struct {
    parsed: ParsedArgs,
    positional: []const []const u8,
};

/// 判断是否为全局选项（--xxx 或 -A、-h），用于向前扫描以分离位置参数
fn isGlobalOption(arg: []const u8) bool {
    if (arg.len < 2 or arg[0] != '-') return false;
    if (arg[1] == '-') return true; // --anything
    // -A、-h 为短选项
    return (arg.len == 2 and (arg[1] == 'A' or arg[1] == 'h'));
}

/// 从命令行参数中解析全局选项，并分离出位置参数。
/// 从第一个不以 "--" 或 "-A/-h" 开头的参数起视为位置参数。
/// --allow-all / --all / -A 表示允许所有权限（与 Deno 一致：net、read、env、write、run、hrtime、ffi）。
/// 典型用法：main 里取 args[2..] 传入（即去掉程序名与子命令）。
pub fn parse(args: []const []const u8) ParseResult {
    var result = ParsedArgs{};
    var i: usize = 0;
    while (i < args.len and isGlobalOption(args[i])) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--allow-all") or std.mem.eql(u8, args[i], "--all") or std.mem.eql(u8, args[i], "-A")) {
            result.allow_net = true;
            result.allow_read = true;
            result.allow_env = true;
            result.allow_write = true;
            result.allow_run = true;
            result.allow_hrtime = true;
            result.allow_ffi = true;
        }
        if (std.mem.eql(u8, args[i], "--allow-net")) result.allow_net = true;
        if (std.mem.eql(u8, args[i], "--allow-read")) result.allow_read = true;
        if (std.mem.eql(u8, args[i], "--allow-env")) result.allow_env = true;
        if (std.mem.eql(u8, args[i], "--allow-write")) result.allow_write = true;
        if (std.mem.eql(u8, args[i], "--allow-run")) result.allow_run = true;
        if (std.mem.eql(u8, args[i], "--allow-hrtime")) result.allow_hrtime = true;
        if (std.mem.eql(u8, args[i], "--allow-ffi")) result.allow_ffi = true;
        if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) result.help = true;
    }
    return .{
        .parsed = result,
        .positional = args[i..],
    };
}
