// shu:report — 与 node:report API 兼容，纯 Zig 实现
// 所有权：getReport/writeReport 为 JS API，返回值 JSC 持有；stringifyReportObjectToUtf8 [Allocates] 返回切片由调用方 free。
//
// ========== API 兼容情况 ==========
//
// | API | 兼容 | 说明 |
// |-----|------|------|
// | getReport([err]) | ✅ 已实现 | 返回诊断报告对象（Node 风格 JSON 对象） |
// | writeReport([filename][, err]) | ✅ 已实现 | 将报告对象序列化为 JSON 文本写入指定文件或 stdout |
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

/// 返回当前 Unix 时间（秒）；无 process io 时返回 0。
fn nowUnixSeconds() i64 {
    const io = libs_process.getProcessIo() orelse return 0;
    const now = std.Io.Clock.Timestamp.now(io, .real);
    return @as(i64, @intCast(@divTrunc(now.raw.nanoseconds, 1_000_000_000)));
}

/// [Allocates] 将 UTF-8 切片转为 JS 字符串值；失败时返回 undefined。
fn makeJsStringValue(ctx: jsc.JSContextRef, allocator: std.mem.Allocator, value: []const u8) jsc.JSValueRef {
    const z = allocator.dupeZ(u8, value) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(z);
    const s = jsc.JSStringCreateWithUTF8CString(z.ptr);
    defer jsc.JSStringRelease(s);
    return jsc.JSValueMakeString(ctx, s);
}

/// 在对象上设置字符串属性；value 为 UTF-8。
fn setStringProperty(ctx: jsc.JSContextRef, allocator: std.mem.Allocator, obj: jsc.JSObjectRef, key: [*:0]const u8, value: []const u8) void {
    const k = jsc.JSStringCreateWithUTF8CString(key);
    defer jsc.JSStringRelease(k);
    _ = jsc.JSObjectSetProperty(ctx, obj, k, makeJsStringValue(ctx, allocator, value), jsc.kJSPropertyAttributeNone, null);
}

/// 在对象上设置数值属性。
fn setNumberProperty(ctx: jsc.JSContextRef, obj: jsc.JSObjectRef, key: [*:0]const u8, value: f64) void {
    const k = jsc.JSStringCreateWithUTF8CString(key);
    defer jsc.JSStringRelease(k);
    _ = jsc.JSObjectSetProperty(ctx, obj, k, jsc.JSValueMakeNumber(ctx, value), jsc.kJSPropertyAttributeNone, null);
}

/// 在对象上设置布尔属性。
fn setBooleanProperty(ctx: jsc.JSContextRef, obj: jsc.JSObjectRef, key: [*:0]const u8, value: bool) void {
    const k = jsc.JSStringCreateWithUTF8CString(key);
    defer jsc.JSStringRelease(k);
    _ = jsc.JSObjectSetProperty(ctx, obj, k, jsc.JSValueMakeBoolean(ctx, value), jsc.kJSPropertyAttributeNone, null);
}

/// 在对象上设置对象属性。
fn setObjectProperty(ctx: jsc.JSContextRef, obj: jsc.JSObjectRef, key: [*:0]const u8, value: jsc.JSObjectRef) void {
    const k = jsc.JSStringCreateWithUTF8CString(key);
    defer jsc.JSStringRelease(k);
    _ = jsc.JSObjectSetProperty(ctx, obj, k, @ptrCast(value), jsc.kJSPropertyAttributeNone, null);
}

