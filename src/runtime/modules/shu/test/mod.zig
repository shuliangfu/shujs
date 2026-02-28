// shu:test — 与 node:test API 兼容的测试运行器，支持 describe/it、beforeAll/afterAll、skip/skipIf/todo/only、run
// 纯 Zig 维护 suite/test 树与执行状态机，run() 时纯 Zig 调用 JSC 执行钩子/测试并处理 Promise，无内联 JS

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");
const runner = @import("runner.zig");

// 模块级 runner 实例，getExports 时创建，进程内复用
var g_runner: ?*runner.RunnerState = null;
/// run() 执行期状态，advance 回调内访问
var g_run_state: ?*RunState = null;

/// 单次执行（钩子或测试）的返回值：value 为 thenable 时走 Promise 链，defer_advance 为 true 时等 t.done()
const JobResult = struct { value: jsc.JSValueRef, defer_advance: bool };

const RunState = struct {
    ctx: jsc.JSContextRef,
    allocator: std.mem.Allocator,
    jobs: std.ArrayList(runner.Job),
    job_index: usize,
    resolve_ref: jsc.JSValueRef,
    reject_ref: jsc.JSValueRef,
    has_only: bool,

    fn runNext(state: *RunState) void {
        if (state.job_index >= state.jobs.items.len) {
            var no_args: [0]jsc.JSValueRef = undefined;
            _ = jsc.JSObjectCallAsFunction(state.ctx, @ptrCast(state.resolve_ref), null, 0, &no_args, null);
            state.jobs.deinit(state.allocator);
            state.allocator.destroy(state);
            g_run_state = null;
            return;
        }
        const result = runCurrentJob(state);
        state.job_index += 1;
        if (result.defer_advance) {
            // 回调风格测试 (t.done)：不调度，等用户调 t.done() 时触发 advance
        } else if (isThenable(state.ctx, result.value)) {
            thenChain(state.ctx, result.value, state);
        } else {
            scheduleAdvance(state.ctx);
        }
    }

    fn runCurrentJob(state: *RunState) JobResult {
        const job = state.jobs.items[state.job_index];
        if (job == .before_all) {
            const p = job.before_all;
            const v = callHook(state.ctx, p.suite.before_all.items[p.idx]);
            return .{ .value = v, .defer_advance = false };
        } else if (job == .after_all) {
            const p = job.after_all;
            const v = callHook(state.ctx, p.suite.after_all.items[p.idx]);
            return .{ .value = v, .defer_advance = false };
        } else if (job == .before_each) {
            const p = job.before_each;
            const v = callHook(state.ctx, p.suite.before_each.items[p.idx]);
            return .{ .value = v, .defer_advance = false };
        } else if (job == .after_each) {
            const p = job.after_each;
            const v = callHook(state.ctx, p.suite.after_each.items[p.idx]);
            return .{ .value = v, .defer_advance = false };
        } else {
            const p = job.run_test;
            return runTestJob(state.ctx, p.suite, p.test_idx, state.has_only);
        }
    }
};

fn callHook(ctx: jsc.JSContextRef, fn_ref: jsc.JSValueRef) jsc.JSValueRef {
    var no_args: [0]jsc.JSValueRef = undefined;
    return jsc.JSObjectCallAsFunction(ctx, @ptrCast(fn_ref), null, 0, &no_args, null);
}

