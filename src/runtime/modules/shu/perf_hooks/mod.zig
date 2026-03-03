// shu:perf_hooks — 性能测量，对应 node:perf_hooks
//
// ========== 已实现的 API（与 Node 兼容） ==========
//
// 【模块导出】require('shu:perf_hooks') 得到：
//   - performance      (见下)
//   - PerformanceObserver (构造函数)
//   - timerify        (函数)
//   - eventLoopUtilization (函数，见“占位”说明)
//   - monitorEventLoopDelay (函数，见“占位”说明)
//
// 【performance 对象】
//   - performance.now()                   高精度毫秒，单调递增（std.time.nanoTimestamp）
//   - performance.timeOrigin             只读数字，首次初始化时的时间起点
//   - performance.mark(name)             记录一条 mark，并异步通知 PerformanceObserver
//   - performance.measure(name [, startMark] [, endMark])  计算时长并记录 measure
//   - performance.clearMarks([name])     清除全部或指定 name 的 marks
//   - performance.clearMeasures([name])  清除全部或指定 name 的 measures
//   - performance.getEntries()           返回当前所有 mark/measure 条目
//   - performance.getEntriesByName(name [, type])  按 name（及可选 type）过滤
//   - performance.getEntriesByType(type) 按 type（'mark' | 'measure' | 'function'）过滤
//   - performance.nodeTiming  (nodeStart、bootstrapComplete、v8Start 等，与 Node 兼容字段，未实现项为 0/-1)
//   条目形状：{ name, entryType, startTime, duration, detail }；mark/measure 支持 options.detail。
//
// 【PerformanceObserver】
//   - new PerformanceObserver(callback)   callback(list, observer)，list 含 getEntries/getEntriesByName/getEntriesByType
//   - observe({ type }) 或 observe({ entryTypes: [...] })  支持 'mark'、'measure'、'function'
//   - observe({ entryTypes, buffered: true })  先交付当前已有该类型的条目，再注册后续推送
//   - disconnect()   取消注册
//   - takeRecords()  返回 []（不缓冲历史记录）
//   通知通过 __shuPerfNotify + setImmediate 异步触发，与 Node 行为一致。
//
// 【timerify】
//   - timerify(fn)   包装函数，调用前后用 performance.now() 记录，产生 entryType 为 'function' 的条目并通知 observer。
//
// 【NODE_PERFORMANCE_* 常量】
//   - 已导出：NODE_PERFORMANCE_GC_MAJOR/MINOR/INCREMENTAL/WEAKCB、NODE_PERFORMANCE_GC_FLAGS_* 等。
//
// ========== 占位 / 未完整实现的 API ==========
//
// 【eventLoopUtilization([el, perf])】
//   - 已导出为函数，调用返回 { idle: 0, active: 0, utilization: 0 }。
//   - 未实现原因：Node 依赖 libuv 的 uv_metrics_idle_time 等，本运行时无 libuv，无事件循环利用率数据。
//
// 【monitorEventLoopDelay([options])】
//   - 已导出为函数，返回带 enable()、disable()、min、max、mean、stddev、percentiles、percentile(n) 的对象，数值均为 0。
//   - 未实现原因：Node 依赖事件循环延迟直方图采样（libuv），本运行时无该能力。
//
// ========== 未实现的 Node 专有 API（及原因） ==========
//
//   - PerformanceObserver 对 entryTypes: ['http'] / ['net'] / ['dns'] 的观测
//     原因：本实现仅在 Zig 层产生 'mark'、'measure'、'function'；http/net/dns 由 Node 各模块注入，未对接。

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");

/// 条目类型：mark、measure、function（timerify 产生）
const PerfEntryType = enum { mark, measure, function };
/// 单条性能条目：mark、measure 或 function；detail_owned 为 options.detail 序列化后的字符串（本模块持有，移除时需 free）
const PerfEntry = struct {
    name: []const u8,
    entry_type: PerfEntryType,
    start_time: f64,
    duration: f64,
    detail_owned: ?[]const u8 = null,
};

/// 全局性能存储（线程局部）；优先使用 run 级 current_allocator，未设置时回退 page_allocator（§1.1 显式 allocator 收敛）
var g_perf_alloc: std.mem.Allocator = undefined;
var g_time_origin: f64 = 0;
var g_marks: std.StringHashMap(f64) = undefined;
var g_entries: std.ArrayList(PerfEntry) = undefined;
var g_perf_init: bool = false;

/// 性能条目列表初始容量，减少 mark/measure 频繁时的扩容（§1.3）
const PERF_ENTRIES_INIT_CAP = 64;

/// 由 run/require 显式注入 allocator，与 run 级一致；未调用前 ensurePerfStore 使用 current_allocator 或 page_allocator（§1.1）
pub fn initPerfStore(allocator: std.mem.Allocator) void {
    if (g_perf_init) return;
    g_perf_alloc = allocator;
    const ns = std.time.nanoTimestamp();
    g_time_origin = @as(f64, @floatFromInt(ns)) / 1_000_000.0;
    g_marks = std.StringHashMap(f64).init(g_perf_alloc);
    g_entries = std.ArrayList(PerfEntry).initCapacity(g_perf_alloc, PERF_ENTRIES_INIT_CAP) catch unreachable;
    g_perf_init = true;
}

fn ensurePerfStore() void {
    if (g_perf_init) return;
    g_perf_alloc = globals.current_allocator orelse std.heap.page_allocator;
    const ns = std.time.nanoTimestamp();
    g_time_origin = @as(f64, @floatFromInt(ns)) / 1_000_000.0;
    g_marks = std.StringHashMap(f64).init(g_perf_alloc);
    g_entries = std.ArrayList(PerfEntry).initCapacity(g_perf_alloc, PERF_ENTRIES_INIT_CAP) catch unreachable;
    g_perf_init = true;
}

