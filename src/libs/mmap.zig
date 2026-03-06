//! 文件 mmap 封装（mmap.zig）
//!
//! 职责：
//!   - 提供高性能只读与可写映射接口，实现零拷贝访问文件内容。
//!   - 针对不同操作系统内核提供特化的预取与性能提示。
//!
//! 极致压榨亮点：
//!   1. **Windows 预扫描优化**：直接调用 `CreateFileW` 并指定 `FILE_FLAG_SEQUENTIAL_SCAN`，极大提升顺序读取性能。
//!   2. **Linux NUMA 绑定**：支持 `mbindToCurrentNode` 将映射区域强制分配在当前处理器的本地 NUMA 节点上。
//!   3. **macOS 激进预读**：利用 macOS 特有的 `F_RDAHEAD` 与 `MADV_WILLNEED` 实现大文件的异步背景预加载。
//!   4. **大页提示**：在 Linux 上检测到映射大于 2MB 时自动触发 `MADV_HUGEPAGE`，减少 TLB 未命中开销。
//!   5. **窄化错误集**：针对映射路径精选 `MmapError` 错误集，优化编译器生成的跳转表性能。
//!
//! 适用规范：
//!   - 遵循 00 §1.7（大文件与 mmap）、§4.2（Linux NUMA 与内存池）。
//!
//! [Allocates] 返回的句柄须由调用方显式执行 `deinit`。

const std = @import("std");
const builtin = @import("builtin");

/// 映射相关的窄化错误集，减少热路径分支压力 (§2.1)
pub const MmapError = error{
    FileNotFound,
    AccessDenied,
    NotAFile,
    FileRead,
    SystemResources,
    Unsupported,
    NameTooLong,
    OutOfMemory,
};

/// 顺序访问提示（Linux/Darwin 通用）；用于 madvise，加强预取
const MADV_SEQUENTIAL = 2;
/// 即将访问提示；对区间调用后内核可预取页（按需 MADV_WILLNEED）
const MADV_WILLNEED = 3;
/// Linux 大页提示（§4.2 THP）；大映射时建议内核使用大页，减少 TLB 未命中
const MADV_HUGEPAGE: c_int = 14;

/// macOS 特有 fcntl 标志
const F_RDAHEAD = 45; // 开启激进预读
const F_NOCACHE = 48; // 绕过内核缓存（防止污染）

extern "c" fn madvise(addr: *anyopaque, length: usize, advice: c_int) c_int;

/// 只读映射文件的句柄；调用方负责在不再使用时调用 deinit 以 unmap
pub const MappedFile = struct {
    /// 映射区域首地址；只读，有效长度为 len
    ptr: [*]align(std.heap.page_size_min) const u8,
    len: usize,
    /// 仅 Windows 使用：CreateFileMapping 句柄，deinit 时 UnmapViewOfFile + CloseHandle
    mapping_handle: ?*anyopaque = null,

    /// 释放映射；调用后不得再访问 ptr
    pub fn deinit(self: *MappedFile) void {
        if (self.len == 0 and self.mapping_handle == null) return;
        if (builtin.os.tag == .windows and self.mapping_handle != null) {
            windowsUnmap(self.ptr, self.mapping_handle.?);
        } else if (self.len > 0) {
            posixMunmap(self.ptr, self.len);
        }
        self.* = .{ .ptr = undefined, .len = 0, .mapping_handle = null };
    }

    /// 返回只读切片，与映射生命周期一致
    pub fn slice(self: *const MappedFile) []const u8 {
        return self.ptr[0..self.len];
    }

    /// 按需预取：提示内核即将访问 [offset..offset+length]，可提前读入页（MADV_WILLNEED）
    pub fn prefetchRange(self: *const MappedFile, offset: usize, length: usize) void {
        if (builtin.os.tag != .windows and length > 0 and offset < self.len) {
            const safe_len = @min(length, self.len - offset);
            _ = madvise(@constCast(@ptrCast(self.ptr + offset)), safe_len, MADV_WILLNEED);
        }
    }
};

