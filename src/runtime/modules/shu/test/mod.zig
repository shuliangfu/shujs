//! # shu:test — Node.js test runner 兼容模块
//!
//! 与 **node:test** API 对齐的测试运行器，供 `require('shu:test')` 使用。suite/test 树、执行状态机、
//! 钩子与测试调度、Promise 链、assert 与 options 合并等逻辑**全部在 Zig 中实现**，不执行任何内联 JS 脚本。
//!
//! ## 与 Node / Deno / Bun 兼容
//!
//! - **Node (node:test)**：describe/it/test、beforeAll/afterAll/beforeEach/afterEach、assert、t、mock、snapshot；选项 skip/todo/only/skipIf/timeout。与 `node --test` 一致，**无需手动 run()**，加载后自动执行。
//! - **Deno**：assert 别名 **assertEquals** / **assertStrictEquals** / **assertThrows** / **assertRejects**；**it.ignore**；**t.step(name, fn)** 子步骤。详见 COMPATIBILITY.md。
//! - **Bun**：describe/test/it、钩子、**describe.skip/only**、**it.each(table)(name, fn)**、**test.serial**、**expect(value).toBe/toEqual/toThrow/toReject**、mock.fn/mock.method。详见 COMPATIBILITY.md。
//!
//! ## 与 node 对齐
//!
//! describe/it/test、beforeAll/afterAll/beforeEach/afterEach、skip/todo/only/skipIf、assert、t.done/skip/todo/name、
//! it(..., { timeout })、mock.fn/mock.method、snapshot(name, value)。执行由模块在加载后通过 **setImmediate** 自动调度，**不导出 run()**。
//!
//! ## shu 特色：灵活、简单、高效
//!
//! - **灵活**：同步（直接 return）、异步（return Promise）、回调（t.done()）三种写法均支持；t.skip/todo 随时结束当前用例。
//! - **简单**：单文件即测，**无需写 run()**；require 后注册 describe/it，脚本同步部分结束后自动执行，与 Deno/Bun 一致。
//! - **高效**：断言与 mock 全 Zig 实现，无内联脚本、无额外 JS 桥接；最小开销、最快启动。
//!
//! ## 导出 API（getExports）
//!
//! - **describe(name, fn)** / **describe.skip** / **describe.ignore** / **describe.only(name, fn)**：注册 suite；skip/only 整 suite 跳过或仅跑。
//! - **it(name, fn)** / **test(name, fn)**：注册用例；options 支持 skip/todo/only/skipIf/**timeout**（毫秒）；**it.each(table)(name, fn)** / **test.each**；**test.serial**。
//! - **beforeAll** / **afterAll** / **beforeEach** / **afterEach**：生命周期钩子。
//! - **it.skip** / **it.ignore** / **it.todo** / **it.only**、**test.skipIf(condition)**：跳过、待办、仅运行、条件跳过。
//! - **assert**：ok、strictEqual、deepStrictEqual、throws、doesNotThrow、fail、rejects、doesNotReject；Deno 别名 assertEquals、assertStrictEquals、assertThrows、assertRejects。
//! - **expect(value)**：toBe、toEqual、toThrow、toReject、toBeTruthy、toBeFalsy（Bun/Jest 风格）。
//! - **t**（测试回调首参）：t.done()、t.skip()、t.todo()、t.name、**t.step(name, fn)**（Deno 子步骤，返回 Promise）。
//! - **mock**：mock.fn([impl])、mock.method(object, methodName)；返回带 .calls、.callCount 的 mock。
//! - **snapshot(name, value)**：同 name 以 JSON 比较，不等则抛错。
//! - **不导出 run()**：加载后通过 setImmediate 自动调度执行；失败时设 `process.exitCode = 1`。
//!
//! ## 架构与数据流
//!
//! - **mod.zig**：getExports 构建 describe/it/beforeAll 等，并在 getExports 末尾用 **setImmediate(内部 run)** 自动调度；调度时用 runner.buildJobList 建任务队列，
//!   创建 RunState，按序执行 Job（beforeAll → beforeEach → 测试 → afterEach → afterAll），
//!   遇 thenable 走 thenChain，否则 scheduleAdvance；回调风格测试通过 t.done() 触发 advance。
//! - **runner.zig**：Suite/TestEntry 树、buildJobList（DFS 生成 Job 列表）、Job 联合体（钩子 + run_test）。
//! - 无内联 JS：assert 统一使用 shu:assert（exception 出参便于 runner 捕获）；mergeOptionsWithFlag 用 JSObjectCopyPropertyNames 复制属性。
//!
//! ## 使用约定
//!
//! - 测试文件**无需**在末尾调用 run()；require('shu:test') 后注册 describe/it，脚本同步部分执行完后由 setImmediate 自动开始跑测，与 Node/Deno/Bun 行为一致。
//! - **`shu test`** 或 **`shu run tests/*.test.js`** 执行测试文件，以进程**退出码**判定成败（0 通过，非 0 失败）。

const std = @import("std");
const jsc = @import("jsc");
const promise_mod = @import("../promise.zig");
const assert_mod = @import("../assert/mod.zig");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");
const runner = @import("runner.zig");
const mock = @import("mock.zig");
const c = std.c;
const libs_process = @import("libs_process");
const libs_io = @import("libs_io");

/// ANSI 颜色：用例结果 ok/fail/skipped 与耗时 (Nms) 在 TTY 下着色；与 CLI test.zig 语义一致。
const c_green = "\x1b[32m";
const c_red = "\x1b[31m";
const c_yellow = "\x1b[33m";
const c_cyan = "\x1b[36m";
const c_reset = "\x1b[0m";
/// 文件头行：深灰（bright black / 90），与下方浅灰用例行区分。
const c_header = "\x1b[90m";

/// 判断是否为保留消息 "true"(4) 或 "false"(5)，用于 skip/todo 的 message 是否需复制（00 §2.1 len+整型比较）
fn isReservedMessage(m: []const u8) bool {
    if (m.len == 4) {
        var a: [4]u8 = undefined;
        @memcpy(a[0..], m[0..4]);
        return @as(u32, @bitCast(a)) == @as(u32, @bitCast([4]u8{ 't', 'r', 'u', 'e' }));
    }
    if (m.len == 5) {
        var b: [8]u8 = [_]u8{0} ** 8;
        @memcpy(b[0..5], m[0..5]);
        return @as(u64, @bitCast(b)) == @as(u64, @bitCast([8]u8{ 'f', 'a', 'l', 's', 'e', 0, 0, 0 }));
    }
    return false;
}

// 模块级 runner 实例，getExports 时创建，进程内复用
var g_runner: ?*runner.RunnerState = null;
/// run() 执行期状态，advance 回调内访问
var g_run_state: ?*RunState = null;

/// 单次执行（钩子或测试）的返回值：value 为 thenable 时走 Promise 链，defer_advance 为 true 时等 t.done()
const JobResult = struct { value: jsc.JSValueRef, defer_advance: bool };

/// 失败异常提取结果：message/stack 均为可选且由 allocator 持有。
const FailureInfo = struct {
    message: ?[]const u8,
    stack: ?[]const u8,
};

/// 单条用例明细：供 SHU_TEST_DETAILS_FILE 生成 JSON 报告时使用。
/// name/status 由 allocator 持有，run 结束统一释放。
const CaseDetail = struct {
    name: []const u8,
    status: []const u8,
    elapsed_ms: i64,
    /// 失败用例的错误消息；通过 Error.message 或异常值字符串化提取。passed/skipped 时为 null。
    error_message: ?[]const u8 = null,
    /// 失败用例的栈信息；优先 Error.stack。passed/skipped 时为 null。
    error_stack: ?[]const u8 = null,
};

const RunState = struct {
    ctx: jsc.JSContextRef,
    allocator: std.mem.Allocator,
    jobs: std.ArrayListUnmanaged(runner.Job),
    job_index: usize,
    resolve_ref: jsc.JSValueRef,
    reject_ref: jsc.JSValueRef,
    has_only: bool,
    /// SHU_TEST_NAME_PATTERN：仅运行完整名称包含该子串的用例；null 表示不过滤。
    name_pattern: ?[]const u8 = null,
    /// SHU_TEST_SKIP_PATTERN：跳过完整名称包含该子串的用例。
    skip_pattern: ?[]const u8 = null,
    /// SHU_TEST_RETRY：失败用例重试次数，0 表示不重试。
    retry_max: u32 = 0,
    /// 当前用例已重试次数（用于 reject 时判断是否再试）。
    retry_count: u32 = 0,
    /// 为 true 表示本次 advance 来自重试，runNext 内不重置 retry_count。
    retry_pending: bool = false,
    /// 当 SHU_TEST_REPORTER=junit 且 SHU_TEST_REPORTER_OUTFILE  set 时收集结果并写 XML；outfile 路径 [Allocates]，由 state 持有并在 writeJUnit 时仍有效。
    junit_outfile: ?[]const u8 = null,
    /// JUnit 用例结果：name 与 message 由 allocator 分配，writeJUnit 后统一释放。
    junit_results: std.ArrayListUnmanaged(struct { name: []const u8, passed: bool, message: ?[]const u8 }) = .{},
    /// JSON 明细报告用例列表：记录每条用例名称、状态、耗时，run 结束后写入 SHU_TEST_DETAILS_FILE。
    detail_results: std.ArrayListUnmanaged(CaseDetail) = .{},
    /// SHU_TEST_SNAPSHOT_FILE：snapshot 持久化文件路径（相对 cwd）；[Allocates]，state 持有，runNext 结束时 free。
    snapshot_file: ?[]const u8 = null,
    /// SHU_TEST_UPDATE_SNAPSHOTS=1 时为 true：将 __shu_snapshot_store 写回文件且 snapshot() 不抛错。
    snapshot_update: bool = false,
    /// SHU_TEST_COVERAGE_DIR：覆盖率输出目录（相对 cwd）；[Allocates]，state 持有，runNext 结束时 free。非 null 表示启用 coverage。
    coverage_dir: ?[]const u8 = null,
    /// SHU_TEST_CWD：测试运行的项目根目录（绝对路径），用于解析 snapshot_file/coverage_dir；[Allocates]，state 持有，runNext 结束时 free。
    test_cwd: ?[]const u8 = null,
    /// 用例级计数：供 shu test CLI 汇总用；run 结束时写入 stderr 一行 __SHU_TEST_CASES__ 供解析。
    case_passed: u32 = 0,
    /// 失败用例数；每次 reject 进入时 +1，最终写入 SHU_TEST_CASES_FILE / stderr 供 CLI 汇总。
    case_failed: u32 = 0,
    case_skipped: u32 = 0,
    /// run 开始时间（毫秒），用于每条用例耗时及 writeCaseSummaryToStderr；不在此处打印 per-file 汇总，由 CLI 最后统一打印 Test cases。
    run_start_ms: i64 = 0,
    /// 当前用例开始时间（毫秒），用于每条 "name ... ok (Nms)" 的 N。
    current_test_start_ms: i64 = 0,
    /// SHU_TEST_BAIL / --fail-fast：true 时首个失败即 reject 并停止；false（默认）时跑完全部用例再 resolve，仅设 exitCode=1。
    /// 为 true 时首个失败即写汇总并停止（SHU_TEST_BAIL/--fail-fast）；默认 false，跑完全部用例并累计 passed/failed/skipped。
    fail_fast: bool = false,
    /// 同步抛错时 rejectWrapper 已对 job_index +1，外层 runNext 返回时不要再 +1，避免覆盖 setImmediate 后的正确索引。
    reject_wrapper_did_advance: bool = false,
    /// !fail_fast 时记录刚失败的 run_test 的 job 下标，advanceCallback 中对该下标不打印 ok、不增加 case_passed。
    last_failed_job_index: ?usize = null,
    /// 记录本轮被判定为 skipped 的 run_test job 下标，advanceCallback 遇到该下标时不再计入 passed。
    last_skipped_job_index: ?usize = null,
    /// 仅在 runTestJob 同步抛错并调用 reject wrapper 前设为 true，rejectWrapperCallback 内据此区分同步/异步以正确计算 failed_job_idx，用后清 false。
    reject_is_sync: bool = false,
    /// 已打印过 "(test failed, job_index=N)" 的 N，同一 job_index 只打印一次，避免 reject 被多次调用时刷屏。
    last_printed_generic_fail_job_index: ?usize = null,
    /// 上一轮实际执行过的 job 下标；同一 job 绝不执行第二次，用于破除任何路径导致的死循环。
    last_run_job_index: ?usize = null,
    /// 本 job 返回了 thenable，未在 runNext 中 job_index += 1，需在 advanceCallback 中补增，否则先打印汇总再跑 reject 会得到错误 failed 数。
    job_index_pending_advance: bool = false,
    /// 断言失败时同步走 reject 路径（不返回 Promise），advance 内「完成」块只写汇总不 destroy，由 runNext 的 else 分支统一 cleanup。
    reject_handled_sync: bool = false,
    /// 当前正在执行的 run_test job 下标（含异步进行中）。用于 rejectWrapper 精准定位失败用例，避免 job_index 推导错位。
    active_run_test_job_index: ?usize = null,

    /// 释放 RunState 持有资源并清空全局引用。
    /// 仅在需要立刻终止当前测试运行时调用（例如 fail-fast 的同步失败路径）。
    fn cleanupAndDestroy(state: *RunState) void {
        state.jobs.deinit(state.allocator);
        state.junit_results.deinit(state.allocator);
        for (state.detail_results.items) |d| {
            state.allocator.free(d.name);
            state.allocator.free(d.status);
            if (d.error_message) |m| state.allocator.free(m);
            if (d.error_stack) |s| state.allocator.free(s);
        }
        state.detail_results.deinit(state.allocator);
        if (state.junit_outfile) |p| state.allocator.free(p);
        if (state.snapshot_file) |p| state.allocator.free(p);
        if (state.coverage_dir) |p| state.allocator.free(p);
        if (state.test_cwd) |p| state.allocator.free(p);
        state.allocator.destroy(state);
        g_run_state = null;
    }

    fn runNext(state: *RunState) void {
        state.reject_wrapper_did_advance = false;
        state.last_printed_generic_fail_job_index = null;
        // 防止重复运行已失败用例：若索引仍停在失败用例或之前，强制推进到失败用例之后
        if (state.last_failed_job_index) |idx| {
            if (state.job_index <= idx) state.job_index = idx + 1;
        }
        // 硬性防护：同一 job 只执行一次，避免成功/失败路径下索引错乱导致的死循环
        while (state.job_index < state.jobs.items.len and state.last_run_job_index != null and state.job_index == state.last_run_job_index.?) {
            state.job_index += 1;
        }
        if (state.job_index >= state.jobs.items.len) {
            saveSnapshotToFileIfRequested(state);
            writeCoveragePlaceholderIfRequested(state);
            writeJUnitIfRequested(state);
            writeCaseSummaryToStderr(state);
            writeCaseDetailsToFileIfRequested(state);
            var no_args: [0]jsc.JSValueRef = undefined;
            _ = jsc.JSObjectCallAsFunction(state.ctx, @ptrCast(state.resolve_ref), null, 0, &no_args, null);
            if (state.reject_handled_sync) {
                state.reject_handled_sync = false;
                return;
            }
            state.jobs.deinit(state.allocator);
            state.junit_results.deinit(state.allocator);
            for (state.detail_results.items) |d| {
                state.allocator.free(d.name);
                state.allocator.free(d.status);
                if (d.error_message) |m| state.allocator.free(m);
                if (d.error_stack) |s| state.allocator.free(s);
            }
            state.detail_results.deinit(state.allocator);
            if (state.junit_outfile) |p| state.allocator.free(p);
            if (state.snapshot_file) |p| state.allocator.free(p);
            if (state.coverage_dir) |p| state.allocator.free(p);
            if (state.test_cwd) |p| state.allocator.free(p);
            state.allocator.destroy(state);
            g_run_state = null;
            return;
        }
        if (!state.retry_pending) state.retry_count = 0;
        state.retry_pending = false;
        // 首次进入时打印 "running N tests from path"（Deno 风格）并记录 run_start_ms；深灰（90）与下方浅灰用例行区分。
        // 当存在 name_pattern（--filter/--test-name-pattern）时，N 仅统计命中过滤条件的 run_test，用于对齐 Deno/Bun 的可见输出预期。
        if (state.job_index == 0) {
            var run_test_count: usize = 0;
            for (state.jobs.items) |j| {
                if (j != .run_test) continue;
                if (state.name_pattern) |pat| {
                    const p = j.run_test;
                    const full_name = runner.getFullTestName(state.allocator, p.suite, p.test_idx) catch continue;
                    defer state.allocator.free(full_name);
                    if (std.mem.indexOf(u8, full_name, pat) == null) continue;
                }
                run_test_count += 1;
            }
            const path = if (c.getenv("SHU_TEST_FILE_PATH")) |p| std.mem.span(p) else "unknown";
            printTestLineStdout("\n{s}running {d} tests from {s}{s}\n", .{ c_header, run_test_count, path, c_reset });
            state.run_start_ms = nowMs();
        }
        state.last_run_job_index = state.job_index;
        const result = runCurrentJob(state);
        if (result.defer_advance) {
            // 回调风格测试 (t.done)：不调度，等用户调 t.done() 时触发 advance
        } else if (isThenable(state.ctx, result.value)) {
            state.job_index_pending_advance = true;
            thenChain(state.ctx, result.value, state);
            return;
        } else {
            if (state.reject_handled_sync) {
                state.reject_handled_sync = false;
                // 非 fail-fast：rejectWrapper 已推进索引并调度下一轮 runNext，不能在这里提前销毁状态。
                // fail-fast：rejectWrapper 已触发顶层 reject，需要立即清理。
                if (state.fail_fast) state.cleanupAndDestroy();
                return;
            }
            if (state.reject_wrapper_did_advance) {
                state.reject_wrapper_did_advance = false;
                // 非 fail-fast：保持 RunState 存活，等待 rejectWrapper 里排队的 runNextOnlyCallback 继续。
                // fail-fast：同步失败后不再继续，立即释放资源。
                if (state.fail_fast) state.cleanupAndDestroy();
                return;
            }
            if (!state.reject_wrapper_did_advance) state.job_index += 1;
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
            state.active_run_test_job_index = state.job_index;
            const p = job.run_test;
            const full_name = runner.getFullTestName(state.allocator, p.suite, p.test_idx) catch
                return .{ .value = jsc.JSValueMakeUndefined(state.ctx), .defer_advance = false };
            defer state.allocator.free(full_name);
            if (state.name_pattern) |pat| {
                if (std.mem.indexOf(u8, full_name, pat) == null) {
                    // 过滤未命中的用例：静默忽略，不打印 skipped，也不计入 skipped 计数。
                    // 仍标记 last_skipped_job_index，避免 advanceCallback 将该 job 误计为 passed。
                    state.last_skipped_job_index = state.job_index;
                    return .{ .value = jsc.JSValueMakeUndefined(state.ctx), .defer_advance = false };
                }
            }
            if (state.skip_pattern) |pat| {
                if (std.mem.indexOf(u8, full_name, pat) != null) {
                    state.last_skipped_job_index = state.job_index;
                    state.case_skipped += 1;
                    printTestResultLine(full_name, .skipped, null);
                    appendCaseDetail(state, full_name, "skipped", 0);
                    return .{ .value = jsc.JSValueMakeUndefined(state.ctx), .defer_advance = false };
                }
            }
            state.current_test_start_ms = nowMs();
            if (state.junit_outfile != null) {
                const name_owned = state.allocator.dupe(u8, full_name) catch return .{ .value = jsc.JSValueMakeUndefined(state.ctx), .defer_advance = false };
                state.junit_results.append(state.allocator, .{ .name = name_owned, .passed = true, .message = null }) catch {
                    state.allocator.free(name_owned);
                    return .{ .value = jsc.JSValueMakeUndefined(state.ctx), .defer_advance = false };
                };
            }
            return runTestJob(state.ctx, state, p.suite, p.test_idx, state.has_only);
        }
    }
};

