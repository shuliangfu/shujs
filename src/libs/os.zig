//! 系统状态采集：平台识别、CPU/内存/磁盘/网络、负载与运行时间等。
//!
//! 本模块为「无服务器/运行时决策」提供只读系统指标，用于并发上限、背压、
//! 健康检查或监控。不依赖 libs_io，仅使用 std 与 builtin；读 /proc、sysfs、
//! sysctl 等内核接口时按项目规则允许使用 std.fs（非业务热路径 I/O）。
//!
//! ## 平台与实现
//!
//! 所有接口按 **comptime 分派**（`builtin.os.tag`）：当前目标只编译当前平台
//! 实现，无运行时 if-os 分支。
//!
//! **兼容范围**：`Platform` 枚举包含 linux、macos、windows、freebsd、openbsd、netbsd、
//! wasi、other，用于 `getPlatform()` 识别并返回当前 OS 标签。但**指标类 API**（CPU、
//! 内存、磁盘、网络、负载、运行时间等）**仅对 Linux / macOS / Windows 有实现**；在
//! freebsd、openbsd、netbsd、wasi 上这些接口一律返回 **`error.Unsupported`**，仅
//! `getPlatform()` 可正确返回对应枚举值。若需在 BSD/WASI 上获得指标，需后续按平台补充实现。
//!
//! 已实现平台简述：
//!
//! - **Linux**：/proc（stat、meminfo、diskstats、net/dev、net/tcp、loadavg、uptime）、
//!   sysfs（thermal、power_supply）；CPU/内存/磁盘/网络/负载/运行时间/温度/电池 均有实现。
//! - **macOS**：Mach task_info（进程 RSS）、sysctlbyname（vm.loadavg、kern.boottime）、
//!   statvfs（磁盘剩余）、getaddrinfo+socket（RTT 探针）；CPU 整体/每核、磁盘利用率、
//!   网络流量、TCP 数、温度、电池 暂返回 null。
//! - **Windows**：GetProcessMemoryInfo（进程 RSS）、GetDiskFreeSpaceExW（磁盘剩余，需 allocator）、
//!   GetTickCount64（运行时间）；其余指标暂返回 null。
//!
//! ## API 分类与平台支持概览
//!
//! | 类别           | 接口示例                         | Linux | macOS | Windows |
//! |----------------|----------------------------------|-------|-------|---------|
//! | 平台           | getPlatform                      | ✓     | ✓     | ✓       |
//! | CPU 整体/每核  | getCpuUsage, getCpuUsagePerCore | ✓     | —     | —       |
//! | 进程 CPU/RSS   | getProcessCpuUsage, getProcessRssKb | ✓ | ✓(RSS) | ✓(RSS)  |
//! | 内存/Swap      | getMemoryInfo, getSwapInfo, isMemoryTight | ✓ | — | — |
//! | 磁盘           | getDiskUtilization, getDiskFreeSpace, isDiskBusy | ✓ | ✓(free) | ✓(free) |
//! | 磁盘按设备     | getDiskUtilizationPerDevice      | ✓     | —     | —       |
//! | 网络流量/忙    | getNetworkActivityBytesDelta, isNetworkBusy | ✓ | — | — |
//! | 网络按接口     | getNetworkStatsPerInterface     | ✓     | —     | —       |
//! | TCP 连接数     | getTcpConnectionCount            | ✓     | —     | —       |
//! | 网络 RTT 探针  | getNetworkRttMs                  | ✓     | ✓     | —       |
//! | 负载/运行时间  | getLoadAverage, getUptimeSeconds | ✓     | ✓     | ✓(uptime) |
//! | 温度/电池      | getCpuTemperatureC, getBatteryPercent | ✓ | — | —   |
//!
//! 上表仅列三大平台；freebsd / openbsd / netbsd / wasi 上除 getPlatform 外均为 null。
//!
//! ## 错误与所有权
//!
//! - **错误集**：指标类 API 返回 **`OsError!T`**，不再用 `?T`。可区分「平台不支持」(Unsupported)、
//!   「I/O 或系统调用失败」(IoError)、「分配失败」(OutOfMemory)，便于调用方区分处理。
//! - **所有权**：需要分配的函数显式接受 `allocator`；文档标注 **[Allocates]** 的，调用方负责 free
//!   返回的切片或切片内字段（如 entry.name）。返回值若为按值类型（如 MemoryInfo）无需 [Borrows]；
//!   仅当返回切片且指向非本函数分配的内存时标 [Borrows]。
//! - getDiskFreeSpace、getTcpConnectionCount 等需 allocator 的接口：allocator 必传，用于路径缓冲或
//!   大块读缓冲，避免栈上 >8KB 导致栈溢出。
//!
//! ## 采样与缓存
//!
//! 部分接口依赖两次采样求差值（CPU、磁盘、网络流量），首次或缓存过期时会阻塞约
//! CPU_SAMPLE_INTERVAL_MS / DISK_SAMPLE_INTERVAL_MS / NET_SAMPLE_INTERVAL_MS；结果在
//! CACHE_VALID_NS 内复用，避免频繁 sleep。

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const win = std.os.windows;

// Windows psapi：GetProcessMemoryInfo（仅 Windows 构建时使用）
const win_psapi = if (builtin.os.tag == .windows) struct {
    pub const PROCESS_MEMORY_COUNTERS = extern struct {
        cb: win.DWORD,
        PageFaultCount: win.DWORD,
        PeakWorkingSetSize: win.SIZE_T,
        WorkingSetSize: win.SIZE_T,
        QuotaPeakPagedPoolUsage: win.SIZE_T,
        QuotaPagedPoolUsage: win.SIZE_T,
        QuotaPeakNonPagedPoolUsage: win.SIZE_T,
        QuotaNonPagedPoolUsage: win.SIZE_T,
        PagefileUsage: win.SIZE_T,
        PeakPagefileUsage: win.SIZE_T,
    };
    pub extern "psapi" fn GetProcessMemoryInfo(
        Process: win.HANDLE,
        ppsmemCounters: *PROCESS_MEMORY_COUNTERS,
        cb: win.DWORD,
    ) win.BOOL;
} else struct {};