/// 将当前时间以毫秒返回（高精度，单调）
fn nowMs() f64 {
    const ns = std.time.nanoTimestamp();
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

/// 从 JS 的 options 对象读取 detail 并序列化为字符串（JSON.stringify 或 String），调用方负责 free 返回的 slice
fn jsOptionsDetailToString(ctx: jsc.JSContextRef, options_val: jsc.JSValueRef) ?[]const u8 {
    if (jsc.JSValueIsUndefined(ctx, options_val) or jsc.JSValueIsNull(ctx, options_val)) return null;
    const obj = jsc.JSValueToObject(ctx, options_val, null) orelse return null;
    const k_detail = jsc.JSStringCreateWithUTF8CString("detail");
    defer jsc.JSStringRelease(k_detail);
    const detail_val = jsc.JSObjectGetProperty(ctx, obj, k_detail, null);
    if (jsc.JSValueIsUndefined(ctx, detail_val)) return null;
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_JSON = jsc.JSStringCreateWithUTF8CString("JSON");
    defer jsc.JSStringRelease(k_JSON);
    const json_val = jsc.JSObjectGetProperty(ctx, global, k_JSON, null);
    const json_obj = jsc.JSValueToObject(ctx, json_val, null) orelse return null;
    const k_stringify = jsc.JSStringCreateWithUTF8CString("stringify");
    defer jsc.JSStringRelease(k_stringify);
    const stringify_val = jsc.JSObjectGetProperty(ctx, json_obj, k_stringify, null);
    const stringify_fn = jsc.JSValueToObject(ctx, stringify_val, null) orelse return null;
    var one: [1]jsc.JSValueRef = .{detail_val};
    const result = jsc.JSObjectCallAsFunction(ctx, stringify_fn, null, 1, &one, null);
    if (jsc.JSValueIsUndefined(ctx, result)) return null;
    const str_ref = jsc.JSValueToStringCopy(ctx, result, null);
    defer jsc.JSStringRelease(str_ref);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(str_ref);
    if (max_sz == 0 or max_sz > 65536) return null;
    const buf = g_perf_alloc.alloc(u8, max_sz) catch return null;
    defer g_perf_alloc.free(buf);
    const n = jsc.JSStringGetUTF8CString(str_ref, buf.ptr, max_sz);
    if (n == 0) return null;
    return g_perf_alloc.dupe(u8, buf[0 .. n - 1]) catch null;
}

/// 释放一条 PerfEntry 占用的 name 与 detail_owned
fn freePerfEntry(entry: PerfEntry) void {
    g_perf_alloc.free(entry.name);
    if (entry.detail_owned) |d| g_perf_alloc.free(d);
}

/// performance.timerify(fn) 返回的包装函数被调用时执行：记录 start，调用原函数，记录 end，推送 entryType 'function' 并通知 observer
fn performanceTimerifyWrapperCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    callee: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const k_fn = jsc.JSStringCreateWithUTF8CString("__shuTimerifyFn");
    defer jsc.JSStringRelease(k_fn);
    const fn_val = jsc.JSObjectGetProperty(ctx, callee, k_fn, null);
    if (jsc.JSValueIsUndefined(ctx, fn_val)) return jsc.JSValueMakeUndefined(ctx);
    const fn_obj = jsc.JSValueToObject(ctx, fn_val, exception) orelse return jsc.JSValueMakeUndefined(ctx);
    ensurePerfStore();
    const start_time = nowMs();
    const result = jsc.JSObjectCallAsFunction(ctx, fn_obj, thisObject, argumentCount, arguments, exception);
    const end_time = nowMs();
    const duration = end_time - start_time;
    var name_buf: [256]u8 = undefined;
    name_buf[0] = 'f';
    name_buf[1] = 'u';
    name_buf[2] = 'n';
    name_buf[3] = 'c';
    name_buf[4] = 't';
    name_buf[5] = 'i';
    name_buf[6] = 'o';
    name_buf[7] = 'n';
    var name_len: usize = 8;
    const k_name = jsc.JSStringCreateWithUTF8CString("name");
    defer jsc.JSStringRelease(k_name);
    const name_val = jsc.JSObjectGetProperty(ctx, fn_obj, k_name, null);
    if (!jsc.JSValueIsUndefined(ctx, name_val)) {
        const name_str = jsc.JSValueToStringCopy(ctx, name_val, null);
        defer jsc.JSStringRelease(name_str);
        const n = jsc.JSStringGetUTF8CString(name_str, &name_buf, name_buf.len);
        if (n > 1) name_len = n - 1;
    }
    const name = g_perf_alloc.dupe(u8, name_buf[0..name_len]) catch return result;
    const entry = PerfEntry{ .name = name, .entry_type = .function, .start_time = start_time, .duration = duration, .detail_owned = null };
    g_entries.append(g_perf_alloc, entry) catch {
        g_perf_alloc.free(name);
        return result;
    };
    notifyObservers(ctx, &.{entry});
    return result;
}

/// performance.timerify(fn)：返回包装函数，调用时产生 entryType 'function' 并通知 PerformanceObserver
fn performanceTimerifyCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const k = jsc.JSStringCreateWithUTF8CString("__shuTimerifyFn");
    defer jsc.JSStringRelease(k);
    const wrapper_name = jsc.JSStringCreateWithUTF8CString("timerified");
    defer jsc.JSStringRelease(wrapper_name);
    const wrapper = jsc.JSObjectMakeFunctionWithCallback(ctx, wrapper_name, performanceTimerifyWrapperCallback);
    _ = jsc.JSObjectSetProperty(ctx, wrapper, k, arguments[0], jsc.kJSPropertyAttributeNone, null);
    return wrapper;
}

/// performance.now()
fn performanceNowCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    ensurePerfStore();
    return jsc.JSValueMakeNumber(ctx, nowMs());
}

/// performance.mark(name)
fn performanceMarkCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    ensurePerfStore();
    const name_str = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(name_str);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(name_str);
    if (max_sz == 0 or max_sz > 1024) return jsc.JSValueMakeUndefined(ctx);
    const buf = g_perf_alloc.alloc(u8, max_sz) catch return jsc.JSValueMakeUndefined(ctx);
    defer g_perf_alloc.free(buf);
    const n = jsc.JSStringGetUTF8CString(name_str, buf.ptr, max_sz);
    if (n == 0) return jsc.JSValueMakeUndefined(ctx);
    const name = g_perf_alloc.dupe(u8, buf[0 .. n - 1]) catch return jsc.JSValueMakeUndefined(ctx);
    var detail_owned: ?[]const u8 = null;
    if (argumentCount >= 2) {
        detail_owned = jsOptionsDetailToString(ctx, arguments[1]);
    }
    const t = nowMs();
    g_marks.put(name, t) catch {};
    const entry = PerfEntry{ .name = name, .entry_type = .mark, .start_time = t, .duration = 0, .detail_owned = detail_owned };
    g_entries.append(g_perf_alloc, entry) catch {
        freePerfEntry(entry);
        return jsc.JSValueMakeUndefined(ctx);
    };
    notifyObservers(ctx, &.{entry});
    return jsc.JSValueMakeUndefined(ctx);
}

/// performance.measure(name [, startMark] [, endMark] [, options])
fn performanceMeasureCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    ensurePerfStore();
    const name_str = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(name_str);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(name_str);
    if (max_sz == 0 or max_sz > 1024) return jsc.JSValueMakeUndefined(ctx);
    const buf = g_perf_alloc.alloc(u8, max_sz) catch return jsc.JSValueMakeUndefined(ctx);
    defer g_perf_alloc.free(buf);
    const n = jsc.JSStringGetUTF8CString(name_str, buf.ptr, max_sz);
    if (n == 0) return jsc.JSValueMakeUndefined(ctx);
    const name = g_perf_alloc.dupe(u8, buf[0 .. n - 1]) catch return jsc.JSValueMakeUndefined(ctx);
    const now = nowMs();
    var start_time: f64 = 0;
    var end_time: f64 = now;
    var start_buf: [1024]u8 = undefined;
    var end_buf: [1024]u8 = undefined;
    if (argumentCount >= 2) {
        const start_ref = jsc.JSValueToStringCopy(ctx, arguments[1], null);
        defer jsc.JSStringRelease(start_ref);
        const sz = jsc.JSStringGetMaximumUTF8CStringSize(start_ref);
        if (sz > 0 and sz <= start_buf.len) {
            const nn = jsc.JSStringGetUTF8CString(start_ref, &start_buf, start_buf.len);
            if (nn > 0) {
                const start_key = g_perf_alloc.dupe(u8, start_buf[0 .. nn - 1]) catch null;
                if (start_key) |k| {
                    defer g_perf_alloc.free(k);
                    start_time = g_marks.get(k) orelse 0;
                }
            }
        }
    }
    if (argumentCount >= 3) {
        const end_ref = jsc.JSValueToStringCopy(ctx, arguments[2], null);
        defer jsc.JSStringRelease(end_ref);
        const sz = jsc.JSStringGetMaximumUTF8CStringSize(end_ref);
        if (sz > 0 and sz <= end_buf.len) {
            const nn = jsc.JSStringGetUTF8CString(end_ref, &end_buf, end_buf.len);
            if (nn > 0) {
                const end_key = g_perf_alloc.dupe(u8, end_buf[0 .. nn - 1]) catch null;
                if (end_key) |k| {
                    defer g_perf_alloc.free(k);
                    end_time = g_marks.get(k) orelse now;
                }
            }
        }
    }
    var detail_owned: ?[]const u8 = null;
    if (argumentCount >= 4) {
        detail_owned = jsOptionsDetailToString(ctx, arguments[3]);
    }
    const duration = end_time - start_time;
    const entry = PerfEntry{ .name = name, .entry_type = .measure, .start_time = start_time, .duration = duration, .detail_owned = detail_owned };
    g_entries.append(g_perf_alloc, entry) catch {
        freePerfEntry(entry);
        return jsc.JSValueMakeUndefined(ctx);
    };
    notifyObservers(ctx, &.{entry});
    return jsc.JSValueMakeUndefined(ctx);
}