fn callHook(ctx: jsc.JSContextRef, fn_ref: jsc.JSValueRef) jsc.JSValueRef {
    var no_args: [0]jsc.JSValueRef = undefined;
    return jsc.JSObjectCallAsFunction(ctx, @ptrCast(fn_ref), null, 0, &no_args, null);
}

fn runTestJob(ctx: jsc.JSContextRef, state: *RunState, suite: *runner.Suite, test_idx: usize, has_only: bool) JobResult {
    const t_entry = &suite.tests.items[test_idx];
    if (t_entry.skip) {
        state.last_skipped_job_index = state.job_index;
        state.case_skipped += 1;
        const full_name = runner.getFullTestName(state.allocator, suite, test_idx) catch return .{ .value = jsc.JSValueMakeUndefined(ctx), .defer_advance = false };
        defer state.allocator.free(full_name);
        printTestResultLine(full_name, .skipped, null);
        appendCaseDetail(state, full_name, "skipped", 0);
        return .{ .value = jsc.JSValueMakeUndefined(ctx), .defer_advance = false };
    }
    if (t_entry.skip_if_ref) |skip_if| {
        // skipIf 可能是布尔/原始值或函数；仅当能转为对象且为函数时才调用，否则当原始值用
        const as_obj = jsc.JSValueToObject(ctx, skip_if, null);
        const cond = if (as_obj != null and jsc.JSObjectIsFunction(ctx, as_obj.?)) blk: {
            var no_args: [0]jsc.JSValueRef = undefined;
            break :blk jsc.JSObjectCallAsFunction(ctx, as_obj.?, null, 0, &no_args, null);
        } else skip_if;
        if (!jsc.JSValueIsUndefined(ctx, cond) and !jsc.JSValueIsNull(ctx, cond) and jsc.JSValueToBoolean(ctx, cond)) {
            state.last_skipped_job_index = state.job_index;
            state.case_skipped += 1;
            const full_name = runner.getFullTestName(state.allocator, suite, test_idx) catch return .{ .value = jsc.JSValueMakeUndefined(ctx), .defer_advance = false };
            defer state.allocator.free(full_name);
            printTestResultLine(full_name, .skipped, null);
            appendCaseDetail(state, full_name, "skipped", 0);
            return .{ .value = jsc.JSValueMakeUndefined(ctx), .defer_advance = false };
        }
    }
    if (has_only and !t_entry.only) {
        state.last_skipped_job_index = state.job_index;
        state.case_skipped += 1;
        const full_name = runner.getFullTestName(state.allocator, suite, test_idx) catch return .{ .value = jsc.JSValueMakeUndefined(ctx), .defer_advance = false };
        defer state.allocator.free(full_name);
        printTestResultLine(full_name, .skipped, null);
        appendCaseDetail(state, full_name, "skipped", 0);
        return .{ .value = jsc.JSValueMakeUndefined(ctx), .defer_advance = false };
    }
    const t_ctx = jsc.JSObjectMake(ctx, null, null);
    // t.name：当前用例名（与 node:test 对齐），只读
    const name_z = suite.allocator.dupeZ(u8, t_entry.name) catch return .{ .value = jsc.JSValueMakeUndefined(ctx), .defer_advance = false };
    defer suite.allocator.free(name_z);
    const name_js_str = jsc.JSStringCreateWithUTF8CString(name_z.ptr);
    defer jsc.JSStringRelease(name_js_str);
    const k_name = jsc.JSStringCreateWithUTF8CString("name");
    defer jsc.JSStringRelease(k_name);
    _ = jsc.JSObjectSetProperty(ctx, t_ctx, k_name, jsc.JSValueMakeString(ctx, name_js_str), jsc.kJSPropertyAttributeNone, null);
    const k_done = jsc.JSStringCreateWithUTF8CString("done");
    defer jsc.JSStringRelease(k_done);
    const k_skip = jsc.JSStringCreateWithUTF8CString("skip");
    defer jsc.JSStringRelease(k_skip);
    const k_todo = jsc.JSStringCreateWithUTF8CString("todo");
    defer jsc.JSStringRelease(k_todo);
    const k_step = jsc.JSStringCreateWithUTF8CString("step");
    defer jsc.JSStringRelease(k_step);
    const noop_ctx_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_done, testContextNoopCallback);
    _ = jsc.JSObjectSetProperty(ctx, t_ctx, k_done, noop_ctx_fn, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, t_ctx, k_skip, noop_ctx_fn, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, t_ctx, k_todo, noop_ctx_fn, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, t_ctx, k_step, jsc.JSObjectMakeFunctionWithCallback(ctx, k_step, stepCallback), jsc.kJSPropertyAttributeNone, null);
    // 通过 __shu_test_run_test_fn 包装：内部执行 testFn(t)，同步异常时存 exc 并返回 Promise.reject(exc)，保证 reject 收到正确 Error（避免 JSC 嵌套 exception 不填回 &exc）
    const run_test_fn = getRunTestWrapperFn(ctx);
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(run_test_fn))) {
        if (t_entry.todo) return .{ .value = jsc.JSValueMakeUndefined(ctx), .defer_advance = false };
        const global = jsc.JSContextGetGlobalObject(ctx);
        setAssertSlotBeforeRun(ctx, global);
        var args_direct = [_]jsc.JSValueRef{t_ctx};
        // 先显式置为 undefined，避免无异常时读取到未初始化内存导致误判失败。
        var exc_direct: jsc.JSValueRef = jsc.JSValueMakeUndefined(ctx);
        const ret_direct = jsc.JSObjectCallAsFunction(ctx, @ptrCast(t_entry.fn_ref), null, 1, &args_direct, @ptrCast(&exc_direct));
        var exc_effective = getAssertExcAfterRun(ctx, global, exc_direct);
        const fail_count = assert_mod.getAndClearAssertFailCount();
        if ((jsc.JSValueIsUndefined(ctx, exc_effective) or jsc.JSValueIsNull(ctx, exc_effective)) and fail_count > 0)
            exc_effective = makeAssertFailedError(ctx);
        clearAssertSlot(ctx, global);
        if (!jsc.JSValueIsUndefined(ctx, exc_effective) and !jsc.JSValueIsNull(ctx, exc_effective)) {
            const promise_rej = makeRejectedPromiseWithExc(ctx, exc_effective);
            // 统一交给 runNext 外层处理 then/reject 链，避免同一 job 被重复 thenChain。
            return .{ .value = promise_rej, .defer_advance = false };
        }
        const defer_advance = jsc.JSValueIsUndefined(ctx, ret_direct) and !isThenable(ctx, ret_direct);
        return .{ .value = ret_direct, .defer_advance = defer_advance };
    }
    var wrap_args = [_]jsc.JSValueRef{ t_entry.fn_ref, t_ctx };
    const promise = jsc.JSObjectCallAsFunction(ctx, @ptrCast(run_test_fn), null, 2, &wrap_args, null);
    if (!jsc.JSValueIsUndefined(ctx, promise) and isThenable(ctx, promise))
        // 由 runNext 统一 thenChain，避免重复推进 job_index。
        return .{ .value = promise, .defer_advance = false };
    if (t_entry.todo) return .{ .value = jsc.JSValueMakeUndefined(ctx), .defer_advance = false };
    const defer_advance = jsc.JSValueIsUndefined(ctx, promise) or !isThenable(ctx, promise);
    return .{ .value = promise, .defer_advance = defer_advance };
}

/// t.done/t.skip/t.todo 的最小 no-op 实现：保持 API 可调用，不在回调内提前推进 runner 索引。
fn testContextNoopCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    return jsc.JSValueMakeUndefined(ctx);
}

fn getAdvanceFn(ctx: jsc.JSContextRef) jsc.JSValueRef {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k = jsc.JSStringCreateWithUTF8CString("__shu_test_advance");
    defer jsc.JSStringRelease(k);
    return jsc.JSObjectGetProperty(ctx, global, k, null);
}

fn getRunTestWrapperFn(ctx: jsc.JSContextRef) jsc.JSValueRef {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k = jsc.JSStringCreateWithUTF8CString("__shu_test_run_test_fn");
    defer jsc.JSStringRelease(k);
    return jsc.JSObjectGetProperty(ctx, global, k, null);
}

/// Deno t.step(name, fn)：执行子步骤，fn 可为同步或返回 Promise；返回 Promise 供 await t.step(...)。约定：单槽 __shu_step_fn。
fn stepCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2 or !jsc.JSObjectIsFunction(ctx, @ptrCast(arguments[1]))) return jsc.JSValueMakeUndefined(ctx);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_fn = jsc.JSStringCreateWithUTF8CString("__shu_step_fn");
    defer jsc.JSStringRelease(k_fn);
    _ = jsc.JSObjectSetProperty(ctx, global, k_fn, arguments[1], jsc.kJSPropertyAttributeNone, null);
    const k_exec = jsc.JSStringCreateWithUTF8CString("");
    defer jsc.JSStringRelease(k_exec);
    const exec = jsc.JSObjectMakeFunctionWithCallback(ctx, k_exec, stepExecutorCallback);
    var args = [_]jsc.JSValueRef{exec};
    const Promise_ctor = promise_mod.getPromiseConstructor(ctx) orelse return jsc.JSValueMakeUndefined(ctx);
    return jsc.JSObjectCallAsConstructor(ctx, Promise_ctor, 1, &args, null);
}

/// t.step 的 Promise executor：调用 __shu_step_fn()，thenable 则链 then(resolve, reject)，否则 resolve(undefined)；抛错则 reject
fn stepExecutorCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const resolve_fn = arguments[0];
    const reject_fn = arguments[1];
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_fn = jsc.JSStringCreateWithUTF8CString("__shu_step_fn");
    defer jsc.JSStringRelease(k_fn);
    const fn_val = jsc.JSObjectGetProperty(ctx, global, k_fn, null);
    if (jsc.JSValueIsUndefined(ctx, fn_val) or !jsc.JSObjectIsFunction(ctx, @ptrCast(fn_val))) {
        var no_args: [0]jsc.JSValueRef = undefined;
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(resolve_fn), null, 0, &no_args, null);
        return jsc.JSValueMakeUndefined(ctx);
    }
    // 显式初始化，避免无异常时读取到未初始化值导致误判 reject。
    var exc: jsc.JSValueRef = jsc.JSValueMakeUndefined(ctx);
    var no_args: [0]jsc.JSValueRef = undefined;
    const ret = jsc.JSObjectCallAsFunction(ctx, @ptrCast(fn_val), null, 0, &no_args, @ptrCast(&exc));
    if (!jsc.JSValueIsUndefined(ctx, exc) and !jsc.JSValueIsNull(ctx, exc)) {
        var one = [_]jsc.JSValueRef{exc};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(reject_fn), null, 1, &one, null);
        return jsc.JSValueMakeUndefined(ctx);
    }
    if (isThenable(ctx, ret)) {
        const k_then = jsc.JSStringCreateWithUTF8CString("then");
        defer jsc.JSStringRelease(k_then);
        const obj = jsc.JSValueToObject(ctx, ret, null) orelse {
            var no_args2: [0]jsc.JSValueRef = undefined;
            _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(resolve_fn), null, 0, &no_args2, null);
            return jsc.JSValueMakeUndefined(ctx);
        };
        const then_fn = jsc.JSObjectGetProperty(ctx, obj, k_then, null);
        if (jsc.JSObjectIsFunction(ctx, @ptrCast(then_fn))) {
            var then_args = [_]jsc.JSValueRef{ resolve_fn, reject_fn };
            _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(then_fn), ret, 2, &then_args, null);
        } else {
            var no_args2: [0]jsc.JSValueRef = undefined;
            _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(resolve_fn), null, 0, &no_args2, null);
        }
    } else {
        var no_args2: [0]jsc.JSValueRef = undefined;
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(resolve_fn), null, 0, &no_args2, null);
    }
    return jsc.JSValueMakeUndefined(ctx);
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

