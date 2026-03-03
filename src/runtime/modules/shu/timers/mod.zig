// 全局 setTimeout、setInterval、clearTimeout、clearInterval 注册与 C 回调
// getExports 供 require("shu:timers")/node:timers，返回与全局相同的定时器 API 对象

const std = @import("std");
const jsc = @import("jsc");
const errors = @import("errors");
const libs_process = @import("libs_process");
const globals = @import("../../../globals.zig");
const common = @import("../../../common.zig");
const cron = @import("../crond/mod.zig");
const async_ctx = @import("../async/context.zig");

/// 向全局对象注册 setTimeout、setInterval、clearTimeout、clearInterval、setImmediate、clearImmediate、queueMicrotask
/// allocator 统一传入（§1.1），本模块暂不使用
pub fn register(ctx: jsc.JSGlobalContextRef, allocator: ?std.mem.Allocator) void {
    _ = allocator;
    const global = jsc.JSContextGetGlobalObject(ctx);
    const name_setTimeout = jsc.JSStringCreateWithUTF8CString("setTimeout");
    defer jsc.JSStringRelease(name_setTimeout);
    const name_setInterval = jsc.JSStringCreateWithUTF8CString("setInterval");
    defer jsc.JSStringRelease(name_setInterval);
    const name_clearTimeout = jsc.JSStringCreateWithUTF8CString("clearTimeout");
    defer jsc.JSStringRelease(name_clearTimeout);
    const name_clearInterval = jsc.JSStringCreateWithUTF8CString("clearInterval");
    defer jsc.JSStringRelease(name_clearInterval);
    const name_setImmediate = jsc.JSStringCreateWithUTF8CString("setImmediate");
    defer jsc.JSStringRelease(name_setImmediate);
    const name_clearImmediate = jsc.JSStringCreateWithUTF8CString("clearImmediate");
    defer jsc.JSStringRelease(name_clearImmediate);
    const name_queueMicrotask = jsc.JSStringCreateWithUTF8CString("queueMicrotask");
    defer jsc.JSStringRelease(name_queueMicrotask);
    _ = jsc.JSObjectSetProperty(ctx, global, name_setTimeout, jsc.JSObjectMakeFunctionWithCallback(ctx, name_setTimeout, setTimeoutCallback), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, global, name_setInterval, jsc.JSObjectMakeFunctionWithCallback(ctx, name_setInterval, setIntervalCallback), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, global, name_clearTimeout, jsc.JSObjectMakeFunctionWithCallback(ctx, name_clearTimeout, clearTimerCallback), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, global, name_clearInterval, jsc.JSObjectMakeFunctionWithCallback(ctx, name_clearInterval, clearTimerCallback), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, global, name_setImmediate, jsc.JSObjectMakeFunctionWithCallback(ctx, name_setImmediate, setImmediateCallback), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, global, name_clearImmediate, jsc.JSObjectMakeFunctionWithCallback(ctx, name_clearImmediate, clearTimerCallback), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, global, name_queueMicrotask, jsc.JSObjectMakeFunctionWithCallback(ctx, name_queueMicrotask, queueMicrotaskCallback), jsc.kJSPropertyAttributeNone, null);
}

/// 返回 shu:timers / node:timers 的 exports（setTimeout、setInterval、clearTimeout、clearInterval、setImmediate、clearImmediate、queueMicrotask），与全局注册同源
pub fn getExports(ctx: jsc.JSContextRef, _: std.mem.Allocator) jsc.JSValueRef {
    const exports = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, exports, "setTimeout", setTimeoutCallback);
    common.setMethod(ctx, exports, "setInterval", setIntervalCallback);
    common.setMethod(ctx, exports, "clearTimeout", clearTimerCallback);
    common.setMethod(ctx, exports, "clearInterval", clearTimerCallback);
    common.setMethod(ctx, exports, "setImmediate", setImmediateCallback);
    common.setMethod(ctx, exports, "clearImmediate", clearTimerCallback);
    common.setMethod(ctx, exports, "queueMicrotask", queueMicrotaskCallback);
    return exports;
}

fn setTimeoutCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    return scheduleTimer(ctx, arguments, argumentCount, false);
}

fn setIntervalCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    return scheduleTimer(ctx, arguments, argumentCount, true);
}

/// setImmediate(cb)：下一轮定时器循环执行，与 setTimeout(cb, 0) 共用 id 与取消逻辑
fn setImmediateCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeNumber(ctx, 0);
    if (globals.current_timer_state == null) return jsc.JSValueMakeNumber(ctx, 0);
    const callback = arguments[0];
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(callback))) return jsc.JSValueMakeNumber(ctx, 0);
    const id = scheduleWithDelay(ctx, callback, 0, false, false);
    return jsc.JSValueMakeNumber(ctx, @floatFromInt(id));
}

/// queueMicrotask(fn)：将 fn 加入微任务队列，在本次脚本执行结束后、runLoop 前执行
fn queueMicrotaskCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const state = globals.current_timer_state orelse return jsc.JSValueMakeUndefined(ctx);
    const callback = arguments[0];
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(callback))) return jsc.JSValueMakeUndefined(ctx);
    jsc.JSValueProtect(ctx, callback);
    state.enqueueMicrotask(@ptrCast(ctx), callback);
    return jsc.JSValueMakeUndefined(ctx);
}

