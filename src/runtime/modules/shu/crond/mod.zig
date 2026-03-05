// Cron 六段表达式解析与下次执行时间计算：秒 分 时 日 月 周
// 格式："* * * * * *" 或 "*/5 0 * * * *" 等，支持 *、N、*/N、N-M
// 并提供 register(ctx, shu_obj) 挂载 Shu.crond、全局 crondClear

const std = @import("std");
const jsc = @import("jsc");
const globals = @import("../../../globals.zig");
const common = @import("../../../common.zig");
const shu_timers = @import("../timers/mod.zig");

/// 单字段规格：允许的值集合（如 0-59 秒中的哪些允许）
pub const FieldSpec = struct {
    /// 若为 true 表示任意值都匹配
    any: bool = false,
    /// 允许的数值（当 any 为 false 时使用）
    allowed: [64]u32 = [_]u32{0} ** 64,
    allowed_len: u32 = 0,

    /// 在 [0, max] 内是否存在 >= v 的下一个允许值；若有则通过 out 返回并返回 true
    pub fn next(self: *const FieldSpec, v: u32, max: u32, out: *u32) bool {
        if (self.any) {
            out.* = v;
            return true;
        }
        var i: u32 = 0;
        while (i < self.allowed_len) : (i += 1) {
            const a = self.allowed[i];
            if (a >= v and a <= max) {
                out.* = a;
                return true;
            }
        }
        return false;
    }
};

/// 解析后的六段：秒(0-59)、分(0-59)、时(0-23)、日(1-31)、月(1-12)、周(0-7，0与7为周日)
pub const ParsedCron = struct {
    sec: FieldSpec,
    min: FieldSpec,
    hour: FieldSpec,
    day: FieldSpec,
    month: FieldSpec,
    dow: FieldSpec,

    /// 释放解析时分配的资源（当前占位无分配）
    pub fn deinit(self: *ParsedCron) void {
        _ = self;
    }
};

/// 解析一段字段（*、N、*/N、N-M），max 为该段最大值（如秒 59）
fn parseField(allocator: std.mem.Allocator, slice: []const u8, max: u32) !FieldSpec {
    _ = allocator;
    const trimmed = std.mem.trim(u8, slice, " \t");
    if (trimmed.len == 0) return error.InvalidCron;
    if (trimmed.len == 1 and trimmed[0] == '*') {
        return .{ .any = true };
    }
    var buf: [64]u32 = undefined;
    var len: usize = 0;
    if (trimmed.len >= 2 and trimmed[0] == '*' and trimmed[1] == '/') {
        const step = std.fmt.parseUnsigned(u32, trimmed[2..], 10) catch return error.InvalidCron;
        if (step == 0) return error.InvalidCron;
        var n: u32 = 0;
        while (n <= max and len < 64) : (n += step) {
            buf[len] = n;
            len += 1;
        }
    } else if (std.mem.indexOfScalar(u8, trimmed, '-')) |_| {
        var it = std.mem.splitScalar(u8, trimmed, '-');
        const a_str = std.mem.trim(u8, it.next() orelse return error.InvalidCron, " \t");
        const b_str = std.mem.trim(u8, it.next() orelse return error.InvalidCron, " \t");
        const a = std.fmt.parseUnsigned(u32, a_str, 10) catch return error.InvalidCron;
        const b = std.fmt.parseUnsigned(u32, b_str, 10) catch return error.InvalidCron;
        if (a > b) return error.InvalidCron;
        var n = a;
        while (n <= b and n <= max and len < 64) : (n += 1) {
            buf[len] = n;
            len += 1;
        }
    } else if (std.mem.indexOfScalar(u8, trimmed, ',') == null) {
        // 单值：无逗号时直接解析，避免 splitScalar 迭代（§2.1 定时密集路径）
        const single = std.fmt.parseUnsigned(u32, trimmed, 10) catch return error.InvalidCron;
        if (single <= max) {
            buf[0] = single;
            len = 1;
        }
    } else {
        var it = std.mem.splitScalar(u8, trimmed, ',');
        while (it.next()) |part| {
            const p = std.mem.trim(u8, part, " \t");
            if (p.len == 0) continue;
            const num = std.fmt.parseUnsigned(u32, p, 10) catch return error.InvalidCron;
            if (num <= max and len < 64) {
                buf[len] = num;
                len += 1;
            }
        }
    }
    if (len == 0) return error.InvalidCron;
    std.mem.sort(u32, buf[0..len], {}, std.sort.asc(u32));
    var out: FieldSpec = .{ .any = false, .allowed_len = @intCast(len) };
    for (buf[0..len], 0..) |v, i| out.allowed[i] = v;
    return out;
}