/// performance.clearMarks([name])
fn performanceClearMarksCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    ensurePerfStore();
    if (argumentCount == 0 or jsc.JSValueIsUndefined(ctx, arguments[0])) {
        var i: usize = 0;
        while (i < g_entries.items.len) {
            if (g_entries.items[i].entry_type == .mark) {
                freePerfEntry(g_entries.items[i]);
                _ = g_entries.orderedRemove(i);
            } else i += 1;
        }
        g_marks.clearRetainingCapacity();
        return jsc.JSValueMakeUndefined(ctx);
    }
    const name_str = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(name_str);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(name_str);
    if (max_sz == 0 or max_sz > 1024) return jsc.JSValueMakeUndefined(ctx);
    const buf = g_perf_alloc.alloc(u8, max_sz) catch return jsc.JSValueMakeUndefined(ctx);
    defer g_perf_alloc.free(buf);
    const n = jsc.JSStringGetUTF8CString(name_str, buf.ptr, max_sz);
    if (n == 0) return jsc.JSValueMakeUndefined(ctx);
    const key = g_perf_alloc.dupe(u8, buf[0 .. n - 1]) catch return jsc.JSValueMakeUndefined(ctx);
    defer g_perf_alloc.free(key);
    _ = g_marks.remove(key);
    var i: usize = 0;
    while (i < g_entries.items.len) {
        if (g_entries.items[i].entry_type == .mark and std.mem.eql(u8, g_entries.items[i].name, key)) {
            freePerfEntry(g_entries.items[i]);
            _ = g_entries.orderedRemove(i);
        } else i += 1;
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// performance.clearMeasures([name])
fn performanceClearMeasuresCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    ensurePerfStore();
    if (argumentCount == 0 or jsc.JSValueIsUndefined(ctx, arguments[0])) {
        var i: usize = 0;
        while (i < g_entries.items.len) {
            if (g_entries.items[i].entry_type == .measure) {
                freePerfEntry(g_entries.items[i]);
                _ = g_entries.orderedRemove(i);
            } else i += 1;
        }
        return jsc.JSValueMakeUndefined(ctx);
    }
    const name_str = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(name_str);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(name_str);
    if (max_sz == 0 or max_sz > 1024) return jsc.JSValueMakeUndefined(ctx);
    const buf = g_perf_alloc.alloc(u8, max_sz) catch return jsc.JSValueMakeUndefined(ctx);
    defer g_perf_alloc.free(buf);
    const n = jsc.JSStringGetUTF8CString(name_str, buf.ptr, max_sz);
    if (n == 0) return jsc.JSValueMakeUndefined(ctx);
    const key = g_perf_alloc.dupe(u8, buf[0 .. n - 1]) catch return jsc.JSValueMakeUndefined(ctx);
    defer g_perf_alloc.free(key);
    var i: usize = 0;
    while (i < g_entries.items.len) {
        if (g_entries.items[i].entry_type == .measure and std.mem.eql(u8, g_entries.items[i].name, key)) {
            freePerfEntry(g_entries.items[i]);
            _ = g_entries.orderedRemove(i);
        } else i += 1;
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// 将一条 PerfEntry 转为 JS 对象 { name, entryType, startTime, duration, detail } { name, entryType, startTime, duration, detail: null }；name 可能非 null 结尾，用栈缓冲
fn entryToJS(ctx: jsc.JSContextRef, e: PerfEntry) jsc.JSObjectRef {
    const obj = jsc.JSObjectMake(ctx, null, null);
    var name_buf: [256]u8 = undefined;
    const name_len = @min(e.name.len, name_buf.len - 1);
    @memcpy(name_buf[0..name_len], e.name[0..name_len]);
    name_buf[name_len] = 0;
    const name_ref = jsc.JSStringCreateWithUTF8CString(&name_buf);
    defer jsc.JSStringRelease(name_ref);
    const type_str = switch (e.entry_type) {
        .mark => "mark",
        .measure => "measure",
        .function => "function",
    };
    const type_ref = jsc.JSStringCreateWithUTF8CString(type_str.ptr);
    defer jsc.JSStringRelease(type_ref);
    _ = jsc.JSObjectSetProperty(ctx, obj, jsc.JSStringCreateWithUTF8CString("name"), jsc.JSValueMakeString(ctx, name_ref), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, jsc.JSStringCreateWithUTF8CString("entryType"), jsc.JSValueMakeString(ctx, type_ref), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, jsc.JSStringCreateWithUTF8CString("startTime"), jsc.JSValueMakeNumber(ctx, e.start_time), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, jsc.JSStringCreateWithUTF8CString("duration"), jsc.JSValueMakeNumber(ctx, e.duration), jsc.kJSPropertyAttributeNone, null);
    const detail_val = if (e.detail_owned) |d| blk: {
        var db: [4096]u8 = undefined;
        const d_len = @min(d.len, db.len - 1);
        @memcpy(db[0..d_len], d[0..d_len]);
        db[d_len] = 0;
        const detail_str = jsc.JSStringCreateWithUTF8CString(&db);
        defer jsc.JSStringRelease(detail_str);
        break :blk jsc.JSValueMakeString(ctx, detail_str);
    } else jsc.JSValueMakeUndefined(ctx);
    _ = jsc.JSObjectSetProperty(ctx, obj, jsc.JSStringCreateWithUTF8CString("detail"), detail_val, jsc.kJSPropertyAttributeNone, null);
    return obj;
}

/// 获取 JS 数组的 length 属性并转为 usize
fn jsArrayLength(ctx: jsc.JSContextRef, arr: jsc.JSObjectRef) usize {
    const k_len = jsc.JSStringCreateWithUTF8CString("length");
    defer jsc.JSStringRelease(k_len);
    const len_val = jsc.JSObjectGetProperty(ctx, arr, k_len, null);
    const n = jsc.JSValueToNumber(ctx, len_val, null);
    if (n < 0 or n != n) return 0; // NaN or negative
    return @intFromFloat(n);
}

/// 在 JS 数组 arr 中查找 entryType 字符串的索引（与 _entryTypes.indexOf(entryType) 等价）
fn jsArrayIndexOfEntryType(ctx: jsc.JSContextRef, arr: jsc.JSObjectRef, entry_type_val: jsc.JSValueRef) i32 {
    const type_str = jsc.JSValueToStringCopy(ctx, entry_type_val, null);
    defer jsc.JSStringRelease(type_str);
    var type_buf: [32]u8 = undefined;
    const tn = jsc.JSStringGetUTF8CString(type_str, &type_buf, type_buf.len);
    if (tn == 0) return -1;
    const want = type_buf[0 .. tn - 1];
    const len = jsArrayLength(ctx, arr);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const elem = jsc.JSObjectGetPropertyAtIndex(ctx, arr, @intCast(i), null);
        const elem_obj = jsc.JSValueToObject(ctx, elem, null) orelse continue;
        const k_et = jsc.JSStringCreateWithUTF8CString("entryType");
        defer jsc.JSStringRelease(k_et);
        const et_val = jsc.JSObjectGetProperty(ctx, elem_obj, k_et, null);
        const et_str = jsc.JSValueToStringCopy(ctx, et_val, null);
        defer jsc.JSStringRelease(et_str);
        var eb: [32]u8 = undefined;
        const en = jsc.JSStringGetUTF8CString(et_str, &eb, eb.len);
        if (en > 0 and std.mem.eql(u8, eb[0 .. en - 1], want)) return @intCast(i);
    }
    return -1;
}

/// Observer 列表 list 的 getEntries()：返回 this.__entries
fn perfListGetEntriesCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const k_entries = jsc.JSStringCreateWithUTF8CString("__entries");
    defer jsc.JSStringRelease(k_entries);
    return jsc.JSObjectGetProperty(ctx, thisObject, k_entries, null);
}