fn scheduleTimer(ctx: jsc.JSContextRef, arguments: [*]const jsc.JSValueRef, argumentCount: usize, is_interval: bool) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeNumber(ctx, 0);
    if (globals.current_timer_state == null) return jsc.JSValueMakeNumber(ctx, 0);
    const callback = arguments[0];
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(callback))) return jsc.JSValueMakeNumber(ctx, 0);
    var ms: u64 = 0;
    if (argumentCount >= 2) {
        const ms_str = jsc.JSValueToStringCopy(ctx, arguments[1], null);
        defer jsc.JSStringRelease(ms_str);
        var buf: [32]u8 = undefined;
        const n = jsc.JSStringGetUTF8CString(ms_str, &buf, buf.len);
        if (n > 0) ms = std.fmt.parseUnsigned(u64, buf[0 .. n - 1], 10) catch 0;
    }
    const id = scheduleWithDelay(ctx, callback, ms, is_interval, false);
    return jsc.JSValueMakeNumber(ctx, @floatFromInt(id));
}

/// 按指定毫秒数将回调加入定时器队列（供 Shu.crond 等复用）；is_crond 为 true 时参与「无参 crondClear 清空全部」
/// 会分配 async_id 并 emitInit，runLoop 中执行前后 push/pop、移除时 emitDestroy
pub fn scheduleWithDelay(ctx: jsc.JSContextRef, callback: jsc.JSValueRef, delay_ms: u64, is_interval: bool, is_crond: bool) u32 {
    const state = globals.current_timer_state orelse return 0;
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(callback))) return 0;
    const ids = async_ctx.allocId();
    async_ctx.emitInit(ctx, ids.async_id, "Timeout", ids.trigger_async_id, jsc.JSValueMakeUndefined(ctx));
    const id = state.next_timer_id;
    state.next_timer_id +%= 1;
    jsc.JSValueProtect(ctx, callback);
    state.pending_timers.append(state.allocator, .{
        .id = id,
        .ctx = @ptrCast(ctx),
        .callback = callback,
        .ms = delay_ms,
        .is_interval = is_interval,
        .scheduled_at = blk: {
            const io = libs_process.getProcessIo() orelse break :blk @as(i64, 0);
            break :blk @as(i64, @intCast(@divTrunc(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds, 1_000_000))) + @as(i64, @intCast(delay_ms));
        },
        .is_crond = is_crond,
        .async_id = ids.async_id,
        .trigger_async_id = ids.trigger_async_id,
    }) catch return 0;
    return id;
}

/// 按 id 取消定时器（与 clearTimeout/clearInterval 同源，供 Shu.crondClear(id) 复用）
pub fn cancelTimer(id: u32) void {
    const state = globals.current_timer_state orelse return;
    for (state.pending_timers.items) |*e| {
        if (e.id == id) {
            e.cancelled = true;
            break;
        }
    }
}

/// 取消所有由 Shu.crond 创建的计划任务（crondClear() 不传参时调用）
pub fn cancelAllCrond() void {
    const state = globals.current_timer_state orelse return;
    for (state.pending_timers.items) |*e| {
        if (e.is_crond) e.cancelled = true;
    }
}

/// 按 cron 六段表达式加入计划任务（秒 分 时 日 月 周）；expression 会被复制保存
pub fn scheduleCron(ctx: jsc.JSContextRef, callback: jsc.JSValueRef, expression: []const u8) u32 {
    const state = globals.current_timer_state orelse return 0;
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(callback))) return 0;
    var parsed = cron.parse(state.allocator, expression) catch return 0;
    defer parsed.deinit();
    const io = libs_process.getProcessIo() orelse return 0;
    const now_sec = @divTrunc(@as(i64, @intCast(@divTrunc(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds, 1_000_000))), 1000);
    const next_sec = cron.nextRun(&parsed, now_sec) orelse return 0;
    const next_ms: i64 = next_sec * 1000;
    const expr_copy = state.allocator.dupe(u8, expression) catch return 0;
    const id = state.next_timer_id;
    state.next_timer_id +%= 1;
    jsc.JSValueProtect(ctx, callback);
    state.pending_timers.append(state.allocator, .{
        .id = id,
        .ctx = @ptrCast(ctx),
        .callback = callback,
        .ms = 0,
        .is_interval = false,
        .scheduled_at = next_ms,
        .is_crond = true,
        .cron_expression = expr_copy,
    }) catch {
        jsc.JSValueUnprotect(ctx, callback);
        state.allocator.free(expr_copy);
        return 0;
    };
    return id;
}

fn clearTimerCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const state = globals.current_timer_state orelse return jsc.JSValueMakeUndefined(ctx);
    const id_str = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(id_str);
    var buf: [32]u8 = undefined;
    const n = jsc.JSStringGetUTF8CString(id_str, &buf, buf.len);
    if (n == 0) return jsc.JSValueMakeUndefined(ctx);
    const id = std.fmt.parseUnsigned(u32, buf[0 .. n - 1], 10) catch return jsc.JSValueMakeUndefined(ctx);
    for (state.pending_timers.items) |*e| {
        if (e.id == id) {
            e.cancelled = true;
            break;
        }
    }
    return jsc.JSValueMakeUndefined(ctx);
}
