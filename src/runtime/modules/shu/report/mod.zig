// shu:report — 与 node:report API 兼容，纯 Zig 实现
//
// ========== API 兼容情况 ==========
//
// | API | 兼容 | 说明 |
// |-----|------|------|
// | getReport([err]) | ✅ 已实现 | 返回诊断报告字符串（头部、进程信息、无真实堆栈时占位） |
// | writeReport([filename][, err]) | ✅ 已实现 | 将 getReport 写入指定文件或 stdout；无 filename 时写 stdout |
//

const std = @import("std");
const jsc = @import("jsc");
const libs_io = @import("libs_io");
const errors = @import("errors");
const libs_process = @import("libs_process");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");

/// 超过此长度写文件时用 libs_io.mapFileReadWrite，减少大报告时的多次 write 与拷贝
const REPORT_MAP_THRESHOLD = 64 * 1024;

/// 生成简单诊断报告字符串（不含真实堆栈；与 Node report 格式近似）；返回的切片由调用方 free。Zig 0.16：用 bufPrint + appendSlice 替代 writer.print。
fn buildReportString(allocator: std.mem.Allocator) []const u8 {
    var list = std.ArrayList(u8).initCapacity(allocator, 2048) catch return "";
    var buf: [512]u8 = undefined;
    list.appendSlice(allocator, "--- Shu diagnostic report ---\n") catch return "";
    const t: i64 = if (libs_process.getProcessIo()) |io| blk: {
        const now = std.Io.Clock.Timestamp.now(io, .real);
        break :blk @as(i64, @intCast(@divTrunc(now.raw.nanoseconds, 1_000_000_000)));
    } else 0;
    const s1 = std.fmt.bufPrint(&buf, "Time: {d}\n", .{t}) catch return "";
    list.appendSlice(allocator, s1) catch return "";
    if (globals.current_run_options) |opts| {
        const s2 = std.fmt.bufPrint(&buf, "Entry: {s}\nCwd: {s}\n", .{ opts.entry_path, opts.cwd }) catch return "";
        list.appendSlice(allocator, s2) catch return "";
        const s3 = std.fmt.bufPrint(&buf, "Permissions: read={} write={} net={} env={} run={} hrtime={} ffi={}\n", .{
            opts.permissions.allow_read,
            opts.permissions.allow_write,
            opts.permissions.allow_net,
            opts.permissions.allow_env,
            opts.permissions.allow_run,
            opts.permissions.allow_hrtime,
            opts.permissions.allow_ffi,
        }) catch return "";
        list.appendSlice(allocator, s3) catch return "";
    } else {
        list.appendSlice(allocator, "(no run context)\n") catch return "";
    }
    list.appendSlice(allocator, "--- End report ---\n") catch return "";
    return list.toOwnedSlice(allocator) catch "";
}

/// getReport([err])：返回报告字符串；err 暂未用于定制堆栈
fn getReportCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const report = buildReportString(allocator);
    defer if (report.len > 0) allocator.free(report);
    if (report.len == 0) return jsc.JSValueMakeUndefined(ctx);
    const z = allocator.dupeZ(u8, report) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(z);
    const str_ref = jsc.JSStringCreateWithUTF8CString(z.ptr);
    defer jsc.JSStringRelease(str_ref);
    return jsc.JSValueMakeString(ctx, str_ref);
}

/// writeReport([filename][, err])：无 filename 时写 stdout，否则写文件；大报告（≥REPORT_MAP_THRESHOLD）走 libs_io.mapFileReadWrite 零拷贝
fn writeReportCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const report = buildReportString(allocator);
    defer if (report.len > 0) allocator.free(report);
    if (report.len == 0) return jsc.JSValueMakeUndefined(ctx);
    if (argumentCount >= 1 and !jsc.JSValueIsUndefined(ctx, arguments[0])) {
        var path_buf: [1024]u8 = undefined;
        const str_ref = jsc.JSValueToStringCopy(ctx, arguments[0], null);
        defer jsc.JSStringRelease(str_ref);
        const n = jsc.JSStringGetUTF8CString(str_ref, &path_buf, path_buf.len);
        if (n > 0) {
            const path = path_buf[0 .. n - 1];
            const resolved = if (globals.current_run_options) |opts|
                std.fs.path.resolve(allocator, &.{ opts.cwd, path }) catch path
            else
                path;
            defer if (resolved.ptr != path.ptr) allocator.free(resolved);
            const io = libs_process.getProcessIo() orelse return jsc.JSValueMakeUndefined(ctx);
            if (report.len >= REPORT_MAP_THRESHOLD) {
                var file = libs_io.createFileAbsolute(resolved, .{}) catch return jsc.JSValueMakeUndefined(ctx);
                defer file.close(io);
                const zero: [1]u8 = .{0};
                file.writePositionalAll(io, zero[0..], report.len - 1) catch return jsc.JSValueMakeUndefined(ctx);
                var mapped = libs_io.mapFileReadWrite(resolved) catch {
                    var fallback = libs_io.createFileAbsolute(resolved, .{}) catch return jsc.JSValueMakeUndefined(ctx);
                    defer fallback.close(io);
                    fallback.writeStreamingAll(io, report) catch return jsc.JSValueMakeUndefined(ctx);
                    return jsc.JSValueMakeUndefined(ctx);
                };
                defer mapped.deinit();
                @memcpy(mapped.slice()[0..report.len], report);
                return jsc.JSValueMakeUndefined(ctx);
            }
            const file = libs_io.createFileAbsolute(resolved, .{}) catch return jsc.JSValueMakeUndefined(ctx);
            defer file.close(io);
            file.writeStreamingAll(io, report) catch return jsc.JSValueMakeUndefined(ctx);
        }
    } else {
        const stdout_io = libs_process.getProcessIo() orelse return jsc.JSValueMakeUndefined(ctx);
        std.Io.File.stdout().writeStreamingAll(stdout_io, report) catch return jsc.JSValueMakeUndefined(ctx);
    }
    return jsc.JSValueMakeUndefined(ctx);
}

pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    _ = allocator;
    const exports = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, exports, "getReport", getReportCallback);
    common.setMethod(ctx, exports, "writeReport", writeReportCallback);
    return exports;
}