/// Observer 列表 list 的 getEntriesByName(name, type)：按 name 与可选 type 过滤
fn perfListGetEntriesByNameCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const k_entries = jsc.JSStringCreateWithUTF8CString("__entries");
    defer jsc.JSStringRelease(k_entries);
    const entries_val = jsc.JSObjectGetProperty(ctx, thisObject, k_entries, null);
    const entries = jsc.JSValueToObject(ctx, entries_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const len = jsArrayLength(ctx, entries);
    var empty0: [0]jsc.JSValueRef = .{};
    if (argumentCount < 1) return jsc.JSObjectMakeArray(ctx, 0, &empty0, null);
    const name_str = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(name_str);
    var name_buf: [512]u8 = undefined;
    const name_n = jsc.JSStringGetUTF8CString(name_str, &name_buf, name_buf.len);
    if (name_n == 0) return jsc.JSObjectMakeArray(ctx, 0, &empty0, null);
    const want_name = name_buf[0 .. name_n - 1];
    var want_type: ?[]const u8 = null;
    if (argumentCount >= 2 and !jsc.JSValueIsUndefined(ctx, arguments[1])) {
        const t_str = jsc.JSValueToStringCopy(ctx, arguments[1], null);
        defer jsc.JSStringRelease(t_str);
        var tb: [16]u8 = undefined;
        const tn = jsc.JSStringGetUTF8CString(t_str, &tb, tb.len);
        if (tn > 0) want_type = tb[0 .. tn - 1];
    }
    var refs = std.ArrayList(jsc.JSValueRef).initCapacity(g_perf_alloc, len) catch return jsc.JSValueMakeUndefined(ctx);
    defer refs.deinit(g_perf_alloc);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const elem = jsc.JSObjectGetPropertyAtIndex(ctx, entries, @intCast(i), null);
        const obj = jsc.JSValueToObject(ctx, elem, null) orelse continue;
        const k_name = jsc.JSStringCreateWithUTF8CString("name");
        defer jsc.JSStringRelease(k_name);
        const n_val = jsc.JSObjectGetProperty(ctx, obj, k_name, null);
        const n_str = jsc.JSValueToStringCopy(ctx, n_val, null);
        defer jsc.JSStringRelease(n_str);
        var nb: [512]u8 = undefined;
        const nn = jsc.JSStringGetUTF8CString(n_str, &nb, nb.len);
        if (nn == 0 or !std.mem.eql(u8, nb[0 .. nn - 1], want_name)) continue;
        if (want_type) |wt| {
            const k_et = jsc.JSStringCreateWithUTF8CString("entryType");
            defer jsc.JSStringRelease(k_et);
            const et_val = jsc.JSObjectGetProperty(ctx, obj, k_et, null);
            const et_str = jsc.JSValueToStringCopy(ctx, et_val, null);
            defer jsc.JSStringRelease(et_str);
            var eb: [16]u8 = undefined;
            const en = jsc.JSStringGetUTF8CString(et_str, &eb, eb.len);
            if (en == 0 or !std.mem.eql(u8, eb[0 .. en - 1], wt)) continue;
        }
        refs.append(g_perf_alloc, elem) catch {};
    }
    if (refs.items.len == 0) return jsc.JSObjectMakeArray(ctx, 0, &empty0, null);
    return jsc.JSObjectMakeArray(ctx, refs.items.len, refs.items.ptr, null);
}

/// Observer 列表 list 的 getEntriesByType(type)：按 type 过滤
fn perfListGetEntriesByTypeCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const k_entries = jsc.JSStringCreateWithUTF8CString("__entries");
    defer jsc.JSStringRelease(k_entries);
    const entries_val = jsc.JSObjectGetProperty(ctx, thisObject, k_entries, null);
    const entries = jsc.JSValueToObject(ctx, entries_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const len = jsArrayLength(ctx, entries);
    var empty0: [0]jsc.JSValueRef = .{};
    if (argumentCount < 1) return jsc.JSObjectMakeArray(ctx, 0, &empty0, null);
    const type_str = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(type_str);
    var type_buf: [16]u8 = undefined;
    const type_n = jsc.JSStringGetUTF8CString(type_str, &type_buf, type_buf.len);
    if (type_n == 0) return jsc.JSObjectMakeArray(ctx, 0, &empty0, null);
    const want_type = type_buf[0 .. type_n - 1];
    var refs = std.ArrayList(jsc.JSValueRef).initCapacity(g_perf_alloc, len) catch return jsc.JSValueMakeUndefined(ctx);
    defer refs.deinit(g_perf_alloc);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const elem = jsc.JSObjectGetPropertyAtIndex(ctx, entries, @intCast(i), null);
        const obj = jsc.JSValueToObject(ctx, elem, null) orelse continue;
        const k_et = jsc.JSStringCreateWithUTF8CString("entryType");
        defer jsc.JSStringRelease(k_et);
        const et_val = jsc.JSObjectGetProperty(ctx, obj, k_et, null);
        const et_str = jsc.JSValueToStringCopy(ctx, et_val, null);
        defer jsc.JSStringRelease(et_str);
        var eb: [16]u8 = undefined;
        const en = jsc.JSStringGetUTF8CString(et_str, &eb, eb.len);
        if (en > 0 and std.mem.eql(u8, eb[0 .. en - 1], want_type)) refs.append(g_perf_alloc, elem) catch {};
    }
    if (refs.items.len == 0) return jsc.JSObjectMakeArray(ctx, 0, &empty0, null);
    return jsc.JSObjectMakeArray(ctx, refs.items.len, refs.items.ptr, null);
}

/// 从 entries 数组创建 list 对象 { getEntries, getEntriesByName, getEntriesByType }，list.__entries = entries
fn makePerfListFromEntries(ctx: jsc.JSContextRef, entries_arr: jsc.JSValueRef) jsc.JSObjectRef {
    const list = jsc.JSObjectMake(ctx, null, null);
    const k_entries = jsc.JSStringCreateWithUTF8CString("__entries");
    defer jsc.JSStringRelease(k_entries);
    _ = jsc.JSObjectSetProperty(ctx, list, k_entries, entries_arr, jsc.kJSPropertyAttributeNone, null);
    common.setMethod(ctx, list, "getEntries", perfListGetEntriesCallback);
    common.setMethod(ctx, list, "getEntriesByName", perfListGetEntriesByNameCallback);
    common.setMethod(ctx, list, "getEntriesByType", perfListGetEntriesByTypeCallback);
    return list;
}

