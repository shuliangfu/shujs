//! shu test 子命令（cli/test.zig）
//!
//! 职责
//!   - 有 scripts.test 时：用 shell 执行该脚本（runScriptInCwd）。
//!   - 无 script 时：默认扫描 tests/ 下 *.test.ts、*.test.js、*.spec.ts、*.spec.js（排除 scan.default_exclude_dirs），对每个文件执行 shu run；无 package.json 时仍可走默认扫描。
//!   - 多文件时按「测试文件路径字母序」依次执行，保证顺序与文件管理器中一致且可复现（如先 example-mock.test.js，再 example.test.js）。
//!   - 默认**按 CPU 核心数并发**执行多测试文件；需顺序执行时传 **--jobs=1**。支持 **--jobs=N** 覆盖并发数，上限 64。
//!   - **--filter=pattern** / **--filter pattern**：仅运行路径中包含 pattern 的测试文件，便于开发时只跑部分用例。
//!
//! 主要 API
//!   - runTest(allocator, parsed, positional)：入口；无 tests/ 或无可匹配文件时给出英文提示。
//!
//! 约定
//!   - 目录遍历与路径经 io_core；面向用户输出为英文；与 PACKAGE_DESIGN.md test 配置、deno test 对齐。

const std = @import("std");
const builtin = @import("builtin");
const args = @import("args.zig");
const version = @import("version.zig");
const libs_io = @import("libs_io");
const libs_process = @import("libs_process");
const manifest = @import("../package/manifest.zig");
const scan = @import("scan.zig");

/// 测试子命令的选项：用于 --bail、--shard、--test-name-pattern 等。字符串字段 [Allocates]，调用方负责 free。
pub const TestOptions = struct {
    /// --bail / --fail-fast：首个失败后停止；非 null 即启用（值 1 表示首个失败即停）。
    bail_after: ?u32 = null,
    /// --shard=i/n：只跑第 i 份（0..n-1）；需 index、total 同时有值才生效。
    shard_index: ?u32 = null,
    shard_total: ?u32 = null,
    /// --test-name-pattern / -t：仅运行名称包含该子串的用例（子进程通过 SHU_TEST_NAME_PATTERN 读取）。
    test_name_pattern: ?[]const u8 = null,
    /// --test-skip-pattern：跳过名称包含该子串的用例（SHU_TEST_SKIP_PATTERN）。
    test_skip_pattern: ?[]const u8 = null,
    /// --timeout=N（毫秒）：默认用例超时（SHU_TEST_TIMEOUT）。
    timeout_ms: ?u32 = null,
    /// --retry=N：失败用例重试次数（SHU_TEST_RETRY）。
    retry: ?u32 = null,
    /// --reporter=junit：输出 JUnit XML（SHU_TEST_REPORTER）。
    reporter: ?[]const u8 = null,
    /// --reporter-outfile=path：JUnit XML 输出路径（SHU_TEST_REPORTER_OUTFILE）。
    reporter_outfile: ?[]const u8 = null,
    /// --preload=path：跑测试前先 require 的脚本路径（SHU_TEST_PRELOAD）。
    preload: ?[]const u8 = null,
    /// --todo：只跑标记为 it.todo / test.todo 的用例（SHU_TEST_TODO_ONLY=1）。
    todo_only: bool = false,
    /// --randomize：随机化测试文件执行顺序（与 --seed 配合）。
    randomize: bool = false,
    /// --seed=N：随机化时使用的种子（SHU_TEST_SEED）；未指定时用当前时间。
    seed: ?u64 = null,
    /// --update-snapshots / -u：将 snapshot(name, value) 的当前值写回 __snapshots__/*.snap 文件（SHU_TEST_UPDATE_SNAPSHOTS=1）。
    update_snapshots: bool = false,
    /// --coverage / --coverage-dir=path：启用覆盖率并指定输出目录（SHU_TEST_COVERAGE=1、SHU_TEST_COVERAGE_DIR）。
    coverage: bool = false,
    /// 覆盖率输出目录；仅当 coverage=true 时有效，未指定时可为默认目录名。
    coverage_dir: ?[]const u8 = null,

    /// 是否有任意需传给子进程的选项（用于决定是否构建 environ_map）。
    pub fn hasEnvOptions(self: *const TestOptions) bool {
        return self.test_name_pattern != null or
            self.test_skip_pattern != null or
            self.timeout_ms != null or
            self.retry != null or
            self.bail_after != null or
            self.reporter != null or
            self.reporter_outfile != null or
            self.preload != null or
            self.todo_only or
            self.randomize or
            self.seed != null or
            self.update_snapshots or
            self.coverage or
            self.coverage_dir != null;
    }
};