/// 构建 Node 风格诊断报告对象（可被 JSON.stringify 直接序列化）。
fn buildReportObject(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSObjectRef {
    const report_obj = jsc.JSObjectMake(ctx, null, null);
    const header_obj = jsc.JSObjectMake(ctx, null, null);
    const permissions_obj = jsc.JSObjectMake(ctx, null, null);
    const js_stack_obj = jsc.JSObjectMake(ctx, null, null);
    const env_obj = jsc.JSObjectMake(ctx, null, null);
    const empty_arr = jsc.JSObjectMakeArray(ctx, 0, undefined, null);

    setNumberProperty(ctx, header_obj, "reportVersion", 1);
    setStringProperty(ctx, allocator, header_obj, "event", "JavaScript API");
    setStringProperty(ctx, allocator, header_obj, "trigger", "GetReport");
    setNumberProperty(ctx, header_obj, "dumpEventTime", @floatFromInt(nowUnixSeconds()));

    if (globals.current_run_options) |opts| {
        // 诊断报告路径统一输出为「相对当前项目」：
        // - cwd 固定为 "."，避免泄露绝对路径
        // - entryPoint 尝试转为相对 cwd 的路径，失败时退回原值
        setStringProperty(ctx, allocator, header_obj, "cwd", ".");

        const entry_rel = std.fs.path.relative(allocator, "", null, opts.cwd, opts.entry_path) catch opts.entry_path;
        defer if (entry_rel.ptr != opts.entry_path.ptr) allocator.free(entry_rel);
        setStringProperty(ctx, allocator, header_obj, "entryPoint", entry_rel);

        setBooleanProperty(ctx, permissions_obj, "allowRead", opts.permissions.allow_read);
        setBooleanProperty(ctx, permissions_obj, "allowWrite", opts.permissions.allow_write);
        setBooleanProperty(ctx, permissions_obj, "allowNet", opts.permissions.allow_net);
        setBooleanProperty(ctx, permissions_obj, "allowEnv", opts.permissions.allow_env);
        setBooleanProperty(ctx, permissions_obj, "allowRun", opts.permissions.allow_run);
        setBooleanProperty(ctx, permissions_obj, "allowHrtime", opts.permissions.allow_hrtime);
        setBooleanProperty(ctx, permissions_obj, "allowFfi", opts.permissions.allow_ffi);
    } else {
        setStringProperty(ctx, allocator, header_obj, "cwd", "");
        setStringProperty(ctx, allocator, header_obj, "entryPoint", "");
    }

    // 当前 runtime 暂未提供完整 JS/native 栈，先输出稳定占位字段，保持对象结构可扩展。
    setStringProperty(ctx, allocator, js_stack_obj, "message", "No JavaScript stack collected in shu runtime yet");
    setObjectProperty(ctx, js_stack_obj, "stack", empty_arr);

    setObjectProperty(ctx, report_obj, "header", header_obj);
    setObjectProperty(ctx, report_obj, "permissions", permissions_obj);
    setObjectProperty(ctx, report_obj, "javascriptStack", js_stack_obj);
    setObjectProperty(ctx, report_obj, "environmentVariables", env_obj);
    return report_obj;
}

/// [Allocates] 将 report 对象序列化为 JSON UTF-8 文本；调用方负责 free。
fn stringifyReportObjectToUtf8(ctx: jsc.JSContextRef, allocator: std.mem.Allocator, report_obj: jsc.JSObjectRef) []const u8 {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_json = jsc.JSStringCreateWithUTF8CString("JSON");
    defer jsc.JSStringRelease(k_json);
    const json_val = jsc.JSObjectGetProperty(ctx, global, k_json, null);
    const json_obj = jsc.JSValueToObject(ctx, json_val, null) orelse return "";

    const k_stringify = jsc.JSStringCreateWithUTF8CString("stringify");
    defer jsc.JSStringRelease(k_stringify);
    const stringify_val = jsc.JSObjectGetProperty(ctx, json_obj, k_stringify, null);
    const stringify_fn = jsc.JSValueToObject(ctx, stringify_val, null) orelse return "";
    if (!jsc.JSObjectIsFunction(ctx, stringify_fn)) return "";

    const indent = jsc.JSValueMakeNumber(ctx, 2);
    var args = [_]jsc.JSValueRef{ @ptrCast(report_obj), jsc.JSValueMakeUndefined(ctx), indent };
    const json_text_val = jsc.JSObjectCallAsFunction(ctx, stringify_fn, json_obj, 3, &args, null);

    const str_ref = jsc.JSValueToStringCopy(ctx, json_text_val, null);
    defer jsc.JSStringRelease(str_ref);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(str_ref);
    if (max_sz == 0) return "";

    const buf = allocator.alloc(u8, max_sz) catch return "";
    const n = jsc.JSStringGetUTF8CString(str_ref, buf.ptr, max_sz);
    if (n == 0) {
        allocator.free(buf);
        return "";
    }
    return buf[0 .. n - 1];
}

/// getReport([err])：返回报告对象（Node 风格）；err 参数当前未用于定制堆栈。
fn getReportCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const report_obj = buildReportObject(ctx, allocator);
    return @ptrCast(report_obj);
}

/// writeReport([filename][, err])：无 filename 时写 stdout，否则写文件；输出为 JSON 文本；大文本（≥REPORT_MAP_THRESHOLD）走 mmap 零拷贝。
fn writeReportCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const report_obj = buildReportObject(ctx, allocator);
    const report = stringifyReportObjectToUtf8(ctx, allocator, report_obj);
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