// 全局槽名：包装测试调用时把同步异常/返回值存到这里，供 Promise executor 读取
const k_shu_test_last_exc = "__shu_test_last_exc";
const k_shu_test_ret = "__shu_test_ret";

/// Promise executor：从 global 读取 __shu_test_last_exc 并调用 reject(exc)，保证 reject 收到 C 层捕获的 Error
fn promiseRejectExecutorCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k = jsc.JSStringCreateWithUTF8CString(k_shu_test_last_exc);
    defer jsc.JSStringRelease(k);
    const exc = jsc.JSObjectGetProperty(ctx, global, k, null);
    const reject_fn = arguments[1];
    var one = [_]jsc.JSValueRef{exc};
    _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(reject_fn), null, 1, &one, null);
    return jsc.JSValueMakeUndefined(ctx);
}

/// Promise executor：从 global 读取 __shu_test_ret 并调用 resolve(ret)
fn promiseResolveExecutorCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k = jsc.JSStringCreateWithUTF8CString(k_shu_test_ret);
    defer jsc.JSStringRelease(k);
    const ret = jsc.JSObjectGetProperty(ctx, global, k, null);
    const resolve_fn = arguments[0];
    var one = [_]jsc.JSValueRef{ret};
    _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(resolve_fn), null, 1, &one, null);
    return jsc.JSValueMakeUndefined(ctx);
}

// 与 shu:assert 约定：runner 跑用例前设此槽，assert 失败时写 __shu_assert_last_exc，runner 读后计入 failed（纯 Zig，无内联 JS）
const k_shu_assert_exc_slot = "__shu_assert_exc_slot";
const k_shu_assert_last_exc = "__shu_assert_last_exc";
const k_shu_assert_did_fail = "__shu_assert_did_fail";

/// [Borrows] 在 ctx 中创建 Error("Assertion failed")，用于 runner 发现 did_fail 但读不到 last_exc 时（如不同 global）仍能走 reject 路径。
fn makeAssertFailedError(ctx: jsc.JSContextRef) jsc.JSValueRef {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_Error = jsc.JSStringCreateWithUTF8CString("Error");
    defer jsc.JSStringRelease(k_Error);
    const k_msg = jsc.JSStringCreateWithUTF8CString("Assertion failed");
    defer jsc.JSStringRelease(k_msg);
    const Error_ctor = jsc.JSObjectGetProperty(ctx, global, k_Error, null);
    if (jsc.JSValueIsUndefined(ctx, Error_ctor)) return jsc.JSValueMakeUndefined(ctx);
    const msg_val = jsc.JSValueMakeString(ctx, k_msg);
    var args = [_]jsc.JSValueRef{msg_val};
    return jsc.JSObjectCallAsConstructor(ctx, @ptrCast(Error_ctor), 1, &args, null);
}

/// 跑用例前：注入 runner global 到 assert，并设槽/清槽，供 assert 失败时写回。
fn setAssertSlotBeforeRun(ctx: jsc.JSContextRef, global: jsc.JSObjectRef) void {
    assert_mod.setRunnerGlobalForAssert(global);
    const k_slot = jsc.JSStringCreateWithUTF8CString(k_shu_assert_exc_slot);
    defer jsc.JSStringRelease(k_slot);
    const k_last = jsc.JSStringCreateWithUTF8CString(k_shu_assert_last_exc);
    defer jsc.JSStringRelease(k_last);
    const k_did = jsc.JSStringCreateWithUTF8CString(k_shu_assert_did_fail);
    defer jsc.JSStringRelease(k_did);
    _ = jsc.JSObjectSetProperty(ctx, global, k_slot, jsc.JSValueMakeBoolean(ctx, true), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, global, k_last, jsc.JSValueMakeUndefined(ctx), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, global, k_did, jsc.JSValueMakeUndefined(ctx), jsc.kJSPropertyAttributeNone, null);
}

/// 跑用例后：若 exc 已 set 则用 exc，否则读 __shu_assert_last_exc（先 runner global 再 ctx global），再否则若 __shu_assert_did_fail 则造 Error，否则 undefined。
fn getAssertExcAfterRun(ctx: jsc.JSContextRef, global: jsc.JSObjectRef, exc: jsc.JSValueRef) jsc.JSValueRef {
    const k_last = jsc.JSStringCreateWithUTF8CString(k_shu_assert_last_exc);
    defer jsc.JSStringRelease(k_last);
    const k_did = jsc.JSStringCreateWithUTF8CString(k_shu_assert_did_fail);
    defer jsc.JSStringRelease(k_did);
    if (!jsc.JSValueIsUndefined(ctx, exc) and !jsc.JSValueIsNull(ctx, exc)) return exc;
    const exc_from_runner = jsc.JSObjectGetProperty(ctx, global, k_last, null);
    if (!jsc.JSValueIsUndefined(ctx, exc_from_runner) and !jsc.JSValueIsNull(ctx, exc_from_runner)) return exc_from_runner;
    const ctx_global = jsc.JSContextGetGlobalObject(ctx);
    if (ctx_global != global) {
        const exc_from_ctx = jsc.JSObjectGetProperty(ctx, ctx_global, k_last, null);
        if (!jsc.JSValueIsUndefined(ctx, exc_from_ctx) and !jsc.JSValueIsNull(ctx, exc_from_ctx)) return exc_from_ctx;
    }
    const did_fail = jsc.JSObjectGetProperty(ctx, global, k_did, null);
    if (!jsc.JSValueIsUndefined(ctx, did_fail) and jsc.JSValueToBoolean(ctx, did_fail)) return makeAssertFailedError(ctx);
    if (ctx_global != global) {
        const did_fail_ctx = jsc.JSObjectGetProperty(ctx, ctx_global, k_did, null);
        if (!jsc.JSValueIsUndefined(ctx, did_fail_ctx) and jsc.JSValueToBoolean(ctx, did_fail_ctx)) return makeAssertFailedError(ctx);
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// 跑用例后清空 assert 槽并清除 runner global 注入，避免残留到下一用例。
fn clearAssertSlot(ctx: jsc.JSContextRef, global: jsc.JSObjectRef) void {
    assert_mod.setRunnerGlobalForAssert(null);
    const k_slot = jsc.JSStringCreateWithUTF8CString(k_shu_assert_exc_slot);
    defer jsc.JSStringRelease(k_slot);
    const k_last = jsc.JSStringCreateWithUTF8CString(k_shu_assert_last_exc);
    defer jsc.JSStringRelease(k_last);
    const k_did = jsc.JSStringCreateWithUTF8CString(k_shu_assert_did_fail);
    defer jsc.JSStringRelease(k_did);
    _ = jsc.JSObjectSetProperty(ctx, global, k_slot, jsc.JSValueMakeUndefined(ctx), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, global, k_last, jsc.JSValueMakeUndefined(ctx), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, global, k_did, jsc.JSValueMakeUndefined(ctx), jsc.kJSPropertyAttributeNone, null);
}

/// 用 exc 构造 Promise.reject(executor) 且 executor(resolve, reject) 会调 reject(exc)；供直接执行分支与 wrapper 共用。
fn makeRejectedPromiseWithExc(ctx: jsc.JSContextRef, exc: jsc.JSValueRef) jsc.JSValueRef {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_exc = jsc.JSStringCreateWithUTF8CString(k_shu_test_last_exc);
    defer jsc.JSStringRelease(k_exc);
    _ = jsc.JSObjectSetProperty(ctx, global, k_exc, exc, jsc.kJSPropertyAttributeNone, null);
    const k_exec = jsc.JSStringCreateWithUTF8CString("");
    defer jsc.JSStringRelease(k_exec);
    const executor = jsc.JSObjectMakeFunctionWithCallback(ctx, k_exec, promiseRejectExecutorCallback);
    const Promise_ctor = promise_mod.getPromiseConstructor(ctx) orelse return jsc.JSValueMakeUndefined(ctx);
    var exec_arg = [_]jsc.JSValueRef{executor};
    return jsc.JSObjectCallAsConstructor(ctx, Promise_ctor, 1, &exec_arg, null);
}

/// 包装单次测试调用：执行 testFn(t)，若同步抛错或 assert 通过槽写入的异常则把 exc 存到 global 并返回 Promise.reject(exc)，否则返回 thenable 或 Promise.resolve(ret)。
fn runTestWrapperCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const test_fn = arguments[0];
    const t_ctx = arguments[1];
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(test_fn))) return jsc.JSValueMakeUndefined(ctx);
    const global = jsc.JSContextGetGlobalObject(ctx);
    setAssertSlotBeforeRun(ctx, global);
    var args = [_]jsc.JSValueRef{t_ctx};
    // 先显式置为 undefined，避免无异常时读取到未初始化内存导致误判失败。
    var exc: jsc.JSValueRef = jsc.JSValueMakeUndefined(ctx);
    const ret = jsc.JSObjectCallAsFunction(ctx, @ptrCast(test_fn), null, 1, &args, @ptrCast(&exc));
    var exc_effective = getAssertExcAfterRun(ctx, global, exc);
    const fail_count = assert_mod.getAndClearAssertFailCount();
    if ((jsc.JSValueIsUndefined(ctx, exc_effective) or jsc.JSValueIsNull(ctx, exc_effective)) and fail_count > 0)
        exc_effective = makeAssertFailedError(ctx);
    clearAssertSlot(ctx, global);
    if (!jsc.JSValueIsUndefined(ctx, exc_effective) and !jsc.JSValueIsNull(ctx, exc_effective)) {
        const state = g_run_state orelse return makeRejectedPromiseWithExc(ctx, exc_effective);
        state.reject_handled_sync = true;
        state.reject_wrapper_did_advance = true;
        state.job_index_pending_advance = true;
        state.reject_is_sync = true;
        const k_exc = jsc.JSStringCreateWithUTF8CString(k_shu_test_last_exc);
        defer jsc.JSStringRelease(k_exc);
        _ = jsc.JSObjectSetProperty(ctx, global, k_exc, exc_effective, jsc.kJSPropertyAttributeNone, null);
        const reject_wrapper = getRejectWrapper(ctx);
        if (!jsc.JSValueIsUndefined(ctx, reject_wrapper) and jsc.JSObjectIsFunction(ctx, @ptrCast(reject_wrapper))) {
            var one_arg = [_]jsc.JSValueRef{exc_effective};
            _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(reject_wrapper), null, 1, &one_arg, null);
        }
        return jsc.JSValueMakeUndefined(ctx);
    }
    if (isThenable(ctx, ret)) return ret;
    const k_ret = jsc.JSStringCreateWithUTF8CString(k_shu_test_ret);
    defer jsc.JSStringRelease(k_ret);
    _ = jsc.JSObjectSetProperty(ctx, global, k_ret, ret, jsc.kJSPropertyAttributeNone, null);
    const k_exec2 = jsc.JSStringCreateWithUTF8CString("");
    defer jsc.JSStringRelease(k_exec2);
    const executor2 = jsc.JSObjectMakeFunctionWithCallback(ctx, k_exec2, promiseResolveExecutorCallback);
    const Promise_ctor2 = promise_mod.getPromiseConstructor(ctx) orelse return jsc.JSValueMakeUndefined(ctx);
    var exec_arg2 = [_]jsc.JSValueRef{executor2};
    return jsc.JSObjectCallAsConstructor(ctx, Promise_ctor2, 1, &exec_arg2, null);
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
    // 保护：某些失败-重试/回调交错路径可能让索引短暂超过队列末尾，先夹紧到合法范围。
    if (state.job_index > state.jobs.items.len) state.job_index = state.jobs.items.len;
    if (state.job_index_pending_advance) {
        state.job_index_pending_advance = false;
        // 仅在队列范围内推进，避免 len+1 导致下方 state.jobs.items[...] 越界。
        if (state.job_index < state.jobs.items.len) state.job_index += 1;
    }
    // runNext 在 runCurrentJob 返回后已执行 job_index += 1（或由上方补增），故刚完成的 job 为 job_index - 1
    if (state.job_index > 0 and state.job_index <= state.jobs.items.len and state.jobs.items[state.job_index - 1] == .run_test) {
        const just_completed_idx = state.job_index - 1;
        if (state.active_run_test_job_index != null and state.active_run_test_job_index.? == just_completed_idx) {
            state.active_run_test_job_index = null;
        }
        // !fail_fast 时该用例可能已失败并打印过 fail，不再打印 ok、不增加 case_passed
        const skip_ok = state.last_failed_job_index != null and state.last_failed_job_index.? == just_completed_idx;
        const skip_skipped = state.last_skipped_job_index != null and state.last_skipped_job_index.? == just_completed_idx;
        if (skip_ok) {
            state.last_failed_job_index = null;
        } else if (skip_skipped) {
            state.last_skipped_job_index = null;
        } else {
            state.case_passed += 1;
            const p = state.jobs.items[just_completed_idx].run_test;
            const elapsed = nowMs() - state.current_test_start_ms;
            if (runner.getFullTestName(state.allocator, p.suite, p.test_idx)) |full_name| {
                defer state.allocator.free(full_name);
                printTestResultLine(full_name, .ok, elapsed);
                appendCaseDetail(state, full_name, "passed", elapsed);
            } else |_| {
                const t_name = p.suite.tests.items[p.test_idx].name;
                printTestResultLine(t_name, .ok, elapsed);
                appendCaseDetail(state, t_name, "passed", elapsed);
            }
        }
    }
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

/// describe(name, fn [, options])：注册一个 suite，执行 fn(suiteCtx)；options 支持 timeout/skipIf，子 suite 与 it 继承（子级覆盖）
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
    var suite_timeout_ms: ?u32 = null;
    var suite_skip_if_ref: ?jsc.JSValueRef = null;
    if (argumentCount >= 3) {
        if (jsc.JSValueToObject(ctx, arguments[2], null)) |opts_obj| {
            const k_timeout = jsc.JSStringCreateWithUTF8CString("timeout");
            defer jsc.JSStringRelease(k_timeout);
            const k_skipIf = jsc.JSStringCreateWithUTF8CString("skipIf");
            defer jsc.JSStringRelease(k_skipIf);
            const v_timeout = jsc.JSObjectGetProperty(ctx, opts_obj, k_timeout, null);
            const v_skip_if = jsc.JSObjectGetProperty(ctx, opts_obj, k_skipIf, null);
            if (!jsc.JSValueIsUndefined(ctx, v_timeout)) {
                const n = jsc.JSValueToNumber(ctx, v_timeout, null);
                if (n >= 0 and n <= 0xFFFF_FFFF and std.math.isFinite(n)) suite_timeout_ms = @intFromFloat(n);
            }
            if (!jsc.JSValueIsUndefined(ctx, v_skip_if)) suite_skip_if_ref = v_skip_if;
        }
    }
    return describeCallbackCore(ctx, allocator, r, name_slice, fn_val, false, false, suite_timeout_ms, suite_skip_if_ref);
}