// -----------------------------------------------------------------------------
// 类型与常量
// -----------------------------------------------------------------------------

/// 运行时所在平台（与 builtin.os.tag 对应，便于业务层分支或日志）。
/// 除三大平台外，列出常见 BSD 与 WASI；其余（freestanding、uefi、emscripten 等）为 other。
/// 注意：本枚举覆盖所有可识别的 OS 标签，但指标类 API（getCpuUsage、getMemoryInfo 等）
/// 仅在 linux/macos/windows 有实现；在 freebsd、openbsd、netbsd、wasi 上仅 getPlatform() 有效，其余返回 null。
pub const Platform = enum {
    linux,
    macos,
    windows,
    freebsd,
    openbsd,
    netbsd,
    wasi,
    other,
};

/// 指标类 API 统一错误集：可区分「平台不支持」与「系统/I/O/分配失败」，利于窄化跳转表与调用方处理。
pub const OsError = error{
    /// 当前平台未实现该指标（如 getCpuUsage 在 Windows 上）。
    Unsupported,
    /// 打开/读取 /proc、sysfs、sysctl 等失败，或系统调用失败。
    IoError,
    /// 分配内存失败（传入的 allocator 返回失败）。
    OutOfMemory,
};

/// CPU 采样间隔（ms），用于两次读取 /proc/stat 计算利用率。
const CPU_SAMPLE_INTERVAL_MS: u32 = 100;
var cpu_usage_cache_percent: u32 = 0;
var cpu_cache_ts_ns: u64 = 0;

// -----------------------------------------------------------------------------
// 平台识别
// -----------------------------------------------------------------------------

/// 返回当前编译/运行目标平台。基于 builtin.os.tag，无运行时开销。
pub fn getPlatform() Platform {
    return switch (builtin.os.tag) {
        .linux => .linux,
        .macos => .macos,
        .windows => .windows,
        .freebsd => .freebsd,
        .openbsd => .openbsd,
        .netbsd => .netbsd,
        .wasi => .wasi,
        else => .other,
    };
}

// -----------------------------------------------------------------------------
// CPU 占用（Linux：/proc/stat 两次采样；macOS/Windows 待实现）
// -----------------------------------------------------------------------------

/// 获取系统整体 CPU 利用率（0..100）。需两次采样，首次或缓存过期时会阻塞约 CPU_SAMPLE_INTERVAL_MS。
/// Linux 读 /proc/stat 首行 "cpu " 的 user+nice+system+idle+... 求 delta，(total-idle)/total*100。
pub fn getCpuUsage() OsError!u32 {
    return switch (builtin.os.tag) {
        .linux => getCpuUsageLinux() orelse return error.IoError,
        else => error.Unsupported,
    };
}

fn getCpuUsageLinux() ?u32 {
    const now_ns = std.time.nanoTimestamp();
    const now_u = if (now_ns < 0) 0 else @as(u64, @intCast(now_ns));
    if (now_u < cpu_cache_ts_ns + CACHE_VALID_NS and cpu_cache_ts_ns != 0) {
        return cpu_usage_cache_percent;
    }
    const s0 = readProcStatCpuLine() orelse return null;
    std.time.sleep(CPU_SAMPLE_INTERVAL_MS * std.time.ns_per_ms);
    const s1 = readProcStatCpuLine() orelse return null;
    const total_delta = if (s1.total > s0.total) s1.total - s0.total else 0;
    const idle_delta = if (s1.idle > s0.idle) s1.idle - s0.idle else 0;
    if (total_delta == 0) return 0;
    const busy = total_delta - idle_delta;
    const percent = @min(100, @as(u32, @intCast((busy * 100) / total_delta)));
    cpu_usage_cache_percent = percent;
    cpu_cache_ts_ns = now_u;
    return percent;
}

const ProcStatCpu = struct { total: u64, idle: u64 };

// Hot-path：CPU 利用率采样入口，缓存未命中时调用。
/// 读取 /proc/stat 首行 "cpu "（总 CPU）的 user+nice+system+idle+iowait+irq+softirq+steal（jiffies），idle 为 idle+iowait。
fn readProcStatCpuLine() ?ProcStatCpu {
    const path = "/proc/stat";
    var file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch return null;
    defer file.close();
    var buf: [512]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    const content = buf[0..n];
    const line_end = std.mem.indexOfScalarPos(u8, content, 0, '\n') orelse content.len;
    const line = content[0..line_end];
    if (!std.mem.startsWith(u8, line, "cpu ")) return null;
    const rest = std.mem.trim(u8, line["cpu ".len..]);
    var total: u64 = 0;
    var idle: u64 = 0;
    var col: u32 = 0;
    var iter = std.mem.splitScalar(u8, rest, ' ');
    while (iter.next()) |seg| {
        if (seg.len == 0) continue;
        col += 1;
        const v = parseDecimalU64(seg) orelse 0;
        if (col <= 8) total += v; // user nice system idle iowait irq softirq steal
        if (col == 4 or col == 5) idle += v; // idle + iowait
        if (col >= 10) break; // 不包含 guest/guest_nice，避免与 user/nice 重复
    }
    return .{ .total = total, .idle = idle };
}

/// 内存信息：总可用与当前可用（单位 kB）。[Borrows] 不分配，仅解析结果。
pub const MemoryInfo = struct {
    total_kb: u64,
    available_kb: u64,
};

/// Swap 信息：总量与未使用量（单位 kB）。用于判断交换区压力。
pub const SwapInfo = struct {
    total_kb: u64,
    free_kb: u64,
};

/// 系统负载：1/5/15 分钟平均负载（与 uptime 一致）。
pub const LoadAverage = struct {
    load_1: f32,
    load_5: f32,
    load_15: f32,
};

/// 单块磁盘设备利用率（名称与 0..100 百分比）。
pub const DiskDeviceUtil = struct {
    name: []const u8,
    utilization_percent: u32,
};

/// 单网口累计流量（字节）。
pub const NetworkInterfaceStats = struct {
    name: []const u8,
    rx_bytes: u64,
    tx_bytes: u64,
};

/// 磁盘剩余空间（某路径所在文件系统）。
pub const DiskSpace = struct {
    total_bytes: u64,
    free_bytes: u64,
};

