//! ZIP 解析与打包：手动解析 EOCD → Central Directory → Local File Header，解压用 std.compress.flate(.raw)，打包用 compressDeflate（raw deflate）。
//! 供 shu:zlib 与 package 等使用；路径须为绝对路径，pack 返回的 slice 调用方 free。

const std = @import("std");
const gzip_mod = @import("../zlib/gzip.zig");

// -----------------------------------------------------------------------------
// ZIP 格式常量（APPNOTE.TXT）
// -----------------------------------------------------------------------------

const EOCD_SIG: u32 = 0x06054b50;
const CDFH_SIG: u32 = 0x02014b50;
const LFH_SIG: u32 = 0x04034b50;

const EOCD_MIN_SIZE: usize = 22; // 不含 signature、comment
const CDFH_FIXED: usize = 46;
const LFH_FIXED: usize = 30;

const COMPRESSION_STORED: u16 = 0;
const COMPRESSION_DEFLATE: u16 = 8;

const MAX_COMMENT_LEN: usize = 65535;

// -----------------------------------------------------------------------------
// 解压：从 zip 字节解析并解包到目录
// -----------------------------------------------------------------------------

/// 将 ZIP 格式字节解包到指定目录。zip_bytes 为完整 zip；dest_dir_path 须为绝对路径。
/// 仅支持 Stored(0) 与 Deflate(8)；拒绝路径含 ".." 的条目。
pub fn extractZipToDir(allocator: std.mem.Allocator, zip_bytes: []const u8, dest_dir_path: []const u8) !void {
    _ = allocator;
    if (zip_bytes.len < EOCD_MIN_SIZE + 4) return error.ZipTooShort;

    const eocd_offset = findEocd(zip_bytes) orelse return error.ZipNoEocd;
    const eocd = parseEocd(zip_bytes, eocd_offset) orelse return error.ZipInvalidEocd;

    if (eocd.cd_offset + eocd.cd_size > zip_bytes.len) return error.ZipInvalidCDFooter;

    var dir = std.fs.openDirAbsolute(dest_dir_path, .{}) catch return error.ZipExtractOpenDirFailed;
    defer dir.close();

    var cd_pos: usize = eocd.cd_offset;

    var i: u16 = 0;
    while (i < eocd.total_entries) : (i += 1) {
        if (cd_pos + 4 > zip_bytes.len) return error.ZipUnexpectedEnd;
        const sig = std.mem.readInt(u32, zip_bytes[cd_pos..][0..4], .little);
        if (sig != CDFH_SIG) return error.ZipBadCDFH;
        if (cd_pos + CDFH_FIXED > zip_bytes.len) return error.ZipUnexpectedEnd;

        const name_len: usize = std.mem.readInt(u16, zip_bytes[cd_pos + 28 ..][0..2], .little);
        const extra_len: usize = std.mem.readInt(u16, zip_bytes[cd_pos + 30 ..][0..2], .little);
        const comment_len: usize = std.mem.readInt(u16, zip_bytes[cd_pos + 32 ..][0..2], .little);
        const comp_size = std.mem.readInt(u32, zip_bytes[cd_pos + 20 ..][0..4], .little);
        _ = std.mem.readInt(u32, zip_bytes[cd_pos + 24 ..][0..4], .little); // uncomp_size，解压时由 flate 自然结束
        const compression = std.mem.readInt(u16, zip_bytes[cd_pos + 10 ..][0..2], .little);
        const lfh_offset = std.mem.readInt(u32, zip_bytes[cd_pos + 42 ..][0..4], .little);

        const name_start = cd_pos + CDFH_FIXED;
        if (name_start + name_len + extra_len + comment_len > zip_bytes.len) return error.ZipUnexpectedEnd;

        const name_slice = zip_bytes[name_start..][0..name_len];
        cd_pos = name_start + name_len + extra_len + comment_len;

        // 安全：拒绝 ".." 与绝对路径
        if (std.mem.indexOf(u8, name_slice, "..") != null) continue;
        const name_str = trimSlash(name_slice);
        if (name_str.len == 0) continue;

        const data_start = try skipLfh(zip_bytes, lfh_offset);
        if (data_start + comp_size > zip_bytes.len) return error.ZipInvalidEntryData;

        const payload = zip_bytes[data_start..][0..comp_size];

        if (name_str[name_str.len - 1] == '/') {
            try dir.makePath(name_str[0 .. name_str.len - 1]);
            continue;
        }

        if (std.fs.path.dirname(name_str)) |parent| {
            if (parent.len > 0) try dir.makePath(parent);
        }
        const file = dir.createFile(name_str, .{}) catch return error.ZipExtractCreateFileFailed;
        defer file.close();

        if (compression == COMPRESSION_STORED) {
            try file.writeAll(payload);
        } else if (compression == COMPRESSION_DEFLATE) {
            try decompressDeflateToFile(file, payload);
        } else {
            return error.ZipUnsupportedCompression;
        }
    }
}