/// describe.skip(name, fn) / describe.ignore(name, fn)：整 suite 跳过，不加入 job 列表；无 options 继承
fn describeSkipCallback(
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
    return describeCallbackCore(ctx, allocator, r, name_slice, fn_val, true, false, null, null);
}

/// describe.only(name, fn)：仅运行该 suite（及其子树内 only 的测试）；无 options
fn describeOnlyCallback(
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
    return describeCallbackCore(ctx, allocator, r, name_slice, fn_val, false, true, null, null);
}

/// 公共 describe 逻辑：创建子 suite、push、调 fn、pop；skip/only 控制 suite.skip 与 suite.only；suite_timeout_ms/suite_skip_if 为本层 options，未指定则继承 parent
fn describeCallbackCore(
    ctx: jsc.JSContextRef,
    allocator: std.mem.Allocator,
    r: *runner.RunnerState,
    name_slice: []const u8,
    fn_val: jsc.JSValueRef,
    suite_skip: bool,
    suite_only: bool,
    suite_timeout_ms: ?u32,
    suite_skip_if_ref: ?jsc.JSValueRef,
) jsc.JSValueRef {
    const parent = r.currentSuite() orelse &r.root;
    const child = allocator.create(runner.Suite) catch return jsc.JSValueMakeUndefined(ctx);
    child.* = .{
        .name = allocator.dupe(u8, name_slice) catch {
            allocator.destroy(child);
            return jsc.JSValueMakeUndefined(ctx);
        },
        .parent = parent,
        .children = .{},
        .tests = .{},
        .before_all = .{},
        .after_all = .{},
        .before_each = .{},
        .after_each = .{},
        .skip = suite_skip,
        .only = suite_only,
        .timeout_ms = suite_timeout_ms orelse parent.timeout_ms,
        .skip_if_ref = suite_skip_if_ref orelse parent.skip_if_ref,
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
    if (suite_only) r.has_only = true;

    r.pushSuite(child);
    defer r.popSuite();
    defer runner.computeOnlyInSubtree(child);

    const suite_ctx = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, suite_ctx, "it", itCallback);
    common.setMethod(ctx, suite_ctx, "test", itCallback);
    common.setMethod(ctx, suite_ctx, "beforeAll", beforeAllCallback);
    common.setMethod(ctx, suite_ctx, "afterAll", afterAllCallback);
    common.setMethod(ctx, suite_ctx, "beforeEach", beforeEachCallback);
    common.setMethod(ctx, suite_ctx, "afterEach", afterEachCallback);
    const describe_fn = getDescribeFn(ctx);
    if (!jsc.JSValueIsUndefined(ctx, describe_fn)) {
        const k_describe = jsc.JSStringCreateWithUTF8CString("describe");
        defer jsc.JSStringRelease(k_describe);
        _ = jsc.JSObjectSetProperty(ctx, suite_ctx, k_describe, describe_fn, jsc.kJSPropertyAttributeNone, null);
    }

    var args = [_]jsc.JSValueRef{suite_ctx};
    _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(fn_val), null, 1, &args, null);
    return jsc.JSValueMakeUndefined(ctx);
}

/// 从 global 读取 __shu_describe_fn，供 describeCallbackCore 挂到 suite_ctx
fn getDescribeFn(ctx: jsc.JSContextRef) jsc.JSValueRef {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k = jsc.JSStringCreateWithUTF8CString("__shu_describe_fn");
    defer jsc.JSStringRelease(k);
    return jsc.JSObjectGetProperty(ctx, global, k, null);
}

/// it(name, fn [, options]) / test(name, fn [, options])：注册一条测试；options 必须在末尾，支持 skip/todo/only/skipIf
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
    const fn_val = arguments[1];
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(fn_val))) return jsc.JSValueMakeUndefined(ctx);

    var skip: bool = false;
    var skip_message: ?[]const u8 = null;
    var todo: bool = false;
    var todo_message: ?[]const u8 = null;
    var only: bool = false;
    var skip_if_ref: ?jsc.JSValueRef = null;
    var timeout_ms: ?u32 = null;
    if (argumentCount >= 3) {
        if (jsc.JSValueToObject(ctx, arguments[2], null)) |opts_obj| {
            const k_skip = jsc.JSStringCreateWithUTF8CString("skip");
            defer jsc.JSStringRelease(k_skip);
            const k_todo = jsc.JSStringCreateWithUTF8CString("todo");
            defer jsc.JSStringRelease(k_todo);
            const k_only = jsc.JSStringCreateWithUTF8CString("only");
            defer jsc.JSStringRelease(k_only);
            const k_skipIf = jsc.JSStringCreateWithUTF8CString("skipIf");
            defer jsc.JSStringRelease(k_skipIf);
            const k_timeout = jsc.JSStringCreateWithUTF8CString("timeout");
            defer jsc.JSStringRelease(k_timeout);
            const v_skip = jsc.JSObjectGetProperty(ctx, opts_obj, k_skip, null);
            const v_todo = jsc.JSObjectGetProperty(ctx, opts_obj, k_todo, null);
            const v_only = jsc.JSObjectGetProperty(ctx, opts_obj, k_only, null);
            const v_skip_if = jsc.JSObjectGetProperty(ctx, opts_obj, k_skipIf, null);
            const v_timeout = jsc.JSObjectGetProperty(ctx, opts_obj, k_timeout, null);
            skip = !jsc.JSValueIsUndefined(ctx, v_skip) and jsc.JSValueToBoolean(ctx, v_skip);
            if (skip) {
                const msg = jsValueToUtf8Alloc(ctx, allocator, v_skip);
                if (msg) |m| {
                    defer allocator.free(m);
                    if (!isReservedMessage(m)) skip_message = allocator.dupe(u8, m) catch null;
                }
            }
            todo = !jsc.JSValueIsUndefined(ctx, v_todo) and jsc.JSValueToBoolean(ctx, v_todo);
            if (todo) {
                const msg = jsValueToUtf8Alloc(ctx, allocator, v_todo);
                if (msg) |m| {
                    defer allocator.free(m);
                    if (!isReservedMessage(m)) todo_message = allocator.dupe(u8, m) catch null;
                }
            }
            only = !jsc.JSValueIsUndefined(ctx, v_only) and jsc.JSValueToBoolean(ctx, v_only);
            if (!jsc.JSValueIsUndefined(ctx, v_skip_if)) skip_if_ref = v_skip_if;
            if (!jsc.JSValueIsUndefined(ctx, v_timeout)) {
                const n = jsc.JSValueToNumber(ctx, v_timeout, null);
                if (n >= 0 and n <= 0xFFFF_FFFF and std.math.isFinite(n)) timeout_ms = @intFromFloat(n);
            }
        }
    }
    if (only) r.has_only = true;

    // 继承：从当前 suite 沿 parent 到 root 取首个非 null 的 timeout_ms / skip_if_ref，用例级 options 覆盖
    var cur: ?*runner.Suite = suite;
    while (cur) |n| : (cur = n.parent) {
        if (timeout_ms == null and n.timeout_ms != null) timeout_ms = n.timeout_ms;
        if (skip_if_ref == null and n.skip_if_ref != null) skip_if_ref = n.skip_if_ref;
        if (timeout_ms != null and skip_if_ref != null) break;
    }

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
        .timeout_ms = timeout_ms,
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

/// Promise 的 executor：接收 (resolve, reject)，构建任务队列、RunState，启动 runNext。若 SHU_TEST_PRELOAD 已设置则先 require 该路径再继续。
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
    // 若设置了 SHU_TEST_PRELOAD，先执行 preload 脚本（如加载环境、polyfill），再构建任务队列
    if (c.getenv("SHU_TEST_PRELOAD")) |p| {
        const global = jsc.JSContextGetGlobalObject(ctx);
        const k_require = jsc.JSStringCreateWithUTF8CString("require");
        defer jsc.JSStringRelease(k_require);
        const require_val = jsc.JSObjectGetProperty(ctx, global, k_require, null);
        if (jsc.JSValueToObject(ctx, require_val, null)) |require_obj| {
            const path_js_str = jsc.JSStringCreateWithUTF8CString(p);
            defer jsc.JSStringRelease(path_js_str);
            const path_js = jsc.JSValueMakeString(ctx, path_js_str);
            var req_args = [_]jsc.JSValueRef{path_js};
            _ = jsc.JSObjectCallAsFunction(ctx, require_obj, null, 1, &req_args, null);
        }
    }
    const r = getOrCreateRunner(allocator) orelse return jsc.JSValueMakeUndefined(ctx);
    runner.computeOnlyInSubtree(&r.root);
    const todo_only = if (c.getenv("SHU_TEST_TODO_ONLY")) |q| (std.mem.span(q).len > 0 and std.mem.span(q)[0] != '0') else false;
    if (todo_only) runner.computeTodoInSubtree(&r.root);
    var jobs = runner.buildJobList(allocator, &r.root, r.has_only, todo_only);
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
        .name_pattern = if (c.getenv("SHU_TEST_NAME_PATTERN")) |p| std.mem.span(p) else null,
        .skip_pattern = if (c.getenv("SHU_TEST_SKIP_PATTERN")) |p| std.mem.span(p) else null,
        .retry_max = if (c.getenv("SHU_TEST_RETRY")) |p| std.fmt.parseInt(u32, std.mem.span(p), 10) catch 0 else 0,
        .retry_count = 0,
        .junit_outfile = null,
        .junit_results = .{},
        .detail_results = .{},
        .fail_fast = (c.getenv("SHU_TEST_BAIL") != null),
    };
    if (c.getenv("SHU_TEST_REPORTER")) |p| {
        if (std.mem.eql(u8, std.mem.span(p), "junit")) {
            if (c.getenv("SHU_TEST_REPORTER_OUTFILE")) |q| {
                state.junit_outfile = allocator.dupe(u8, std.mem.span(q)) catch null;
            }
        }
    }
    if (c.getenv("SHU_TEST_TIMEOUT")) |p| {
        const span = std.mem.span(p);
        if (std.fmt.parseInt(u32, span, 10)) |ms| {
            const global = jsc.JSContextGetGlobalObject(ctx);
            const k = jsc.JSStringCreateWithUTF8CString("__shu_default_timeout_ms");
            defer jsc.JSStringRelease(k);
            _ = jsc.JSObjectSetProperty(ctx, global, k, jsc.JSValueMakeNumber(ctx, @floatFromInt(ms)), jsc.kJSPropertyAttributeNone, null);
        } else |_| {}
    }
    if (c.getenv("SHU_TEST_SNAPSHOT_FILE")) |p| {
        state.snapshot_file = allocator.dupe(u8, std.mem.span(p)) catch null;
    }
    state.snapshot_update = if (c.getenv("SHU_TEST_UPDATE_SNAPSHOTS")) |q|
        (std.mem.span(q).len > 0 and std.mem.span(q)[0] != '0')
    else
        false;
    if (c.getenv("SHU_TEST_COVERAGE")) |q| {
        if (std.mem.span(q).len > 0 and std.mem.span(q)[0] != '0') {
            if (c.getenv("SHU_TEST_COVERAGE_DIR")) |d|
                state.coverage_dir = allocator.dupe(u8, std.mem.span(d)) catch null
            else
                state.coverage_dir = allocator.dupe(u8, "coverage") catch null;
        }
    }
    if (c.getenv("SHU_TEST_CWD")) |p| state.test_cwd = allocator.dupe(u8, std.mem.span(p)) catch null;
    g_run_state = state;
    if (state.snapshot_file != null) loadSnapshotFromFile(state);
    RunState.runNext(state);
    return jsc.JSValueMakeUndefined(ctx);
}

/// 失败时设 process.exitCode = 1 并调用原始 reject；若 SHU_TEST_RETRY 且未超次数则重试当前用例。
fn rejectWrapperCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const state = g_run_state orelse return jsc.JSValueMakeUndefined(ctx);
    if (state.retry_max > 0 and state.retry_count < state.retry_max) {
        state.retry_count += 1;
        if (state.job_index > 0) state.job_index -= 1;
        state.retry_pending = true;
        scheduleAdvance(ctx);
        return jsc.JSValueMakeUndefined(ctx);
    }
    if (state.junit_outfile != null and state.junit_results.items.len > 0) {
        state.junit_results.items[state.junit_results.items.len - 1].passed = false;
        if (argumentCount >= 1) {
            if (jsValueToUtf8Alloc(state.ctx, state.allocator, arguments[0])) |msg| {
                state.junit_results.items[state.junit_results.items.len - 1].message = msg;
            }
        }
        writeJUnitIfRequested(state);
    }
    // 每次失败都累计；默认不因单次失败停止，会继续跑后续用例；仅当 fail_fast（SHU_TEST_BAIL/--fail-fast）时写汇总并停止。
    state.case_failed += 1;
    // 在 shu test 子进程模式下，失败发生后立即刷新一次 cases 文件，防止后续调度异常提前结束时仍保留初始 0,0,0。
    // 正常结束路径会再次覆盖为最终汇总，因此这里是幂等的提前持久化。
    if (isRunningUnderShuTest()) writeCaseSummaryToStderr(state);
    // 同步抛错时 job_index 尚未在 runNext 中 +1，失败用例在 job_index；异步 reject 时已在 +1 后，失败用例在 job_index - 1。用 reject_is_sync 区分，避免连续两个 run_test 时误把下一用例当成本次失败。
    const failed_job_idx: usize = blk: {
        if (state.active_run_test_job_index) |idx| break :blk idx;
        if (state.reject_is_sync) {
            state.reject_is_sync = false;
            if (state.job_index < state.jobs.items.len and state.jobs.items[state.job_index] == .run_test)
                break :blk state.job_index;
        } else if (state.job_index > 0 and state.jobs.items[state.job_index - 1] == .run_test) {
            break :blk state.job_index - 1;
        } else if (state.job_index < state.jobs.items.len and state.jobs.items[state.job_index] == .run_test) {
            break :blk state.job_index;
        }
        break :blk state.jobs.items.len;
    };
    state.last_failed_job_index = failed_job_idx;
    state.active_run_test_job_index = null;
    if (failed_job_idx < state.jobs.items.len) {
        const p = state.jobs.items[failed_job_idx].run_test;
        const elapsed = nowMs() - state.current_test_start_ms;
        const fail_info = if (argumentCount >= 1)
            extractFailureMessageAndStack(ctx, state.allocator, arguments[0])
        else
            FailureInfo{ .message = null, .stack = null };
        defer if (fail_info.message) |m| state.allocator.free(m);
        defer if (fail_info.stack) |s| state.allocator.free(s);
        if (runner.getFullTestName(state.allocator, p.suite, p.test_idx)) |full_name| {
            defer state.allocator.free(full_name);
            printTestResultLine(full_name, .fail, elapsed);
            appendCaseDetailWithError(state, full_name, "failed", elapsed, fail_info.message, fail_info.stack);
        } else |_| {
            const t_name = p.suite.tests.items[p.test_idx].name;
            printTestResultLine(t_name, .fail, elapsed);
            appendCaseDetailWithError(state, t_name, "failed", elapsed, fail_info.message, fail_info.stack);
        }
        // 失败时打印断言/异常信息，便于排查
        if (argumentCount >= 1) printAssertionErrorMessage(ctx, state.allocator, arguments[0]);
    } else {
        // 同一 job_index 只打印一次，避免 Promise 链多次 reject 导致刷屏与死循环感
        if (state.last_printed_generic_fail_job_index != state.job_index) {
            state.last_printed_generic_fail_job_index = state.job_index;
            printTestLineStdout("(test failed, job_index={d})\n", .{state.job_index});
        }
    }
    // 在附加失败明细后刷新一次明细文件，避免异常退出时丢失 case 列表。
    if (isRunningUnderShuTest()) writeCaseDetailsToFileIfRequested(state);
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
    if (state.fail_fast) {
        // --fail-fast / SHU_TEST_BAIL：立即写 cases 并 reject，停止后续用例
        writeCaseSummaryToStderr(state);
        writeCaseDetailsToFileIfRequested(state);
        const err = if (argumentCount >= 1) arguments[0] else jsc.JSValueMakeUndefined(ctx);
        var args = [_]jsc.JSValueRef{err};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(state.reject_ref), null, 1, &args, null);
    } else {
        // 默认：跑完全部用例；不 reject。仅同步抛错时 job_index 尚未 +1；标记已推进并 +1，外层 runNext 返回时不再 +1
        if (failed_job_idx == state.job_index) {
            state.reject_wrapper_did_advance = true;
        }
        // 强制推进到失败用例之后，保证 setImmediate 回调绝不会再次运行同一用例，消除死循环
        if (failed_job_idx < state.jobs.items.len) {
            state.job_index = failed_job_idx + 1;
        } else {
            // 无法解析出 run_test 时（如钩子失败），直接推进到末尾，下一轮 runNext 会结束
            state.job_index = state.jobs.items.len;
        }
        const k_set_imm = jsc.JSStringCreateWithUTF8CString("setImmediate");
        defer jsc.JSStringRelease(k_set_imm);
        const k_run_next = jsc.JSStringCreateWithUTF8CString("__shu_test_run_next");
        defer jsc.JSStringRelease(k_run_next);
        const set_imm = jsc.JSObjectGetProperty(ctx, global, k_set_imm, null);
        const run_next_fn = jsc.JSObjectGetProperty(ctx, global, k_run_next, null);
        if (!jsc.JSValueIsUndefined(ctx, set_imm) and jsc.JSObjectIsFunction(ctx, @ptrCast(set_imm)) and
            !jsc.JSValueIsUndefined(ctx, run_next_fn) and jsc.JSObjectIsFunction(ctx, @ptrCast(run_next_fn)))
        {
            var one_arg = [_]jsc.JSValueRef{run_next_fn};
            _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(set_imm), null, 1, &one_arg, null);
        } else {
            RunState.runNext(state);
        }
    }
    return jsc.JSValueMakeUndefined(ctx);
}

