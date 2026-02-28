// 高性能 I/O 核心（io_core）：统一 API，按目标平台编译期分派，无运行时分支。
//
// 职责
//   - 对外提供与平台无关的 HighPerfIO、sendFile、BufferPool、RingBuffer、MappedFile 等；
//   - 编译时根据 builtin.os.tag 只链接当前平台的实现（linux.zig / darwin.zig / windows.zig），
//     符合 00-性能规则 §2.2 comptime 分派，无多余二进制与分支。
//
// 导出
//   - api：公共类型与错误（Completion、SendFileError、InitOptions、BufferPool），见 api.zig；
//   - HighPerfIO、sendFile：由 backend（linux/darwin/windows）实现，本模块仅转发；
//   - RingBuffer：无锁 SPSC 环形队列，平台无关，见 ring_buffer.zig；
//   - MappedFile / MappedFileWritable、mapFileReadOnly / mapFileReadWrite：大文件 mmap，见 mmap.zig。
//
// 平台
//   - Linux => linux.zig（io_uring + sendfile）；
//   - macOS/BSD => darwin.zig（kqueue + sendfile）；
//   - Windows => windows.zig（IOCP + AcceptEx 首包零拷贝入池 + GQCSEx 批量收割 + TransmitFile）；
//   - 其他 => 编译错误。
//
// Buffer 调度与解析路线：ChunkAllocator（api.zig）、SIMD 扫描示例（simd_scan.zig）、见 docs/IO_CORE_ROADMAP.md

const builtin = @import("builtin");

// 公共类型与错误，三端共用
pub const api = @import("api.zig");
pub const Completion = api.Completion;
pub const SendFileError = api.SendFileError;
pub const InitOptions = api.InitOptions;
pub const BufferPool = api.BufferPool;
pub const ChunkAllocator = api.ChunkAllocator;

/// SIMD 向量化扫描示例（\r/\n 定位），供 HTTP 等解析器参考；零拷贝：解析结果应持 []const u8 引用池内内存
pub const simd_scan = @import("simd_scan.zig");

// 无锁环形队列，平台无关
pub const RingBuffer = @import("ring_buffer.zig").RingBuffer;

// 大文件 mmap（§1.7）：只读与可写；含 Windows 实现及 Linux MAP_POPULATE/THP 优化
pub const MappedFile = @import("mmap.zig").MappedFile;
pub const MappedFileWritable = @import("mmap.zig").MappedFileWritable;
pub const mapFileReadOnly = @import("mmap.zig").mapFileReadOnly;
pub const mapFileReadWrite = @import("mmap.zig").mapFileReadWrite;

// 按 OS 选择实现，编译时只包含当前平台
const backend = switch (builtin.os.tag) {
    .linux => @import("linux.zig"),
    .macos, .freebsd, .netbsd, .openbsd => @import("darwin.zig"),
    .windows => @import("windows.zig"),
    else => @compileError("io_core 暂不支持此平台，仅 Linux / macOS(BSD) / Windows"),
};

/// 当前平台的高性能 I/O 句柄类型
pub const HighPerfIO = backend.HighPerfIO;

/// 零拷贝：文件 → 网络（Linux sendfile / Darwin sendfile / Windows TransmitFile），符合 00-性能规范 §3.4、§4
pub const sendFile = backend.sendFile;

/// 异步文件 I/O：submitReadFile/submitWriteFile + pollCompletions 返回 tag=file_read/file_write；Linux 用独立 io_uring，Darwin/Windows 用工作线程
pub const AsyncFileIO = backend.AsyncFileIO;