/// 从文件末尾向前查找 EOCD 签名，返回签名所在偏移（不含 comment 影响时的合理搜索范围）。
fn findEocd(data: []const u8) ?usize {
    const search_start = if (data.len > MAX_COMMENT_LEN + EOCD_MIN_SIZE + 4)
        data.len - (MAX_COMMENT_LEN + EOCD_MIN_SIZE + 4)
    else
        0;
    var i: usize = data.len;
    while (i >= search_start + 4) {
        i -= 1;
        if (i < 3) break;
        const sig = std.mem.readInt(u32, data[i - 3 ..][0..4], .little);
        if (sig == EOCD_SIG) return i - 3;
    }
    return null;
}

const EocdParsed = struct {
    total_entries: u16,
    cd_size: u32,
    cd_offset: u32,
};

fn parseEocd(data: []const u8, offset: usize) ?EocdParsed {
    if (offset + 4 + EOCD_MIN_SIZE > data.len) return null;
    const p = offset + 4;
    return .{
        .total_entries = std.mem.readInt(u16, data[p + 8 ..][0..2], .little),
        .cd_size = std.mem.readInt(u32, data[p + 12 ..][0..4], .little),
        .cd_offset = std.mem.readInt(u32, data[p + 16 ..][0..4], .little),
    };
}

/// 跳过 LFH（30 + name_len + extra_len），返回压缩数据起始偏移。
fn skipLfh(data: []const u8, lfh_offset: usize) !usize {
    if (lfh_offset + LFH_FIXED > data.len) return error.ZipInvalidLFH;
    const sig = std.mem.readInt(u32, data[lfh_offset..][0..4], .little);
    if (sig != LFH_SIG) return error.ZipBadLFH;
    const name_len = std.mem.readInt(u16, data[lfh_offset + 26 ..][0..2], .little);
    const extra_len = std.mem.readInt(u16, data[lfh_offset + 28 ..][0..2], .little);
    const data_start = lfh_offset + LFH_FIXED + name_len + extra_len;
    if (data_start > data.len) return error.ZipInvalidLFH;
    return data_start;
}

fn trimSlash(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, "/");
}

/// 将 raw deflate 的 payload 解压并写入 file。
fn decompressDeflateToFile(file: std.fs.File, payload: []const u8) !void {
    var in_reader = std.io.Reader.fixed(payload);
    var dec_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var dec = std.compress.flate.Decompress.init(&in_reader, .raw, &dec_buf);

    var buf: [8192]u8 = undefined;
    while (true) {
        var vec: [1][]u8 = .{buf[0..]};
        const n = std.io.Reader.readVec(&dec.reader, &vec) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        if (n == 0) break;
        try file.writeAll(buf[0..n]);
    }
}

// -----------------------------------------------------------------------------
// 打包：目录 → ZIP 字节（Stored 或 Deflate）
// -----------------------------------------------------------------------------

/// 将指定目录递归打包为 ZIP 格式字节。dir_path 须为绝对路径；返回的切片由调用方 free。
pub fn packZipFromDir(allocator: std.mem.Allocator, dir_path: []const u8) ![]const u8 {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return error.ZipPackOpenDirFailed;
    defer dir.close();

    var out = std.ArrayList(u8).initCapacity(allocator, 64 * 1024) catch return error.OutOfMemory;
    defer out.deinit(allocator);

    var cd_entries = std.ArrayList(u8).initCapacity(allocator, 32 * 1024) catch return error.OutOfMemory;
    defer cd_entries.deinit(allocator);

    var total_entries: u16 = 0;

    try packDirRecursive(allocator, &dir, &out, &cd_entries, "", &total_entries);

    const cd_start = out.items.len;
    try out.appendSlice(allocator, cd_entries.items);
    const cd_size: u32 = @intCast(cd_entries.items.len);

    try writeEocd(allocator, &out, total_entries, cd_size, @intCast(cd_start));

    return out.toOwnedSlice(allocator);
}

