// 定时器队列与事件循环：TimerEntry、TimerState、runTimerLoop、微任务队列
// 供 engine.zig 持有并在 evaluate 后驱动，供 modules/shu/timers 回调入队

const std = @import("std");
const jsc = @import("jsc");
const cron = @import("../crond/mod.zig");
const async_ctx = @import("../async/context.zig");

/// 微任务项：仅存 ctx + callback，执行后需 Unprotect
pub const MicrotaskEntry = struct {
    ctx: jsc.JSGlobalContextRef,
    callback: jsc.JSValueRef,
};

/// 单个定时器项；回调已 JSValueProtect，移除时需 JSValueUnprotect
pub const TimerEntry = struct {
    id: u32,
    ctx: jsc.JSGlobalContextRef,
    callback: jsc.JSValueRef,
    ms: u64,
    is_interval: bool,
    scheduled_at: i64,
    cancelled: bool = false,
    /// 是否由 Shu.crond 创建，用于 crondClear() 无参时清空全部计划任务
    is_crond: bool = false,
    /// cron 表达式（仅 is_crond 且非 interval 时使用）；触发后根据此计算下次执行并重入队；需在取消/ deinit 时 free
    cron_expression: ?[]const u8 = null,
    /// async_hooks 对接：非 0 时执行回调前后 push/pop 上下文，移除时 emitDestroy
    async_id: u64 = 0,
    trigger_async_id: u64 = 0,
};

/// 定时器/微任务初始容量，减少热路径扩容（§1.3）
const PENDING_TIMERS_INIT_CAP = 32;
const MICROTASK_QUEUE_INIT_CAP = 32;