/// 解析六段表达式 "sec min hour day month dow"，返回的 ParsedCron 需由调用方 deinit
/// 用手动按空格切分替代 std.mem.splitScalar，避免 0.16 std 内 findScalarPos(slice[i..][0..block_len]) 在剩余长度 < block_len 时越界
pub fn parse(allocator: std.mem.Allocator, expression: []const u8) !ParsedCron {
    if (expression.len == 0) return error.InvalidCron;
    // 与 crondCallback 中 max_sz > 256 拒绝一致，避免损坏的 len 导致越界或死循环
    if (expression.len > 256) return error.InvalidCron;
    var parts: [6][]const u8 = undefined;
    var n: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= expression.len and n < 6) {
        const at_end = (i >= expression.len);
        const at_space = if (at_end) false else (expression[i] == ' ');
        if (at_end or at_space) {
            if (start < i) {
                parts[n] = expression[start..i];
                n += 1;
            }
            start = i + 1;
        }
        i += 1;
    }
    if (start < expression.len and n < 6) {
        parts[n] = expression[start..];
        n += 1;
    }
    if (n != 6) return error.InvalidCron;
    // 拒绝第七段：n==6 时若 start 后还有非空白内容则 InvalidCron
    if (start < expression.len) {
        const rest = std.mem.trim(u8, expression[start..], " \t");
        if (rest.len > 0) return error.InvalidCron;
    }
    return .{
        .sec = try parseField(allocator, parts[0], 59),
        .min = try parseField(allocator, parts[1], 59),
        .hour = try parseField(allocator, parts[2], 23),
        .day = try parseField(allocator, parts[3], 31),
        .month = try parseField(allocator, parts[4], 12),
        .dow = try parseField(allocator, parts[5], 7),
    };
}

const SECS_PER_DAY: i64 = 86400;
const EPOCH_YEAR: i64 = 1970;

fn isLeapYear(y: i64) bool {
    if (@rem(y, 4) != 0) return false;
    if (@rem(y, 100) != 0) return true;
    return @rem(y, 400) == 0;
}

fn daysInMonth(year: i64, month: u32) u32 {
    const days: [12]u32 = .{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (month == 0 or month > 12) return 0;
    var d = days[month - 1];
    if (month == 2 and isLeapYear(year)) d += 1;
    return d;
}

/// 将 unix 秒转为 (秒, 分, 时, 日, 月, 年, 周几 0-6 周日=0)
fn unixToComponents(unix_sec: i64) struct { sec: u32, min: u32, hour: u32, day: u32, month: u32, year: i64, dow: u32 } {
    var s = unix_sec;
    const sec: u32 = @intCast(@rem(s, 60));
    s = @divTrunc(s, 60);
    const min: u32 = @intCast(@rem(s, 60));
    s = @divTrunc(s, 60);
    const hour: u32 = @intCast(@rem(s, 24));
    s = @divTrunc(s, 24);
    // 1970-01-01 为周四，在 0=周日  convention 下为 4
    const dow: u32 = @intCast(@rem(s + 4, 7));
    var day_count: i64 = s;
    var year = EPOCH_YEAR;
    while (true) {
        const days_in_year: i64 = if (isLeapYear(year)) 366 else 365;
        if (day_count >= 0 and day_count < days_in_year) break;
        if (day_count < 0) {
            year -= 1;
            const prev_days: i64 = if (isLeapYear(year)) 366 else 365;
            day_count += prev_days;
        } else {
            day_count -= days_in_year;
            year += 1;
        }
    }
    var month: u32 = 1;
    var day: u32 = @intCast(day_count + 1);
    while (month <= 12) {
        const dim = daysInMonth(year, month);
        if (day <= dim) break;
        day -= dim;
        month += 1;
    }
    return .{ .sec = sec, .min = min, .hour = hour, .day = day, .month = month, .year = year, .dow = dow };
}

/// 将 (秒,分,时,日,月,年) 转为 unix 秒
fn componentsToUnix(sec: u32, min: u32, hour: u32, day: u32, month: u32, year: i64) i64 {
    var total_days: i64 = 0;
    var y: i64 = EPOCH_YEAR;
    while (y < year) : (y += 1) {
        total_days += if (isLeapYear(y)) 366 else 365;
    }
    var m: u32 = 1;
    while (m < month) : (m += 1) {
        total_days += daysInMonth(year, m);
    }
    total_days += @as(i64, day) - 1;
    return total_days * SECS_PER_DAY + @as(i64, hour) * 3600 + @as(i64, min) * 60 + @as(i64, sec);
}

fn fieldMatches(spec: *const FieldSpec, v: u32, max: u32) bool {
    if (spec.any) return v <= max;
    var i: u32 = 0;
    while (i < spec.allowed_len) : (i += 1) {
        if (spec.allowed[i] == v) return true;
    }
    return false;
}

/// 计算从 from_unix_sec 起下一个满足 cron 的执行时刻（unix 秒）；最多向前扫描约 2 年
pub fn nextRun(parsed: *const ParsedCron, from_unix_sec: i64) ?i64 {
    const max_scan: i64 = 2 * 366 * SECS_PER_DAY;
    var t = from_unix_sec + 1;
    while (t - from_unix_sec <= max_scan) {
        const c = unixToComponents(t);
        const dim = daysInMonth(c.year, c.month);
        if (!fieldMatches(&parsed.sec, c.sec, 59)) {
            t += 1;
            continue;
        }
        if (!fieldMatches(&parsed.min, c.min, 59)) {
            t += 1;
            continue;
        }
        if (!fieldMatches(&parsed.hour, c.hour, 23)) {
            t += 1;
            continue;
        }
        if (!fieldMatches(&parsed.day, c.day, dim)) {
            t += 1;
            continue;
        }
        if (!fieldMatches(&parsed.month, c.month, 12)) {
            t += 1;
            continue;
        }
        var dow_ok = parsed.dow.any;
        if (!dow_ok) {
            var di: u32 = 0;
            while (di < parsed.dow.allowed_len) : (di += 1) {
                const d = parsed.dow.allowed[di];
                if (d == c.dow or (d == 7 and c.dow == 0)) {
                    dow_ok = true;
                    break;
                }
            }
        }
        const dow_match = dow_ok;
        if (dow_match) return t;
        t += 1;
    }
    return null;
}

// --- Shu.crond / crondClear 注册（供 engine/shu/mod.zig 或 bindings 调用）---

/// §1.1 显式 allocator 收敛：register(ctx, shu_obj, allocator) 时注入，回调内优先使用
threadlocal var g_crond_allocator: ?std.mem.Allocator = null;

fn crondCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const callback = arguments[1];
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(callback))) return jsc.JSValueMakeUndefined(ctx);
    const expr_js = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(expr_js);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(expr_js);
    if (max_sz == 0 or max_sz > 256) return jsc.JSValueMakeUndefined(ctx);
    const allocator = g_crond_allocator orelse globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const buf = allocator.alloc(u8, max_sz) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(buf);
    const n = jsc.JSStringGetUTF8CString(expr_js, buf.ptr, max_sz);
    if (n == 0) return jsc.JSValueMakeUndefined(ctx);
    const expression = buf[0 .. n - 1];
    const id = shu_timers.scheduleCron(ctx, callback, expression);
    if (id == 0) return jsc.JSValueMakeUndefined(ctx);
    const result_obj = jsc.JSObjectMake(ctx, null, null);
    const k_stop = jsc.JSStringCreateWithUTF8CString("stop");
    defer jsc.JSStringRelease(k_stop);
    const k_crond_id = jsc.JSStringCreateWithUTF8CString("__crond_id");
    defer jsc.JSStringRelease(k_crond_id);
    const stop_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_stop, crondStopCallback);
    _ = jsc.JSObjectSetProperty(ctx, stop_fn, k_crond_id, jsc.JSValueMakeNumber(ctx, @floatFromInt(id)), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, result_obj, k_stop, stop_fn, jsc.kJSPropertyAttributeNone, null);
    return result_obj;
}

