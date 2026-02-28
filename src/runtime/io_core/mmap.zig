// 文件 mmap 封装（mmap.zig）：只读与可写映射，零拷贝访问文件内容。
//
// 职责
//   - mapFileReadOnly(path)：只读映射，返回 MappedFile，调用方 deinit 释放；
//   - mapFileReadWrite(path)：可写映射（MAP_SHARED），返回 MappedFileWritable，写入同步到文件；
//   - MappedFile / MappedFileWritable 提供 slice()、deinit()、prefetchRange(offset, length)（仅 POSIX）。
//
// 适用场景
//   - 任意大小、任意格式文件；大文件（大模型权重、日志、数据集）时优势明显：不预分配整文件内存、按需换页，无「内核→用户缓冲」二次拷贝；
//   - 格式无关：仅将文件按原始字节映射，由调用方按 slice() 得到的 []u8/[]const u8 自行解析。
//
// 平台
//   - Linux/Darwin：posix mmap；Linux 上使用 MAP_POPULATE 预填页，大映射（≥2MB）时 madvise MADV_HUGEPAGE；
//   - Windows：CreateFileMappingW + MapViewOfFile；deinit 时 UnmapViewOfFile + CloseHandle(mapping_handle)。
//
// 性能优化（规范 §1.7、§4.2）
//   - 映射后 madvise(..., MADV_SEQUENTIAL)，顺序扫时预取与回收更优；
//   - prefetchRange(offset, len)：madvise(..., MADV_WILLNEED)，适合稀疏访问；
//   - Linux：MAP_POPULATE 减少首次访问缺页；MADV_HUGEPAGE 建议 THP，减少 TLB 未命中。
//
// 调用约定
//   - mapFileReadOnly / mapFileReadWrite 返回的句柄由调用方在不再使用时调用 deinit；未 deinit 前 slice() 有效。

const std = @import("std");
const builtin = @import("builtin");