fn runTestJob(ctx: jsc.JSContextRef, suite: *runner.Suite, test_idx: usize, has_only: bool) JobResult {
    const t_entry = &suite.tests.items[test_idx];
    if (t_entry.skip) return .{ .value = jsc.JSValueMakeUndefined(ctx), .defer_advance = false };
    if (t_entry.skip_if_ref) |skip_if| {
        const cond = if (jsc.JSObjectIsFunction(ctx, @ptrCast(skip_if)))
            blk: {
                var no_args: [0]jsc.JSValueRef = undefined;
                break :blk jsc.JSObjectCallAsFunction(ctx, @ptrCast(skip_if), null, 0, &no_args, null);
            }
        else
            skip_if;
        if (!jsc.JSValueIsUndefined(ctx, cond) and !jsc.JSValueIsNull(ctx, cond) and jsc.JSValueToBoolean(ctx, cond))
            return .{ .value = jsc.JSValueMakeUndefined(ctx), .defer_advance = false };
    }
    if (has_only and !t_entry.only) return .{ .value = jsc.JSValueMakeUndefined(ctx), .defer_advance = false };
    const t_ctx = jsc.JSObjectMake(ctx, null, null);
    const k_done = jsc.JSStringCreateWithUTF8CString("done");
    defer jsc.JSStringRelease(k_done);
    const advance = getAdvanceFn(ctx);
    _ = jsc.JSObjectSetProperty(ctx, t_ctx, k_done, advance, jsc.kJSPropertyAttributeNone, null);
    var args = [_]jsc.JSValueRef{ t_ctx };
    const ret = jsc.JSObjectCallAsFunction(ctx, @ptrCast(t_entry.fn_ref), null, 1, &args, null);
    if (t_entry.todo) return .{ .value = jsc.JSValueMakeUndefined(ctx), .defer_advance = false };
    const defer_advance = jsc.JSValueIsUndefined(ctx, ret) and !isThenable(ctx, ret);
    return .{ .value = ret, .defer_advance = defer_advance };
}

fn getAdvanceFn(ctx: jsc.JSContextRef) jsc.JSValueRef {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k = jsc.JSStringCreateWithUTF8CString("__shu_test_advance");
    defer jsc.JSStringRelease(k);
    return jsc.JSObjectGetProperty(ctx, global, k, null);
}

fn scheduleAdvance(ctx: jsc.JSContextRef) void {
    const advance = getAdvanceFn(ctx);
    if (jsc.JSObjectIsFunction(ctx, @ptrCast(advance))) {
        var no_args: [0]jsc.JSValueRef = undefined;
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(advance), null, 0, &no_args, null);
    }
}

fn isThenable(ctx: jsc.JSContextRef, val: jsc.JSValueRef) bool {
    if (jsc.JSValueIsUndefined(ctx, val) or jsc.JSValueIsNull(ctx, val)) return false;
    const obj = jsc.JSValueToObject(ctx, val, null) orelse return false;
    const k_then = jsc.JSStringCreateWithUTF8CString("then");
    defer jsc.JSStringRelease(k_then);
    const then_val = jsc.JSObjectGetProperty(ctx, obj, k_then, null);
    return jsc.JSObjectIsFunction(ctx, @ptrCast(then_val));
}

/// Promise.then(advance, rejectWrapper)：成功时 advance 继续下一 job，失败时 wrapper 设 process.exitCode 并调 reject
fn thenChain(ctx: jsc.JSContextRef, promise: jsc.JSValueRef, state: *RunState) void {
    _ = state;
    const obj = jsc.JSValueToObject(ctx, promise, null) orelse return;
    const k_then = jsc.JSStringCreateWithUTF8CString("then");
    defer jsc.JSStringRelease(k_then);
    const then_fn = jsc.JSObjectGetProperty(ctx, obj, k_then, null);
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(then_fn))) return;
    const advance = getAdvanceFn(ctx);
    const reject_wrapper = getRejectWrapper(ctx);
    var args = [_]jsc.JSValueRef{ advance, reject_wrapper };
    _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(then_fn), @ptrCast(promise), 2, &args, null);
}

fn advanceCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const state = g_run_state orelse return jsc.JSValueMakeUndefined(ctx);
    RunState.runNext(state);
    return jsc.JSValueMakeUndefined(ctx);
}

fn getOrCreateRunner(allocator: std.mem.Allocator) ?*runner.RunnerState {
    if (g_runner) |r| return r;
    g_runner = runner.RunnerState.create(allocator) catch return null;
    return g_runner;
}

/// 从 JS 值取字符串到 Zig 堆，调用方负责 free
fn jsValueToUtf8Alloc(ctx: jsc.JSContextRef, allocator: std.mem.Allocator, val: jsc.JSValueRef) ?[]const u8 {
    if (jsc.JSValueIsUndefined(ctx, val) or jsc.JSValueIsNull(ctx, val)) return null;
    const str_ref = jsc.JSValueToStringCopy(ctx, val, null);
    defer jsc.JSStringRelease(str_ref);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(str_ref);
    if (max_sz == 0 or max_sz > 4096) return null;
    const buf = allocator.alloc(u8, max_sz) catch return null;
    const n = jsc.JSStringGetUTF8CString(str_ref, buf.ptr, max_sz);
    if (n == 0) {
        allocator.free(buf);
        return null;
    }
    return allocator.dupe(u8, buf[0 .. n - 1]) catch {
        allocator.free(buf);
        return null;
    };
}