fn getRejectWrapper(ctx: jsc.JSContextRef) jsc.JSValueRef {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k = jsc.JSStringCreateWithUTF8CString("__shu_test_reject_wrapper");
    defer jsc.JSStringRelease(k);
    return jsc.JSObjectGetProperty(ctx, global, k, null);
}

/// 仅执行 runNext、不经过 advance；供 !fail_fast 时 setImmediate 调度，避免嵌套导致 job_index 被覆盖。
fn runNextOnlyCallback(
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

/// 将字符串中 XML 特殊字符转义为实体，用于 JUnit name/message。调用方负责 free 返回值。
fn escapeXml(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var list = std.ArrayList(u8).initCapacity(allocator, s.len + 32) catch return error.OutOfMemory;
    defer list.deinit(allocator);
    for (s) |ch| {
        switch (ch) {
            '&' => try list.appendSlice(allocator, "&amp;"),
            '<' => try list.appendSlice(allocator, "&lt;"),
            '>' => try list.appendSlice(allocator, "&gt;"),
            '"' => try list.appendSlice(allocator, "&quot;"),
            '\'' => try list.appendSlice(allocator, "&apos;"),
            else => try list.append(allocator, ch),
        }
    }
    return list.toOwnedSlice(allocator);
}

/// 当 state.snapshot_file 与 snapshot_update 均设置时，将全局 __shu_snapshot_store 序列化为 JSON 写入该文件；会创建项目根下 snapshots 目录及父级路径。
fn saveSnapshotToFileIfRequested(state: *RunState) void {
    if (state.snapshot_file == null or !state.snapshot_update) return;
    saveSnapshotToFile(state);
}

/// 当 state.coverage_dir 已设置时，创建该目录并写入占位 lcov.info（当前未做行/分支采集，仅保证 --coverage 流程可运行）。
fn writeCoveragePlaceholderIfRequested(state: *RunState) void {
    const dir = state.coverage_dir orelse return;
    const io = libs_process.getProcessIo() orelse return;
    const path_abs = if (libs_io.pathIsAbsolute(dir))
        dir
    else if (state.test_cwd) |cwd|
        libs_io.pathJoin(state.allocator, &.{ cwd, dir }) catch return
    else blk: {
        var path_buf: [libs_io.max_path_bytes]u8 = undefined;
        const cwd = libs_io.realpath(".", &path_buf) catch return;
        break :blk libs_io.pathJoin(state.allocator, &.{ cwd, dir }) catch return;
    };
    defer if (!libs_io.pathIsAbsolute(dir)) state.allocator.free(path_abs);
    libs_io.makePathAbsolute(path_abs) catch return;
    const lcov_path = libs_io.pathJoin(state.allocator, &.{ path_abs, "lcov.info" }) catch return;
    defer state.allocator.free(lcov_path);
    var file = libs_io.createFileAbsolute(lcov_path, .{}) catch return;
    defer file.close(io);
    const placeholder = "TN:\nend_of_record\n";
    file.writeStreamingAll(io, placeholder) catch return;
}

/// 从 path（相对 cwd）读取 JSON 对象并填充全局 __shu_snapshot_store；文件不存在或解析失败时静默返回。
fn loadSnapshotFromFile(state: *RunState) void {
    const path = state.snapshot_file orelse return;
    const io = libs_process.getProcessIo() orelse return;
    var cwd = libs_io.openDirCwd(".", .{}) catch return;
    defer cwd.close(io);
    const content = cwd.readFileAlloc(io, path, state.allocator, std.Io.Limit.unlimited) catch return;
    defer state.allocator.free(content);
    var parsed = std.json.parseFromSlice(std.json.Value, state.allocator, content, .{ .allocate = .alloc_always }) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const global = jsc.JSContextGetGlobalObject(state.ctx);
    const k_store = jsc.JSStringCreateWithUTF8CString("__shu_snapshot_store");
    defer jsc.JSStringRelease(k_store);
    var store_val = jsc.JSObjectGetProperty(state.ctx, global, k_store, null);
    if (jsc.JSValueIsUndefined(state.ctx, store_val) or jsc.JSValueIsNull(state.ctx, store_val)) {
        store_val = jsc.JSObjectMake(state.ctx, null, null);
        _ = jsc.JSObjectSetProperty(state.ctx, global, k_store, store_val, jsc.kJSPropertyAttributeNone, null);
    }
    const store = jsc.JSValueToObject(state.ctx, store_val, null) orelse return;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        const str_val = switch (entry.value_ptr.*) {
            .string => entry.value_ptr.*.string,
            .number_string => entry.value_ptr.*.number_string,
            else => continue,
        };
        const key_z = state.allocator.dupeZ(u8, entry.key_ptr.*) catch continue;
        defer state.allocator.free(key_z);
        const k_js = jsc.JSStringCreateWithUTF8CString(key_z.ptr);
        defer jsc.JSStringRelease(k_js);
        const val_z = state.allocator.dupeZ(u8, str_val) catch continue;
        defer state.allocator.free(val_z);
        const v_ref = jsc.JSStringCreateWithUTF8CString(val_z.ptr);
        defer jsc.JSStringRelease(v_ref);
        const v_js = jsc.JSValueMakeString(state.ctx, v_ref);
        _ = jsc.JSObjectSetProperty(state.ctx, store, k_js, v_js, jsc.kJSPropertyAttributeNone, null);
    }
}

/// JSON 字符串转义：将 " 与 \ 转义后追加到 list。
fn appendJsonEscaped(allocator: std.mem.Allocator, list: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => try list.append(allocator, ch),
        }
    }
}

/// 将全局 __shu_snapshot_store 的键值（均为字符串）序列化为 JSON 并写入 state.snapshot_file；若 state.test_cwd 已设置则用其解析相对路径，否则用 realpath(".")；会创建父目录。
fn saveSnapshotToFile(state: *RunState) void {
    const path = state.snapshot_file orelse return;
    const ctx = state.ctx;
    const allocator = state.allocator;
    const io = libs_process.getProcessIo() orelse return;
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_store = jsc.JSStringCreateWithUTF8CString("__shu_snapshot_store");
    defer jsc.JSStringRelease(k_store);
    const store_val = jsc.JSObjectGetProperty(ctx, global, k_store, null);
    if (jsc.JSValueIsUndefined(ctx, store_val) or jsc.JSValueIsNull(ctx, store_val)) return;
    const store = jsc.JSValueToObject(ctx, store_val, null) orelse return;
    const names = jsc.JSObjectCopyPropertyNames(ctx, store);
    defer jsc.JSPropertyNameArrayRelease(names);
    const count = jsc.JSPropertyNameArrayGetCount(names);
    var out = std.ArrayList(u8).initCapacity(allocator, 4096) catch return;
    defer out.deinit(allocator);
    out.append(allocator, '{') catch return;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (i > 0) out.appendSlice(allocator, ",") catch return;
        const name_ref = jsc.JSPropertyNameArrayGetNameAtIndex(names, i);
        const size = jsc.JSStringGetMaximumUTF8CStringSize(name_ref);
        var buf = allocator.alloc(u8, size) catch return;
        defer allocator.free(buf);
        const len = jsc.JSStringGetUTF8CString(name_ref, buf.ptr, size);
        const key = buf[0..len];
        const val_ref = jsc.JSObjectGetProperty(ctx, store, name_ref, null);
        const val_str_ref = jsc.JSValueToStringCopy(ctx, val_ref, null);
        defer jsc.JSStringRelease(val_str_ref);
        const val_size = jsc.JSStringGetMaximumUTF8CStringSize(val_str_ref);
        var val_buf = allocator.alloc(u8, val_size) catch return;
        defer allocator.free(val_buf);
        const val_len = jsc.JSStringGetUTF8CString(val_str_ref, val_buf.ptr, val_size);
        const val_slice = val_buf[0..val_len];
        out.append(allocator, '"') catch return;
        appendJsonEscaped(allocator, &out, key) catch return;
        out.appendSlice(allocator, "\":\"") catch return;
        appendJsonEscaped(allocator, &out, val_slice) catch return;
        out.append(allocator, '"') catch return;
    }
    out.append(allocator, '}') catch return;
    const path_abs = if (libs_io.pathIsAbsolute(path))
        path
    else if (state.test_cwd) |cwd|
        libs_io.pathJoin(allocator, &.{ cwd, path }) catch return
    else blk: {
        var path_buf: [libs_io.max_path_bytes]u8 = undefined;
        const cwd = libs_io.realpath(".", &path_buf) catch return;
        break :blk libs_io.pathJoin(allocator, &.{ cwd, path }) catch return;
    };
    defer if (!libs_io.pathIsAbsolute(path)) allocator.free(path_abs);
    const parent = libs_io.pathDirname(path_abs) orelse return;
    libs_io.makePathAbsolute(parent) catch {};
    var file = libs_io.createFileAbsolute(path_abs, .{}) catch return;
    defer file.close(io);
    file.writeStreamingAll(io, out.items) catch return;
}

/// 返回当前时间（毫秒）；无 process io 时返回 0。
fn nowMs() i64 {
    const io = libs_process.getProcessIo() orelse return 0;
    return @as(i64, @intCast(@divTrunc(std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds, 1_000_000)));
}

/// 是否由 shu test 子进程运行（有 SHU_TEST_FILE_PATH 时）：测试行写 stderr（父进程 .stderr = .inherit 时直接到终端），用例数写 SHU_TEST_CASES_FILE 文件。
fn isRunningUnderShuTest() bool {
    return c.getenv("SHU_TEST_FILE_PATH") != null;
}

/// 在 shu test 下、run() 尚未执行前写入 0,0,0 到 SHU_TEST_CASES_FILE，确保子进程提前退出时父进程仍能读到文件；run() 结束时再覆盖为真实计数。
fn writeInitialZeroCasesFile() void {
    if (!isRunningUnderShuTest()) return;
    const path_z = c.getenv("SHU_TEST_CASES_FILE") orelse return;
    const path = std.mem.span(path_z);
    var f = libs_io.createFileAbsolute(path, .{}) catch return;
    const io = libs_process.getProcessIo() orelse return;
    defer f.close(io);
    var line_buf: [80]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "__SHU_TEST_CASES__{{\"passed\":0,\"failed\":0,\"skipped\":0}}\n", .{}) catch return;
    var w_buf: [64]u8 = undefined;
    var w = f.writer(io, &w_buf);
    _ = w.interface.writeAll(line) catch return;
    _ = w.interface.flush() catch return;
}

/// 向 stderr 或 stdout 打印一行测试输出（Deno 风格：用例名 ... ok/fail/skipped (Nms)）。
/// 当 isRunningUnderShuTest() 时写 process io 的 stderr，父进程 .stderr = .inherit 时直接显示在终端；否则写 stdout 或 std.debug.print。
fn printTestLineStdout(comptime fmt: []const u8, args: anytype) void {
    if (isRunningUnderShuTest()) {
        if (libs_process.getProcessIo()) |io| {
            var buf: [1024]u8 = undefined;
            var w = std.Io.File.Writer.init(std.Io.File.stderr(), io, &buf);
            w.interface.print(fmt, args) catch return;
            w.interface.flush() catch {};
        } else {
            std.debug.print(fmt, args);
        }
        return;
    }
    if (libs_process.getProcessIo()) |io| {
        var buf: [1024]u8 = undefined;
        var w = std.Io.File.Writer.init(std.Io.File.stdout(), io, &buf);
        w.interface.print(fmt, args) catch return;
        w.interface.flush() catch {};
    } else {
        std.debug.print(fmt, args);
    }
}

/// 失败时从 JS Error 或字符串取内容并打印到与用例结果同一流（shu test 下为 stderr），便于排查。
/// 仅当能解析出可读的 message 或字符串时才打印；若得到的是数字转成的字符串（如 -3.44e-103）则跳过，避免垃圾输出。
fn printAssertionErrorMessage(ctx: jsc.JSContextRef, allocator: std.mem.Allocator, err_value: jsc.JSValueRef) void {
    if (jsc.JSValueIsUndefined(ctx, err_value) or jsc.JSValueIsNull(ctx, err_value)) return;
    var msg_slice: ?[]const u8 = null;
    defer if (msg_slice) |s| allocator.free(s);
    if (jsc.JSValueToObject(ctx, err_value, null)) |obj| {
        const k_message = jsc.JSStringCreateWithUTF8CString("message");
        defer jsc.JSStringRelease(k_message);
        const msg_val = jsc.JSObjectGetProperty(ctx, obj, k_message, null);
        msg_slice = jsValueToUtf8Alloc(ctx, allocator, msg_val);
    }
    if (msg_slice == null) msg_slice = jsValueToUtf8Alloc(ctx, allocator, err_value);
    // 仅打印可读消息：长度合理且不以数字/科学计数开头（避免引擎传入数字转成字符串如 -3.44e-103）
    if (msg_slice) |s| {
        if (s.len >= 2 and s.len <= 512) {
            const first = s[0];
            const looks_like_number = (first == '-' or first == '+') or std.ascii.isDigit(first);
            if (!looks_like_number) printTestLineStdout("  {s}\n", .{s});
        }
    }
}