/// [Allocates] 从 positional 解析 --filter=pattern 或 --filter pattern；未指定时返回 null。调用方负责 free 返回值。
fn parseTestFilter(allocator: std.mem.Allocator, positional: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < positional.len) : (i += 1) {
        const arg = positional[i];
        if (std.mem.startsWith(u8, arg, "--filter=")) {
            const rest = arg["--filter=".len..];
            return allocator.dupe(u8, rest) catch return null;
        }
        if (std.mem.eql(u8, arg, "--filter")) {
            i += 1;
            if (i < positional.len) return allocator.dupe(u8, positional[i]) catch return null;
            return null;
        }
    }
    return null;
}

/// 从 test 子命令的 positional 中解析 --jobs=N 或 --jobs N。未指定时返回 null（调用方用 CPU 核心数）；指定时返回 N（上限 64）。
fn parseTestJobs(positional: []const []const u8) ?u32 {
    var i: usize = 0;
    while (i < positional.len) : (i += 1) {
        const arg = positional[i];
        if (std.mem.startsWith(u8, arg, "--jobs=")) {
            const rest = arg["--jobs=".len..];
            const n = std.fmt.parseInt(u32, rest, 10) catch return 1;
            return @min(n, 64);
        }
        if (std.mem.eql(u8, arg, "--jobs")) {
            i += 1;
            if (i < positional.len) {
                const n = std.fmt.parseInt(u32, positional[i], 10) catch return 1;
                return @min(n, 64);
            }
            return 1;
        }
    }
    return null;
}

/// 从 positional 解析 --bail、--fail-fast、--bail=N。返回非 null 表示启用（值为 1 表示首个失败即停）。
fn parseTestBail(allocator: std.mem.Allocator, positional: []const []const u8) ?u32 {
    _ = allocator;
    var i: usize = 0;
    while (i < positional.len) : (i += 1) {
        const arg = positional[i];
        if (std.mem.eql(u8, arg, "--bail") or std.mem.eql(u8, arg, "--fail-fast")) return 1;
        if (std.mem.startsWith(u8, arg, "--bail=")) {
            const rest = arg["--bail=".len..];
            return std.fmt.parseInt(u32, rest, 10) catch 1;
        }
    }
    return null;
}

/// 从 positional 解析 --shard=index/total 或 --shard index total。返回 (index, total)，无效时返回 null。
fn parseTestShard(allocator: std.mem.Allocator, positional: []const []const u8) ?struct { u32, u32 } {
    _ = allocator;
    var i: usize = 0;
    while (i < positional.len) : (i += 1) {
        const arg = positional[i];
        if (std.mem.startsWith(u8, arg, "--shard=")) {
            const rest = arg["--shard=".len..];
            var it = std.mem.splitScalar(u8, rest, '/');
            const a = it.next() orelse return null;
            const b = it.next() orelse return null;
            const idx = std.fmt.parseInt(u32, std.mem.trim(u8, a, &std.ascii.whitespace), 10) catch return null;
            const tot = std.fmt.parseInt(u32, std.mem.trim(u8, b, &std.ascii.whitespace), 10) catch return null;
            if (tot == 0 or idx >= tot) return null;
            return .{ idx, tot };
        }
        if (std.mem.eql(u8, arg, "--shard")) {
            i += 1;
            if (i + 1 < positional.len) {
                const idx = std.fmt.parseInt(u32, positional[i], 10) catch return null;
                i += 1;
                const tot = std.fmt.parseInt(u32, positional[i], 10) catch return null;
                if (tot == 0 or idx >= tot) return null;
                return .{ idx, tot };
            }
            return null;
        }
    }
    return null;
}

/// [Allocates] 从 positional 解析 --test-name-pattern=pat 或 -t pat。调用方 free。
fn parseTestNamePattern(allocator: std.mem.Allocator, positional: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < positional.len) : (i += 1) {
        const arg = positional[i];
        if (std.mem.startsWith(u8, arg, "--test-name-pattern=")) {
            const rest = arg["--test-name-pattern=".len..];
            return allocator.dupe(u8, rest) catch return null;
        }
        if (std.mem.eql(u8, arg, "--test-name-pattern") or std.mem.eql(u8, arg, "-t")) {
            i += 1;
            if (i < positional.len) return allocator.dupe(u8, positional[i]) catch return null;
            return null;
        }
    }
    return null;
}