/// describe(name, fn)：注册一个 suite，执行 fn(suiteCtx)，suiteCtx 上有 it/test/beforeAll/afterAll/beforeEach/afterEach
fn describeCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const r = getOrCreateRunner(allocator) orelse return jsc.JSValueMakeUndefined(ctx);
    const name_slice = jsValueToUtf8Alloc(ctx, allocator, arguments[0]) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(name_slice);
    const fn_val = arguments[1];
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(fn_val))) return jsc.JSValueMakeUndefined(ctx);

    const parent = r.currentSuite() orelse &r.root;
    const child = allocator.create(runner.Suite) catch return jsc.JSValueMakeUndefined(ctx);
    child.* = .{
        .name = allocator.dupe(u8, name_slice) catch {
            allocator.destroy(child);
            return jsc.JSValueMakeUndefined(ctx);
        },
        .parent = parent,
        .children = std.ArrayList(*runner.Suite).initCapacity(allocator, 0) catch return jsc.JSValueMakeUndefined(ctx),
        .tests = std.ArrayList(runner.TestEntry).initCapacity(allocator, 0) catch return jsc.JSValueMakeUndefined(ctx),
        .before_all = std.ArrayList(jsc.JSValueRef).initCapacity(allocator, 0) catch return jsc.JSValueMakeUndefined(ctx),
        .after_all = std.ArrayList(jsc.JSValueRef).initCapacity(allocator, 0) catch return jsc.JSValueMakeUndefined(ctx),
        .before_each = std.ArrayList(jsc.JSValueRef).initCapacity(allocator, 0) catch return jsc.JSValueMakeUndefined(ctx),
        .after_each = std.ArrayList(jsc.JSValueRef).initCapacity(allocator, 0) catch return jsc.JSValueMakeUndefined(ctx),
        .allocator = allocator,
    };
    parent.children.append(allocator, child) catch {
        allocator.free(child.name);
        child.children.deinit(allocator);
        child.tests.deinit(allocator);
        child.before_all.deinit(allocator);
        child.after_all.deinit(allocator);
        child.before_each.deinit(allocator);
        child.after_each.deinit(allocator);
        allocator.destroy(child);
        return jsc.JSValueMakeUndefined(ctx);
    };

    r.pushSuite(child);
    defer r.popSuite();

    const suite_ctx = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, suite_ctx, "it", itCallback);
    common.setMethod(ctx, suite_ctx, "test", itCallback);
    common.setMethod(ctx, suite_ctx, "beforeAll", beforeAllCallback);
    common.setMethod(ctx, suite_ctx, "afterAll", afterAllCallback);
    common.setMethod(ctx, suite_ctx, "beforeEach", beforeEachCallback);
    common.setMethod(ctx, suite_ctx, "afterEach", afterEachCallback);
    common.setMethod(ctx, suite_ctx, "describe", describeCallback);

    var args = [_]jsc.JSValueRef{ suite_ctx };
    _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(fn_val), null, 1, &args, null);
    return jsc.JSValueMakeUndefined(ctx);
}

