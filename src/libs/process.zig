//! 进程级状态：std.Io 与 std.process.Environ，由 main 启动时设置。
//! 供 CLI、io_core、runtime（无 Io/Environ 参数的调用）使用。

const std = @import("std");
const os = @import("libs_os");

var process_io: ?std.Io = null;
var process_environ: ?std.process.Environ = null;

/// 设置进程级 io（main 入口处调用 setProcessIo(init.io)）
pub fn setProcessIo(io: std.Io) void {
    process_io = io;
}

/// 返回进程级 io；未设置时返回 null。
pub fn getProcessIo() ?std.Io {
    return process_io;
}

/// 设置进程级 environ（main 入口处调用 setProcessEnviron(init.minimal.environ)）
pub fn setProcessEnviron(environ: std.process.Environ) void {
    process_environ = environ;
}

/// 返回进程级 environ；未设置时返回 null。
pub fn getProcessEnviron() ?std.process.Environ {
    return process_environ;
}

/// 返回 CPU 核数（u32，至少 1）；供忙时压低并发到核数时使用。
fn cpuCountU32() u32 {
    const n_usize = std.Thread.getCpuCount() catch return 1;
    const n: u32 = @intCast(@min(n_usize, std.math.maxInt(u32)));
    return if (n == 0) 1 else n;
}

/// 解析/安装等 I/O 密集型场景的 CPU 倍数：4× 在常见 registry 限流下通常优于 2×；8× 以上易触发 429。
const CONCURRENCY_CPU_MULTIPLIER: u32 = 4;

/// 从环境变量或 CPU 数得到基准并发上限（内部共用）；按 CPU 的 CONCURRENCY_CPU_MULTIPLIER 倍计算，适应 I/O 密集型；返回 [1, max]。
fn concurrencyCapBase(max: u32) u32 {
    if (std.c.getenv("SHU_CONCURRENCY_CAP")) |v| {
        const span = std.mem.span(v);
        if (span.len > 0) {
            if (std.fmt.parseInt(u32, span, 10)) |override| {
                return @min(max, @max(1, override));
            } else |_| {}
        }
    }
    const n_usize = std.Thread.getCpuCount() catch return max;
    const n: u32 = @intCast(@min(n_usize, std.math.maxInt(u32)));
    // I/O 密集型时并发可高于核数；避免 n * multiplier 溢出
    const mult: u32 = CONCURRENCY_CPU_MULTIPLIER;
    const scaled: u32 = if (n <= std.math.maxInt(u32) / mult) n * mult else std.math.maxInt(u32);
    var cap_val = @min(max, scaled);
    if (cap_val == 0) cap_val = 1;
    return cap_val;
}

/// 用于**并发下载**（网络 + 落盘）的并发上限；基准为 CPU 数的 CONCURRENCY_CPU_MULTIPLIER 倍，忙时压低。
///
/// **环境变量（可选）**：SHU_CONCURRENCY_CAP 直接指定并发上限（u32），解析成功则 clamped 到 1..max 并直接返回。
///
/// **逻辑**：1）基准 = min(max, 4×CPU)；2）若运行时探测到内存紧张 / **磁盘忙** / 网络忙，
/// 则 cap = min(base, CPU 数)。适用于 install、包下载等既打网络又写磁盘的场景。
pub fn getConcurrencyCap(max: u32) u32 {
    var cap_val = concurrencyCapBase(max);
    if (os.isMemoryTight() or os.isDiskBusy() or os.isNetworkBusy()) {
        cap_val = @min(cap_val, cpuCountU32());
    }
    return cap_val;
}

/// 用于**纯并发网络请求**（如 API、解析请求）的并发上限；基准为 CPU 数的 4 倍，忙时压低；不考虑磁盘 I/O。
///
/// **环境变量（可选）**：SHU_CONCURRENCY_CAP 同上。
///
/// **逻辑**：1）基准 = min(max, 4×CPU)；2）若运行时探测到**内存紧张或网络忙**（不查磁盘），
/// 则 cap = min(base, CPU 数)。适用于只发请求、不写盘的解析/拉元数据等场景。
pub fn getConcurrencyCapForRequests(max: u32) u32 {
    var cap_val = concurrencyCapBase(max);
    if (os.isMemoryTight() or os.isNetworkBusy()) {
        cap_val = @min(cap_val, cpuCountU32());
    }
    return cap_val;
}