/// [Allocates] 从 positional 解析 --test-skip-pattern=pat。调用方 free。
fn parseTestSkipPattern(allocator: std.mem.Allocator, positional: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < positional.len) : (i += 1) {
        const arg = positional[i];
        if (std.mem.startsWith(u8, arg, "--test-skip-pattern=")) {
            const rest = arg["--test-skip-pattern=".len..];
            return allocator.dupe(u8, rest) catch return null;
        }
        if (std.mem.eql(u8, arg, "--test-skip-pattern")) {
            i += 1;
            if (i < positional.len) return allocator.dupe(u8, positional[i]) catch return null;
            return null;
        }
    }
    return null;
}

/// 从 positional 解析 --timeout=N（毫秒）。
fn parseTestTimeout(positional: []const []const u8) ?u32 {
    var i: usize = 0;
    while (i < positional.len) : (i += 1) {
        const arg = positional[i];
        if (std.mem.startsWith(u8, arg, "--timeout=")) {
            const rest = arg["--timeout=".len..];
            return std.fmt.parseInt(u32, rest, 10) catch null;
        }
        if (std.mem.eql(u8, arg, "--timeout")) {
            i += 1;
            if (i < positional.len) return std.fmt.parseInt(u32, positional[i], 10) catch null;
            return null;
        }
    }
    return null;
}

/// 从 positional 解析 --retry=N。
fn parseTestRetry(positional: []const []const u8) ?u32 {
    var i: usize = 0;
    while (i < positional.len) : (i += 1) {
        const arg = positional[i];
        if (std.mem.startsWith(u8, arg, "--retry=")) {
            const rest = arg["--retry=".len..];
            return std.fmt.parseInt(u32, rest, 10) catch null;
        }
        if (std.mem.eql(u8, arg, "--retry")) {
            i += 1;
            if (i < positional.len) return std.fmt.parseInt(u32, positional[i], 10) catch null;
            return null;
        }
    }
    return null;
}

/// [Allocates] 从 positional 解析 --reporter=name 或 --reporter name。调用方 free。
fn parseTestReporter(allocator: std.mem.Allocator, positional: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < positional.len) : (i += 1) {
        const arg = positional[i];
        if (std.mem.startsWith(u8, arg, "--reporter=")) {
            const rest = arg["--reporter=".len..];
            return allocator.dupe(u8, rest) catch return null;
        }
        if (std.mem.eql(u8, arg, "--reporter")) {
            i += 1;
            if (i < positional.len) return allocator.dupe(u8, positional[i]) catch return null;
            return null;
        }
    }
    return null;
}

/// [Allocates] 从 positional 解析 --reporter-outfile=path 或 --reporter-outfile path。调用方 free。
fn parseTestReporterOutfile(allocator: std.mem.Allocator, positional: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < positional.len) : (i += 1) {
        const arg = positional[i];
        if (std.mem.startsWith(u8, arg, "--reporter-outfile=")) {
            const rest = arg["--reporter-outfile=".len..];
            return allocator.dupe(u8, rest) catch return null;
        }
        if (std.mem.eql(u8, arg, "--reporter-outfile")) {
            i += 1;
            if (i < positional.len) return allocator.dupe(u8, positional[i]) catch return null;
            return null;
        }
    }
    return null;
}

/// [Allocates] 从 positional 解析 --preload=path 或 --preload path。调用方 free。
fn parseTestPreload(allocator: std.mem.Allocator, positional: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < positional.len) : (i += 1) {
        const arg = positional[i];
        if (std.mem.startsWith(u8, arg, "--preload=")) {
            const rest = arg["--preload=".len..];
            return allocator.dupe(u8, rest) catch return null;
        }
        if (std.mem.eql(u8, arg, "--preload")) {
            i += 1;
            if (i < positional.len) return allocator.dupe(u8, positional[i]) catch return null;
            return null;
        }
    }
    return null;
}

/// 从 positional 解析 --todo；存在即返回 true。
fn parseTestTodo(positional: []const []const u8) bool {
    for (positional) |arg| {
        if (std.mem.eql(u8, arg, "--todo")) return true;
    }
    return false;
}

/// 从 positional 解析 --randomize；存在即返回 true。
fn parseTestRandomize(positional: []const []const u8) bool {
    for (positional) |arg| {
        if (std.mem.eql(u8, arg, "--randomize")) return true;
    }
    return false;
}