/// 可写映射文件的句柄；写入会反映到文件（MAP_SHARED）；调用方负责 deinit
pub const MappedFileWritable = struct {
    /// 映射区域首地址；可读可写，有效长度为 len
    ptr: [*]align(std.heap.page_size_min) u8,
    len: usize,
    /// 仅 Windows 使用
    mapping_handle: ?*anyopaque = null,

    /// 释放映射（会刷回文件）；调用后不得再访问 ptr
    pub fn deinit(self: *MappedFileWritable) void {
        if (self.len == 0 and self.mapping_handle == null) return;
        if (builtin.os.tag == .windows and self.mapping_handle != null) {
            windowsUnmap(@ptrCast(self.ptr), self.mapping_handle.?);
        } else if (self.len > 0) {
            posixMunmap(@as([*]align(std.heap.page_size_min) const u8, @ptrCast(self.ptr)), self.len);
        }
        self.* = .{ .ptr = undefined, .len = 0, .mapping_handle = null };
    }

    /// 返回可写切片，与映射生命周期一致；写入会持久化到文件
    pub fn slice(self: *MappedFileWritable) []u8 {
        return self.ptr[0..self.len];
    }

    /// 按需预取：提示内核即将访问 [offset..offset+length]（MADV_WILLNEED）；仅 POSIX
    pub fn prefetchRange(self: *const MappedFileWritable, offset: usize, length: usize) void {
        if (builtin.os.tag != .windows and length > 0 and offset < self.len) {
            const safe_len = @min(length, self.len - offset);
            _ = madvise(@ptrCast(self.ptr + offset), safe_len, MADV_WILLNEED);
        }
    }
};

/// [Allocates] 将路径对应的文件以只读方式映射进进程地址空间；调用方负责 deinit。
/// 任意大小、任意格式均可；大文件时可避免 readToEndAlloc 的整文件分配与多次拷贝（§1.7）
pub fn mapFileReadOnly(path: []const u8) MmapError!MappedFile {
    return switch (builtin.os.tag) {
        .linux, .macos, .freebsd, .netbsd, .openbsd => mapFileReadOnlyPosix(path),
        .windows => mapFileReadOnlyWindows(path),
        else => error.Unsupported,
    };
}

/// [Allocates] 将路径对应的文件以可读可写方式映射进进程地址空间；调用方负责 deinit。
/// 任意格式；使用 MAP_SHARED，写入会同步到文件；适用于已存在且非空文件
pub fn mapFileReadWrite(path: []const u8) MmapError!MappedFileWritable {
    return switch (builtin.os.tag) {
        .linux, .macos, .freebsd, .netbsd, .openbsd => mapFileReadWritePosix(path),
        .windows => mapFileReadWriteWindows(path),
        else => error.Unsupported,
    };
}

const posix = std.posix;