/// it(name [, options], fn) / test(name [, options], fn)：注册一条测试到当前 suite；options 支持 skip/todo/only/skipIf
fn itCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const r = getOrCreateRunner(allocator) orelse return jsc.JSValueMakeUndefined(ctx);
    const suite = r.currentSuite() orelse &r.root;
    const name_slice = jsValueToUtf8Alloc(ctx, allocator, arguments[0]) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(name_slice);

    var fn_val: jsc.JSValueRef = undefined;
    var skip: bool = false;
    var skip_message: ?[]const u8 = null;
    var todo: bool = false;
    var todo_message: ?[]const u8 = null;
    var only: bool = false;
    var skip_if_ref: ?jsc.JSValueRef = null;

    if (argumentCount == 2) {
        fn_val = arguments[1];
    } else {
        const second = arguments[1];
        if (jsc.JSObjectIsFunction(ctx, @ptrCast(second))) {
            fn_val = second;
        } else if (jsc.JSValueToObject(ctx, second, null)) |opts_obj| {
            fn_val = arguments[2];
            const k_skip = jsc.JSStringCreateWithUTF8CString("skip");
            defer jsc.JSStringRelease(k_skip);
            const k_todo = jsc.JSStringCreateWithUTF8CString("todo");
            defer jsc.JSStringRelease(k_todo);
            const k_only = jsc.JSStringCreateWithUTF8CString("only");
            defer jsc.JSStringRelease(k_only);
            const k_skipIf = jsc.JSStringCreateWithUTF8CString("skipIf");
            defer jsc.JSStringRelease(k_skipIf);
            const v_skip = jsc.JSObjectGetProperty(ctx, opts_obj, k_skip, null);
            const v_todo = jsc.JSObjectGetProperty(ctx, opts_obj, k_todo, null);
            const v_only = jsc.JSObjectGetProperty(ctx, opts_obj, k_only, null);
            const v_skip_if = jsc.JSObjectGetProperty(ctx, opts_obj, k_skipIf, null);
            skip = !jsc.JSValueIsUndefined(ctx, v_skip) and jsc.JSValueToBoolean(ctx, v_skip);
            if (skip) {
                const msg = jsValueToUtf8Alloc(ctx, allocator, v_skip);
                if (msg) |m| {
                    defer allocator.free(m);
                    if (!std.mem.eql(u8, m, "true") and !std.mem.eql(u8, m, "false")) skip_message = allocator.dupe(u8, m) catch null;
                }
            }
            todo = !jsc.JSValueIsUndefined(ctx, v_todo) and jsc.JSValueToBoolean(ctx, v_todo);
            if (todo) {
                const msg = jsValueToUtf8Alloc(ctx, allocator, v_todo);
                if (msg) |m| {
                    defer allocator.free(m);
                    if (!std.mem.eql(u8, m, "true") and !std.mem.eql(u8, m, "false")) todo_message = allocator.dupe(u8, m) catch null;
                }
            }
            only = !jsc.JSValueIsUndefined(ctx, v_only) and jsc.JSValueToBoolean(ctx, v_only);
            if (!jsc.JSValueIsUndefined(ctx, v_skip_if)) skip_if_ref = v_skip_if;
        } else {
            fn_val = arguments[1];
        }
    }
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(fn_val))) return jsc.JSValueMakeUndefined(ctx);
    if (only) r.has_only = true;

    defer if (skip_message) |s| allocator.free(s);
    defer if (todo_message) |s| allocator.free(s);
    const entry = runner.TestEntry{
        .name = allocator.dupe(u8, name_slice) catch return jsc.JSValueMakeUndefined(ctx),
        .fn_ref = fn_val,
        .skip = skip,
        .skip_message = if (skip_message) |s| allocator.dupe(u8, s) catch null else null,
        .todo = todo,
        .todo_message = if (todo_message) |s| allocator.dupe(u8, s) catch null else null,
        .only = only,
        .skip_if_ref = skip_if_ref,
    };
    suite.tests.append(suite.allocator, entry) catch {
        allocator.free(entry.name);
        if (entry.skip_message) |s| allocator.free(s);
        if (entry.todo_message) |s| allocator.free(s);
        return jsc.JSValueMakeUndefined(ctx);
    };
    return jsc.JSValueMakeUndefined(ctx);
}

fn beforeAllCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1 or !jsc.JSObjectIsFunction(ctx, @ptrCast(arguments[0]))) return jsc.JSValueMakeUndefined(ctx);
    const r = getOrCreateRunner(globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx)) orelse return jsc.JSValueMakeUndefined(ctx);
    const suite = r.currentSuite() orelse &r.root;
    suite.before_all.append(suite.allocator, arguments[0]) catch return jsc.JSValueMakeUndefined(ctx);
    return jsc.JSValueMakeUndefined(ctx);
}

fn afterAllCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1 or !jsc.JSObjectIsFunction(ctx, @ptrCast(arguments[0]))) return jsc.JSValueMakeUndefined(ctx);
    const r = getOrCreateRunner(globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx)) orelse return jsc.JSValueMakeUndefined(ctx);
    const suite = r.currentSuite() orelse &r.root;
    suite.after_all.append(suite.allocator, arguments[0]) catch return jsc.JSValueMakeUndefined(ctx);
    return jsc.JSValueMakeUndefined(ctx);
}