/// 从 positional 解析 --seed=N 或 --seed N。未指定时返回 null。
fn parseTestSeed(positional: []const []const u8) ?u64 {
    var i: usize = 0;
    while (i < positional.len) : (i += 1) {
        const arg = positional[i];
        if (std.mem.startsWith(u8, arg, "--seed=")) {
            const rest = arg["--seed=".len..];
            return std.fmt.parseInt(u64, rest, 10) catch null;
        }
        if (std.mem.eql(u8, arg, "--seed")) {
            i += 1;
            if (i < positional.len) return std.fmt.parseInt(u64, positional[i], 10) catch null;
            return null;
        }
    }
    return null;
}

/// 从 positional 解析 --update-snapshots 或 -u；存在即返回 true。
fn parseTestUpdateSnapshots(positional: []const []const u8) bool {
    for (positional) |arg| {
        if (std.mem.eql(u8, arg, "--update-snapshots") or std.mem.eql(u8, arg, "-u")) return true;
    }
    return false;
}

/// 从 positional 解析 --coverage；存在即返回 true。
fn parseTestCoverage(positional: []const []const u8) bool {
    for (positional) |arg| {
        if (std.mem.eql(u8, arg, "--coverage")) return true;
    }
    return false;
}

/// [Allocates] 从 positional 解析 --coverage-dir=path 或 --coverage-dir path。调用方 free。
fn parseTestCoverageDir(allocator: std.mem.Allocator, positional: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < positional.len) : (i += 1) {
        const arg = positional[i];
        if (std.mem.startsWith(u8, arg, "--coverage-dir=")) {
            const rest = arg["--coverage-dir=".len..];
            return allocator.dupe(u8, rest) catch return null;
        }
        if (std.mem.eql(u8, arg, "--coverage-dir")) {
            i += 1;
            if (i < positional.len) return allocator.dupe(u8, positional[i]) catch return null;
            return null;
        }
    }
    return null;
}

/// [Allocates] 从 positional 汇总解析 TestOptions。调用方负责对返回结构体中的字符串字段 free。
fn parseTestOptions(allocator: std.mem.Allocator, positional: []const []const u8) TestOptions {
    const shard = parseTestShard(allocator, positional);
    return .{
        .bail_after = parseTestBail(allocator, positional),
        .shard_index = if (shard) |s| s[0] else null,
        .shard_total = if (shard) |s| s[1] else null,
        .test_name_pattern = parseTestNamePattern(allocator, positional),
        .test_skip_pattern = parseTestSkipPattern(allocator, positional),
        .timeout_ms = parseTestTimeout(positional),
        .retry = parseTestRetry(positional),
        .reporter = parseTestReporter(allocator, positional),
        .reporter_outfile = parseTestReporterOutfile(allocator, positional),
        .preload = parseTestPreload(allocator, positional),
        .todo_only = parseTestTodo(positional),
        .randomize = parseTestRandomize(positional),
        .seed = parseTestSeed(positional),
        .update_snapshots = parseTestUpdateSnapshots(positional),
        .coverage = parseTestCoverage(positional),
        .coverage_dir = parseTestCoverageDir(allocator, positional),
    };
}

/// 执行 shu test：有 scripts.test 则用 shell 执行；否则默认扫描 tests/ 下 *.test.ts、*.test.js、*.spec.ts、*.spec.js（排除 default_exclude_dirs），对每个文件执行 shu run。
/// 支持 positional 中的 --jobs=N 以并行执行多测试文件。
pub fn runTest(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8, io: std.Io) !void {
    _ = parsed;
    const default_jobs = std.Thread.getCpuCount() catch 1;
    const jobs = @min(parseTestJobs(positional) orelse default_jobs, 64);
    try version.printCommandHeader(io, "test");
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = libs_io.realpath(".", &cwd_buf) catch {
        try printStderr(io, "shu test: cannot get current directory\n", .{});
        return error.CwdFailed;
    };
    const cwd_owned = allocator.dupe(u8, cwd) catch return;
    defer allocator.free(cwd_owned);

    const filter = parseTestFilter(allocator, positional);
    defer if (filter) |f| allocator.free(f);

    var options = parseTestOptions(allocator, positional);
    defer {
        if (options.test_name_pattern) |p| allocator.free(p);
        if (options.test_skip_pattern) |p| allocator.free(p);
        if (options.reporter) |p| allocator.free(p);
        if (options.reporter_outfile) |p| allocator.free(p);
        if (options.preload) |p| allocator.free(p);
        if (options.coverage_dir) |p| allocator.free(p);
    }

    var loaded = manifest.Manifest.load(allocator, cwd_owned) catch |e| {
        if (e == error.ManifestNotFound) {
            return runDefaultTests(allocator, cwd_owned, io, jobs, filter, &options);
        }
        return e;
    };
    defer loaded.arena.deinit();
    const m = &loaded.manifest;

    if (m.scripts.get("test")) |cmd| {
        runScriptInCwd(allocator, cwd_owned, cmd, io) catch |e| {
            try printStderr(io, "shu test: script failed\n", .{});
            return e;
        };
        try printToStdout(io, "\n", .{});
        return;
    }

    return runDefaultTests(allocator, cwd_owned, io, jobs, filter, &options);
}