/// 提取失败异常的 message/stack（均为可选）。返回值中的切片由调用方负责 free。
fn extractFailureMessageAndStack(
    ctx: jsc.JSContextRef,
    allocator: std.mem.Allocator,
    err_value: jsc.JSValueRef,
) FailureInfo {
    if (jsc.JSValueIsUndefined(ctx, err_value) or jsc.JSValueIsNull(ctx, err_value)) return .{ .message = null, .stack = null };
    var message: ?[]const u8 = null;
    var stack: ?[]const u8 = null;
    if (jsc.JSValueToObject(ctx, err_value, null)) |obj| {
        const k_message = jsc.JSStringCreateWithUTF8CString("message");
        defer jsc.JSStringRelease(k_message);
        const k_stack = jsc.JSStringCreateWithUTF8CString("stack");
        defer jsc.JSStringRelease(k_stack);
        const message_val = jsc.JSObjectGetProperty(ctx, obj, k_message, null);
        const stack_val = jsc.JSObjectGetProperty(ctx, obj, k_stack, null);
        message = jsValueToUtf8Alloc(ctx, allocator, message_val);
        stack = jsValueToUtf8Alloc(ctx, allocator, stack_val);
    }
    if (message == null) message = jsValueToUtf8Alloc(ctx, allocator, err_value);
    return .{ .message = message, .stack = stack };
}

/// 用例结果类型，用于 printTestResultLine 着色。
const TestResultKind = enum { ok, fail, skipped };

/// 打印单条用例结果行并着色：ok 绿、fail 红、skipped 黄、耗时 (Nms) 青；非 TTY 不插 ANSI。输出为英文。
fn printTestResultLine(name: []const u8, kind: TestResultKind, elapsed_ms: ?i64) void {
    const use_color = if (isRunningUnderShuTest()) c.isatty(2) != 0 else c.isatty(1) != 0;
    if (use_color) {
        switch (kind) {
            .ok => {
                const ms = elapsed_ms orelse 0;
                printTestLineStdout("{s} ... {s}ok{s} ({s}{d}ms{s})\n", .{ name, c_green, c_reset, c_cyan, ms, c_reset });
            },
            .fail => {
                const ms = elapsed_ms orelse 0;
                printTestLineStdout("{s} ... {s}fail{s} ({s}{d}ms{s})\n", .{ name, c_red, c_reset, c_cyan, ms, c_reset });
            },
            .skipped => printTestLineStdout("{s} ... {s}skipped{s}\n", .{ name, c_yellow, c_reset }),
        }
    } else {
        switch (kind) {
            .ok => printTestLineStdout("{s} ... ok ({d}ms)\n", .{ name, elapsed_ms orelse 0 }),
            .fail => printTestLineStdout("{s} ... fail ({d}ms)\n", .{ name, elapsed_ms orelse 0 }),
            .skipped => printTestLineStdout("{s} ... skipped\n", .{name}),
        }
    }
}

/// 写入用例汇总：shu test 时写 SHU_TEST_CASES_FILE 指定路径（CLI 读该文件汇总）；否则写 stderr。
fn writeCaseSummaryToStderr(state: *RunState) void {
    if (isRunningUnderShuTest()) {
        const path_z = c.getenv("SHU_TEST_CASES_FILE") orelse return;
        const path = std.mem.span(path_z);
        var f = libs_io.createFileAbsolute(path, .{}) catch return;
        const io = libs_process.getProcessIo() orelse return;
        defer f.close(io);
        var line_buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "__SHU_TEST_CASES__{{\"passed\":{d},\"failed\":{d},\"skipped\":{d}}}\n", .{
            state.case_passed,
            state.case_failed,
            state.case_skipped,
        }) catch return;
        var w_buf: [64]u8 = undefined;
        var w = f.writer(io, &w_buf);
        _ = w.interface.writeAll(line) catch return;
        _ = w.interface.flush() catch return;
        return;
    }
    if (libs_process.getProcessIo()) |io| {
        var buf: [128]u8 = undefined;
        var w = std.Io.File.Writer.init(std.Io.File.stderr(), io, &buf);
        w.interface.print("__SHU_TEST_CASES__{{\"passed\":{d},\"failed\":{d},\"skipped\":{d}}}\n", .{
            state.case_passed,
            state.case_failed,
            state.case_skipped,
        }) catch {};
        w.interface.flush() catch {};
    }
    std.debug.print("__SHU_TEST_CASES__{{\"passed\":{d},\"failed\":{d},\"skipped\":{d}}}\n", .{
        state.case_passed,
        state.case_failed,
        state.case_skipped,
    });
}

/// 记录单条用例明细（名称、状态、耗时）；用于最终 JSON/HTML/Markdown/JUnit 报告聚合。
/// [Allocates] 内部复制 name/status，错误字段可选并复制；由 RunState 在结束时统一释放。
fn appendCaseDetailWithError(
    state: *RunState,
    name: []const u8,
    status: []const u8,
    elapsed_ms: i64,
    error_message: ?[]const u8,
    error_stack: ?[]const u8,
) void {
    const name_owned = state.allocator.dupe(u8, name) catch return;
    errdefer state.allocator.free(name_owned);
    const status_owned = state.allocator.dupe(u8, status) catch return;
    errdefer state.allocator.free(status_owned);
    const msg_owned = if (error_message) |m| state.allocator.dupe(u8, m) catch null else null;
    errdefer if (msg_owned) |m| state.allocator.free(m);
    const stack_owned = if (error_stack) |s| state.allocator.dupe(u8, s) catch null else null;
    state.detail_results.append(state.allocator, .{
        .name = name_owned,
        .status = status_owned,
        .elapsed_ms = elapsed_ms,
        .error_message = msg_owned,
        .error_stack = stack_owned,
    }) catch {
        state.allocator.free(name_owned);
        state.allocator.free(status_owned);
        if (msg_owned) |m| state.allocator.free(m);
        if (stack_owned) |s| state.allocator.free(s);
    };
}

/// 简版用例明细记录（无错误信息）。
fn appendCaseDetail(state: *RunState, name: []const u8, status: []const u8, elapsed_ms: i64) void {
    appendCaseDetailWithError(state, name, status, elapsed_ms, null, null);
}

/// 若设置 SHU_TEST_DETAILS_FILE，则输出当前测试文件的用例明细 JSON（供 shu test 主进程聚合）。
/// JSON 结构：{ file, totalMs, cases:[{name,status,elapsedMs,errorMessage?,errorStack?}] }。
fn writeCaseDetailsToFileIfRequested(state: *RunState) void {
    if (!isRunningUnderShuTest()) return;
    const path_z = c.getenv("SHU_TEST_DETAILS_FILE") orelse return;
    const path = std.mem.span(path_z);
    const file_display = if (c.getenv("SHU_TEST_FILE_PATH")) |p| std.mem.span(p) else "unknown";
    const total_ms: i64 = @max(0, nowMs() - state.run_start_ms);

    var out = std.ArrayList(u8).initCapacity(state.allocator, 1024) catch return;
    defer out.deinit(state.allocator);
    out.appendSlice(state.allocator, "{\"file\":\"") catch return;
    appendJsonEscaped(state.allocator, &out, file_display) catch return;
    out.appendSlice(state.allocator, "\",\"totalMs\":") catch return;
    var num_buf: [32]u8 = undefined;
    const total_s = std.fmt.bufPrint(&num_buf, "{d}", .{total_ms}) catch return;
    out.appendSlice(state.allocator, total_s) catch return;
    out.appendSlice(state.allocator, ",\"cases\":[") catch return;
    for (state.detail_results.items, 0..) |d, i| {
        if (i != 0) out.appendSlice(state.allocator, ",") catch return;
        out.appendSlice(state.allocator, "{\"name\":\"") catch return;
        appendJsonEscaped(state.allocator, &out, d.name) catch return;
        out.appendSlice(state.allocator, "\",\"status\":\"") catch return;
        appendJsonEscaped(state.allocator, &out, d.status) catch return;
        out.appendSlice(state.allocator, "\",\"elapsedMs\":") catch return;
        const elapsed_s = std.fmt.bufPrint(&num_buf, "{d}", .{d.elapsed_ms}) catch return;
        out.appendSlice(state.allocator, elapsed_s) catch return;
        if (d.error_message) |msg| {
            out.appendSlice(state.allocator, ",\"errorMessage\":\"") catch return;
            appendJsonEscaped(state.allocator, &out, msg) catch return;
            out.appendSlice(state.allocator, "\"") catch return;
        }
        if (d.error_stack) |stk| {
            out.appendSlice(state.allocator, ",\"errorStack\":\"") catch return;
            appendJsonEscaped(state.allocator, &out, stk) catch return;
            out.appendSlice(state.allocator, "\"") catch return;
        }
        out.appendSlice(state.allocator, "}") catch return;
    }
    out.appendSlice(state.allocator, "]}") catch return;

    const io = libs_process.getProcessIo() orelse return;
    var f = libs_io.createFileAbsolute(path, .{}) catch return;
    defer f.close(io);
    f.writeStreamingAll(io, out.items) catch return;
}

/// 当 SHU_TEST_REPORTER=junit 且 SHU_TEST_REPORTER_OUTFILE 已设置时，将收集的用例结果写入 JUnit XML 文件；写完后释放各 result 的 name/message 并清空列表。
fn writeJUnitIfRequested(state: *RunState) void {
    const outfile = state.junit_outfile orelse return;
    const io = libs_process.getProcessIo() orelse return;
    var out = std.ArrayList(u8).initCapacity(state.allocator, 4096) catch return;
    defer out.deinit(state.allocator);
    var failures: u32 = 0;
    for (state.junit_results.items) |r| {
        if (!r.passed) failures += 1;
    }
    var buf: [64]u8 = undefined;
    out.appendSlice(state.allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<testsuites>\n<testsuite name=\"shu\" tests=\"") catch return;
    out.appendSlice(state.allocator, std.fmt.bufPrint(&buf, "{d}", .{state.junit_results.items.len}) catch return) catch return;
    out.appendSlice(state.allocator, "\" failures=\"") catch return;
    out.appendSlice(state.allocator, std.fmt.bufPrint(&buf, "{d}", .{failures}) catch return) catch return;
    out.appendSlice(state.allocator, "\" errors=\"0\">\n") catch return;
    for (state.junit_results.items) |r| {
        const name_esc = escapeXml(state.allocator, r.name) catch return;
        defer state.allocator.free(name_esc);
        if (r.passed) {
            out.appendSlice(state.allocator, "<testcase name=\"") catch return;
            out.appendSlice(state.allocator, name_esc) catch return;
            out.appendSlice(state.allocator, "\"/>\n") catch return;
        } else {
            const msg_esc = if (r.message) |m| escapeXml(state.allocator, m) catch null else null;
            defer if (msg_esc) |e| state.allocator.free(e);
            const msg_attr = if (msg_esc) |e| e else "";
            out.appendSlice(state.allocator, "<testcase name=\"") catch return;
            out.appendSlice(state.allocator, name_esc) catch return;
            out.appendSlice(state.allocator, "\"><failure message=\"") catch return;
            out.appendSlice(state.allocator, msg_attr) catch return;
            out.appendSlice(state.allocator, "\"/></testcase>\n") catch return;
        }
    }
    out.appendSlice(state.allocator, "</testsuite>\n</testsuites>\n") catch return;
    const path_abs = if (libs_io.pathIsAbsolute(outfile))
        outfile
    else blk: {
        var path_buf: [libs_io.max_path_bytes]u8 = undefined;
        const cwd = libs_io.realpath(".", &path_buf) catch return;
        break :blk libs_io.pathJoin(state.allocator, &.{ cwd, outfile }) catch return;
    };
    defer if (!libs_io.pathIsAbsolute(outfile)) state.allocator.free(path_abs);
    var file = libs_io.createFileAbsolute(path_abs, .{}) catch return;
    defer file.close(io);
    file.writeStreamingAll(io, out.items) catch return;
    for (state.junit_results.items) |*r| {
        state.allocator.free(r.name);
        if (r.message) |m| state.allocator.free(m);
    }
    state.junit_results.shrinkRetainingCapacity(0);
}

/// run()：纯 Zig 构建任务队列，用 Promise(executor) 启动，返回 Promise；失败时 reject 并设 process.exitCode = 1。支持 run({ timeout }) 传默认超时（毫秒），当前仅存储。
fn runCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount >= 1 and !jsc.JSValueIsUndefined(ctx, arguments[0]) and !jsc.JSValueIsNull(ctx, arguments[0])) {
        if (jsc.JSValueToObject(ctx, arguments[0], null)) |opts_obj| {
            const k_timeout = jsc.JSStringCreateWithUTF8CString("timeout");
            defer jsc.JSStringRelease(k_timeout);
            const v_timeout = jsc.JSObjectGetProperty(ctx, opts_obj, k_timeout, null);
            if (!jsc.JSValueIsUndefined(ctx, v_timeout)) {
                const n = jsc.JSValueToNumber(ctx, v_timeout, null);
                if (n >= 0 and n <= 0xFFFF_FFFF and std.math.isFinite(n)) {
                    const global = jsc.JSContextGetGlobalObject(ctx);
                    const k = jsc.JSStringCreateWithUTF8CString("__shu_default_timeout_ms");
                    defer jsc.JSStringRelease(k);
                    _ = jsc.JSObjectSetProperty(ctx, global, k, jsc.JSValueMakeNumber(ctx, n), jsc.kJSPropertyAttributeNone, null);
                }
            }
        }
    }
    const Promise_ctor = promise_mod.getPromiseConstructor(ctx) orelse return jsc.JSValueMakeUndefined(ctx);
    const k_executor = jsc.JSStringCreateWithUTF8CString("");
    defer jsc.JSStringRelease(k_executor);
    const executor_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_executor, runExecutorCallback);
    var args = [_]jsc.JSValueRef{executor_fn};
    return jsc.JSObjectCallAsConstructor(ctx, Promise_ctor, 1, &args, null);
}

/// 将用户 options 对象与单键值合并后返回新对象；用于 it.skip/todo/only(name, fn, options) 时保留 options 并加上 skip/todo/only 标志。纯 Zig：遍历 base 属性复制到新对象再设 key。
/// [Borrows] 返回的 JS 对象由 JSC 管理。
fn mergeOptionsWithFlag(
    ctx: jsc.JSContextRef,
    _: std.mem.Allocator,
    base: jsc.JSValueRef,
    key_utf8: []const u8,
    value: jsc.JSValueRef,
) jsc.JSValueRef {
    const base_obj = jsc.JSValueToObject(ctx, base, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const out = jsc.JSObjectMake(ctx, null, null);
    const names = jsc.JSObjectCopyPropertyNames(ctx, base_obj);
    defer jsc.JSPropertyNameArrayRelease(names);
    const count = jsc.JSPropertyNameArrayGetCount(names);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const name_ref = jsc.JSPropertyNameArrayGetNameAtIndex(names, @intCast(i));
        const val = jsc.JSObjectGetProperty(ctx, base_obj, name_ref, null);
        _ = jsc.JSObjectSetProperty(ctx, out, name_ref, val, jsc.kJSPropertyAttributeNone, null);
    }
    const key_str = jsc.JSStringCreateWithUTF8CString(key_utf8.ptr);
    defer jsc.JSStringRelease(key_str);
    _ = jsc.JSObjectSetProperty(ctx, out, key_str, value, jsc.kJSPropertyAttributeNone, null);
    return out;
}