fn beforeEachCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1 or !jsc.JSObjectIsFunction(ctx, @ptrCast(arguments[0]))) return jsc.JSValueMakeUndefined(ctx);
    const r = getOrCreateRunner(globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx)) orelse return jsc.JSValueMakeUndefined(ctx);
    const suite = r.currentSuite() orelse &r.root;
    suite.before_each.append(suite.allocator, arguments[0]) catch return jsc.JSValueMakeUndefined(ctx);
    return jsc.JSValueMakeUndefined(ctx);
}

fn afterEachCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1 or !jsc.JSObjectIsFunction(ctx, @ptrCast(arguments[0]))) return jsc.JSValueMakeUndefined(ctx);
    const r = getOrCreateRunner(globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx)) orelse return jsc.JSValueMakeUndefined(ctx);
    const suite = r.currentSuite() orelse &r.root;
    suite.after_each.append(suite.allocator, arguments[0]) catch return jsc.JSValueMakeUndefined(ctx);
    return jsc.JSValueMakeUndefined(ctx);
}

/// Promise 的 executor：接收 (resolve, reject)，构建任务队列、RunState，启动 runNext
fn runExecutorCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const r = getOrCreateRunner(allocator) orelse return jsc.JSValueMakeUndefined(ctx);
    var jobs = runner.buildJobList(allocator, &r.root, r.has_only);
    const state = allocator.create(RunState) catch {
        jobs.deinit(allocator);
        return jsc.JSValueMakeUndefined(ctx);
    };
    state.* = .{
        .ctx = ctx,
        .allocator = allocator,
        .jobs = jobs,
        .job_index = 0,
        .resolve_ref = arguments[0],
        .reject_ref = arguments[1],
        .has_only = r.has_only,
    };
    g_run_state = state;
    RunState.runNext(state);
    return jsc.JSValueMakeUndefined(ctx);
}

/// 失败时设 process.exitCode = 1 并调用原始 reject
fn rejectWrapperCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const state = g_run_state orelse return jsc.JSValueMakeUndefined(ctx);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_process = jsc.JSStringCreateWithUTF8CString("process");
    defer jsc.JSStringRelease(k_process);
    const process_val = jsc.JSObjectGetProperty(ctx, global, k_process, null);
    if (!jsc.JSValueIsUndefined(ctx, process_val)) {
        if (jsc.JSValueToObject(ctx, process_val, null)) |process_obj| {
            const k_exit = jsc.JSStringCreateWithUTF8CString("exitCode");
            defer jsc.JSStringRelease(k_exit);
            _ = jsc.JSObjectSetProperty(ctx, process_obj, k_exit, jsc.JSValueMakeNumber(ctx, 1), jsc.kJSPropertyAttributeNone, null);
        }
    }
    const err = if (argumentCount >= 1) arguments[0] else jsc.JSValueMakeUndefined(ctx);
    var args = [_]jsc.JSValueRef{ err };
    _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(state.reject_ref), null, 1, &args, null);
    return jsc.JSValueMakeUndefined(ctx);
}

fn getRejectWrapper(ctx: jsc.JSContextRef) jsc.JSValueRef {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k = jsc.JSStringCreateWithUTF8CString("__shu_test_reject_wrapper");
    defer jsc.JSStringRelease(k);
    return jsc.JSObjectGetProperty(ctx, global, k, null);
}

/// run()：纯 Zig 构建任务队列，用 Promise(executor) 启动，返回 Promise；失败时 reject 并设 process.exitCode = 1
fn runCallback(
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
    const k_promise = jsc.JSStringCreateWithUTF8CString("Promise");
    defer jsc.JSStringRelease(k_promise);
    const promise_ctor = jsc.JSObjectGetProperty(ctx, global, k_promise, null);
    if (jsc.JSValueIsUndefined(ctx, promise_ctor)) return jsc.JSValueMakeUndefined(ctx);
    const k_executor = jsc.JSStringCreateWithUTF8CString("");
    defer jsc.JSStringRelease(k_executor);
    const executor_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_executor, runExecutorCallback);
    var args = [_]jsc.JSValueRef{ executor_fn };
    return jsc.JSObjectCallAsConstructor(ctx, @ptrCast(promise_ctor), 1, &args, null);
}