/// 并行执行时的 worker 上下文；paths 与 cwd_owned、self_exe、options 在 join 前有效，由主线程保证不释放。
const TestWorkerCtx = struct {
    allocator: std.mem.Allocator,
    cwd_owned: []const u8,
    self_exe: []const u8,
    paths: []const []const u8,
    total: usize,
    next_index: std.atomic.Value(usize),
    failed_count: std.atomic.Value(u32),
    print_guard: std.atomic.Value(u32),
    io: std.Io,
    /// 测试选项（用于构建子进程 env）；只读，主线程持有。
    options: *const TestOptions,
    /// 当 options.bail_after != null 时由主线程传入；首个失败时置 true，worker 取任务前检查并退出。
    bail_requested: ?*std.atomic.Value(bool) = null,
};

/// [Allocates] 由 run_path（如 "tests/example.test.js"）计算对应 snapshot 文件路径：dir/__snapshots__/basename.snap。调用方 free 返回值。
fn snapshotFilePathForRunPath(allocator: std.mem.Allocator, run_path: []const u8) ![]const u8 {
    const dir = libs_io.pathDirname(run_path) orelse ".";
    const base = libs_io.pathBasename(run_path);
    const base_dot_snap = try std.fmt.allocPrint(allocator, "{s}.snap", .{base});
    defer allocator.free(base_dot_snap);
    return libs_io.pathJoin(allocator, &.{ dir, "__snapshots__", base_dot_snap });
}

/// [Allocates] 根据 options 与可选 snapshot_file_path 构建子进程环境（继承当前进程 env 并追加 SHU_TEST_*）。
/// snapshot_file_path 由调用方计算并负责生命周期（env 仅存引用）；传 null 则不设 SHU_TEST_SNAPSHOT_FILE。调用方负责 env.deinit()。
fn buildTestEnvironMap(allocator: std.mem.Allocator, options: *const TestOptions, snapshot_file_path: ?[]const u8) !std.process.Environ.Map {
    const env_block = libs_process.getProcessEnviron() orelse std.process.Environ.empty;
    var env = try std.process.Environ.createMap(env_block, allocator);
    if (options.test_name_pattern) |p| try env.put("SHU_TEST_NAME_PATTERN", p);
    if (options.test_skip_pattern) |p| try env.put("SHU_TEST_SKIP_PATTERN", p);
    if (options.timeout_ms) |n| {
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "0";
        try env.put("SHU_TEST_TIMEOUT", s);
    }
    if (options.retry) |n| {
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "0";
        try env.put("SHU_TEST_RETRY", s);
    }
    if (options.bail_after != null) try env.put("SHU_TEST_BAIL", "1");
    if (options.reporter) |r| try env.put("SHU_TEST_REPORTER", r);
    if (options.reporter_outfile) |p| try env.put("SHU_TEST_REPORTER_OUTFILE", p);
    if (options.preload) |p| try env.put("SHU_TEST_PRELOAD", p);
    if (options.todo_only) try env.put("SHU_TEST_TODO_ONLY", "1");
    if (options.randomize) try env.put("SHU_TEST_RANDOMIZE", "1");
    if (options.seed) |n| {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch "0";
        try env.put("SHU_TEST_SEED", s);
    }
    if (options.update_snapshots) try env.put("SHU_TEST_UPDATE_SNAPSHOTS", "1");
    if (options.coverage) try env.put("SHU_TEST_COVERAGE", "1");
    if (options.coverage_dir) |d| try env.put("SHU_TEST_COVERAGE_DIR", d);
    if (snapshot_file_path) |p| try env.put("SHU_TEST_SNAPSHOT_FILE", p);
    return env;
}