const MAX_CPU_CORES: usize = 256;
const CLK_TCK: u64 = 100; // Linux 通常为 100，用于 /proc/stat 与 /proc/self/stat 的 tick 转秒

/// 内存紧张判定阈值：可用内存占比低于此值时视为紧张，建议降低并发。
const MEMORY_TIGHT_RATIO_NUMERATOR: u64 = 10; // 即 10/100 = 10%
const MEMORY_TIGHT_RATIO_DENOMINATOR: u64 = 100;

/// 磁盘采样间隔（ms），用于两次读取 diskstats 计算利用率。
const DISK_SAMPLE_INTERVAL_MS: u32 = 50;
/// 磁盘利用率超过此比例（0..100）视为繁忙。
const DISK_BUSY_PERCENT: u32 = 80;
/// 磁盘/网络采样结果缓存有效期（ns），避免每次调用都阻塞采样。
const CACHE_VALID_NS: u64 = 5_000_000_000; // 5s

/// 网络活动：采样窗口内总字节数（rx+tx）。超过阈值可视为「网络忙」。
const NET_SAMPLE_INTERVAL_MS: u32 = 50;
/// 若 50ms 内总流量超过此值（字节），视为网络繁忙。
const NET_BUSY_BYTES_THRESHOLD: u64 = 5 * 1024 * 1024; // 5MB in 50ms ≈ 800MB/s

// Linux 下磁盘/网络采样缓存（首次采样会阻塞 DISK_SAMPLE_INTERVAL_MS + NET 时间）
var disk_utilization_cache_percent: u32 = 0;
var disk_cache_ts_ns: u64 = 0;

/// 将 io_ticks 差值（ms）转为 0..100 利用率。防除零与乘法溢出。Hot-path，内联减少调用开销。
inline fn diskDeltaToPercent(delta_ms: u64) u32 {
    if (DISK_SAMPLE_INTERVAL_MS == 0) return 0;
    const prod = @mulWithOverflow(delta_ms, 100);
    const p = if (prod[1] != 0) std.math.maxInt(u64) else prod[0];
    return @min(100, @as(u32, @intCast(p / DISK_SAMPLE_INTERVAL_MS)));
}

/// Hot-path：无符号十进制解析，用于 /proc、sysfs 等固定格式。遇非数字或溢出返回 null。
/// 比 std.fmt.parseInt 少通用边界与分支，适合热路径。内联便于在解析循环中消除调用开销。
inline fn parseDecimalU64(slice: []const u8) ?u64 {
    if (slice.len == 0) return null;
    var val: u64 = 0;
    for (slice) |c| {
        if (c < '0' or c > '9') return null;
        const digit = c - '0';
        const ov = @mulWithOverflow(val, 10);
        if (ov[1] != 0) return null;
        const add_ov = @addWithOverflow(ov[0], digit);
        if (add_ov[1] != 0) return null;
        val = add_ov[0];
    }
    return val;
}
var net_bytes_delta_cache: u64 = 0;
var net_cache_ts_ns: u64 = 0;

// -----------------------------------------------------------------------------
// 内存（各平台可扩展）
// -----------------------------------------------------------------------------

/// 获取系统内存信息。Linux 读 /proc/meminfo 的 MemTotal、MemAvailable（无则用 MemFree）。不分配内存。
pub fn getMemoryInfo() OsError!MemoryInfo {
    return switch (builtin.os.tag) {
        .linux => getMemoryInfoLinux() orelse return error.IoError,
        else => error.Unsupported,
    };
}

/// Linux：解析 /proc/meminfo。规则允许此处用 std.fs 读内核接口（非业务热路径文件 I/O）。
fn getMemoryInfoLinux() ?MemoryInfo {
    const path = "/proc/meminfo";
    var file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch return null;
    defer file.close();
    var buf: [4096]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    const content = buf[0..n];
    var total_kb: u64 = 0;
    var available_kb: u64 = 0;
    var has_available = false;
    var i: usize = 0;
    while (i < content.len) {
        const line_end = std.mem.indexOfScalarPos(u8, content, i, '\n') orelse content.len;
        const line = std.mem.trim(u8, content[i..line_end]);
        i = line_end + 1;
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            total_kb = parseMeminfoValue(line["MemTotal:".len..]) orelse continue;
        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            available_kb = parseMeminfoValue(line["MemAvailable:".len..]) orelse continue;
            has_available = true;
        } else if (std.mem.startsWith(u8, line, "MemFree:") and !has_available) {
            available_kb = parseMeminfoValue(line["MemFree:".len..]) orelse continue;
        }
    }
    if (total_kb == 0) return null;
    return .{ .total_kb = total_kb, .available_kb = available_kb };
}

/// 解析 meminfo 行中 " 12345 kB" 形式的数值，返回 kB 或 null。
fn parseMeminfoValue(rest: []const u8) ?u64 {
    const trimmed = std.mem.trim(u8, rest);
    var i: usize = 0;
    while (i < trimmed.len and trimmed[i] != ' ' and trimmed[i] != '\t') i += 1;
    const num_slice = trimmed[0..i];
    return parseDecimalU64(num_slice);
}

/// 当前是否内存紧张（可用占比低于 MEMORY_TIGHT_RATIO）。用于并发上限等。取不到指标时返回 false。
pub fn isMemoryTight() bool {
    const info = getMemoryInfo() catch return false;
    if (info.total_kb == 0) return false;
    return info.available_kb * MEMORY_TIGHT_RATIO_DENOMINATOR < info.total_kb * MEMORY_TIGHT_RATIO_NUMERATOR;
}

/// 获取 Swap 使用量（SwapTotal、SwapFree，单位 kB）。Linux 读 /proc/meminfo。
pub fn getSwapInfo() OsError!SwapInfo {
    return switch (builtin.os.tag) {
        .linux => getSwapInfoLinux() orelse return error.IoError,
        else => error.Unsupported,
    };
}