/// 定时器队列与 id 分配器；含微任务队列供 queueMicrotask 使用
pub const TimerState = struct {
    allocator: std.mem.Allocator,
    pending_timers: std.ArrayList(TimerEntry) = undefined,
    microtask_queue: std.ArrayList(MicrotaskEntry) = undefined,
    next_timer_id: u32 = 1,

    /// 使用给定 allocator 初始化定时器队列与微任务队列；预分配容量减少扩容（§1.3）
    pub fn init(allocator: std.mem.Allocator) !TimerState {
        return .{
            .allocator = allocator,
            .pending_timers = try std.ArrayList(TimerEntry).initCapacity(allocator, PENDING_TIMERS_INIT_CAP),
            .microtask_queue = try std.ArrayList(MicrotaskEntry).initCapacity(allocator, MICROTASK_QUEUE_INIT_CAP),
        };
    }

    /// 将微任务入队；callback 会在 runMicrotasks 中执行并 Unprotect，调用方需先 Protect
    pub fn enqueueMicrotask(self: *TimerState, ctx: jsc.JSGlobalContextRef, callback: jsc.JSValueRef) void {
        self.microtask_queue.append(self.allocator, .{ .ctx = ctx, .callback = callback }) catch {};
    }

    /// 执行当前队列中所有微任务（按入队顺序），执行后 Unprotect；若执行中再次入队则继续执行直到队列为空；应在 runLoop 前调用
    pub fn runMicrotasks(self: *TimerState, ctx: jsc.JSGlobalContextRef) void {
        const list = &self.microtask_queue;
        while (list.items.len > 0) {
            const e = list.orderedRemove(0);
            const empty_args: [0]jsc.JSValueRef = .{};
            _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(e.callback), null, 0, &empty_args, null);
            jsc.JSValueUnprotect(@ptrCast(e.ctx), e.callback);
        }
    }

    /// 释放所有定时器项与微任务（Unprotect 回调、free cron 表达式）并释放队列
    pub fn deinit(self: *TimerState) void {
        for (self.pending_timers.items) |*e| {
            jsc.JSValueUnprotect(@ptrCast(e.ctx), e.callback);
            if (e.cron_expression) |expr| self.allocator.free(expr);
        }
        self.pending_timers.deinit(self.allocator);
        for (self.microtask_queue.items) |e| {
            jsc.JSValueUnprotect(@ptrCast(e.ctx), e.callback);
        }
        self.microtask_queue.deinit(self.allocator);
    }

    /// 脚本执行结束后按 scheduled_at 执行到期回调，interval 重新入队
    pub fn runLoop(self: *TimerState, ctx: jsc.JSGlobalContextRef) void {
        while (self.pending_timers.items.len > 0) {
            const now = std.time.milliTimestamp();
            var i: usize = 0;
            var fired: bool = false;
            while (i < self.pending_timers.items.len) {
                const e = &self.pending_timers.items[i];
                if (e.cancelled) {
                    if (e.async_id != 0) async_ctx.emitDestroy(ctx, e.async_id);
                    jsc.JSValueUnprotect(@ptrCast(e.ctx), e.callback);
                    if (e.cron_expression) |expr| self.allocator.free(expr);
                    _ = self.pending_timers.orderedRemove(i);
                    continue;
                }
                if (now < e.scheduled_at) {
                    i += 1;
                    continue;
                }
                fired = true;
                var resource: jsc.JSValueRef = jsc.JSValueMakeUndefined(ctx);
                if (e.async_id != 0) {
                    const res_obj = jsc.JSObjectMake(ctx, null, null);
                    const k_type = jsc.JSStringCreateWithUTF8CString("type");
                    defer jsc.JSStringRelease(k_type);
                    const v_type = jsc.JSStringCreateWithUTF8CString("Timeout");
                    defer jsc.JSStringRelease(v_type);
                    _ = jsc.JSObjectSetProperty(ctx, res_obj, k_type, jsc.JSValueMakeString(ctx, v_type), jsc.kJSPropertyAttributeNone, null);
                    const k_id = jsc.JSStringCreateWithUTF8CString("id");
                    defer jsc.JSStringRelease(k_id);
                    _ = jsc.JSObjectSetProperty(ctx, res_obj, k_id, jsc.JSValueMakeNumber(ctx, @floatFromInt(e.id)), jsc.kJSPropertyAttributeNone, null);
                    resource = res_obj;
                    async_ctx.pushContext(ctx, e.async_id, e.trigger_async_id, resource);
                }
                const empty_args: [0]jsc.JSValueRef = .{};
                _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(e.callback), null, 0, &empty_args, null);
                if (e.async_id != 0) async_ctx.popContext(ctx);
                if (e.is_interval) {
                    e.scheduled_at = now + @as(i64, @intCast(e.ms));
                    i += 1;
                } else if (e.cron_expression) |expr| {
                    var parsed = cron.parse(self.allocator, expr) catch {
                        if (e.async_id != 0) async_ctx.emitDestroy(ctx, e.async_id);
                        jsc.JSValueUnprotect(@ptrCast(e.ctx), e.callback);
                        self.allocator.free(expr);
                        _ = self.pending_timers.orderedRemove(i);
                        continue;
                    };
                    defer parsed.deinit();
                    const from_sec = @divTrunc(now, 1000);
                    const next_sec = cron.nextRun(&parsed, from_sec);
                    if (next_sec) |ns| {
                        const next_ms = ns * 1000;
                        _ = self.pending_timers.append(self.allocator, .{
                            .id = e.id,
                            .ctx = e.ctx,
                            .callback = e.callback,
                            .ms = 0,
                            .is_interval = false,
                            .scheduled_at = next_ms,
                            .is_crond = true,
                            .cron_expression = expr,
                            .async_id = e.async_id,
                            .trigger_async_id = e.trigger_async_id,
                        }) catch {
                            jsc.JSValueUnprotect(@ptrCast(e.ctx), e.callback);
                            self.allocator.free(expr);
                        };
                    } else {
                        if (e.async_id != 0) async_ctx.emitDestroy(ctx, e.async_id);
                        jsc.JSValueUnprotect(@ptrCast(e.ctx), e.callback);
                        self.allocator.free(expr);
                    }
                    _ = self.pending_timers.orderedRemove(i);
                } else {
                    if (e.async_id != 0) async_ctx.emitDestroy(ctx, e.async_id);
                    jsc.JSValueUnprotect(@ptrCast(e.ctx), e.callback);
                    _ = self.pending_timers.orderedRemove(i);
                }
            }
            if (self.pending_timers.items.len == 0) break;
            if (!fired) {
                var next: i64 = std.math.maxInt(i64);
                for (self.pending_timers.items) |e| {
                    const d = e.scheduled_at - std.time.milliTimestamp();
                    if (d < next and d > 0) next = d;
                }
                if (next != std.math.maxInt(i64) and next > 0) std.Thread.sleep(@intCast(next * 1_000_000));
            }
        }
    }
};