/// Worker 线程入口：从 next_index 取任务，执行 shu run tests/<path>；支持 --bail 与 SHU_TEST_* 环境变量。
fn testFileWorker(ctx: *TestWorkerCtx) void {
    while (true) {
        if (ctx.bail_requested) |bail| {
            if (bail.load(.acquire)) break;
        }
        const idx = ctx.next_index.fetchAdd(1, .monotonic);
        if (idx >= ctx.total) break;
        const item = ctx.paths[idx];
        const run_path = libs_io.pathJoin(ctx.allocator, &.{ "tests", item }) catch {
            _ = ctx.failed_count.fetchAdd(1, .monotonic);
            if (ctx.bail_requested) |bail| bail.store(true, .release);
            continue;
        };
        defer ctx.allocator.free(run_path);
        const snap_path = snapshotFilePathForRunPath(ctx.allocator, run_path) catch {
            _ = ctx.failed_count.fetchAdd(1, .monotonic);
            continue;
        };
        defer ctx.allocator.free(snap_path);
        while (ctx.print_guard.swap(1, .acquire) != 0) {
            std.Thread.yield() catch {};
        }
        printToStdout(ctx.io, "Running {s} ...\n", .{run_path}) catch {};
        ctx.print_guard.store(0, .release);
        var argv_buf: [8][]const u8 = undefined;
        argv_buf[0] = ctx.self_exe;
        argv_buf[1] = "run";
        argv_buf[2] = "--allow-read";
        argv_buf[3] = run_path;
        var argv_len: usize = 4;
        if (ctx.options.update_snapshots or ctx.options.coverage) {
            argv_buf[4] = "--allow-write";
            argv_len = 5;
        }
        const argv = argv_buf[0..argv_len];
        if (ctx.options.hasEnvOptions()) {
            var env = buildTestEnvironMap(ctx.allocator, ctx.options, snap_path) catch {
                _ = ctx.failed_count.fetchAdd(1, .monotonic);
                continue;
            };
            defer env.deinit();
            env.put("SHU_TEST_CWD", ctx.cwd_owned) catch {};
            var child = std.process.spawn(ctx.io, .{
                .argv = argv,
                .cwd = .{ .path = ctx.cwd_owned },
                .environ_map = &env,
                .stdin = .inherit,
                .stdout = .inherit,
                .stderr = .inherit,
            }) catch {
                _ = ctx.failed_count.fetchAdd(1, .monotonic);
                if (ctx.bail_requested) |bail| bail.store(true, .release);
                continue;
            };
            const term = child.wait(ctx.io) catch {
                _ = ctx.failed_count.fetchAdd(1, .monotonic);
                if (ctx.bail_requested) |bail| bail.store(true, .release);
                continue;
            };
            switch (term) {
                .exited => |code| {
                    if (code != 0) {
                        _ = ctx.failed_count.fetchAdd(1, .monotonic);
                        if (ctx.bail_requested) |bail| bail.store(true, .release);
                    }
                },
                .signal, .stopped, .unknown => {
                    _ = ctx.failed_count.fetchAdd(1, .monotonic);
                    if (ctx.bail_requested) |bail| bail.store(true, .release);
                },
            }
        } else {
            var child = std.process.spawn(ctx.io, .{
                .argv = argv,
                .cwd = .{ .path = ctx.cwd_owned },
                .stdin = .inherit,
                .stdout = .inherit,
                .stderr = .inherit,
            }) catch {
                _ = ctx.failed_count.fetchAdd(1, .monotonic);
                if (ctx.bail_requested) |bail| bail.store(true, .release);
                continue;
            };
            const term = child.wait(ctx.io) catch {
                _ = ctx.failed_count.fetchAdd(1, .monotonic);
                if (ctx.bail_requested) |bail| bail.store(true, .release);
                continue;
            };
            switch (term) {
                .exited => |code| {
                    if (code != 0) {
                        _ = ctx.failed_count.fetchAdd(1, .monotonic);
                        if (ctx.bail_requested) |bail| bail.store(true, .release);
                    }
                },
                .signal, .stopped, .unknown => {
                    _ = ctx.failed_count.fetchAdd(1, .monotonic);
                    if (ctx.bail_requested) |bail| bail.store(true, .release);
                },
            }
        }
    }
}