fn getSwapInfoLinux() ?SwapInfo {
    const path = "/proc/meminfo";
    var file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch return null;
    defer file.close();
    var buf: [4096]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    const content = buf[0..n];
    var total_kb: u64 = 0;
    var free_kb: u64 = 0;
    var i: usize = 0;
    while (i < content.len) {
        const line_end = std.mem.indexOfScalarPos(u8, content, i, '\n') orelse content.len;
        const line = std.mem.trim(u8, content[i..line_end]);
        i = line_end + 1;
        if (std.mem.startsWith(u8, line, "SwapTotal:")) {
            total_kb = parseMeminfoValue(line["SwapTotal:".len..]) orelse 0;
        } else if (std.mem.startsWith(u8, line, "SwapFree:")) {
            free_kb = parseMeminfoValue(line["SwapFree:".len..]) orelse 0;
        }
    }
    return .{ .total_kb = total_kb, .free_kb = free_kb };
}

// -----------------------------------------------------------------------------
// 当前进程：RSS、CPU 占用（Linux：/proc/self/status、/proc/self/stat）
// -----------------------------------------------------------------------------

/// 当前进程常驻内存 RSS（单位 kB）。Linux 读 /proc/self/status 的 VmRSS。
pub fn getProcessRssKb() OsError!u64 {
    return switch (builtin.os.tag) {
        .linux => getProcessRssKbLinux() orelse return error.IoError,
        .macos => getProcessRssKbMacos() orelse return error.IoError,
        .windows => getProcessRssKbWindows() orelse return error.IoError,
        else => error.Unsupported,
    };
}

fn getProcessRssKbLinux() ?u64 {
    const path = "/proc/self/status";
    var file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch return null;
    defer file.close();
    var buf: [4096]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    const content = buf[0..n];
    var i: usize = 0;
    while (i < content.len) {
        const line_end = std.mem.indexOfScalarPos(u8, content, i, '\n') orelse content.len;
        const line = std.mem.trim(u8, content[i..line_end]);
        i = line_end + 1;
        if (std.mem.startsWith(u8, line, "VmRSS:")) {
            return parseMeminfoValue(line["VmRSS:".len..]);
        }
    }
    return null;
}

fn getProcessRssKbMacos() ?u64 {
    const c = @cImport({
        @cInclude("mach/mach.h");
    });
    var info: c.mach_task_basic_info_data_t = undefined;
    var count: c.mach_msg_type_number_t = c.MACH_TASK_BASIC_INFO_COUNT;
    const kr = c.task_info(c.mach_task_self(), c.MACH_TASK_BASIC_INFO, @ptrCast(&info), &count);
    if (kr != c.KERN_SUCCESS) return null;
    return info.resident_size / 1024;
}

fn getProcessRssKbWindows() ?u64 {
    if (builtin.os.tag != .windows) return null;
    var pmc: win_psapi.PROCESS_MEMORY_COUNTERS = undefined;
    pmc.cb = @sizeOf(win_psapi.PROCESS_MEMORY_COUNTERS);
    if (win_psapi.GetProcessMemoryInfo(win.kernel32.GetCurrentProcess(), &pmc, pmc.cb) == 0) return null;
    return pmc.WorkingSetSize / 1024;
}

/// 当前进程 CPU 占用（0..100*N 核，即多核可超 100）。两次采样，间隔 CPU_SAMPLE_INTERVAL_MS。Linux 读 /proc/self/stat utime+stime。
pub fn getProcessCpuUsage() OsError!u32 {
    return switch (builtin.os.tag) {
        .linux => getProcessCpuUsageLinux() orelse return error.IoError,
        else => error.Unsupported,
    };
}

fn getProcessCpuUsageLinux() ?u32 {
    const t0 = readProcSelfStatUtimeStime() orelse return null;
    std.time.sleep(CPU_SAMPLE_INTERVAL_MS * std.time.ns_per_ms);
    const t1 = readProcSelfStatUtimeStime() orelse return null;
    const interval_ticks = CLK_TCK * CPU_SAMPLE_INTERVAL_MS / 1000;
    if (interval_ticks == 0) return 0;
    const delta = if (t1 >= t0) t1 - t0 else 0;
    return @min(99999, @as(u32, @intCast((delta * 100) / interval_ticks)));
}

/// 读取 /proc/self/stat 的 utime(14) + stime(15)。comm 在括号内可能含空格，故从最后一个 ')' 后按空格数字段；) 后依次为 state,ppid,pgrp,...,utime,stime，第 12、13 个 token 为 utime、stime。
fn readProcSelfStatUtimeStime() ?u64 {
    const path = "/proc/self/stat";
    var file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch return null;
    defer file.close();
    var buf: [512]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    const content = buf[0..n];
    const last_paren = std.mem.lastIndexOfScalar(u8, content, ')') orelse return null;
    var col: u32 = 0;
    var utime: u64 = 0;
    var stime: u64 = 0;
    var iter = std.mem.splitScalar(u8, std.mem.trim(u8, content[last_paren + 1 ..]), ' ');
    while (iter.next()) |seg| {
        if (seg.len == 0) continue;
        col += 1;
        const v = parseDecimalU64(seg) orelse 0;
        if (col == 12) utime = v;
        if (col == 13) stime = v;
    }
    return utime + stime;
}

/// [Allocates] 每核 CPU 利用率（0..100），与 /proc/stat 的 cpu0、cpu1… 顺序一致。调用方负责 free 返回切片。
pub fn getCpuUsagePerCore(allocator: std.mem.Allocator) OsError![]u32 {
    return switch (builtin.os.tag) {
        .linux => getCpuUsagePerCoreLinux(allocator) orelse return error.IoError,
        else => error.Unsupported,
    };
}

fn getCpuUsagePerCoreLinux(allocator: std.mem.Allocator) ?[]u32 {
    const t0 = readProcStatAllCpuLines(allocator) orelse return null;
    defer allocator.free(t0);
    std.time.sleep(CPU_SAMPLE_INTERVAL_MS * std.time.ns_per_ms);
    const t1 = readProcStatAllCpuLines(allocator) orelse return null;
    defer allocator.free(t1);
    if (t0.len != t1.len or t0.len == 0) return null;
    const out = allocator.alloc(u32, t0.len) catch return null;
    for (t0, t1, out) |a, b, *o| {
        const total_d = if (b.total > a.total) b.total - a.total else 0;
        const idle_d = if (b.idle > a.idle) b.idle - a.idle else 0;
        if (total_d == 0) {
            o.* = 0;
        } else {
            o.* = @min(100, @as(u32, @intCast((total_d - idle_d) * 100 / total_d)));
        }
    }
    return out;
}