/// test.skip(name [, options], fn) / it.skip(...)：等价于 test(name, { ...options, skip: true }, fn)
fn skipCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    _ = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const opts = jsc.JSObjectMake(ctx, null, null);
    const k_skip = jsc.JSStringCreateWithUTF8CString("skip");
    defer jsc.JSStringRelease(k_skip);
    _ = jsc.JSObjectSetProperty(ctx, opts, k_skip, jsc.JSValueMakeBoolean(ctx, true), jsc.kJSPropertyAttributeNone, null);
    var args: [3]jsc.JSValueRef = undefined;
    args[0] = arguments[0];
    args[1] = opts;
    args[2] = arguments[1];
    if (argumentCount >= 3) {
        args[1] = arguments[1];
        args[2] = arguments[2];
    }
    const global = jsc.JSContextGetGlobalObject(ctx);
    var exc_buf: [1]jsc.JSValueRef = undefined;
    return itCallback(ctx, global, global, 3, &args, exc_buf[0..].ptr);
}

/// test.todo(name [, options], fn) / it.todo(...)：等价于 test(name, { ...options, todo: true }, fn)
fn todoCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const opts = jsc.JSObjectMake(ctx, null, null);
    const k_todo = jsc.JSStringCreateWithUTF8CString("todo");
    defer jsc.JSStringRelease(k_todo);
    _ = jsc.JSObjectSetProperty(ctx, opts, k_todo, jsc.JSValueMakeBoolean(ctx, true), jsc.kJSPropertyAttributeNone, null);
    var args: [3]jsc.JSValueRef = undefined;
    args[0] = arguments[0];
    args[1] = opts;
    args[2] = arguments[1];
    if (argumentCount >= 3) {
        args[1] = arguments[1];
        args[2] = arguments[2];
    }
    const global = jsc.JSContextGetGlobalObject(ctx);
    var exc_buf: [1]jsc.JSValueRef = undefined;
    return itCallback(ctx, global, global, 3, &args, exc_buf[0..].ptr);
}

/// test.only(name [, options], fn) / it.only(...)：仅运行该测试（需配合 run 时 has_only）
fn onlyCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const opts = jsc.JSObjectMake(ctx, null, null);
    const k_only = jsc.JSStringCreateWithUTF8CString("only");
    defer jsc.JSStringRelease(k_only);
    _ = jsc.JSObjectSetProperty(ctx, opts, k_only, jsc.JSValueMakeBoolean(ctx, true), jsc.kJSPropertyAttributeNone, null);
    var args: [3]jsc.JSValueRef = undefined;
    args[0] = arguments[0];
    args[1] = opts;
    args[2] = arguments[1];
    if (argumentCount >= 3) {
        args[1] = arguments[1];
        args[2] = arguments[2];
    }
    const global = jsc.JSContextGetGlobalObject(ctx);
    var exc_buf: [1]jsc.JSValueRef = undefined;
    return itCallback(ctx, global, global, 3, &args, exc_buf[0..].ptr);
}

/// test.skipIf(condition)(name, fn)：条件为真时跳过；返回的函数通过 JS 闭包捕获 condition，调用时等价于 it(name, { skipIf: condition }, fn)
fn skipIfCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const condition = arguments[0];
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const script_z = allocator.dupeZ(u8,
        "(function(cond){ var it = globalThis.__shu_test_exports && globalThis.__shu_test_exports.it; return function(name, optsOrFn, fn){ var opts = (typeof optsOrFn === 'function') ? { skipIf: cond } : (function(){ var o = {}; for(var k in optsOrFn) o[k]=optsOrFn[k]; o.skipIf=cond; return o; })(); return it ? it(name, opts, typeof optsOrFn === 'function' ? optsOrFn : fn) : undefined; }; })") catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(script_z);
    const script_ref = jsc.JSStringCreateWithUTF8CString(script_z.ptr);
    defer jsc.JSStringRelease(script_ref);
    const factory = jsc.JSEvaluateScript(ctx, script_ref, null, null, 1, null);
    if (jsc.JSValueIsUndefined(ctx, factory)) return jsc.JSValueMakeUndefined(ctx);
    var args = [_]jsc.JSValueRef{condition};
    return jsc.JSObjectCallAsFunction(ctx, @ptrCast(factory), null, 1, &args, null);
}