/// 默认行为：扫描 tests/ 下 test/spec 文件并执行 shu run；排除 scan.default_exclude_dirs。jobs > 1 且多文件时并行执行。
/// filter 非 null 时仅运行路径包含该子串的文件；options 控制 --bail、--shard、--test-name-pattern 等并传给子进程。
fn runDefaultTests(allocator: std.mem.Allocator, cwd_owned: []const u8, io: std.Io, jobs: u32, filter: ?[]const u8, options: *const TestOptions) !void {
    const tests_dir_abs = try libs_io.pathJoin(allocator, &.{ cwd_owned, "tests" });
    defer allocator.free(tests_dir_abs);

    var tests_dir = libs_io.openDirAbsolute(tests_dir_abs, .{}) catch {
        try printStderr(io, "shu test: no tests/ directory. Create tests/ with *.test.ts, *.test.js, *.spec.ts, or *.spec.js files.\n", .{});
        return error.NoTestsDir;
    };
    tests_dir.close(io);

    var list = try scan.collectFilesRecursive(allocator, tests_dir_abs, &scan.test_extensions, io);
    defer {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    }
    if (list.items.len == 0) {
        try printStderr(io, "shu test: no test files found under tests/\n", .{});
        try printToStdout(io, "\n", .{});
        return;
    }

    // 按测试文件路径字母序排序，保证执行顺序与文件管理器中的顺序一致且可复现（先 example-mock.test.js，再 example.test.js 等）。
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    // 若指定了 --filter，只保留路径中包含 filter 子串的文件（子路径匹配，便于只跑某类用例）。
    if (filter) |pat| {
        var write: usize = 0;
        for (list.items) |item| {
            if (std.mem.indexOf(u8, item, pat) != null) {
                list.items[write] = item;
                write += 1;
            } else {
                allocator.free(item);
            }
        }
        list.shrinkRetainingCapacity(write);
        if (list.items.len == 0) {
            try printStderr(io, "shu test: no test files matching filter \"{s}\".\n", .{pat});
            try printToStdout(io, "\n", .{});
            return;
        }
    }

    // --shard=i/n：只保留第 i 份文件（index % n == i），用于 CI 分片并行。
    if (options.shard_total != null and options.shard_index != null) {
        const n = options.shard_total.?;
        const i = options.shard_index.?;
        var write: usize = 0;
        for (list.items, 0..) |item, index| {
            if (@as(u32, @intCast(index)) % n == i) {
                list.items[write] = item;
                write += 1;
            } else {
                allocator.free(item);
            }
        }
        list.shrinkRetainingCapacity(write);
        if (list.items.len == 0) {
            try printStderr(io, "shu test: no test files in shard {d}/{d}.\n", .{ i, n });
            try printToStdout(io, "\n", .{});
            return;
        }
    }

    // --randomize：按 --seed 打乱测试文件顺序，便于发现顺序依赖；未指定 seed 时用当前时间。
    if (options.randomize and list.items.len > 1) {
        // 未指定 --seed 时用固定种子 0，打乱顺序仍可复现；需每次不同顺序时传 --seed=N（如时间戳）
        const seed: u64 = options.seed orelse 0;
        var prng = std.Random.DefaultPrng.init(seed);
        prng.random().shuffle([]const u8, list.items);
    }

    const self_exe = std.process.executablePathAlloc(io, allocator) catch {
        try printStderr(io, "shu test: cannot get executable path\n", .{});
        return error.SelfExeFailed;
    };
    defer allocator.free(self_exe);

    const total = list.items.len;
    const use_parallel = jobs > 1 and total > 1;
    if (!use_parallel) {
        var failed_count: u32 = 0;
        for (list.items) |item| {
            if (options.bail_after != null and failed_count > 0) break;
            const run_path = try libs_io.pathJoin(allocator, &.{ "tests", item });
            defer allocator.free(run_path);
            const snap_path = try snapshotFilePathForRunPath(allocator, run_path);
            defer allocator.free(snap_path);
            try printToStdout(io, "Running {s} ...\n", .{run_path});
            var argv_buf: [8][]const u8 = undefined;
            argv_buf[0] = self_exe;
            argv_buf[1] = "run";
            argv_buf[2] = "--allow-read";
            argv_buf[3] = run_path;
            var argv_len: usize = 4;
            if (options.update_snapshots or options.coverage) {
                argv_buf[4] = "--allow-write";
                argv_len = 5;
            }
            const argv = argv_buf[0..argv_len];
            if (options.hasEnvOptions()) {
                var env = try buildTestEnvironMap(allocator, options, snap_path);
                defer env.deinit();
                env.put("SHU_TEST_CWD", cwd_owned) catch {};
                var child = try std.process.spawn(io, .{
                    .argv = argv,
                    .cwd = .{ .path = cwd_owned },
                    .environ_map = &env,
                    .stdin = .inherit,
                    .stdout = .inherit,
                    .stderr = .inherit,
                });
                const term = try child.wait(io);
                switch (term) {
                    .exited => |code| {
                        if (code != 0) {
                            failed_count += 1;
                            if (options.bail_after != null) break;
                        }
                    },
                    .signal, .stopped, .unknown => {
                        failed_count += 1;
                        if (options.bail_after != null) break;
                    },
                }
            } else {
                var child = try std.process.spawn(io, .{
                    .argv = argv,
                    .cwd = .{ .path = cwd_owned },
                    .stdin = .inherit,
                    .stdout = .inherit,
                    .stderr = .inherit,
                });
                const term = try child.wait(io);
                switch (term) {
                    .exited => |code| {
                        if (code != 0) {
                            failed_count += 1;
                            if (options.bail_after != null) break;
                        }
                    },
                    .signal, .stopped, .unknown => {
                        failed_count += 1;
                        if (options.bail_after != null) break;
                    },
                }
            }
        }
        if (failed_count > 0) {
            try printStderr(io, "shu test: {d} of {d} file(s) failed.\n", .{ failed_count, total });
            return error.ScriptExitedNonZero;
        }
        try printToStdout(io, "All {d} test file(s) passed.\n", .{total});
        return;
    }

    const next_index = std.atomic.Value(usize).init(0);
    const failed_atomic = std.atomic.Value(u32).init(0);
    const print_guard = std.atomic.Value(u32).init(0);
    var bail_atomic = std.atomic.Value(bool).init(false);
    const n_workers = @min(jobs, total);
    var ctx = TestWorkerCtx{
        .allocator = allocator,
        .cwd_owned = cwd_owned,
        .self_exe = self_exe,
        .paths = list.items,
        .total = total,
        .next_index = next_index,
        .failed_count = failed_atomic,
        .print_guard = print_guard,
        .io = io,
        .options = options,
        .bail_requested = if (options.bail_after != null) &bail_atomic else null,
    };
    var threads = try std.ArrayList(std.Thread).initCapacity(allocator, n_workers);
    defer threads.deinit(allocator);
    for (0..n_workers) |_| {
        try threads.append(allocator, try std.Thread.spawn(.{}, testFileWorker, .{&ctx}));
    }
    for (threads.items) |t| t.join();
    const failed_count = failed_atomic.load(.monotonic);
    if (failed_count > 0) {
        try printStderr(io, "shu test: {d} of {d} file(s) failed.\n", .{ failed_count, total });
        return error.ScriptExitedNonZero;
    }
    try printToStdout(io, "All {d} test file(s) passed.\n", .{total});
}