fn readProcStatAllCpuLines(allocator: std.mem.Allocator) ?[]ProcStatCpu {
    var file = std.fs.openFileAbsolute("/proc/stat", .{ .mode = .read_only }) catch return null;
    defer file.close();
    var buf = allocator.alloc(u8, 16384) catch return null;
    defer allocator.free(buf);
    const n = file.readAll(buf) catch return null;
    const content = buf[0..n];
    var list = std.ArrayListUnmanaged(ProcStatCpu).initCapacity(allocator, MAX_CPU_CORES) catch return null;
    var i: usize = 0;
    while (i < content.len) {
        const line_end = std.mem.indexOfScalarPos(u8, content, i, '\n') orelse content.len;
        const line = content[i..line_end];
        i = line_end + 1;
        if (!std.mem.startsWith(u8, line, "cpu")) break;
        if (line.len >= 4 and line[3] == ' ') {
            i = line_end + 1;
            continue; // 跳过总行 "cpu "（仅 "cpu0"、"cpu1" 等有数字）
        }
        const rest = if (line.len > 4) std.mem.trim(u8, line[4..]) else "";
        var total: u64 = 0;
        var idle: u64 = 0;
        var col: u32 = 0;
        var iter = std.mem.splitScalar(u8, rest, ' ');
        while (iter.next()) |seg| {
            if (seg.len == 0) continue;
            col += 1;
            const v = parseDecimalU64(seg) orelse 0;
            if (col <= 8) total += v;
            if (col == 4 or col == 5) idle += v;
            if (col >= 10) break;
        }
        list.append(allocator, .{ .total = total, .idle = idle }) catch return null;
    }
    return list.toOwnedSlice(allocator) catch return null;
}

// -----------------------------------------------------------------------------
// 磁盘 I/O（Linux：/proc/diskstats 两次采样求利用率）
// -----------------------------------------------------------------------------

/// 获取磁盘 I/O 利用率（0..100）。需两次采样，首次或缓存过期时会阻塞约 DISK_SAMPLE_INTERVAL_MS。Linux 读 /proc/diskstats 的 io_ticks（字段 13）求 delta。
pub fn getDiskUtilization() OsError!u32 {
    return switch (builtin.os.tag) {
        .linux => getDiskUtilizationLinux() orelse return error.IoError,
        else => error.Unsupported,
    };
}

fn getDiskUtilizationLinux() ?u32 {
    const now_ns = std.time.nanoTimestamp();
    const now_u = if (now_ns < 0) 0 else @as(u64, @intCast(now_ns));
    if (now_u < disk_cache_ts_ns + CACHE_VALID_NS and disk_cache_ts_ns != 0) {
        return disk_utilization_cache_percent;
    }
    const t0 = readDiskstatsIoTicks() orelse return null;
    std.time.sleep(DISK_SAMPLE_INTERVAL_MS * std.time.ns_per_ms);
    const t1 = readDiskstatsIoTicks() orelse return null;
    const delta_ms = if (t1 > t0) t1 - t0 else 0;
    const percent = diskDeltaToPercent(delta_ms);
    disk_utilization_cache_percent = percent;
    disk_cache_ts_ns = now_u;
    return percent;
}

// Hot-path：磁盘利用率采样入口，缓存未命中时调用。
/// 读取 /proc/diskstats 所有块设备的 io_ticks（第 13 列）之和（ms）。
fn readDiskstatsIoTicks() ?u64 {
    const path = "/proc/diskstats";
    var file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch return null;
    defer file.close();
    var buf: [8192]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    const content = buf[0..n];
    var total: u64 = 0;
    var i: usize = 0;
    while (i < content.len) {
        const line_end = std.mem.indexOfScalarPos(u8, content, i, '\n') orelse content.len;
        const line = content[i..line_end];
        i = line_end + 1;
        const fields = std.mem.splitScalar(u8, std.mem.trim(u8, line), ' ');
        var col: u32 = 0;
        var val: u64 = 0;
        while (fields.next()) |segment| {
            if (segment.len == 0) continue;
            col += 1;
            if (col == 13) {
                val = parseDecimalU64(segment) orelse 0;
                break;
            }
        }
        if (col >= 13) total += val;
    }
    return total;
}

/// 磁盘是否繁忙（利用率超过 DISK_BUSY_PERCENT）。会触发一次采样（含 50ms sleep）或使用缓存。取不到指标时返回 false。
pub fn isDiskBusy() bool {
    const util = getDiskUtilization() catch return false;
    return util >= DISK_BUSY_PERCENT;
}

/// [Allocates] 各块设备 I/O 利用率（0..100）。需两次采样（约 50ms）。调用方负责 free 返回切片，并逐项 free(entry.name)。
pub fn getDiskUtilizationPerDevice(allocator: std.mem.Allocator) OsError![]DiskDeviceUtil {
    return switch (builtin.os.tag) {
        .linux => getDiskUtilizationPerDeviceLinux(allocator) orelse return error.IoError,
        else => error.Unsupported,
    };
}

fn getDiskUtilizationPerDeviceLinux(allocator: std.mem.Allocator) ?[]DiskDeviceUtil {
    const t0 = readDiskstatsPerDevice(allocator) orelse return null;
    defer freeDiskstatsPerDevice(allocator, t0);
    std.time.sleep(DISK_SAMPLE_INTERVAL_MS * std.time.ns_per_ms);
    const t1 = readDiskstatsPerDevice(allocator) orelse return null;
    defer freeDiskstatsPerDevice(allocator, t1);
    if (t0.len != t1.len) {
        freeDiskstatsPerDevice(allocator, t1);
        return null;
    }
    const out = allocator.alloc(DiskDeviceUtil, t0.len) catch return null;
    for (t0, t1, out) |a, b, *o| {
        if (!std.mem.eql(u8, a.name, b.name)) {
            allocator.free(out);
            return null;
        }
        const delta_ms = if (b.io_ticks > a.io_ticks) b.io_ticks - a.io_ticks else 0;
        o.* = .{
            .name = allocator.dupe(u8, a.name) catch {
                allocator.free(out);
                return null;
            },
            .utilization_percent = diskDeltaToPercent(delta_ms),
        };
    }
    return out;
}

