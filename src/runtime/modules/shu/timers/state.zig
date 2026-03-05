// 定时器队列与事件循环：TimerEntry、TimerState、runTimerLoop、微任务队列
// 供 engine.zig 持有并在 evaluate 后驱动，供 modules/shu/timers 回调入队
// 所有权：pending_timers/microtask_queue 由 TimerState 持有，deinit 时释放；TimerEntry.cron_expression 由 TimerState 在移除或 deinit 时 free。

const std = @import("std");
const builtin = @import("builtin");
const jsc = @import("jsc");
const errors = @import("errors");
const libs_process = @import("libs_process");
const globals = @import("../../../globals.zig");
const cron = @import("../crond/mod.zig");
const async_ctx = @import("../async/context.zig");
const run_loop_impl = switch (builtin.os.tag) {
    .macos => @import("run_loop_darwin.zig"),
    else => @import("run_loop_noop.zig"),
};

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

/// 定时器队列与 id 分配器；含微任务队列供 queueMicrotask 使用（01 §1.2：结构体内用 ArrayListUnmanaged 以利 Cache）
pub const TimerState = struct {
    allocator: std.mem.Allocator,
    pending_timers: std.ArrayListUnmanaged(TimerEntry) = .{},
    microtask_queue: std.ArrayListUnmanaged(MicrotaskEntry) = .{},
    next_timer_id: u32 = 1,

    /// 使用给定 allocator 初始化定时器队列与微任务队列；预分配容量减少扩容（§1.3）
    pub fn init(allocator: std.mem.Allocator) !TimerState {
        const pending = try std.ArrayListUnmanaged(TimerEntry).initCapacity(allocator, PENDING_TIMERS_INIT_CAP);
        const micro = try std.ArrayListUnmanaged(MicrotaskEntry).initCapacity(allocator, MICROTASK_QUEUE_INIT_CAP);
        return .{
            .allocator = allocator,
            .pending_timers = pending,
            .microtask_queue = micro,
        };
    }

    /// 将微任务入队；callback 会在 runMicrotasks 中执行并 Unprotect，调用方需先 Protect
    pub fn enqueueMicrotask(self: *TimerState, ctx: jsc.JSGlobalContextRef, callback: jsc.JSValueRef) void {
        self.microtask_queue.append(self.allocator, .{ .ctx = ctx, .callback = callback }) catch {};
    }

    /// 执行当前队列中所有微任务（按入队顺序），执行后 Unprotect；若执行中再次入队则继续执行直到队列为空；应在 runLoop 前调用。
    /// 先收割 fetch worker 完成项并 resolve 对应 Promise；再跑一次 RunLoop 迭代（macOS）以便 JSC 执行 Promise then/catch 微任务。
    pub fn runMicrotasks(self: *TimerState, ctx: jsc.JSGlobalContextRef) void {
        if (globals.drain_fetch_results) |drain| drain(ctx);
        const list = &self.microtask_queue;
        while (list.items.len > 0) {
            const e = list.orderedRemove(0);
            // 仅当 callback 为有效函数时调用，避免 undefined/null 等 tagged 值当指针传入导致 segfault
            if (!jsc.JSValueIsUndefined(ctx, e.callback) and !jsc.JSValueIsNull(ctx, e.callback) and jsc.JSObjectIsFunction(ctx, @ptrCast(e.callback))) {
                const empty_args: [0]jsc.JSValueRef = .{};
                _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(e.callback), null, 0, &empty_args, null);
            }
            jsc.JSValueUnprotect(@ptrCast(e.ctx), e.callback);
        }
        run_loop_impl.runOneIteration();
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

    /// 返回当前时间（毫秒，用于与 scheduled_at 比较）；有 process io 用 Io.Clock；
    /// 无 io 时返回足够大值使已入队定时器均视为到期，避免 run 脚本（如 load.js）
    /// 无 io 时 runLoop 直接 return 导致 setTimeout 永不触发（Zig 0.16 已移除 std.time.nanoTimestamp，故不做真实时钟 fallback）
    fn nowMs(self: *const TimerState) i64 {
        _ = self;
        if (libs_process.getProcessIo()) |io| {
            return @as(i64, @intCast(@divTrunc(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds, 1_000_000)));
        }
        return std.math.maxInt(i64);
    }

    /// 脚本执行结束后按 scheduled_at 执行到期回调，interval 重新入队；无 process io 时仍用 std.time 取时与 sleep，保证 setTimeout/setInterval 可跑完（如 bench load 客户端）
    pub fn runLoop(self: *TimerState, ctx: jsc.JSGlobalContextRef) void {
        while (self.pending_timers.items.len > 0) {
            const now = self.nowMs();
            var i: usize = 0;
            var fired: bool = false;
            while (i < self.pending_timers.items.len) {
                const e = &self.pending_timers.items[i];
                // 复制一份，避免 runMicrotasks/回调内修改 pending_timers 导致 e 悬空（0xaa 毒化）
                const entry_ctx = e.ctx;
                const entry_callback = e.callback;
                const entry_id = e.id;
                const entry_async_id = e.async_id;
                const entry_trigger_async_id = e.trigger_async_id;
                const entry_is_interval = e.is_interval;
                const entry_ms = e.ms;
                const entry_cron_expression = e.cron_expression;
                if (e.cancelled) {
                    if (entry_async_id != 0) async_ctx.emitDestroy(ctx, entry_async_id);
                    jsc.JSValueUnprotect(@ptrCast(entry_ctx), entry_callback);
                    if (entry_cron_expression) |expr| self.allocator.free(expr);
                    _ = self.pending_timers.orderedRemove(i);
                    continue;
                }
                if (now < e.scheduled_at) {
                    i += 1;
                    continue;
                }
                fired = true;
                var resource: jsc.JSValueRef = jsc.JSValueMakeUndefined(ctx);
                if (entry_async_id != 0) {
                    const res_obj = jsc.JSObjectMake(ctx, null, null);
                    const k_type = jsc.JSStringCreateWithUTF8CString("type");
                    defer jsc.JSStringRelease(k_type);
                    const v_type = jsc.JSStringCreateWithUTF8CString("Timeout");
                    defer jsc.JSStringRelease(v_type);
                    _ = jsc.JSObjectSetProperty(ctx, res_obj, k_type, jsc.JSValueMakeString(ctx, v_type), jsc.kJSPropertyAttributeNone, null);
                    const k_id = jsc.JSStringCreateWithUTF8CString("id");
                    defer jsc.JSStringRelease(k_id);
                    _ = jsc.JSObjectSetProperty(ctx, res_obj, k_id, jsc.JSValueMakeNumber(ctx, @floatFromInt(entry_id)), jsc.kJSPropertyAttributeNone, null);
                    resource = res_obj;
                    async_ctx.pushContext(ctx, entry_async_id, entry_trigger_async_id, resource);
                }
                // 仅当 callback 为有效函数时调用，避免无效指针导致 segfault（与 getOptionalCallback 同理）
                const empty_args: [0]jsc.JSValueRef = .{};
                if (!jsc.JSValueIsUndefined(ctx, entry_callback) and !jsc.JSValueIsNull(ctx, entry_callback) and jsc.JSObjectIsFunction(ctx, @ptrCast(entry_callback)))
                    _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(entry_callback), null, 0, &empty_args, null);
                if (entry_async_id != 0) async_ctx.popContext(ctx);
                // interval 在 runMicrotasks 前更新列表项，避免 runMicrotasks 内修改列表导致 e 悬空
                if (entry_is_interval) {
                    e.scheduled_at = now + @as(i64, @intCast(entry_ms));
                    i += 1;
                }
                // 每轮 timer 回调后排空微任务，使 Promise.then（如 fetch 完成）在本轮 runLoop 内执行，脚本仅 run 无 server 时也能跑完 async/await
                self.runMicrotasks(ctx);
                if (entry_is_interval) {
                    continue;
                }
                // runMicrotasks 可能已修改列表，按 id 查找再移除，避免 index 失效导致 index out of bounds
                const remove_idx = blk: {
                    for (self.pending_timers.items, 0..) |item, idx| {
                        if (item.id == entry_id) break :blk idx;
                    }
                    break :blk null;
                };
                if (entry_cron_expression) |expr| {
                    var parsed = cron.parse(self.allocator, expr) catch {
                        if (entry_async_id != 0) async_ctx.emitDestroy(ctx, entry_async_id);
                        jsc.JSValueUnprotect(@ptrCast(entry_ctx), entry_callback);
                        self.allocator.free(expr);
                        if (remove_idx) |idx| _ = self.pending_timers.orderedRemove(idx);
                        continue;
                    };
                    defer parsed.deinit();
                    const from_sec = @divTrunc(now, 1000);
                    const next_sec = cron.nextRun(&parsed, from_sec);
                    if (next_sec) |ns| {
                        const next_ms = ns * 1000;
                        _ = self.pending_timers.append(self.allocator, .{
                            .id = entry_id,
                            .ctx = entry_ctx,
                            .callback = entry_callback,
                            .ms = 0,
                            .is_interval = false,
                            .scheduled_at = next_ms,
                            .is_crond = true,
                            .cron_expression = expr,
                            .async_id = entry_async_id,
                            .trigger_async_id = entry_trigger_async_id,
                        }) catch {
                            jsc.JSValueUnprotect(@ptrCast(entry_ctx), entry_callback);
                            self.allocator.free(expr);
                        };
                    } else {
                        if (entry_async_id != 0) async_ctx.emitDestroy(ctx, entry_async_id);
                        jsc.JSValueUnprotect(@ptrCast(entry_ctx), entry_callback);
                        self.allocator.free(expr);
                    }
                    if (remove_idx) |idx| _ = self.pending_timers.orderedRemove(idx);
                } else {
                    if (entry_async_id != 0) async_ctx.emitDestroy(ctx, entry_async_id);
                    jsc.JSValueUnprotect(@ptrCast(entry_ctx), entry_callback);
                    if (remove_idx) |idx| _ = self.pending_timers.orderedRemove(idx);
                }
            }
            if (self.pending_timers.items.len == 0) break;
            if (!fired) {
                const now_ms = self.nowMs();
                var next: i64 = std.math.maxInt(i64);
                for (self.pending_timers.items) |e| {
                    const d = e.scheduled_at - now_ms;
                    if (d < next and d > 0) next = d;
                }
                if (next != std.math.maxInt(i64) and next > 0) {
                    const sleep_ns: u64 = @intCast(next * 1_000_000);
                    if (libs_process.getProcessIo()) |io| {
                        std.Io.sleep(io, .{ .nanoseconds = sleep_ns }, .real) catch {};
                    }
                    // 无 io 时 nowMs 已返回 maxInt，理论上不会走到“未到期需 sleep”分支；若走到则跳过 sleep 避免依赖已移除的 std.time.sleep
                }
            }
        }
    }
};