/// __shuPerfNotify(entries)：创建 list，安排 setImmediate 后按 entryType 通知各 observer
fn shuPerfNotifyCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const entries_val = arguments[0];
    const entries_arr = jsc.JSValueToObject(ctx, entries_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const list = makePerfListFromEntries(ctx, entries_val);
    const first = jsc.JSObjectGetPropertyAtIndex(ctx, entries_arr, 0, null);
    const k_et = jsc.JSStringCreateWithUTF8CString("entryType");
    defer jsc.JSStringRelease(k_et);
    const entry_type_val = jsc.JSObjectGetProperty(ctx, jsc.JSValueToObject(ctx, first, null) orelse return jsc.JSValueMakeUndefined(ctx), k_et, null);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_pending = jsc.JSStringCreateWithUTF8CString("__shuPerfPending");
    defer jsc.JSStringRelease(k_pending);
    const pending = jsc.JSObjectMake(ctx, null, null);
    const k_list = jsc.JSStringCreateWithUTF8CString("list");
    defer jsc.JSStringRelease(k_list);
    const k_entryType = jsc.JSStringCreateWithUTF8CString("entryType");
    defer jsc.JSStringRelease(k_entryType);
    _ = jsc.JSObjectSetProperty(ctx, pending, k_list, list, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, pending, k_entryType, entry_type_val, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, global, k_pending, pending, jsc.kJSPropertyAttributeNone, null);
    const k_setImmediate = jsc.JSStringCreateWithUTF8CString("setImmediate");
    defer jsc.JSStringRelease(k_setImmediate);
    const set_imm = jsc.JSObjectGetProperty(ctx, global, k_setImmediate, null);
    const deferred_name = jsc.JSStringCreateWithUTF8CString("__shuPerfDeferred");
    defer jsc.JSStringRelease(deferred_name);
    const deferred_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, deferred_name, shuPerfNotifyDeferredCallback);
    if (jsc.JSValueIsUndefined(ctx, set_imm) or !jsc.JSObjectIsFunction(ctx, @ptrCast(set_imm))) {
        var no_args: [0]jsc.JSValueRef = .{};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(deferred_fn), null, 0, &no_args, null);
        return jsc.JSValueMakeUndefined(ctx);
    }
    var zero: [1]jsc.JSValueRef = .{deferred_fn};
    _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(set_imm), null, 1, &zero, null);
    return jsc.JSValueMakeUndefined(ctx);
}

/// setImmediate 调用的延迟函数：从 __shuPerfPending 取 list/entryType，遍历 __shuPerfObservers 并调用 _callback(list, observer)
fn shuPerfNotifyDeferredCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    _ = argumentCount;
    _ = arguments;
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_pending = jsc.JSStringCreateWithUTF8CString("__shuPerfPending");
    defer jsc.JSStringRelease(k_pending);
    const pending_val = jsc.JSObjectGetProperty(ctx, global, k_pending, null);
    if (jsc.JSValueIsUndefined(ctx, pending_val) or jsc.JSValueIsNull(ctx, pending_val)) return jsc.JSValueMakeUndefined(ctx);
    _ = jsc.JSObjectSetProperty(ctx, global, k_pending, jsc.JSValueMakeUndefined(ctx), jsc.kJSPropertyAttributeNone, null);
    const pending = jsc.JSValueToObject(ctx, pending_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const k_list = jsc.JSStringCreateWithUTF8CString("list");
    defer jsc.JSStringRelease(k_list);
    const k_entryType = jsc.JSStringCreateWithUTF8CString("entryType");
    defer jsc.JSStringRelease(k_entryType);
    const list = jsc.JSObjectGetProperty(ctx, pending, k_list, null);
    const entry_type_val = jsc.JSObjectGetProperty(ctx, pending, k_entryType, null);
    const k_observers = jsc.JSStringCreateWithUTF8CString("__shuPerfObservers");
    defer jsc.JSStringRelease(k_observers);
    const observers_val = jsc.JSObjectGetProperty(ctx, global, k_observers, null);
    const observers = jsc.JSValueToObject(ctx, observers_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const n = jsArrayLength(ctx, observers);
    const k_cb = jsc.JSStringCreateWithUTF8CString("_callback");
    defer jsc.JSStringRelease(k_cb);
    const k_types = jsc.JSStringCreateWithUTF8CString("_entryTypes");
    defer jsc.JSStringRelease(k_types);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const obs_val = jsc.JSObjectGetPropertyAtIndex(ctx, observers, @intCast(i), null);
        const obs = jsc.JSValueToObject(ctx, obs_val, null) orelse continue;
        const types_val = jsc.JSObjectGetProperty(ctx, obs, k_types, null);
        if (jsc.JSValueIsUndefined(ctx, types_val)) continue;
        const types_arr = jsc.JSValueToObject(ctx, types_val, null) orelse continue;
        if (jsArrayIndexOfEntryType(ctx, types_arr, entry_type_val) < 0) continue;
        const cb_val = jsc.JSObjectGetProperty(ctx, obs, k_cb, null);
        if (jsc.JSValueIsUndefined(ctx, cb_val) or !jsc.JSObjectIsFunction(ctx, @ptrCast(cb_val))) continue;
        var args: [2]jsc.JSValueRef = .{ list, obs_val };
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(cb_val), null, 2, &args, null);
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// 调用 JS 的 __shuPerfNotify(entriesArray) 以异步通知 PerformanceObserver
fn notifyObservers(ctx: jsc.JSContextRef, new_entries: []const PerfEntry) void {
    if (new_entries.len == 0) return;
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k = jsc.JSStringCreateWithUTF8CString("__shuPerfNotify");
    defer jsc.JSStringRelease(k);
    const fn_val = jsc.JSObjectGetProperty(ctx, global, k, null);
    if (jsc.JSValueIsUndefined(ctx, fn_val) or jsc.JSValueIsNull(ctx, fn_val)) return;
    const fn_obj = jsc.JSValueToObject(ctx, fn_val, null) orelse return;
    const refs = g_perf_alloc.alloc(jsc.JSValueRef, new_entries.len) catch return;
    defer g_perf_alloc.free(refs);
    for (new_entries, refs) |e, *r| r.* = entryToJS(ctx, e);
    const arr = jsc.JSObjectMakeArray(ctx, new_entries.len, refs.ptr, null);
    var one: [1]jsc.JSValueRef = .{arr};
    _ = jsc.JSObjectCallAsFunction(ctx, fn_obj, null, 1, &one, null);
}

/// performance.getEntries()
fn performanceGetEntriesCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    ensurePerfStore();
    const refs = g_perf_alloc.alloc(jsc.JSValueRef, g_entries.items.len) catch return jsc.JSValueMakeUndefined(ctx);
    defer g_perf_alloc.free(refs);
    for (g_entries.items, refs) |e, *r| r.* = entryToJS(ctx, e);
    const arr = jsc.JSObjectMakeArray(ctx, g_entries.items.len, refs.ptr, null);
    return arr;
}

/// performance.getEntriesByName(name [, type])
fn performanceGetEntriesByNameCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    var empty_arr: [0]jsc.JSValueRef = .{};
    if (argumentCount < 1) return jsc.JSObjectMakeArray(ctx, 0, &empty_arr, null);
    ensurePerfStore();
    const name_str = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(name_str);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(name_str);
    if (max_sz == 0 or max_sz > 1024) return jsc.JSObjectMakeArray(ctx, 0, &empty_arr, null);
    const buf = g_perf_alloc.alloc(u8, max_sz) catch return jsc.JSObjectMakeArray(ctx, 0, &empty_arr, null);
    defer g_perf_alloc.free(buf);
    const n = jsc.JSStringGetUTF8CString(name_str, buf.ptr, max_sz);
    if (n == 0) return jsc.JSObjectMakeArray(ctx, 0, &empty_arr, null);
    const name = buf[0 .. n - 1];
    var filter_type: ?PerfEntryType = null;
    if (argumentCount >= 2 and !jsc.JSValueIsUndefined(ctx, arguments[1])) {
        const type_str = jsc.JSValueToStringCopy(ctx, arguments[1], null);
        defer jsc.JSStringRelease(type_str);
        var type_buf: [16]u8 = undefined;
        const tn = jsc.JSStringGetUTF8CString(type_str, &type_buf, type_buf.len);
        if (tn > 0) {
            const ts = type_buf[0 .. tn - 1];
            if (std.mem.eql(u8, ts, "mark")) filter_type = .mark else if (std.mem.eql(u8, ts, "measure")) filter_type = .measure else if (std.mem.eql(u8, ts, "function")) filter_type = .function;
        }
    }
    var empty_arr2: [0]jsc.JSValueRef = .{};
    var list = std.ArrayList(PerfEntry).initCapacity(g_perf_alloc, 0) catch return jsc.JSObjectMakeArray(ctx, 0, &empty_arr2, null);
    defer list.deinit(g_perf_alloc);
    for (g_entries.items) |e| {
        if (!std.mem.eql(u8, e.name, name)) continue;
        if (filter_type) |ft| if (e.entry_type != ft) continue;
        list.append(g_perf_alloc, e) catch {};
    }
    const list_refs = g_perf_alloc.alloc(jsc.JSValueRef, list.items.len) catch return jsc.JSObjectMakeArray(ctx, 0, &empty_arr2, null);
    defer g_perf_alloc.free(list_refs);
    for (list.items, list_refs) |e, *r| r.* = entryToJS(ctx, e);
    return jsc.JSObjectMakeArray(ctx, list.items.len, list_refs.ptr, null);
}