fn packDirRecursive(
    allocator: std.mem.Allocator,
    dir: *std.fs.Dir,
    out: *std.ArrayList(u8),
    cd_entries: *std.ArrayList(u8),
    prefix: []const u8,
    total_entries: *u16,
) !void {
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const name = entry.name;
        const arc_name = if (prefix.len == 0) name else try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name });
        defer if (prefix.len > 0) allocator.free(arc_name);

        switch (entry.kind) {
            .directory => {
                const dir_name = try std.fmt.allocPrint(allocator, "{s}/", .{arc_name});
                defer allocator.free(dir_name);
                try writeLfhStored(allocator, out, dir_name, &.{});
                const lfh_offset: u32 = @intCast(out.items.len - (LFH_FIXED + dir_name.len));
                try writeCdfh(allocator, cd_entries, dir_name, 0, 0, 0, 0, lfh_offset);
                total_entries.* += 1;

                var sub = dir.openDir(name, .{ .iterate = true }) catch continue;
                defer sub.close();
                try packDirRecursive(allocator, &sub, out, cd_entries, arc_name, total_entries);
            },
            .file => {
                const content = dir.readFileAlloc(allocator, name, 64 * 1024 * 1024) catch continue;
                defer allocator.free(content);

                const compressed = gzip_mod.compressDeflate(allocator, content) catch content;
                const use_deflate = compressed.ptr != content.ptr;
                defer if (use_deflate) allocator.free(compressed);

                const payload: []const u8 = if (use_deflate) compressed else content;
                const comp_size: u32 = @intCast(payload.len);
                const uncomp_size: u32 = @intCast(content.len);
                const crc = std.hash.Crc32.hash(content);

                try writeLfh(allocator, out, arc_name, if (use_deflate) COMPRESSION_DEFLATE else COMPRESSION_STORED, comp_size, uncomp_size, crc, payload);
                const lfh_offset: u32 = @intCast(out.items.len - (LFH_FIXED + arc_name.len + payload.len));
                try writeCdfh(allocator, cd_entries, arc_name, if (use_deflate) COMPRESSION_DEFLATE else COMPRESSION_STORED, comp_size, uncomp_size, crc, lfh_offset);
                total_entries.* += 1;
            },
            else => {},
        }
    }
}

fn writeEocd(allocator: std.mem.Allocator, out: *std.ArrayList(u8), total_entries: u16, cd_size: u32, cd_offset: u32) !void {
    _ = allocator;
    var buf: [4 + EOCD_MIN_SIZE]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], EOCD_SIG, .little);
    std.mem.writeInt(u16, buf[4..6], 0, .little);
    std.mem.writeInt(u16, buf[6..8], 0, .little);
    std.mem.writeInt(u16, buf[8..10], total_entries, .little);
    std.mem.writeInt(u16, buf[10..12], total_entries, .little);
    std.mem.writeInt(u32, buf[12..16], cd_size, .little);
    std.mem.writeInt(u32, buf[16..20], cd_offset, .little);
    std.mem.writeInt(u16, buf[20..22], 0, .little);
    try out.appendSlice(buf[0..]);
}

fn writeLfh(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, compression: u16, comp_size: u32, uncomp_size: u32, crc: u32, payload: []const u8) !void {
    try writeLfhStored(allocator, out, name, payload);
    // 覆盖 LFH 中：compression(8)、crc(14)、comp_size(18)、uncomp_size(22)
    const base = out.items.len - (LFH_FIXED + name.len + payload.len);
    std.mem.writeInt(u16, out.items[base + 8 ..][0..2], compression, .little);
    std.mem.writeInt(u32, out.items[base + 14 ..][0..4], crc, .little);
    std.mem.writeInt(u32, out.items[base + 18 ..][0..4], comp_size, .little);
    std.mem.writeInt(u32, out.items[base + 22 ..][0..4], uncomp_size, .little);
}

fn writeLfhStored(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, payload: []const u8) !void {
    var h: [LFH_FIXED]u8 = undefined;
    @memset(&h, 0);
    std.mem.writeInt(u32, h[0..4], LFH_SIG, .little);
    std.mem.writeInt(u16, h[8..10], COMPRESSION_STORED, .little);
    std.mem.writeInt(u32, h[18..22], @intCast(payload.len), .little);
    std.mem.writeInt(u32, h[22..26], @intCast(payload.len), .little);
    std.mem.writeInt(u16, h[26..28], @intCast(name.len), .little);
    try out.appendSlice(allocator, &h);
    try out.appendSlice(allocator, name);
    try out.appendSlice(allocator, payload);
}

fn writeCdfh(allocator: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, compression: u16, comp_size: u32, uncomp_size: u32, crc: u32, lfh_offset: u32) !void {
    var h: [CDFH_FIXED]u8 = undefined;
    @memset(&h, 0);
    std.mem.writeInt(u32, h[0..4], CDFH_SIG, .little);
    std.mem.writeInt(u16, h[10..12], compression, .little);
    std.mem.writeInt(u32, h[16..20], crc, .little);
    std.mem.writeInt(u32, h[20..24], comp_size, .little);
    std.mem.writeInt(u32, h[24..28], uncomp_size, .little);
    std.mem.writeInt(u16, h[28..30], @intCast(name.len), .little);
    std.mem.writeInt(u32, h[42..46], lfh_offset, .little);
    try out.appendSlice(allocator, &h);
    try out.appendSlice(allocator, name);
}