/// test.skip(name, fn [, options]) / it.skip(...)：等价于 it(name, fn, { ...options, skip: true })
fn skipCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    var args: [3]jsc.JSValueRef = undefined;
    args[0] = arguments[0];
    args[1] = arguments[1];
    args[2] = if (argumentCount >= 3)
        mergeOptionsWithFlag(ctx, allocator, arguments[2], "skip", jsc.JSValueMakeBoolean(ctx, true))
    else blk: {
        const opts = jsc.JSObjectMake(ctx, null, null);
        const k_skip = jsc.JSStringCreateWithUTF8CString("skip");
        defer jsc.JSStringRelease(k_skip);
        _ = jsc.JSObjectSetProperty(ctx, opts, k_skip, jsc.JSValueMakeBoolean(ctx, true), jsc.kJSPropertyAttributeNone, null);
        break :blk opts;
    };
    const global = jsc.JSContextGetGlobalObject(ctx);
    // 显式初始化 exception 缓冲，避免无异常场景下未初始化值向上冒泡。
    var exc_buf: [1]jsc.JSValueRef = .{jsc.JSValueMakeUndefined(ctx)};
    return itCallback(ctx, global, global, 3, &args, exc_buf[0..].ptr);
}

/// test.todo(name, fn [, options]) / it.todo(...)：等价于 it(name, fn, { ...options, todo: true })
fn todoCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    var args: [3]jsc.JSValueRef = undefined;
    args[0] = arguments[0];
    args[1] = arguments[1];
    args[2] = if (argumentCount >= 3)
        mergeOptionsWithFlag(ctx, allocator, arguments[2], "todo", jsc.JSValueMakeBoolean(ctx, true))
    else blk: {
        const opts = jsc.JSObjectMake(ctx, null, null);
        const k_todo = jsc.JSStringCreateWithUTF8CString("todo");
        defer jsc.JSStringRelease(k_todo);
        _ = jsc.JSObjectSetProperty(ctx, opts, k_todo, jsc.JSValueMakeBoolean(ctx, true), jsc.kJSPropertyAttributeNone, null);
        break :blk opts;
    };
    const global = jsc.JSContextGetGlobalObject(ctx);
    // 显式初始化 exception 缓冲，避免无异常场景下未初始化值向上冒泡。
    var exc_buf: [1]jsc.JSValueRef = .{jsc.JSValueMakeUndefined(ctx)};
    return itCallback(ctx, global, global, 3, &args, exc_buf[0..].ptr);
}

/// test.only(name, fn [, options]) / it.only(...)：仅运行该测试（需配合 run 时 has_only）
fn onlyCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    var args: [3]jsc.JSValueRef = undefined;
    args[0] = arguments[0];
    args[1] = arguments[1];
    args[2] = if (argumentCount >= 3)
        mergeOptionsWithFlag(ctx, allocator, arguments[2], "only", jsc.JSValueMakeBoolean(ctx, true))
    else blk: {
        const opts = jsc.JSObjectMake(ctx, null, null);
        const k_only = jsc.JSStringCreateWithUTF8CString("only");
        defer jsc.JSStringRelease(k_only);
        _ = jsc.JSObjectSetProperty(ctx, opts, k_only, jsc.JSValueMakeBoolean(ctx, true), jsc.kJSPropertyAttributeNone, null);
        break :blk opts;
    };
    const global = jsc.JSContextGetGlobalObject(ctx);
    // 显式初始化 exception 缓冲，避免无异常场景下未初始化值向上冒泡。
    var exc_buf: [1]jsc.JSValueRef = .{jsc.JSValueMakeUndefined(ctx)};
    return itCallback(ctx, global, global, 3, &args, exc_buf[0..].ptr);
}

/// skipIf(condition) 返回的包装函数被调用时执行：从 callee 读 condition，按 (name, fn [, options]) 调 it
fn skipIfWrapperCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    callee: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception_out: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const k_cond = jsc.JSStringCreateWithUTF8CString("__shu_skipIf_cond");
    defer jsc.JSStringRelease(k_cond);
    const condition = jsc.JSObjectGetProperty(ctx, callee, k_cond, null);
    if (jsc.JSValueIsUndefined(ctx, condition)) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    var args: [3]jsc.JSValueRef = undefined;
    args[0] = arguments[0];
    args[1] = arguments[1];
    args[2] = if (argumentCount >= 3)
        mergeOptionsWithFlag(ctx, allocator, arguments[2], "skipIf", condition)
    else blk: {
        const opts = jsc.JSObjectMake(ctx, null, null);
        const k_skipIf = jsc.JSStringCreateWithUTF8CString("skipIf");
        defer jsc.JSStringRelease(k_skipIf);
        _ = jsc.JSObjectSetProperty(ctx, opts, k_skipIf, condition, jsc.kJSPropertyAttributeNone, null);
        break :blk opts;
    };
    const global = jsc.JSContextGetGlobalObject(ctx);
    return itCallback(ctx, global, global, 3, &args, exception_out);
}

/// test.skipIf(condition)：返回 (name, fn [, options]) 风格的函数，调用时等价于 it(name, fn, { ...options, skipIf: condition })
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
    const k_name = jsc.JSStringCreateWithUTF8CString("skipIf");
    defer jsc.JSStringRelease(k_name);
    const wrapper_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_name, skipIfWrapperCallback);
    const k_cond = jsc.JSStringCreateWithUTF8CString("__shu_skipIf_cond");
    defer jsc.JSStringRelease(k_cond);
    _ = jsc.JSObjectSetProperty(ctx, wrapper_fn, k_cond, condition, jsc.kJSPropertyAttributeNone, null);
    return wrapper_fn;
}

/// it.each(table)：返回 (name, fn) => void；对 table 每行注册一条 it(name_row, wrapper)。Bun 风格；约定：单槽 __shu_each_*。
fn itEachCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const table = arguments[0];
    const k_each_table = jsc.JSStringCreateWithUTF8CString("__shu_each_table");
    defer jsc.JSStringRelease(k_each_table);
    const k_name = jsc.JSStringCreateWithUTF8CString("each");
    defer jsc.JSStringRelease(k_name);
    const returned_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_name, eachReturnedCallback);
    _ = jsc.JSObjectSetProperty(ctx, returned_fn, k_each_table, table, jsc.kJSPropertyAttributeNone, null);
    return returned_fn;
}

/// it.each(table)(name, fn) 的 (name, fn) 回调：遍历 table，每行设 __shu_each_row/__shu_each_fn 后调 it(name_row, wrapper)
fn eachReturnedCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    callee: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception_out: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const name_val = arguments[0];
    const fn_val = arguments[1];
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(fn_val))) return jsc.JSValueMakeUndefined(ctx);
    const k_table = jsc.JSStringCreateWithUTF8CString("__shu_each_table");
    defer jsc.JSStringRelease(k_table);
    const table = jsc.JSObjectGetProperty(ctx, callee, k_table, null);
    if (jsc.JSValueIsUndefined(ctx, table) or jsc.JSValueIsNull(ctx, table)) return jsc.JSValueMakeUndefined(ctx);
    const table_obj = jsc.JSValueToObject(ctx, table, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const k_length = jsc.JSStringCreateWithUTF8CString("length");
    defer jsc.JSStringRelease(k_length);
    const len_val = jsc.JSObjectGetProperty(ctx, table_obj, k_length, null);
    const len_f = jsc.JSValueToNumber(ctx, len_val, null);
    if (!std.math.isFinite(len_f) or len_f < 0) return jsc.JSValueMakeUndefined(ctx);
    const len: usize = @intFromFloat(len_f);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_row = jsc.JSStringCreateWithUTF8CString("__shu_each_row");
    defer jsc.JSStringRelease(k_row);
    const k_fn = jsc.JSStringCreateWithUTF8CString("__shu_each_fn");
    defer jsc.JSStringRelease(k_fn);
    const k_wrapper = jsc.JSStringCreateWithUTF8CString("eachWrapper");
    defer jsc.JSStringRelease(k_wrapper);
    const wrapper_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_wrapper, eachWrapperCallback);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const row = jsc.JSObjectGetProperty(ctx, table_obj, jsc.JSValueMakeNumber(ctx, @floatFromInt(i)), null);
        _ = jsc.JSObjectSetProperty(ctx, global, k_row, row, jsc.kJSPropertyAttributeNone, null);
        _ = jsc.JSObjectSetProperty(ctx, global, k_fn, fn_val, jsc.kJSPropertyAttributeNone, null);
        var name_str_js: jsc.JSValueRef = name_val;
        if (jsc.JSObjectIsFunction(ctx, @ptrCast(name_val))) {
            const k_apply = jsc.JSStringCreateWithUTF8CString("apply");
            defer jsc.JSStringRelease(k_apply);
            const apply_fn = jsc.JSObjectGetProperty(ctx, jsc.JSValueToObject(ctx, name_val, null).?, k_apply, null);
            if (jsc.JSObjectIsFunction(ctx, @ptrCast(apply_fn))) {
                var apply_args = [_]jsc.JSValueRef{ jsc.JSValueMakeUndefined(ctx), row };
                name_str_js = jsc.JSObjectCallAsFunction(ctx, @ptrCast(apply_fn), name_val, 2, &apply_args, null);
            }
        }
        var it_args = [_]jsc.JSValueRef{ name_str_js, wrapper_fn };
        _ = itCallback(ctx, global, global, 2, &it_args, exception_out);
        if (!jsc.JSValueIsUndefined(ctx, exception_out[0])) return jsc.JSValueMakeUndefined(ctx);
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// it.each 每行用例的包装：调用 fn(t, ...row)，row 来自 __shu_each_row
fn eachWrapperCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const t = arguments[0];
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_row = jsc.JSStringCreateWithUTF8CString("__shu_each_row");
    defer jsc.JSStringRelease(k_row);
    const k_fn = jsc.JSStringCreateWithUTF8CString("__shu_each_fn");
    defer jsc.JSStringRelease(k_fn);
    const row = jsc.JSObjectGetProperty(ctx, global, k_row, null);
    const fn_val = jsc.JSObjectGetProperty(ctx, global, k_fn, null);
    if (jsc.JSValueIsUndefined(ctx, fn_val) or !jsc.JSObjectIsFunction(ctx, @ptrCast(fn_val))) return jsc.JSValueMakeUndefined(ctx);
    const row_obj = jsc.JSValueToObject(ctx, row, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const k_length = jsc.JSStringCreateWithUTF8CString("length");
    defer jsc.JSStringRelease(k_length);
    const len_val = jsc.JSObjectGetProperty(ctx, row_obj, k_length, null);
    const len_f = jsc.JSValueToNumber(ctx, len_val, null);
    if (!std.math.isFinite(len_f) or len_f < 0) return jsc.JSValueMakeUndefined(ctx);
    const len: usize = @intFromFloat(len_f);
    const k_Array = jsc.JSStringCreateWithUTF8CString("Array");
    defer jsc.JSStringRelease(k_Array);
    const Array_ctor = jsc.JSObjectGetProperty(ctx, global, k_Array, null);
    var len_arg = [_]jsc.JSValueRef{jsc.JSValueMakeNumber(ctx, @floatFromInt(len + 1))};
    const args_arr = jsc.JSObjectCallAsConstructor(ctx, @ptrCast(Array_ctor), 1, &len_arg, null);
    if (jsc.JSValueIsUndefined(ctx, args_arr)) return jsc.JSValueMakeUndefined(ctx);
    const k0 = jsc.JSStringCreateWithUTF8CString("0");
    defer jsc.JSStringRelease(k0);
    _ = jsc.JSObjectSetProperty(ctx, args_arr, k0, t, jsc.kJSPropertyAttributeNone, null);
    var idx: usize = 0;
    while (idx < len) : (idx += 1) {
        const el = jsc.JSObjectGetProperty(ctx, row_obj, jsc.JSValueMakeNumber(ctx, @floatFromInt(idx)), null);
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrintZ(&buf, "{d}", .{idx + 1}) catch break;
        const k_idx = jsc.JSStringCreateWithUTF8CString(s.ptr);
        defer jsc.JSStringRelease(k_idx);
        _ = jsc.JSObjectSetProperty(ctx, args_arr, k_idx, el, jsc.kJSPropertyAttributeNone, null);
    }
    const k_apply = jsc.JSStringCreateWithUTF8CString("apply");
    defer jsc.JSStringRelease(k_apply);
    const apply_fn = jsc.JSObjectGetProperty(ctx, jsc.JSValueToObject(ctx, fn_val, null).?, k_apply, null);
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(apply_fn))) return jsc.JSValueMakeUndefined(ctx);
    var apply_args = [_]jsc.JSValueRef{ jsc.JSValueMakeUndefined(ctx), args_arr };
    return jsc.JSObjectCallAsFunction(ctx, @ptrCast(apply_fn), fn_val, 2, &apply_args, null);
}

/// mock：与 node:test mock 兼容，由 mock.zig 实现；mock.fn([implementation]) 返回带 .calls、.callCount 的 mock 函数
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
    const allocator = globals.current_allocator orelse return jsc.JSObjectMake(ctx, null, null);
    return mock.getExports(ctx, allocator);
}