/// Zig 0.16：std.fs.openFileAbsolute 已迁移，此处用 posix.openat 取得 fd 供 mmap。Darwin 上 posix.O 来自 std.c 无 RDONLY 成员，用数值。
fn mapFileReadOnlyPosix(path: []const u8) MmapError!MappedFile {
    if (path.len >= std.Io.Dir.max_path_bytes) return error.NameTooLong;
    var path_z: [std.Io.Dir.max_path_bytes]u8 = undefined;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    const o_rdonly: posix.O = switch (builtin.os.tag) {
        .linux => posix.O.RDONLY,
        else => @bitCast(@as(u32, 0)), // O_RDONLY on Darwin/BSD；posix.O 为 packed struct(u32)
    };
    const fd = posix.openat(posix.AT.FDCWD, path_z[0..path.len], o_rdonly, 0) catch |e| switch (e) {
        error.FileNotFound => return error.FileNotFound,
        error.AccessDenied => return error.AccessDenied,
        else => return error.FileRead,
    };
    defer _ = std.c.close(fd);

    if (builtin.os.tag == .macos) {
        // macOS 极致优化：开启激进异步预读
        _ = std.c.fcntl(fd, F_RDAHEAD, @as(c_int, 1));
    }

    var stat: std.c.Stat = undefined;
    if (std.c.fstat(fd, &stat) != 0) return error.FileRead;
    const mode = if (builtin.os.tag == .linux) stat.st_mode else stat.mode;
    if (mode & std.c.S.IFMT != std.c.S.IFREG) return error.NotAFile;
    const size = if (builtin.os.tag == .linux) stat.st_size else stat.size;
    if (size == 0) {
        const empty: [0]u8 = .{};
        return .{ .ptr = @alignCast(empty[0..].ptr), .len = 0, .mapping_handle = null };
    }
    const len: usize = @intCast(size);
    const prot_read: posix.PROT = if (builtin.os.tag == .linux) posix.PROT.READ else @bitCast(@as(c_int, 1)); // Darwin: PROT_READ=1
    const ptr = if (builtin.os.tag == .linux)
        try mapFileLinux(fd, len, false)
    else
        posix.mmap(
            null,
            len,
            prot_read,
            .{ .TYPE = .PRIVATE },
            fd,
            0,
        ) catch return error.SystemResources;

    adviseSequential(@ptrCast(ptr.ptr), ptr.len);
    if (builtin.os.tag == .macos) {
        // macOS 对于大文件的异步加载提示
        if (len >= 1024 * 1024) {
            _ = madvise(@ptrCast(ptr.ptr), ptr.len, MADV_WILLNEED);
        }
    }
    if (builtin.os.tag == .linux) {
        if (len >= 2 * 1024 * 1024) {
            _ = madvise(@ptrCast(ptr.ptr), ptr.len, MADV_HUGEPAGE);
        }
        // 极致优化：将映射内存绑定到当前线程所在的 NUMA 节点 (§3.1, §4.2)
        mbindToCurrentNode(@ptrCast(ptr.ptr), ptr.len);
    }
    return .{ .ptr = @ptrCast(ptr.ptr), .len = ptr.len, .mapping_handle = null };
}

/// 可写映射：PROT_READ | PROT_WRITE + MAP_SHARED，写入会持久化到文件。Zig 0.16 用 posix.openat；Darwin 用数值 O_RDWR。
fn mapFileReadWritePosix(path: []const u8) MmapError!MappedFileWritable {
    if (path.len >= std.Io.Dir.max_path_bytes) return error.NameTooLong;
    var path_z: [std.Io.Dir.max_path_bytes]u8 = undefined;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    const o_rdwr: posix.O = switch (builtin.os.tag) {
        .linux => posix.O.RDWR,
        else => @bitCast(@as(u32, 2)), // O_RDWR on Darwin/BSD；posix.O 为 packed struct(u32)
    };
    const fd = posix.openat(posix.AT.FDCWD, path_z[0..path.len], o_rdwr, 0) catch |e| switch (e) {
        error.FileNotFound => return error.FileNotFound,
        error.AccessDenied => return error.AccessDenied,
        else => return error.FileRead,
    };
    defer _ = std.c.close(fd);

    if (builtin.os.tag == .macos) {
        _ = std.c.fcntl(fd, F_RDAHEAD, @as(c_int, 1));
    }

    var stat: std.c.Stat = undefined;
    if (std.c.fstat(fd, &stat) != 0) return error.FileRead;
    const mode_rw = if (builtin.os.tag == .linux) stat.st_mode else stat.mode;
    if (mode_rw & std.c.S.IFMT != std.c.S.IFREG) return error.NotAFile;
    const size_rw = if (builtin.os.tag == .linux) stat.st_size else stat.size;
    if (size_rw == 0) {
        var empty: [0]u8 = .{};
        return .{ .ptr = @alignCast(empty[0..].ptr), .len = 0, .mapping_handle = null };
    }
    const len: usize = @intCast(size_rw);
    const prot_rw: posix.PROT = if (builtin.os.tag == .linux) posix.PROT.READ | posix.PROT.WRITE else @bitCast(@as(c_int, 1 | 2)); // Darwin: PROT_READ=1, PROT_WRITE=2
    const ptr = if (builtin.os.tag == .linux)
        try mapFileLinux(fd, len, true)
    else
        posix.mmap(
            null,
            len,
            prot_rw,
            .{ .TYPE = .SHARED },
            fd,
            0,
        ) catch return error.SystemResources;

    adviseSequential(@ptrCast(ptr.ptr), ptr.len);
    if (builtin.os.tag == .macos) {
        if (len >= 1024 * 1024) {
            _ = madvise(@ptrCast(ptr.ptr), ptr.len, MADV_WILLNEED);
        }
    }
    if (builtin.os.tag == .linux) {
        if (len >= 2 * 1024 * 1024) {
            _ = madvise(@ptrCast(ptr.ptr), ptr.len, MADV_HUGEPAGE);
        }
        mbindToCurrentNode(@ptrCast(ptr.ptr), ptr.len);
    }
    return .{ .ptr = ptr.ptr, .len = ptr.len, .mapping_handle = null };
}