/// mock：占位，与 node:test mock 兼容；后续可实现 fn/method/timers
fn mockCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    _ = argumentCount;
    _ = arguments;
    const obj = jsc.JSObjectMake(ctx, null, null);
    const k_fn = jsc.JSStringCreateWithUTF8CString("fn");
    defer jsc.JSStringRelease(k_fn);
    common.setMethod(ctx, obj, "fn", node_compat.notImplementedCallback);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_fn, jsc.JSObjectMakeFunctionWithCallback(ctx, k_fn, node_compat.notImplementedCallback), jsc.kJSPropertyAttributeNone, null);
    return obj;
}

/// snapshot：占位，与 node:test snapshot 兼容
fn snapshotCallback(
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
    var no_args: [0]jsc.JSValueRef = undefined;
    var exc_buf: [1]jsc.JSValueRef = undefined;
    return node_compat.notImplementedCallback(ctx, global, global, 0, @as([*]const jsc.JSValueRef, @ptrCast(&no_args)), exc_buf[0..].ptr);
}

const node_compat = @import("../node_compat/mod.zig");

/// 返回 shu:test 的完整 exports：describe、it、test（可调用且带 .skip/.todo/.only/.skipIf）、beforeAll、afterAll、beforeEach、afterEach、run、mock、snapshot；默认导出为 it
pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    _ = getOrCreateRunner(allocator);
    const obj = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, obj, "describe", describeCallback);
    common.setMethod(ctx, obj, "beforeAll", beforeAllCallback);
    common.setMethod(ctx, obj, "afterAll", afterAllCallback);
    common.setMethod(ctx, obj, "beforeEach", beforeEachCallback);
    common.setMethod(ctx, obj, "afterEach", afterEachCallback);
    common.setMethod(ctx, obj, "run", runCallback);
    common.setMethod(ctx, obj, "mock", mockCallback);
    common.setMethod(ctx, obj, "snapshot", snapshotCallback);

    const k_it = jsc.JSStringCreateWithUTF8CString("it");
    defer jsc.JSStringRelease(k_it);
    const k_test = jsc.JSStringCreateWithUTF8CString("test");
    defer jsc.JSStringRelease(k_test);
    const it_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_it, itCallback);
    common.setMethod(ctx, it_fn, "skip", skipCallback);
    common.setMethod(ctx, it_fn, "todo", todoCallback);
    common.setMethod(ctx, it_fn, "only", onlyCallback);
    common.setMethod(ctx, it_fn, "skipIf", skipIfCallback);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_it, it_fn, jsc.kJSPropertyAttributeNone, null);

    const test_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_test, itCallback);
    common.setMethod(ctx, test_fn, "skip", skipCallback);
    common.setMethod(ctx, test_fn, "todo", todoCallback);
    common.setMethod(ctx, test_fn, "only", onlyCallback);
    common.setMethod(ctx, test_fn, "skipIf", skipIfCallback);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_test, test_fn, jsc.kJSPropertyAttributeNone, null);

    const k_default = jsc.JSStringCreateWithUTF8CString("default");
    defer jsc.JSStringRelease(k_default);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_default, test_fn, jsc.kJSPropertyAttributeNone, null);

    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_exports = jsc.JSStringCreateWithUTF8CString("__shu_test_exports");
    defer jsc.JSStringRelease(k_exports);
    _ = jsc.JSObjectSetProperty(ctx, global, k_exports, obj, jsc.kJSPropertyAttributeNone, null);
    const k_advance = jsc.JSStringCreateWithUTF8CString("__shu_test_advance");
    defer jsc.JSStringRelease(k_advance);
    _ = jsc.JSObjectSetProperty(ctx, global, k_advance, jsc.JSObjectMakeFunctionWithCallback(ctx, k_advance, advanceCallback), jsc.kJSPropertyAttributeNone, null);
    const k_reject_wrapper = jsc.JSStringCreateWithUTF8CString("__shu_test_reject_wrapper");
    defer jsc.JSStringRelease(k_reject_wrapper);
    _ = jsc.JSObjectSetProperty(ctx, global, k_reject_wrapper, jsc.JSObjectMakeFunctionWithCallback(ctx, k_reject_wrapper, rejectWrapperCallback), jsc.kJSPropertyAttributeNone, null);
    return obj;
}