/// performance.getEntriesByType(type)
fn performanceGetEntriesByTypeCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    var empty_arr: [0]jsc.JSValueRef = .{};
    if (argumentCount < 1) return jsc.JSObjectMakeArray(ctx, 0, &empty_arr, null);
    ensurePerfStore();
    const type_str = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(type_str);
    var type_buf: [16]u8 = undefined;
    const nn = jsc.JSStringGetUTF8CString(type_str, &type_buf, type_buf.len);
    if (nn == 0) return jsc.JSObjectMakeArray(ctx, 0, &empty_arr, null);
    const type_slice = type_buf[0 .. nn - 1];
    const want_mark = std.mem.eql(u8, type_slice, "mark");
    const want_measure = std.mem.eql(u8, type_slice, "measure");
    const want_function = std.mem.eql(u8, type_slice, "function");
    var list = std.ArrayList(PerfEntry).initCapacity(g_perf_alloc, 0) catch return jsc.JSObjectMakeArray(ctx, 0, &empty_arr, null);
    defer list.deinit(g_perf_alloc);
    for (g_entries.items) |e| {
        if (e.entry_type == .mark and want_mark) list.append(g_perf_alloc, e) catch {} else if (e.entry_type == .measure and want_measure) list.append(g_perf_alloc, e) catch {} else if (e.entry_type == .function and want_function) list.append(g_perf_alloc, e) catch {};
    }
    const list_refs = g_perf_alloc.alloc(jsc.JSValueRef, list.items.len) catch return jsc.JSObjectMakeArray(ctx, 0, &empty_arr, null);
    defer g_perf_alloc.free(list_refs);
    for (list.items, list_refs) |e, *r| r.* = entryToJS(ctx, e);
    return jsc.JSObjectMakeArray(ctx, list.items.len, list_refs.ptr, null);
}

/// 创建 performance.nodeTiming 兼容对象（Node 启动时间等；本运行时用 timeOrigin 填充 nodeStart/bootstrapComplete，其余为 0）
fn makeNodeTimingObject(ctx: jsc.JSContextRef) jsc.JSObjectRef {
    const nt = jsc.JSObjectMake(ctx, null, null);
    const setNum = struct {
        fn f(c: jsc.JSContextRef, o: jsc.JSObjectRef, key: [*]const u8, val: f64) void {
            const k = jsc.JSStringCreateWithUTF8CString(key);
            defer jsc.JSStringRelease(k);
            _ = jsc.JSObjectSetProperty(c, o, k, jsc.JSValueMakeNumber(c, val), jsc.kJSPropertyAttributeNone, null);
        }
    }.f;
    setNum(ctx, nt, "nodeStart", -1);
    setNum(ctx, nt, "nodeStartTimestamp", g_time_origin);
    setNum(ctx, nt, "v8Start", -1);
    setNum(ctx, nt, "v8StartTimestamp", 0);
    setNum(ctx, nt, "bootstrapComplete", -1);
    setNum(ctx, nt, "bootstrapCompleteTimestamp", g_time_origin);
    setNum(ctx, nt, "environment", -1);
    setNum(ctx, nt, "environmentTimestamp", 0);
    setNum(ctx, nt, "loopStart", -1);
    setNum(ctx, nt, "loopStartTimestamp", 0);
    setNum(ctx, nt, "loopExit", -1);
    setNum(ctx, nt, "loopExitTimestamp", 0);
    setNum(ctx, nt, "idleTime", 0);
    return nt;
}

/// 创建 performance 对象并挂载方法
fn makePerformanceObject(ctx: jsc.JSGlobalContextRef) jsc.JSObjectRef {
    ensurePerfStore();
    const perf = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, perf, "now", performanceNowCallback);
    common.setMethod(ctx, perf, "mark", performanceMarkCallback);
    common.setMethod(ctx, perf, "measure", performanceMeasureCallback);
    common.setMethod(ctx, perf, "clearMarks", performanceClearMarksCallback);
    common.setMethod(ctx, perf, "clearMeasures", performanceClearMeasuresCallback);
    common.setMethod(ctx, perf, "getEntries", performanceGetEntriesCallback);
    common.setMethod(ctx, perf, "getEntriesByName", performanceGetEntriesByNameCallback);
    common.setMethod(ctx, perf, "getEntriesByType", performanceGetEntriesByTypeCallback);
    common.setMethod(ctx, perf, "timerify", performanceTimerifyCallback);
    const time_origin_ref = jsc.JSStringCreateWithUTF8CString("timeOrigin");
    defer jsc.JSStringRelease(time_origin_ref);
    _ = jsc.JSObjectSetProperty(ctx, perf, time_origin_ref, jsc.JSValueMakeNumber(ctx, g_time_origin), jsc.kJSPropertyAttributeNone, null);
    const node_timing_ref = jsc.JSStringCreateWithUTF8CString("nodeTiming");
    defer jsc.JSStringRelease(node_timing_ref);
    _ = jsc.JSObjectSetProperty(ctx, perf, node_timing_ref, makeNodeTimingObject(ctx), jsc.kJSPropertyAttributeNone, null);
    return perf;
}

/// PerformanceObserver 构造函数：new PerformanceObserver(callback) -> 设置 this._callback、this._entryTypes=[]
fn performanceObserverCtorCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const k_cb = jsc.JSStringCreateWithUTF8CString("_callback");
    defer jsc.JSStringRelease(k_cb);
    const k_types = jsc.JSStringCreateWithUTF8CString("_entryTypes");
    defer jsc.JSStringRelease(k_types);
    _ = jsc.JSObjectSetProperty(ctx, thisObject, k_cb, if (argumentCount >= 1) arguments[0] else jsc.JSValueMakeUndefined(ctx), jsc.kJSPropertyAttributeNone, null);
    var empty: [0]jsc.JSValueRef = .{};
    _ = jsc.JSObjectSetProperty(ctx, thisObject, k_types, jsc.JSObjectMakeArray(ctx, 0, &empty, null), jsc.kJSPropertyAttributeNone, null);
    return thisObject;
}