/// snapshot(name, value) 或 snapshot(value)：与 node:test snapshot 兼容的最小实现；用全局 __shu_snapshot_store 存 name→JSON.stringify(value)，再次同 name 时比较，不等则抛错。SHU_TEST_UPDATE_SNAPSHOTS=1 时仅写入 store 不比较。
fn snapshotCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception_out: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_store = jsc.JSStringCreateWithUTF8CString("__shu_snapshot_store");
    defer jsc.JSStringRelease(k_store);
    var store_val = jsc.JSObjectGetProperty(ctx, global, k_store, null);
    if (jsc.JSValueIsUndefined(ctx, store_val) or jsc.JSValueIsNull(ctx, store_val)) {
        store_val = jsc.JSObjectMake(ctx, null, null);
        _ = jsc.JSObjectSetProperty(ctx, global, k_store, store_val, jsc.kJSPropertyAttributeNone, null);
    }
    const store = jsc.JSValueToObject(ctx, store_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const name_js: jsc.JSValueRef = if (argumentCount >= 2) arguments[0] else blk: {
        const k_default = jsc.JSStringCreateWithUTF8CString("default");
        defer jsc.JSStringRelease(k_default);
        break :blk jsc.JSValueMakeString(ctx, k_default);
    };
    const value_js = if (argumentCount >= 2) arguments[1] else arguments[0];
    const k_json = jsc.JSStringCreateWithUTF8CString("JSON");
    defer jsc.JSStringRelease(k_json);
    const k_stringify = jsc.JSStringCreateWithUTF8CString("stringify");
    defer jsc.JSStringRelease(k_stringify);
    const json_val = jsc.JSObjectGetProperty(ctx, global, k_json, null);
    const json_obj = jsc.JSValueToObject(ctx, json_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const stringify_fn = jsc.JSObjectGetProperty(ctx, json_obj, k_stringify, null);
    if (jsc.JSValueIsUndefined(ctx, stringify_fn) or !jsc.JSObjectIsFunction(ctx, @ptrCast(stringify_fn))) return jsc.JSValueMakeUndefined(ctx);
    // 显式初始化，避免无异常时读取到未初始化值导致提前返回。
    var exc: jsc.JSValueRef = jsc.JSValueMakeUndefined(ctx);
    var one_arg = [_]jsc.JSValueRef{value_js};
    const str_val = jsc.JSObjectCallAsFunction(ctx, @ptrCast(stringify_fn), @ptrCast(json_obj), 1, &one_arg, @ptrCast(&exc));
    if (!jsc.JSValueIsUndefined(ctx, exc) and !jsc.JSValueIsNull(ctx, exc)) return jsc.JSValueMakeUndefined(ctx);
    const name_ref = jsc.JSValueToStringCopy(ctx, name_js, null);
    defer jsc.JSStringRelease(name_ref);
    if (g_run_state) |s| {
        if (s.snapshot_update) {
            _ = jsc.JSObjectSetProperty(ctx, store, name_ref, str_val, jsc.kJSPropertyAttributeNone, null);
            return jsc.JSValueMakeUndefined(ctx);
        }
    }
    const existing = jsc.JSObjectGetProperty(ctx, store, name_ref, null);
    if (jsc.JSValueIsUndefined(ctx, existing) or jsc.JSValueIsNull(ctx, existing)) {
        _ = jsc.JSObjectSetProperty(ctx, store, name_ref, str_val, jsc.kJSPropertyAttributeNone, null);
        return jsc.JSValueMakeUndefined(ctx);
    }
    const k_object = jsc.JSStringCreateWithUTF8CString("Object");
    defer jsc.JSStringRelease(k_object);
    const Object_val = jsc.JSObjectGetProperty(ctx, global, k_object, null);
    const Object_obj = jsc.JSValueToObject(ctx, Object_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const k_is = jsc.JSStringCreateWithUTF8CString("is");
    defer jsc.JSStringRelease(k_is);
    const is_fn = jsc.JSObjectGetProperty(ctx, Object_obj, k_is, null);
    if (jsc.JSValueIsUndefined(ctx, is_fn) or !jsc.JSObjectIsFunction(ctx, @ptrCast(is_fn))) return jsc.JSValueMakeUndefined(ctx);
    var is_args = [_]jsc.JSValueRef{ str_val, existing };
    const is_result = jsc.JSObjectCallAsFunction(ctx, @ptrCast(is_fn), null, 2, &is_args, null);
    if (jsc.JSValueToBoolean(ctx, is_result)) return jsc.JSValueMakeUndefined(ctx);
    const k_msg = jsc.JSStringCreateWithUTF8CString("Snapshot mismatch");
    defer jsc.JSStringRelease(k_msg);
    assert_mod.setAssertException(ctx, jsc.JSValueMakeString(ctx, k_msg), exception_out);
    return jsc.JSValueMakeUndefined(ctx);
}

const node_compat = @import("../node_compat/mod.zig");

/// 从 global.__shu_assert 取方法并调用，用于 expect 委托给 shu:assert
fn callAssertMethod(ctx: jsc.JSContextRef, method_name: [*]const u8, args: []const jsc.JSValueRef, exception_out: [*]jsc.JSValueRef) jsc.JSValueRef {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_assert = jsc.JSStringCreateWithUTF8CString("__shu_assert");
    defer jsc.JSStringRelease(k_assert);
    const assert_val = jsc.JSObjectGetProperty(ctx, global, k_assert, null);
    if (jsc.JSValueIsUndefined(ctx, assert_val)) return jsc.JSValueMakeUndefined(ctx);
    const assert_obj = jsc.JSValueToObject(ctx, assert_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const k_method = jsc.JSStringCreateWithUTF8CString(method_name);
    defer jsc.JSStringRelease(k_method);
    const method_fn = jsc.JSObjectGetProperty(ctx, assert_obj, k_method, null);
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(method_fn))) return jsc.JSValueMakeUndefined(ctx);
    return jsc.JSObjectCallAsFunction(ctx, @ptrCast(method_fn), null, args.len, args.ptr, exception_out);
}

/// expect(value)：Bun/Jest 风格；设 __shu_expect_value 并返回 matcher 对象。约定：单槽 __shu_expect_value。
fn expectCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_val = jsc.JSStringCreateWithUTF8CString("__shu_expect_value");
    defer jsc.JSStringRelease(k_val);
    _ = jsc.JSObjectSetProperty(ctx, global, k_val, arguments[0], jsc.kJSPropertyAttributeNone, null);
    const matchers = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, matchers, "toBe", expectToBeCallback);
    common.setMethod(ctx, matchers, "toEqual", expecttoEqualCallback);
    common.setMethod(ctx, matchers, "toThrow", expectToThrowCallback);
    common.setMethod(ctx, matchers, "toReject", expectToRejectCallback);
    common.setMethod(ctx, matchers, "toBeTruthy", expectToBeTruthyCallback);
    common.setMethod(ctx, matchers, "toBeFalsy", expectToBeFalsyCallback);
    return matchers;
}

fn getExpectValue(ctx: jsc.JSContextRef) jsc.JSValueRef {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k = jsc.JSStringCreateWithUTF8CString("__shu_expect_value");
    defer jsc.JSStringRelease(k);
    return jsc.JSObjectGetProperty(ctx, global, k, null);
}

fn expectToBeCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception_out: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const actual = getExpectValue(ctx);
    var args = [_]jsc.JSValueRef{ actual, arguments[0] };
    _ = callAssertMethod(ctx, "strictEqual", &args, exception_out);
    return jsc.JSValueMakeUndefined(ctx);
}

fn expecttoEqualCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception_out: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const actual = getExpectValue(ctx);
    var args = [_]jsc.JSValueRef{ actual, arguments[0] };
    _ = callAssertMethod(ctx, "deepStrictEqual", &args, exception_out);
    return jsc.JSValueMakeUndefined(ctx);
}

fn expectToThrowCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception_out: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const fn_val = getExpectValue(ctx);
    var args: [2]jsc.JSValueRef = undefined;
    args[0] = fn_val;
    args[1] = if (argumentCount >= 1) arguments[0] else jsc.JSValueMakeUndefined(ctx);
    _ = callAssertMethod(ctx, "throws", &args, exception_out);
    return jsc.JSValueMakeUndefined(ctx);
}

/// expect(promise).toReject()：返回 assert.rejects(promise)；需 __shu_assert 已挂到 global
fn expectToRejectCallback(
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
    const k_assert = jsc.JSStringCreateWithUTF8CString("__shu_assert");
    defer jsc.JSStringRelease(k_assert);
    const assert_val = jsc.JSObjectGetProperty(ctx, global, k_assert, null);
    if (jsc.JSValueIsUndefined(ctx, assert_val)) return jsc.JSValueMakeUndefined(ctx);
    const assert_obj = jsc.JSValueToObject(ctx, assert_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const k_rejects = jsc.JSStringCreateWithUTF8CString("rejects");
    defer jsc.JSStringRelease(k_rejects);
    const rejects_fn = jsc.JSObjectGetProperty(ctx, assert_obj, k_rejects, null);
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(rejects_fn))) return jsc.JSValueMakeUndefined(ctx);
    const inner = getExpectValue(ctx);
    var one = [_]jsc.JSValueRef{inner};
    var exc: jsc.JSValueRef = undefined;
    return jsc.JSObjectCallAsFunction(ctx, @ptrCast(rejects_fn), null, 1, &one, @ptrCast(&exc));
}

fn expectToBeTruthyCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception_out: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    _ = argumentCount;
    _ = arguments;
    const actual = getExpectValue(ctx);
    var one = [_]jsc.JSValueRef{actual};
    _ = callAssertMethod(ctx, "ok", one[0..], exception_out);
    return jsc.JSValueMakeUndefined(ctx);
}

fn expectToBeFalsyCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception_out: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    _ = argumentCount;
    _ = arguments;
    const actual = getExpectValue(ctx);
    if (jsc.JSValueToBoolean(ctx, actual)) {
        const k_msg = jsc.JSStringCreateWithUTF8CString("Expected value to be falsy");
        defer jsc.JSStringRelease(k_msg);
        assert_mod.setAssertException(ctx, jsc.JSValueMakeString(ctx, k_msg), exception_out);
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// 返回 shu:test 的完整 exports：describe、it、test（可调用且带 .skip/.todo/.only/.skipIf/.each）、beforeAll、afterAll、beforeEach、afterEach、run、mock、snapshot、assert、expect；默认导出为 it
pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    _ = getOrCreateRunner(allocator);
    const obj = jsc.JSObjectMake(ctx, null, null);

    const k_describe = jsc.JSStringCreateWithUTF8CString("describe");
    defer jsc.JSStringRelease(k_describe);
    const describe_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_describe, describeCallback);
    common.setMethod(ctx, describe_fn, "skip", describeSkipCallback);
    common.setMethod(ctx, describe_fn, "ignore", describeSkipCallback);
    common.setMethod(ctx, describe_fn, "only", describeOnlyCallback);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_describe, describe_fn, jsc.kJSPropertyAttributeNone, null);

    common.setMethod(ctx, obj, "beforeAll", beforeAllCallback);
    common.setMethod(ctx, obj, "afterAll", afterAllCallback);
    common.setMethod(ctx, obj, "beforeEach", beforeEachCallback);
    common.setMethod(ctx, obj, "afterEach", afterEachCallback);
    // mock 导出为对象 { fn, method }，供 mock.fn() / mock.method() 使用
    const k_mock = jsc.JSStringCreateWithUTF8CString("mock");
    defer jsc.JSStringRelease(k_mock);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_mock, mock.getExports(ctx, allocator), jsc.kJSPropertyAttributeNone, null);
    common.setMethod(ctx, obj, "snapshot", snapshotCallback);

    const k_it = jsc.JSStringCreateWithUTF8CString("it");
    defer jsc.JSStringRelease(k_it);
    const k_test = jsc.JSStringCreateWithUTF8CString("test");
    defer jsc.JSStringRelease(k_test);
    const it_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_it, itCallback);
    common.setMethod(ctx, it_fn, "skip", skipCallback);
    common.setMethod(ctx, it_fn, "ignore", skipCallback);
    common.setMethod(ctx, it_fn, "todo", todoCallback);
    common.setMethod(ctx, it_fn, "only", onlyCallback);
    common.setMethod(ctx, it_fn, "skipIf", skipIfCallback);
    common.setMethod(ctx, it_fn, "each", itEachCallback);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_it, it_fn, jsc.kJSPropertyAttributeNone, null);

    const test_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_test, itCallback);
    common.setMethod(ctx, test_fn, "skip", skipCallback);
    common.setMethod(ctx, test_fn, "ignore", skipCallback);
    common.setMethod(ctx, test_fn, "todo", todoCallback);
    common.setMethod(ctx, test_fn, "only", onlyCallback);
    common.setMethod(ctx, test_fn, "skipIf", skipIfCallback);
    common.setMethod(ctx, test_fn, "each", itEachCallback);
    common.setMethod(ctx, test_fn, "serial", itCallback);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_test, test_fn, jsc.kJSPropertyAttributeNone, null);

    const k_default = jsc.JSStringCreateWithUTF8CString("default");
    defer jsc.JSStringRelease(k_default);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_default, test_fn, jsc.kJSPropertyAttributeNone, null);

    // assert：统一使用 shu:assert（exception_out 便于 runner 捕获）；并挂到 global.__shu_assert 供 expect().toReject 使用
    const assert_obj = assert_mod.getExports(ctx, allocator);
    if (!jsc.JSValueIsUndefined(ctx, assert_obj)) {
        const k_assert = jsc.JSStringCreateWithUTF8CString("assert");
        defer jsc.JSStringRelease(k_assert);
        _ = jsc.JSObjectSetProperty(ctx, obj, k_assert, assert_obj, jsc.kJSPropertyAttributeNone, null);
    }

    const global = jsc.JSContextGetGlobalObject(ctx);
    if (!jsc.JSValueIsUndefined(ctx, assert_obj)) {
        const k_shu_assert = jsc.JSStringCreateWithUTF8CString("__shu_assert");
        defer jsc.JSStringRelease(k_shu_assert);
        _ = jsc.JSObjectSetProperty(ctx, global, k_shu_assert, assert_obj, jsc.kJSPropertyAttributeNone, null);
    }
    const k_expect = jsc.JSStringCreateWithUTF8CString("expect");
    defer jsc.JSStringRelease(k_expect);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_expect, jsc.JSObjectMakeFunctionWithCallback(ctx, k_expect, expectCallback), jsc.kJSPropertyAttributeNone, null);

    const k_describe_fn = jsc.JSStringCreateWithUTF8CString("__shu_describe_fn");
    defer jsc.JSStringRelease(k_describe_fn);
    _ = jsc.JSObjectSetProperty(ctx, global, k_describe_fn, describe_fn, jsc.kJSPropertyAttributeNone, null);

    // 与 Node/Deno/Bun 一致：不导出 run()，加载后自动执行。先写 0,0,0 以便子进程提前退出时父进程仍能读到用例文件；run() 结束时再覆盖。
    writeInitialZeroCasesFile();
    // 用 queueMicrotask(run) 保证在脚本同步部分结束、runMicrotasks() 时立即跑测，不依赖 runLoop 的 setImmediate，避免子进程下 0 用例。
    const k_queueMicrotask = jsc.JSStringCreateWithUTF8CString("queueMicrotask");
    defer jsc.JSStringRelease(k_queueMicrotask);
    const queue_micro = jsc.JSObjectGetProperty(ctx, global, k_queueMicrotask, null);
    if (!jsc.JSValueIsUndefined(ctx, queue_micro) and jsc.JSObjectIsFunction(ctx, @ptrCast(queue_micro))) {
        const k_run_internal = jsc.JSStringCreateWithUTF8CString("");
        defer jsc.JSStringRelease(k_run_internal);
        const run_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_run_internal, runCallback);
        var one_arg = [_]jsc.JSValueRef{run_fn};
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(queue_micro), null, 1, &one_arg, null);
    }

    const k_exports = jsc.JSStringCreateWithUTF8CString("__shu_test_exports");
    defer jsc.JSStringRelease(k_exports);
    _ = jsc.JSObjectSetProperty(ctx, global, k_exports, obj, jsc.kJSPropertyAttributeNone, null);
    const k_advance = jsc.JSStringCreateWithUTF8CString("__shu_test_advance");
    defer jsc.JSStringRelease(k_advance);
    _ = jsc.JSObjectSetProperty(ctx, global, k_advance, jsc.JSObjectMakeFunctionWithCallback(ctx, k_advance, advanceCallback), jsc.kJSPropertyAttributeNone, null);
    const k_reject_wrapper = jsc.JSStringCreateWithUTF8CString("__shu_test_reject_wrapper");
    defer jsc.JSStringRelease(k_reject_wrapper);
    _ = jsc.JSObjectSetProperty(ctx, global, k_reject_wrapper, jsc.JSObjectMakeFunctionWithCallback(ctx, k_reject_wrapper, rejectWrapperCallback), jsc.kJSPropertyAttributeNone, null);
    const k_run_test_fn = jsc.JSStringCreateWithUTF8CString("__shu_test_run_test_fn");
    defer jsc.JSStringRelease(k_run_test_fn);
    _ = jsc.JSObjectSetProperty(ctx, global, k_run_test_fn, jsc.JSObjectMakeFunctionWithCallback(ctx, k_run_test_fn, runTestWrapperCallback), jsc.kJSPropertyAttributeNone, null);
    const k_run_next = jsc.JSStringCreateWithUTF8CString("__shu_test_run_next");
    defer jsc.JSStringRelease(k_run_next);
    _ = jsc.JSObjectSetProperty(ctx, global, k_run_next, jsc.JSObjectMakeFunctionWithCallback(ctx, k_run_next, runNextOnlyCallback), jsc.kJSPropertyAttributeNone, null);
    return obj;
}