/// 单设备 diskstats 行解析结果。name 为切片、io_ticks 为 u64，结构体自然 8 字节对齐，便于遍历时缓存友好。
const DiskstatsEntry = struct { name: []const u8, io_ticks: u64 };

fn readDiskstatsPerDevice(allocator: std.mem.Allocator) ?[]DiskstatsEntry {
    var file = std.fs.openFileAbsolute("/proc/diskstats", .{ .mode = .read_only }) catch return null;
    defer file.close();
    var buf: [8192]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    const content = buf[0..n];
    var list = std.ArrayListUnmanaged(DiskstatsEntry).initCapacity(allocator, 32) catch return null;
    var i: usize = 0;
    while (i < content.len) {
        const line_end = std.mem.indexOfScalarPos(u8, content, i, '\n') orelse content.len;
        const line = std.mem.trim(u8, content[i..line_end]);
        i = line_end + 1;
        if (line.len == 0) continue;
        var col: u32 = 0;
        var name: ?[]const u8 = null;
        var io_ticks: u64 = 0;
        var iter = std.mem.splitScalar(u8, line, ' ');
        while (iter.next()) |seg| {
            if (seg.len == 0) continue;
            col += 1;
            if (col == 3) name = seg;
            if (col == 13) {
                io_ticks = parseDecimalU64(seg) orelse 0;
                break;
            }
        }
        if (name) |nstr| {
            list.append(allocator, .{ .name = allocator.dupe(u8, nstr) catch return null, .io_ticks = io_ticks }) catch return null;
        }
    }
    return list.toOwnedSlice(allocator) catch return null;
}

fn freeDiskstatsPerDevice(allocator: std.mem.Allocator, entries: []DiskstatsEntry) void {
    for (entries) |e| allocator.free(e.name);
    allocator.free(entries);
}

/// 指定路径所在文件系统的剩余空间（总字节、可用字节）。Linux/macOS 用 statvfs；Windows 用 GetDiskFreeSpaceExW。allocator 必传：Windows 用于 path 转 UTF-16；Linux/macOS 用于路径缓冲，避免栈溢出。
pub fn getDiskFreeSpace(path: []const u8, allocator: std.mem.Allocator) OsError!DiskSpace {
    return switch (builtin.os.tag) {
        .linux, .macos => getDiskFreeSpacePosix(allocator, path),
        .windows => getDiskFreeSpaceWindows(allocator, path),
        else => error.Unsupported,
    };
}

/// [Allocates] 内部用 allocator 分配 path 的 null 结尾副本，调用 statvfs 后即释放，避免栈上大数组。
fn getDiskFreeSpacePosix(allocator: std.mem.Allocator, path: []const u8) OsError!DiskSpace {
    const path_z = allocator.dupeZ(u8, path) catch return error.OutOfMemory;
    defer allocator.free(path_z);
    var stat: std.posix.statvfs = undefined;
    if (std.posix.statvfs(path_z.ptr, &stat) != 0) return error.IoError;
    const total = stat.f_blocks * stat.f_frsize;
    const free = stat.f_bavail * stat.f_frsize;
    return .{ .total_bytes = total, .free_bytes = free };
}

/// [Allocates] Windows：path 转 UTF-16 后调 GetDiskFreeSpaceExW；调用方无需单独 free（内部用 allocator 后即释放）。
fn getDiskFreeSpaceWindows(allocator: std.mem.Allocator, path: []const u8) OsError!DiskSpace {
    if (builtin.os.tag != .windows) return error.Unsupported;
    const path_wide = std.unicode.utf8ToUtf16LeStringWithNull(allocator, path) catch return error.OutOfMemory;
    defer allocator.free(path_wide);
    var free_bytes: u64 = undefined;
    var total_bytes: u64 = undefined;
    var total_free: u64 = undefined;
    if (win.kernel32.GetDiskFreeSpaceExW(
        path_wide.ptr,
        @ptrCast(&free_bytes),
        @ptrCast(&total_bytes),
        @ptrCast(&total_free),
    ) == 0) return error.IoError;
    return .{ .total_bytes = total_bytes, .free_bytes = free_bytes };
}

// -----------------------------------------------------------------------------
// 网络活动（Linux：/proc/net/dev 两次采样求字节增量）
// -----------------------------------------------------------------------------

/// 获取最近采样窗口内网络总流量（rx+tx 字节）。用于判断「网络是否很忙」。首次或缓存过期会阻塞约 NET_SAMPLE_INTERVAL_MS。
pub fn getNetworkActivityBytesDelta() OsError!u64 {
    return switch (builtin.os.tag) {
        .linux => getNetworkActivityLinux() orelse return error.IoError,
        else => error.Unsupported,
    };
}

fn getNetworkActivityLinux() ?u64 {
    const now_ns = std.time.nanoTimestamp();
    const now_u = if (now_ns < 0) 0 else @as(u64, @intCast(now_ns));
    if (now_u < net_cache_ts_ns + CACHE_VALID_NS and net_cache_ts_ns != 0) {
        return net_bytes_delta_cache;
    }
    const t0 = readNetDevTotalBytes() orelse return null;
    std.time.sleep(NET_SAMPLE_INTERVAL_MS * std.time.ns_per_ms);
    const t1 = readNetDevTotalBytes() orelse return null;
    const delta = if (t1 > t0) t1 - t0 else 0;
    net_bytes_delta_cache = delta;
    net_cache_ts_ns = now_u;
    return delta;
}

