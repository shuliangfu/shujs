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
const std = @import("std");

// Zig 0.16：进程级 Io 来自 libs_process（process.zig），main 启动时 setProcessIo(init.io)
const libs_process = @import("libs_process");
pub const setProcessIo = libs_process.setProcessIo;
pub const getProcessIo = libs_process.getProcessIo;

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

// 统一文件/目录 API（同步 + AsyncFileIO）；Linux/Darwin/Windows 三种 AsyncFileIO 实现均在 file.zig 内，由 mod 统一导出
const file = @import("file.zig");
pub const File = file.File;
pub const Dir = file.Dir;
pub const FileOpenFlags = file.FileOpenFlags;
pub const FileCreateFlags = file.FileCreateFlags;
pub const DirOpenOptions = file.DirOpenOptions;
pub const DirSymLinkFlags = file.DirSymLinkFlags;
pub const DirCopyFileOptions = file.DirCopyFileOptions;
pub const FileOpenError = file.FileOpenError;
pub const openFileAbsolute = file.openFileAbsolute;
pub const createFileAbsolute = file.createFileAbsolute;
pub const openDirAbsolute = file.openDirAbsolute;
pub const openDirCwd = file.openDirCwd;
pub const realpath = file.realpath;
pub const makeDirAbsolute = file.makeDirAbsolute;
pub const makePathAbsolute = file.makePathAbsolute;
pub const deleteFileAbsolute = file.deleteFileAbsolute;
pub const deleteDirAbsolute = file.deleteDirAbsolute;
pub const renameAbsolute = file.renameAbsolute;
pub const accessAbsolute = file.accessAbsolute;
pub const readLinkAbsolute = file.readLinkAbsolute;
pub const symLinkAbsolute = file.symLinkAbsolute;
pub const max_path_bytes = file.max_path_bytes;
pub const copyFileAbsolute = file.copyFileAbsolute;
pub const deleteTreeAbsolute = file.deleteTreeAbsolute;
pub const pathDirname = file.pathDirname;
pub const pathBasename = file.pathBasename;
pub const pathExtension = file.pathExtension;
pub const pathIsAbsolute = file.pathIsAbsolute;
pub const pathJoin = file.pathJoin;
pub const pathResolve = file.pathResolve;
pub const pathRelative = file.pathRelative;
/// 从 std.io.Reader 分块读取最多 max_bytes，避免 gzip 等解压流触发 Writer.rebase；供 registry 等 HTTP 响应体读取。调用方 free 返回的切片。
pub const readReaderUpTo = file.readReaderUpTo;
/// 异步文件 I/O：submitReadFile/submitWriteFile + pollCompletions 返回 tag=file_read/file_write；三平台实现均在 file.zig 内
pub const AsyncFileIO = file.AsyncFileIO;

/// 统一 HTTP 客户端：request(任意方法)/get(GET 便捷)，供 package/registry、shu:fetch 使用；仅 Zig 路径（std.http.Client）
pub const http = @import("http.zig");

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

/// NUMA：Linux 下将内存区域绑定到当前 CPU 所在 NUMA 节点（00 §4.2）；Darwin/Windows 为 no-op，三端同签名由 backend 实现
pub const mbindToCurrentNode = backend.mbindToCurrentNode;