/// 在 cwd 下用 shell 执行 cmd（/bin/sh -c cmd 或 cmd.exe /c cmd）；stdio 继承。Zig 0.16：spawn(io, options)、wait(io)。
fn runScriptInCwd(allocator: std.mem.Allocator, cwd: []const u8, cmd: []const u8, io: std.Io) !void {
    _ = allocator;
    var argv_buf: [3][]const u8 = undefined;
    if (builtin.os.tag == .windows) {
        argv_buf[0] = "cmd.exe";
        argv_buf[1] = "/c";
        argv_buf[2] = cmd;
    } else {
        argv_buf[0] = "/bin/sh";
        argv_buf[1] = "-c";
        argv_buf[2] = cmd;
    }
    const argv = argv_buf[0..3];
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.ScriptExitedNonZero,
        .signal, .stopped => return error.ScriptSignalled,
        .unknown => return error.ScriptExitedNonZero,
    }
}

fn printToStdout(io: std.Io, comptime fmt_str: []const u8, fargs: anytype) !void {
    var buf: [64]u8 = undefined;
    var w = std.Io.File.Writer.init(std.Io.File.stdout(), io, &buf);
    try w.interface.print(fmt_str, fargs);
    try w.interface.flush();
}

fn printStderr(io: std.Io, comptime fmt_str: []const u8, fargs: anytype) !void {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.Writer.init(std.Io.File.stderr(), io, &buf);
    try w.interface.print(fmt_str, fargs);
    try w.interface.flush();
}