// Hot-path：网络流量采样入口，缓存未命中时调用。
/// 读取 /proc/net/dev 所有接口的 rx_bytes + tx_bytes 之和（前两列数据在 ":" 后）。
fn readNetDevTotalBytes() ?u64 {
    const path = "/proc/net/dev";
    var file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch return null;
    defer file.close();
    var buf: [4096]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    const content = buf[0..n];
    var total: u64 = 0;
    var i: usize = 0;
    var line_index: u32 = 0;
    while (i < content.len) {
        const line_end = std.mem.indexOfScalarPos(u8, content, i, '\n') orelse content.len;
        const line = content[i..line_end];
        i = line_end + 1;
        line_index += 1;
        if (line_index <= 2) continue; // 跳过表头两行
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const rest = std.mem.trim(u8, line[colon + 1 ..]);
        var col: u32 = 0;
        var rx: u64 = 0;
        var tx: u64 = 0;
        var iter = std.mem.splitScalar(u8, rest, ' ');
        while (iter.next()) |seg| {
            if (seg.len == 0) continue;
            col += 1;
            const v = parseDecimalU64(seg) orelse 0;
            if (col == 1) rx = v;
            if (col == 9) tx = v;
        }
        total += rx + tx;
    }
    return total;
}

/// 网络是否繁忙（采样窗口内流量超过 NET_BUSY_BYTES_THRESHOLD）。会触发一次采样或使用缓存。取不到指标时返回 false。
pub fn isNetworkBusy() bool {
    const delta = getNetworkActivityBytesDelta() catch return false;
    return delta >= NET_BUSY_BYTES_THRESHOLD;
}

/// [Allocates] 各网络接口的累计 rx/tx 字节（一次读取 /proc/net/dev）。调用方负责 free 返回切片，并逐项 free(entry.name)。
pub fn getNetworkStatsPerInterface(allocator: std.mem.Allocator) OsError![]NetworkInterfaceStats {
    return switch (builtin.os.tag) {
        .linux => getNetworkStatsPerInterfaceLinux(allocator) orelse return error.IoError,
        else => error.Unsupported,
    };
}

fn getNetworkStatsPerInterfaceLinux(allocator: std.mem.Allocator) ?[]NetworkInterfaceStats {
    var file = std.fs.openFileAbsolute("/proc/net/dev", .{ .mode = .read_only }) catch return null;
    defer file.close();
    var buf: [4096]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    const content = buf[0..n];
    var list = std.ArrayListUnmanaged(NetworkInterfaceStats).initCapacity(allocator, 16) catch return null;
    var i: usize = 0;
    var line_index: u32 = 0;
    while (i < content.len) {
        const line_end = std.mem.indexOfScalarPos(u8, content, i, '\n') orelse content.len;
        const line = content[i..line_end];
        i = line_end + 1;
        line_index += 1;
        if (line_index <= 2) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const rest = std.mem.trim(u8, line[colon + 1 ..]);
        var col: u32 = 0;
        var rx: u64 = 0;
        var tx: u64 = 0;
        var iter = std.mem.splitScalar(u8, rest, ' ');
        while (iter.next()) |seg| {
            if (seg.len == 0) continue;
            col += 1;
            const v = parseDecimalU64(seg) orelse 0;
            if (col == 1) rx = v;
            if (col == 9) tx = v;
        }
        const name = allocator.dupe(u8, std.mem.trim(u8, line[0..colon])) catch return null;
        list.append(allocator, .{ .name = name, .rx_bytes = rx, .tx_bytes = tx }) catch {
            allocator.free(name);
            return null;
        };
    }
    return list.toOwnedSlice(allocator) catch return null;
}

/// 当前 TCP 连接数（ESTABLISHED 等）。Linux 统计 /proc/net/tcp 行数减表头。allocator 用于读文件缓冲（避免栈上 32KB）。
pub fn getTcpConnectionCount(allocator: std.mem.Allocator) OsError!u32 {
    return switch (builtin.os.tag) {
        .linux => getTcpConnectionCountLinux(allocator) orelse return error.IoError,
        else => error.Unsupported,
    };
}

fn getTcpConnectionCountLinux(allocator: std.mem.Allocator) ?u32 {
    var file = std.fs.openFileAbsolute("/proc/net/tcp", .{ .mode = .read_only }) catch return null;
    defer file.close();
    var buf = allocator.alloc(u8, 32768) catch return null;
    defer allocator.free(buf);
    const n = file.readAll(buf) catch return null;
    const content = buf[0..n];
    var count: u32 = 0;
    var i: usize = 0;
    var line_index: u32 = 0;
    while (i < content.len) {
        const line_end = std.mem.indexOfScalarPos(u8, content, i, '\n') orelse content.len;
        line_index += 1;
        i = line_end + 1;
        if (line_index == 1) continue; // 表头
        count += 1;
    }
    return if (count > 0) count - 1 else 0;
}

// -----------------------------------------------------------------------------
// 网络 RTT/延迟（主动 TCP connect 探针）
// -----------------------------------------------------------------------------

/// [Allocates] 对 host:port 做一次 TCP connect 探针，返回往返时间（毫秒）。调用方无需单独 free。可能阻塞至 OS 默认 connect 超时。
pub fn getNetworkRttMs(allocator: std.mem.Allocator, host: []const u8, port: u16) OsError!u32 {
    return switch (builtin.os.tag) {
        .linux, .macos => getNetworkRttMsPosix(allocator, host, port) orelse return error.IoError,
        else => error.Unsupported,
    };
}

fn getNetworkRttMsPosix(allocator: std.mem.Allocator, host: []const u8, port: u16) ?u32 {
    const host_z = allocator.dupeZ(u8, host) catch return null;
    defer allocator.free(host_z);
    var port_buf: [6]u8 = undefined;
    const port_len = std.fmt.formatIntBuf(&port_buf, port, 10, .lower, .{});
    const port_z = allocator.dupeZ(u8, port_buf[0..port_len]) catch return null;
    defer allocator.free(port_z);
    var hints: std.c.addrinfo = undefined;
    @memset(std.mem.asBytes(&hints), 0);
    hints.family = std.c.AF.UNSPEC;
    hints.socktype = std.c.SOCK.STREAM;
    var res: ?*std.c.addrinfo = null;
    if (std.c.getaddrinfo(host_z.ptr, port_z.ptr, &hints, &res) != 0) return null;
    defer if (res) |r| std.c.freeaddrinfo(r);
    const first = res orelse return null;
    const fd = std.c.socket(first.family, first.socktype, first.protocol);
    if (fd == -1) return null;
    defer _ = std.c.close(fd);
    const t0 = std.time.nanoTimestamp();
    if (std.c.connect(fd, first.addr, first.addrlen) != 0) return null;
    const t1 = std.time.nanoTimestamp();
    const ns = t1 - t0;
    if (ns < 0) return 0;
    return @as(u32, @intCast(@min(0xFFFF_FFFF, @as(u64, @intCast(ns)) / std.time.ns_per_ms)));
}