/// PerformanceObserver.prototype.observe(opts)：解析 entryTypes，可选 buffered 先交付已有条目，再注册到 __shuPerfObservers
fn performanceObserverObserveCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const opts = jsc.JSValueToObject(ctx, arguments[0], null) orelse return jsc.JSValueMakeUndefined(ctx);
    const k_entryTypes = jsc.JSStringCreateWithUTF8CString("entryTypes");
    defer jsc.JSStringRelease(k_entryTypes);
    const k_type = jsc.JSStringCreateWithUTF8CString("type");
    defer jsc.JSStringRelease(k_type);
    const entry_types_val = jsc.JSObjectGetProperty(ctx, opts, k_entryTypes, null);
    var types_arr: jsc.JSValueRef = undefined;
    if (!jsc.JSValueIsUndefined(ctx, entry_types_val)) {
        types_arr = entry_types_val;
    } else {
        const single_val = jsc.JSObjectGetProperty(ctx, opts, k_type, null);
        if (!jsc.JSValueIsUndefined(ctx, single_val)) {
            var one: [1]jsc.JSValueRef = .{single_val};
            types_arr = jsc.JSObjectMakeArray(ctx, 1, &one, null);
        } else {
            var empty: [0]jsc.JSValueRef = .{};
            types_arr = jsc.JSObjectMakeArray(ctx, 0, &empty, null);
        }
    }
    const k_types = jsc.JSStringCreateWithUTF8CString("_entryTypes");
    defer jsc.JSStringRelease(k_types);
    _ = jsc.JSObjectSetProperty(ctx, thisObject, k_types, types_arr, jsc.kJSPropertyAttributeNone, null);
    const k_buffered = jsc.JSStringCreateWithUTF8CString("buffered");
    defer jsc.JSStringRelease(k_buffered);
    const buffered_val = jsc.JSObjectGetProperty(ctx, opts, k_buffered, null);
    if (jsc.JSValueToBoolean(ctx, buffered_val)) {
        const global = jsc.JSContextGetGlobalObject(ctx);
        const k_perf = jsc.JSStringCreateWithUTF8CString("__shuPerfPerformance");
        defer jsc.JSStringRelease(k_perf);
        const perf_val = jsc.JSObjectGetProperty(ctx, global, k_perf, null);
        const perf = jsc.JSValueToObject(ctx, perf_val, null);
        if (perf) |perf_obj| {
            const k_getByType = jsc.JSStringCreateWithUTF8CString("getEntriesByType");
            defer jsc.JSStringRelease(k_getByType);
            const get_fn = jsc.JSObjectGetProperty(ctx, perf_obj, k_getByType, null);
            const types_obj = jsc.JSValueToObject(ctx, types_arr, null) orelse return jsc.JSValueMakeUndefined(ctx);
            const type_len = jsArrayLength(ctx, types_obj);
            const k_cb = jsc.JSStringCreateWithUTF8CString("_callback");
            defer jsc.JSStringRelease(k_cb);
            const cb = jsc.JSObjectGetProperty(ctx, thisObject, k_cb, null);
            var i: usize = 0;
            while (i < type_len) : (i += 1) {
                const t_val = jsc.JSObjectGetPropertyAtIndex(ctx, types_obj, @intCast(i), null);
                var one_arg: [1]jsc.JSValueRef = .{t_val};
                const entries = jsc.JSObjectCallAsFunction(ctx, @ptrCast(get_fn), perf_obj, 1, &one_arg, null);
                const entries_arr = jsc.JSValueToObject(ctx, entries, null) orelse continue;
                if (jsArrayLength(ctx, entries_arr) == 0) continue;
                const list = makePerfListFromEntries(ctx, entries);
                var cb_args: [2]jsc.JSValueRef = .{ list, thisObject };
                _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(cb), null, 2, &cb_args, null);
            }
        }
    }
    const k_observers = jsc.JSStringCreateWithUTF8CString("__shuPerfObservers");
    defer jsc.JSStringRelease(k_observers);
    const observers_val = jsc.JSObjectGetProperty(ctx, jsc.JSContextGetGlobalObject(ctx), k_observers, null);
    const observers = jsc.JSValueToObject(ctx, observers_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const n = jsArrayLength(ctx, observers);
    var found = false;
    var j: usize = 0;
    while (j < n) : (j += 1) {
        if (jsc.JSObjectGetPropertyAtIndex(ctx, observers, @intCast(j), null) == thisObject) {
            found = true;
            break;
        }
    }
    if (!found) {
        const k_push = jsc.JSStringCreateWithUTF8CString("push");
        defer jsc.JSStringRelease(k_push);
        const push_val = jsc.JSObjectGetProperty(ctx, observers, k_push, null);
        var push_args: [1]jsc.JSValueRef = .{thisObject};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(push_val), observers, 1, &push_args, null);
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// PerformanceObserver.prototype.disconnect()：从 __shuPerfObservers 中移除 this
fn performanceObserverDisconnectCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_observers = jsc.JSStringCreateWithUTF8CString("__shuPerfObservers");
    defer jsc.JSStringRelease(k_observers);
    const observers_val = jsc.JSObjectGetProperty(ctx, global, k_observers, null);
    const observers = jsc.JSValueToObject(ctx, observers_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const k_splice = jsc.JSStringCreateWithUTF8CString("splice");
    defer jsc.JSStringRelease(k_splice);
    const splice_fn = jsc.JSObjectGetProperty(ctx, observers, k_splice, null);
    const n = jsArrayLength(ctx, observers);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (jsc.JSObjectGetPropertyAtIndex(ctx, observers, @intCast(i), null) == thisObject) {
            var args: [2]jsc.JSValueRef = .{ jsc.JSValueMakeNumber(ctx, @floatFromInt(i)), jsc.JSValueMakeNumber(ctx, 1) };
            _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(splice_fn), observers, 2, &args, null);
            break;
        }
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// PerformanceObserver.prototype.takeRecords()：返回空数组（本实现不缓冲记录）
fn performanceObserverTakeRecordsCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    var empty: [0]jsc.JSValueRef = .{};
    return jsc.JSObjectMakeArray(ctx, 0, &empty, null);
}

/// eventLoopUtilization([el, perf])：占位实现，返回 { idle: 0, active: 0, utilization: 0 }
fn eventLoopUtilizationCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const obj = jsc.JSObjectMake(ctx, null, null);
    const k_idle = jsc.JSStringCreateWithUTF8CString("idle");
    defer jsc.JSStringRelease(k_idle);
    const k_active = jsc.JSStringCreateWithUTF8CString("active");
    defer jsc.JSStringRelease(k_active);
    const k_util = jsc.JSStringCreateWithUTF8CString("utilization");
    defer jsc.JSStringRelease(k_util);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_idle, jsc.JSValueMakeNumber(ctx, 0), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_active, jsc.JSValueMakeNumber(ctx, 0), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_util, jsc.JSValueMakeNumber(ctx, 0), jsc.kJSPropertyAttributeNone, null);
    return obj;
}

/// monitorEventLoopDelay 返回的 Histogram 的 enable/disable 占位（无操作）
fn histogramEnableDisableCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    return jsc.JSValueMakeUndefined(ctx);
}

/// Histogram.prototype.percentile(n)：占位返回 0
fn histogramPercentileCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    return jsc.JSValueMakeNumber(ctx, 0);
}

/// monitorEventLoopDelay([options])：占位实现，返回带 min/max/mean/stddev/percentiles/enable/disable/percentile 的对象，数值均为 0
fn monitorEventLoopDelayCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const hist = jsc.JSObjectMake(ctx, null, null);
    const setNum = struct {
        fn f(c: jsc.JSContextRef, o: jsc.JSObjectRef, key: [*]const u8, val: f64) void {
            const k = jsc.JSStringCreateWithUTF8CString(key);
            defer jsc.JSStringRelease(k);
            _ = jsc.JSObjectSetProperty(c, o, k, jsc.JSValueMakeNumber(c, val), jsc.kJSPropertyAttributeNone, null);
        }
    }.f;
    setNum(ctx, hist, "min", 0);
    setNum(ctx, hist, "max", 0);
    setNum(ctx, hist, "mean", 0);
    setNum(ctx, hist, "stddev", 0);
    const k_percentiles = jsc.JSStringCreateWithUTF8CString("percentiles");
    defer jsc.JSStringRelease(k_percentiles);
    _ = jsc.JSObjectSetProperty(ctx, hist, k_percentiles, jsc.JSObjectMake(ctx, null, null), jsc.kJSPropertyAttributeNone, null);
    common.setMethod(ctx, hist, "enable", histogramEnableDisableCallback);
    common.setMethod(ctx, hist, "disable", histogramEnableDisableCallback);
    common.setMethod(ctx, hist, "percentile", histogramPercentileCallback);
    return hist;
}

