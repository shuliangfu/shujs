//! Tar 打包与解包：使用 std.tar（Writer / pipeToFileSystem）
//! 供 package、cli pack 等复用；路径须为绝对路径或通过 io_core 解析后再传入。
//! TODO: migrate to libs_io (rule §3.0) when libs_io exposes dir iteration + tar writer; current I/O via std.fs.

const std = @import("std");

/// [Allocates] 将指定目录递归打包为 tar 格式字节；调用方须用同一 allocator free 返回值。
/// dir_path 须为绝对路径；返回的切片由调用方 free。
pub fn packTarFromDir(allocator: std.mem.Allocator, dir_path: []const u8) ![]const u8 {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return error.TarOpenDirFailed;
    defer dir.close();

    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    var tar_writer: std.tar.Writer = .{ .underlying_writer = &output.writer };

    try packDirRecursive(allocator, &dir, &tar_writer, "");
    try tar_writer.finishPedantically();

    const written = output.written();
    return allocator.dupe(u8, written);
}

/// 递归将目录项写入 tar；base 为当前在 tar 内的相对路径前缀（可为空）。
fn packDirRecursive(allocator: std.mem.Allocator, dir: *std.fs.Dir, w: *std.tar.Writer, base: []const u8) !void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const name = entry.name;
        const sub_path = if (base.len == 0) name else try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, name });
        defer if (base.len > 0) allocator.free(sub_path);

        switch (entry.kind) {
            .directory => {
                try w.writeDir(sub_path, .{});
                var sub_dir = dir.openDir(name, .{ .iterate = true }) catch continue;
                defer sub_dir.close();
                try packDirRecursive(allocator, &sub_dir, w, sub_path);
            },
            .file => {
                const file = dir.openFile(name, .{}) catch continue;
                defer file.close();
                const size = file.getEndPos() catch continue;
                var file_reader = file.reader(undefined);
                try w.writeFileStream(sub_path, size, &file_reader.interface, .{});
            },
            .sym_link => {
                const link = std.fs.readLinkAbsoluteC(dir.fd, name, &([_]u8{undefined} ** (std.fs.max_path_bytes))) catch continue;
                try w.writeLink(sub_path, link, .{});
            },
            else => {},
        }
    }
}

/// 将 tar 格式字节解包到指定目录。
/// tar_bytes 为完整 tar 归档；dest_dir_path 须为绝对路径，目录须已存在或可由父级创建。
pub fn extractTarToDir(allocator: std.mem.Allocator, tar_bytes: []const u8, dest_dir_path: []const u8) !void {
    _ = allocator;
    var dir = std.fs.openDirAbsolute(dest_dir_path, .{}) catch return error.TarExtractOpenFailed;
    defer dir.close();

    var reader = std.Io.Reader.fixed(tar_bytes);
    try std.tar.pipeToFileSystem(dir, &reader, .{});
}