/// stop() 的 C 回调：从 callee 取 __crond_id 并 cancelTimer，纯 Zig 无内联 JS
fn crondStopCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    callee: jsc.JSObjectRef,
    argumentCount: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    _ = argumentCount;
    const k = jsc.JSStringCreateWithUTF8CString("__crond_id");
    defer jsc.JSStringRelease(k);
    const id_val = jsc.JSObjectGetProperty(ctx, callee, k, null);
    const n = jsc.JSValueToNumber(ctx, id_val, null);
    const id: u32 = @intFromFloat(n);
    shu_timers.cancelTimer(id);
    return jsc.JSValueMakeUndefined(ctx);
}

fn crondClearCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) {
        shu_timers.cancelAllCrond();
        return jsc.JSValueMakeUndefined(ctx);
    }
    const n = jsc.JSValueToNumber(ctx, arguments[0], null);
    const id: u32 = @intFromFloat(n);
    shu_timers.cancelTimer(id);
    return jsc.JSValueMakeUndefined(ctx);
}

/// 向 shu_obj 挂载 Shu.crond、并向全局挂载 crondClear（供 engine/shu/mod.zig 或 bindings 调用）
/// allocator 可选；传入时注入 g_crond_allocator，§1.1 显式 allocator 收敛
pub fn register(ctx: jsc.JSGlobalContextRef, shu_obj: jsc.JSObjectRef, allocator: ?std.mem.Allocator) void {
    if (allocator) |a| g_crond_allocator = a;
    common.setMethod(ctx, shu_obj, "crond", crondCallback);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const name_crondClear = jsc.JSStringCreateWithUTF8CString("crondClear");
    defer jsc.JSStringRelease(name_crondClear);
    const crondClear_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, name_crondClear, crondClearCallback);
    _ = jsc.JSObjectSetProperty(ctx, global, name_crondClear, crondClear_fn, jsc.kJSPropertyAttributeNone, null);
}