/// Linux 专用：MAP_POPULATE 预填页，减少首次访问缺页；read_only 为 false 时用 MAP_SHARED
fn mapFileLinux(fd: std.posix.fd_t, len: usize, writable: bool) MmapError![]align(std.heap.page_size_min) u8 {
    const linux = std.os.linux;
    const flags_read = linux.MAP.PRIVATE | linux.MAP.POPULATE;
    const flags_rw = linux.MAP.SHARED | linux.MAP.POPULATE;
    const prot = if (writable) linux.PROT.READ | linux.PROT.WRITE else linux.PROT.READ;
    const flags = if (writable) flags_rw else flags_read;
    return linux.mmap(null, len, prot, flags, fd, 0) catch return error.SystemResources;
}

/// 极致优化：将映射内存绑定到当前线程所在的 NUMA 节点 (§3.1, §4.2)
fn mbindToCurrentNode(ptr: [*]const u8, len: usize) void {
    if (builtin.os.tag != .linux) return;
    const linux = std.os.linux;
    var cpu: c_uint = 0;
    var node: c_uint = 0;
    // 获取当前 CPU 和所在的 NUMA 节点
    if (linux.getcpu(&cpu, &node, null) == 0) {
        const nodemask: usize = @as(usize, 1) << @as(u6, @intCast(node & 63));
        const MPOL_PREFERRED = 1;
        const MPOL_F_RELATIVE_NODES = (1 << 14);
        // mbind 系统调用：将内存范围绑定到指定的 NUMA 节点
        _ = linux.syscall6(.mbind, @intFromPtr(ptr), len, MPOL_PREFERRED | MPOL_F_RELATIVE_NODES, @intFromPtr(&nodemask), @sizeOf(usize) * 8, 0);
    }
}

/// 提示内核该区域将顺序访问，利于预取与回收（忽略返回值，内核可忽略提示）
fn adviseSequential(addr: *anyopaque, length: usize) void {
    _ = madvise(addr, length, MADV_SEQUENTIAL);
}

fn posixMunmap(ptr: [*]align(std.heap.page_size_min) const u8, len: usize) void {
    posix.munmap(@as([*]align(std.heap.page_size_min) u8, @ptrCast(@constCast(ptr)))[0..len]);
}

// ---------- Windows：CreateFileMapping + MapViewOfFile ----------
const win = std.os.windows;
const kernel32 = win.kernel32;
const PAGE_READONLY: win.DWORD = 0x02;
const PAGE_READWRITE: win.DWORD = 0x04;
const FILE_MAP_READ: win.DWORD = 0x0004;
const FILE_MAP_WRITE: win.DWORD = 0x0002;