// -----------------------------------------------------------------------------
// 系统负载、运行时间、温度、电池
// -----------------------------------------------------------------------------

/// 系统负载（1/5/15 分钟平均）。Linux 读 /proc/loadavg；macOS 用 sysctlbyname("vm.loadavg")。
pub fn getLoadAverage() OsError!LoadAverage {
    return switch (builtin.os.tag) {
        .linux => getLoadAverageLinux() orelse return error.IoError,
        .macos => getLoadAverageMacos() orelse return error.IoError,
        else => error.Unsupported,
    };
}

fn getLoadAverageLinux() ?LoadAverage {
    var file = std.fs.openFileAbsolute("/proc/loadavg", .{ .mode = .read_only }) catch return null;
    defer file.close();
    var buf: [128]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    const line = std.mem.trim(u8, buf[0..n]);
    var iter = std.mem.splitScalar(u8, line, ' ');
    const l1 = iter.next() orelse return null;
    const l5 = iter.next() orelse return null;
    const l15 = iter.next() orelse return null;
    return .{
        .load_1 = std.fmt.parseFloat(f32, l1) catch return null,
        .load_5 = std.fmt.parseFloat(f32, l5) catch return null,
        .load_15 = std.fmt.parseFloat(f32, l15) catch return null,
    };
}

/// macOS：sysctlbyname("vm.loadavg") 得到 struct loadavg（ldavg[3]、fscale），换算为浮点。
fn getLoadAverageMacos() ?LoadAverage {
    const c = @cImport({
        @cInclude("sys/sysctl.h");
    });
    var load: c.struct_loadavg = undefined;
    var size: c.size_t = @sizeOf(c.struct_loadavg);
    if (c.sysctlbyname("vm.loadavg", &load, &size, null, 0) != 0) return null;
    const scale: f32 = if (load.fscale > 0) @floatFromInt(load.fscale) else 1.0;
    return .{
        .load_1 = @as(f32, @floatFromInt(load.ldavg[0])) / scale,
        .load_5 = @as(f32, @floatFromInt(load.ldavg[1])) / scale,
        .load_15 = @as(f32, @floatFromInt(load.ldavg[2])) / scale,
    };
}

/// 系统运行时间（秒）。Linux 读 /proc/uptime；macOS 用 kern.boottime；Windows 用 GetTickCount64。
pub fn getUptimeSeconds() OsError!u64 {
    return switch (builtin.os.tag) {
        .linux => getUptimeSecondsLinux() orelse return error.IoError,
        .macos => getUptimeSecondsMacos() orelse return error.IoError,
        .windows => getUptimeSecondsWindows() orelse return error.IoError,
        else => error.Unsupported,
    };
}

fn getUptimeSecondsLinux() ?u64 {
    var file = std.fs.openFileAbsolute("/proc/uptime", .{ .mode = .read_only }) catch return null;
    defer file.close();
    var buf: [64]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    var i: usize = 0;
    while (i < n and buf[i] != ' ' and buf[i] != '\n') i += 1;
    return parseDecimalU64(buf[0..i]);
}

/// macOS：sysctlbyname("kern.boottime") 得 timeval，当前时间减启动时间即 uptime。
fn getUptimeSecondsMacos() ?u64 {
    const c = @cImport({
        @cInclude("sys/sysctl.h");
        @cInclude("sys/time.h");
    });
    var boot: c.struct_timeval = undefined;
    var size: c.size_t = @sizeOf(c.struct_timeval);
    if (c.sysctlbyname("kern.boottime", &boot, &size, null, 0) != 0) return null;
    var now: c.struct_timeval = undefined;
    if (c.gettimeofday(&now, null) != 0) return null;
    const boot_sec = @as(i64, boot.tv_sec) + @divTrunc(@as(i64, boot.tv_usec), 1_000_000);
    const now_sec = @as(i64, now.tv_sec) + @divTrunc(@as(i64, now.tv_usec), 1_000_000);
    const uptime = now_sec - boot_sec;
    return if (uptime >= 0) @as(u64, @intCast(uptime)) else 0;
}

/// Windows：GetTickCount64 返回自启动以来的毫秒数，除以 1000 得秒。
fn getUptimeSecondsWindows() ?u64 {
    if (builtin.os.tag != .windows) return null;
    const ms = win.kernel32.GetTickCount64();
    return ms / 1000;
}

/// CPU 或热区温度（摄氏度）。Linux 读 sysfs thermal_zone0。
pub fn getCpuTemperatureC() OsError!f32 {
    return switch (builtin.os.tag) {
        .linux => getCpuTemperatureLinux() orelse return error.IoError,
        else => error.Unsupported,
    };
}

fn getCpuTemperatureLinux() ?f32 {
    const path = "/sys/class/thermal/thermal_zone0/temp";
    var file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch return null;
    defer file.close();
    var buf: [32]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    const trim = std.mem.trim(u8, buf[0..n]);
    const millic = std.fmt.parseInt(i64, trim, 10) catch return null;
    return @as(f32, @floatFromInt(millic)) / 1000.0;
}

/// 电池电量（0..100）。Linux 读 sysfs power_supply/BAT0/capacity。
pub fn getBatteryPercent() OsError!u32 {
    return switch (builtin.os.tag) {
        .linux => getBatteryPercentLinux() orelse return error.IoError,
        else => error.Unsupported,
    };
}

fn getBatteryPercentLinux() ?u32 {
    const path = "/sys/class/power_supply/BAT0/capacity";
    var file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch return null;
    defer file.close();
    var buf: [16]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    const percent = std.fmt.parseInt(u32, std.mem.trim(u8, buf[0..n]), 10) catch return null;
    return @min(100, percent);
}