/// 注入 __shuPerfNotify 与 __shuPerfObservers（纯 Zig 实现，不执行 JS 脚本）
fn ensurePerfBootstrap(ctx: jsc.JSContextRef) void {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_notify = jsc.JSStringCreateWithUTF8CString("__shuPerfNotify");
    defer jsc.JSStringRelease(k_notify);
    if (!jsc.JSValueIsUndefined(ctx, jsc.JSObjectGetProperty(ctx, global, k_notify, null))) return;
    var empty: [0]jsc.JSValueRef = .{};
    const observers_arr = jsc.JSObjectMakeArray(ctx, 0, &empty, null);
    const k_observers = jsc.JSStringCreateWithUTF8CString("__shuPerfObservers");
    defer jsc.JSStringRelease(k_observers);
    _ = jsc.JSObjectSetProperty(ctx, global, k_observers, observers_arr, jsc.kJSPropertyAttributeNone, null);
    const notify_name = jsc.JSStringCreateWithUTF8CString("__shuPerfNotify");
    defer jsc.JSStringRelease(notify_name);
    const notify_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, notify_name, shuPerfNotifyCallback);
    _ = jsc.JSObjectSetProperty(ctx, global, k_notify, notify_fn, jsc.kJSPropertyAttributeNone, null);
}

/// 构建并返回 require('shu:perf_hooks') 的 exports：{ performance, PerformanceObserver, timerify, eventLoopUtilization, monitorEventLoopDelay, NODE_PERFORMANCE_* }
pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    initPerfStore(allocator);
    ensurePerfBootstrap(ctx);

    const exports = jsc.JSObjectMake(ctx, null, null);
    const perf = makePerformanceObject(ctx);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_perf = jsc.JSStringCreateWithUTF8CString("__shuPerfPerformance");
    defer jsc.JSStringRelease(k_perf);
    _ = jsc.JSObjectSetProperty(ctx, global, k_perf, perf, jsc.kJSPropertyAttributeNone, null);

    const perf_name = jsc.JSStringCreateWithUTF8CString("performance");
    defer jsc.JSStringRelease(perf_name);
    _ = jsc.JSObjectSetProperty(ctx, exports, perf_name, perf, jsc.kJSPropertyAttributeNone, null);

    const obs_ctor_name = jsc.JSStringCreateWithUTF8CString("PerformanceObserver");
    defer jsc.JSStringRelease(obs_ctor_name);
    const obs_ctor = jsc.JSObjectMakeFunctionWithCallback(ctx, obs_ctor_name, performanceObserverCtorCallback);
    const k_proto = jsc.JSStringCreateWithUTF8CString("prototype");
    defer jsc.JSStringRelease(k_proto);
    const obs_proto = jsc.JSObjectGetProperty(ctx, obs_ctor, k_proto, null);
    const obs_proto_obj = jsc.JSValueToObject(ctx, obs_proto, null) orelse return exports;
    common.setMethod(ctx, obs_proto_obj, "observe", performanceObserverObserveCallback);
    common.setMethod(ctx, obs_proto_obj, "disconnect", performanceObserverDisconnectCallback);
    common.setMethod(ctx, obs_proto_obj, "takeRecords", performanceObserverTakeRecordsCallback);
    const obs_name = jsc.JSStringCreateWithUTF8CString("PerformanceObserver");
    defer jsc.JSStringRelease(obs_name);
    _ = jsc.JSObjectSetProperty(ctx, exports, obs_name, obs_ctor, jsc.kJSPropertyAttributeNone, null);

    const k_timerify = jsc.JSStringCreateWithUTF8CString("timerify");
    defer jsc.JSStringRelease(k_timerify);
    const timerify_val = jsc.JSObjectGetProperty(ctx, perf, k_timerify, null);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_timerify, timerify_val, jsc.kJSPropertyAttributeNone, null);

    const elu_name = jsc.JSStringCreateWithUTF8CString("eventLoopUtilization");
    defer jsc.JSStringRelease(elu_name);
    _ = jsc.JSObjectSetProperty(ctx, exports, elu_name, jsc.JSObjectMakeFunctionWithCallback(ctx, elu_name, eventLoopUtilizationCallback), jsc.kJSPropertyAttributeNone, null);

    const monitor_name = jsc.JSStringCreateWithUTF8CString("monitorEventLoopDelay");
    defer jsc.JSStringRelease(monitor_name);
    _ = jsc.JSObjectSetProperty(ctx, exports, monitor_name, jsc.JSObjectMakeFunctionWithCallback(ctx, monitor_name, monitorEventLoopDelayCallback), jsc.kJSPropertyAttributeNone, null);

    const setConst = struct {
        fn f(c: jsc.JSContextRef, o: jsc.JSObjectRef, key: [*]const u8, val: i32) void {
            const k = jsc.JSStringCreateWithUTF8CString(key);
            defer jsc.JSStringRelease(k);
            _ = jsc.JSObjectSetProperty(c, o, k, jsc.JSValueMakeNumber(c, @floatFromInt(val)), jsc.kJSPropertyAttributeNone, null);
        }
    }.f;
    // NODE_ 前缀：兼容 Node.js，与 Node perf_hooks 常量一致
    setConst(ctx, exports, "NODE_PERFORMANCE_GC_MAJOR", 4);
    setConst(ctx, exports, "NODE_PERFORMANCE_GC_MINOR", 1);
    setConst(ctx, exports, "NODE_PERFORMANCE_GC_INCREMENTAL", 8);
    setConst(ctx, exports, "NODE_PERFORMANCE_GC_WEAKCB", 16);
    setConst(ctx, exports, "NODE_PERFORMANCE_GC_FLAGS_NO", 0);
    setConst(ctx, exports, "NODE_PERFORMANCE_GC_FLAGS_CONSTRUCT_RETAINED", 1);
    setConst(ctx, exports, "NODE_PERFORMANCE_GC_FLAGS_FORCED", 2);
    setConst(ctx, exports, "NODE_PERFORMANCE_GC_FLAGS_SYNCHRONOUS_PHANTOM_PROCESSING", 4);
    setConst(ctx, exports, "NODE_PERFORMANCE_GC_FLAGS_ALL_AVAILABLE_GARBAGE", 8);
    setConst(ctx, exports, "NODE_PERFORMANCE_GC_FLAGS_ALL_EXTERNAL_MEMORY", 16);
    setConst(ctx, exports, "NODE_PERFORMANCE_GC_FLAGS_SCHEDULE_IDLE", 32);
    // SHU_ 前缀：shu 运行时自有常量，数值与 NODE_ 一致，便于 shu 生态使用
    setConst(ctx, exports, "SHU_PERFORMANCE_GC_MAJOR", 4);
    setConst(ctx, exports, "SHU_PERFORMANCE_GC_MINOR", 1);
    setConst(ctx, exports, "SHU_PERFORMANCE_GC_INCREMENTAL", 8);
    setConst(ctx, exports, "SHU_PERFORMANCE_GC_WEAKCB", 16);
    setConst(ctx, exports, "SHU_PERFORMANCE_GC_FLAGS_NO", 0);
    setConst(ctx, exports, "SHU_PERFORMANCE_GC_FLAGS_CONSTRUCT_RETAINED", 1);
    setConst(ctx, exports, "SHU_PERFORMANCE_GC_FLAGS_FORCED", 2);
    setConst(ctx, exports, "SHU_PERFORMANCE_GC_FLAGS_SYNCHRONOUS_PHANTOM_PROCESSING", 4);
    setConst(ctx, exports, "SHU_PERFORMANCE_GC_FLAGS_ALL_AVAILABLE_GARBAGE", 8);
    setConst(ctx, exports, "SHU_PERFORMANCE_GC_FLAGS_ALL_EXTERNAL_MEMORY", 16);
    setConst(ctx, exports, "SHU_PERFORMANCE_GC_FLAGS_SCHEDULE_IDLE", 32);

    return exports;
}