fn mapFileReadOnlyWindows(path: []const u8) MmapError!MappedFile {
    const path_w = std.os.windows.sliceToPrefixedFileDecoded(path) catch return error.NameTooLong;
    // 极致优化：直接使用 CreateFileW 并指定 FILE_FLAG_SEQUENTIAL_SCAN 提示内核预取 (§4.3)
    const file_handle = kernel32.CreateFileW(
        path_w.span().ptr,
        win.GENERIC_READ,
        win.FILE_SHARE_READ,
        null,
        win.OPEN_EXISTING,
        win.FILE_ATTRIBUTE_NORMAL | win.FILE_FLAG_SEQUENTIAL_SCAN,
        null,
    );
    if (file_handle == win.INVALID_HANDLE_VALUE) {
        return switch (kernel32.GetLastError()) {
            .FILE_NOT_FOUND => error.FileNotFound,
            .ACCESS_DENIED => error.AccessDenied,
            else => error.FileRead,
        };
    }
    defer _ = kernel32.CloseHandle(file_handle);

    var size: win.LARGE_INTEGER = undefined;
    if (kernel32.GetFileSizeEx(file_handle, &size) == 0) return error.FileRead;
    const fsize = @as(u64, @bitCast(size));
    if (fsize == 0) {
        const empty: [0]u8 = .{};
        return .{ .ptr = @alignCast(empty[0..].ptr), .len = 0, .mapping_handle = null };
    }

    const size_lo = @as(win.DWORD, @intCast(fsize & 0xFFFFFFFF));
    const size_hi = @as(win.DWORD, @intCast(fsize >> 32));
    const mapping = kernel32.CreateFileMappingW(
        file_handle,
        null,
        PAGE_READONLY,
        size_hi,
        size_lo,
        null,
    ) orelse return error.AccessDenied;
    errdefer _ = kernel32.CloseHandle(mapping);

    const view = kernel32.MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, 0) orelse {
        _ = kernel32.CloseHandle(mapping);
        return error.AccessDenied;
    };
    return .{
        .ptr = @ptrCast(view),
        .len = @as(usize, @intCast(fsize)),
        .mapping_handle = mapping,
    };
}

fn mapFileReadWriteWindows(path: []const u8) MmapError!MappedFileWritable {
    const path_w = std.os.windows.sliceToPrefixedFileDecoded(path) catch return error.NameTooLong;
    const file_handle = kernel32.CreateFileW(
        path_w.span().ptr,
        win.GENERIC_READ | win.GENERIC_WRITE,
        win.FILE_SHARE_READ | win.FILE_SHARE_WRITE,
        null,
        win.OPEN_EXISTING,
        win.FILE_ATTRIBUTE_NORMAL | win.FILE_FLAG_SEQUENTIAL_SCAN,
        null,
    );
    if (file_handle == win.INVALID_HANDLE_VALUE) {
        return switch (kernel32.GetLastError()) {
            .FILE_NOT_FOUND => error.FileNotFound,
            .ACCESS_DENIED => error.AccessDenied,
            else => error.FileRead,
        };
    }
    defer _ = kernel32.CloseHandle(file_handle);

    var size: win.LARGE_INTEGER = undefined;
    if (kernel32.GetFileSizeEx(file_handle, &size) == 0) return error.FileRead;
    const fsize = @as(u64, @bitCast(size));
    if (fsize == 0) {
        var empty: [0]u8 = .{};
        return .{ .ptr = @alignCast(empty[0..].ptr), .len = 0, .mapping_handle = null };
    }

    const size_lo = @as(win.DWORD, @intCast(fsize & 0xFFFFFFFF));
    const size_hi = @as(win.DWORD, @intCast(fsize >> 32));
    const mapping = kernel32.CreateFileMappingW(
        file_handle,
        null,
        PAGE_READWRITE,
        size_hi,
        size_lo,
        null,
    ) orelse return error.AccessDenied;
    errdefer _ = kernel32.CloseHandle(mapping);

    const view = kernel32.MapViewOfFile(mapping, FILE_MAP_WRITE, 0, 0, 0) orelse {
        _ = kernel32.CloseHandle(mapping);
        return error.AccessDenied;
    };
    return .{
        .ptr = @ptrCast(view),
        .len = @as(usize, @intCast(fsize)),
        .mapping_handle = mapping,
    };
}

fn windowsUnmap(ptr: [*]align(std.heap.page_size_min) const u8, mapping_handle: *anyopaque) void {
    _ = kernel32.UnmapViewOfFile(@ptrCast(ptr));
    _ = kernel32.CloseHandle(@ptrCast(mapping_handle));
}