/// 顺序访问提示（Linux/Darwin 通用）；用于 madvise，加强预取
const MADV_SEQUENTIAL = 2;
/// 即将访问提示；对区间调用后内核可预取页（按需 MADV_WILLNEED）
const MADV_WILLNEED = 3;
/// Linux 大页提示（§4.2 THP）；大映射时建议内核使用大页，减少 TLB 未命中
const MADV_HUGEPAGE: c_int = 14;
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

    /// 按需预取：提示内核即将访问 [offset..offset+length]，可提前读入页（MADV_WILLNEED）；仅 POSIX
    pub fn prefetchRange(self: *const MappedFile, offset: usize, length: usize) void {
        if (builtin.os.tag != .windows and length > 0 and offset < self.len) {
            const safe_len = @min(length, self.len - offset);
            _ = madvise(@ptrCast(self.ptr + offset), safe_len, MADV_WILLNEED);
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

/// 将路径对应的文件以只读方式映射进进程地址空间；调用方负责 deinit
/// 任意大小、任意格式均可；大文件时可避免 readToEndAlloc 的整文件分配与多次拷贝（§1.7）
pub fn mapFileReadOnly(path: []const u8) !MappedFile {
    return switch (builtin.os.tag) {
        .linux, .macos, .freebsd, .netbsd, .openbsd => mapFileReadOnlyPosix(path),
        .windows => mapFileReadOnlyWindows(path),
        else => error.Unsupported,
    };
}

/// 将路径对应的文件以可读可写方式映射进进程地址空间；调用方负责 deinit
/// 任意格式；使用 MAP_SHARED，写入会同步到文件；适用于已存在且非空文件
pub fn mapFileReadWrite(path: []const u8) !MappedFileWritable {
    return switch (builtin.os.tag) {
        .linux, .macos, .freebsd, .netbsd, .openbsd => mapFileReadWritePosix(path),
        .windows => mapFileReadWriteWindows(path),
        else => error.Unsupported,
    };
}

const posix = std.posix;

fn mapFileReadOnlyPosix(path: []const u8) !MappedFile {
    const file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch |e| switch (e) {
        error.FileNotFound => return error.FileNotFound,
        error.AccessDenied => return error.AccessDenied,
        else => return e,
    };
    defer file.close();
    const stat = file.stat() catch return error.FileRead;
    if (stat.kind != .file) return error.NotAFile;
    const size = stat.size;
    if (size == 0) {
        const empty: [0]u8 = .{};
        return .{ .ptr = @alignCast(empty[0..].ptr), .len = 0, .mapping_handle = null };
    }
    const len: usize = @intCast(size);
    const ptr = if (builtin.os.tag == .linux)
        try mapFileLinux(file.handle, len, false)
    else
        try posix.mmap(
            null,
            len,
            posix.PROT.READ,
            .{ .TYPE = .PRIVATE },
            file.handle,
            0,
        );
    adviseSequential(@ptrCast(ptr.ptr), ptr.len);
    if (builtin.os.tag == .linux and len >= 2 * 1024 * 1024) {
        _ = madvise(@ptrCast(ptr.ptr), ptr.len, MADV_HUGEPAGE);
    }
    return .{ .ptr = @ptrCast(ptr.ptr), .len = ptr.len, .mapping_handle = null };
}

/// 可写映射：PROT_READ | PROT_WRITE + MAP_SHARED，写入会持久化到文件
fn mapFileReadWritePosix(path: []const u8) !MappedFileWritable {
    const file = std.fs.openFileAbsolute(path, .{ .mode = .read_write }) catch |e| switch (e) {
        error.FileNotFound => return error.FileNotFound,
        error.AccessDenied => return error.AccessDenied,
        else => return e,
    };
    defer file.close();
    const stat = file.stat() catch return error.FileRead;
    if (stat.kind != .file) return error.NotAFile;
    const size = stat.size;
    if (size == 0) {
        var empty: [0]u8 = .{};
        return .{ .ptr = @alignCast(empty[0..].ptr), .len = 0, .mapping_handle = null };
    }
    const len: usize = @intCast(size);
    const ptr = if (builtin.os.tag == .linux)
        try mapFileLinux(file.handle, len, true)
    else
        try posix.mmap(
            null,
            len,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );
    adviseSequential(@ptrCast(ptr.ptr), ptr.len);
    if (builtin.os.tag == .linux and len >= 2 * 1024 * 1024) {
        _ = madvise(@ptrCast(ptr.ptr), ptr.len, MADV_HUGEPAGE);
    }
    return .{ .ptr = ptr.ptr, .len = ptr.len, .mapping_handle = null };
}

/// Linux 专用：MAP_POPULATE 预填页，减少首次访问缺页；read_only 为 false 时用 MAP_SHARED
fn mapFileLinux(fd: std.posix.fd_t, len: usize, writable: bool) ![]align(std.heap.page_size_min) u8 {
    const linux = std.os.linux;
    const flags_read = linux.MAP.PRIVATE | linux.MAP.POPULATE;
    const flags_rw = linux.MAP.SHARED | linux.MAP.POPULATE;
    const prot = if (writable) linux.PROT.READ | linux.PROT.WRITE else linux.PROT.READ;
    const flags = if (writable) flags_rw else flags_read;
    return linux.mmap(null, len, prot, flags, fd, 0);
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

fn mapFileReadOnlyWindows(path: []const u8) !MappedFile {
    const file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch |e| switch (e) {
        error.FileNotFound => return error.FileNotFound,
        error.AccessDenied => return error.AccessDenied,
        else => return e,
    };
    defer file.close();
    const stat = file.stat() catch return error.FileRead;
    if (stat.kind != .file) return error.NotAFile;
    const size = stat.size;
    if (size == 0) {
        const empty: [0]u8 = .{};
        return .{ .ptr = @alignCast(empty[0..].ptr), .len = 0, .mapping_handle = null };
    }
    const size_lo = @as(win.DWORD, @intCast(size & 0xFFFFFFFF));
    const size_hi = @as(win.DWORD, @intCast(size >> 32));
    const mapping = kernel32.CreateFileMappingW(
        file.handle,
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
        .len = @as(usize, @intCast(size)),
        .mapping_handle = mapping,
    };
}

fn mapFileReadWriteWindows(path: []const u8) !MappedFileWritable {
    const file = std.fs.openFileAbsolute(path, .{ .mode = .read_write }) catch |e| switch (e) {
        error.FileNotFound => return error.FileNotFound,
        error.AccessDenied => return error.AccessDenied,
        else => return e,
    };
    defer file.close();
    const stat = file.stat() catch return error.FileRead;
    if (stat.kind != .file) return error.NotAFile;
    const size = stat.size;
    if (size == 0) {
        var empty: [0]u8 = .{};
        return .{ .ptr = @alignCast(empty[0..].ptr), .len = 0, .mapping_handle = null };
    }
    const size_lo = @as(win.DWORD, @intCast(size & 0xFFFFFFFF));
    const size_hi = @as(win.DWORD, @intCast(size >> 32));
    const mapping = kernel32.CreateFileMappingW(
        file.handle,
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
        .len = @as(usize, @intCast(size)),
        .mapping_handle = mapping,
    };
}

fn windowsUnmap(ptr: [*]align(std.heap.page_size_min) const u8, mapping_handle: *anyopaque) void {
    _ = kernel32.UnmapViewOfFile(@ptrCast(ptr));
    _ = kernel32.CloseHandle(@ptrCast(mapping_handle));
}
