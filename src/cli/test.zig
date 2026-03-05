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

/// 判断 positional[i] 是否为「带单独取值的选项」（下一项为值，需跳过）。
fn optionTakesNextArg(arg: []const u8) bool {
    if (arg.len == 0 or arg[0] != '-') return false;
    if (std.mem.eql(u8, arg, "--filter")) return true;
    if (std.mem.eql(u8, arg, "--jobs")) return true;
    if (std.mem.eql(u8, arg, "--bail")) return true;
    if (std.mem.eql(u8, arg, "--shard")) return true;
    if (std.mem.eql(u8, arg, "--test-name-pattern") or std.mem.eql(u8, arg, "-t")) return true;
    if (std.mem.eql(u8, arg, "--test-skip-pattern")) return true;
    if (std.mem.eql(u8, arg, "--timeout")) return true;
    if (std.mem.eql(u8, arg, "--retry")) return true;
    if (std.mem.eql(u8, arg, "--reporter")) return true;
    if (std.mem.eql(u8, arg, "--reporter-outfile")) return true;
    if (std.mem.eql(u8, arg, "--preload")) return true;
    if (std.mem.eql(u8, arg, "--seed")) return true;
    if (std.mem.eql(u8, arg, "--coverage-dir")) return true;
    return false;
}

/// [Allocates] 从 positional 解析「仅跑这些文件」：非选项且非选项值的参数视为文件路径。无则返回 null；有则返回列表，每项为 run_path 形式（如 tests/foo.test.js），调用方逐项 free 并 list.deinit。
fn parsePositionalTestFiles(allocator: std.mem.Allocator, positional: []const []const u8) ?std.ArrayList([]const u8) {
    var list = std.ArrayList([]const u8).initCapacity(allocator, 0) catch return null;
    var i: usize = 0;
    while (i < positional.len) : (i += 1) {
        const arg = positional[i];
        if (arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "--shard")) {
                i += 2;
                continue;
            }
            if (optionTakesNextArg(arg)) {
                i += 1;
                continue;
            }
            continue;
        }
        const run_path = if (std.mem.startsWith(u8, arg, "tests/"))
            allocator.dupe(u8, arg) catch continue
        else
            libs_io.pathJoin(allocator, &.{ "tests", arg }) catch continue;
        list.append(allocator, run_path) catch {
            allocator.free(run_path);
            continue;
        };
    }
    if (list.items.len == 0) {
        list.deinit(allocator);
        return null;
    }
    return list;
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
            var explicit = parsePositionalTestFiles(allocator, positional);
            defer if (explicit) |*list| {
                for (list.items) |p| allocator.free(p);
                list.deinit(allocator);
            };
            return runDefaultTests(allocator, cwd_owned, io, jobs, filter, &options, &parsed, if (explicit) |*list_ptr| list_ptr else null);
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

    var explicit = parsePositionalTestFiles(allocator, positional);
    defer if (explicit) |*list| {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    };
    return runDefaultTests(allocator, cwd_owned, io, jobs, filter, &options, &parsed, if (explicit) |*list_ptr| list_ptr else null);
}

/// 子进程 stderr 中 __SHU_TEST_CASES__ 行的解析结果；未找到时全为 0。
const CaseSummary = struct { passed: u32, failed: u32, skipped: u32 };

/// 从子进程写入的 SHU_TEST_CASES_FILE 路径读取一行并解析用例数；文件不存在或解析失败返回全 0。读后删除该文件。Deno 风格下子进程 stderr 已 inherit，用例数通过文件回传。经 libs_io 打开/读/删。
fn readCasesFile(allocator: std.mem.Allocator, io: std.Io, cases_file_path: []const u8) CaseSummary {
    var f = libs_io.openFileAbsolute(cases_file_path, .{ .mode = .read_only }) catch return .{ .passed = 0, .failed = 0, .skipped = 0 };
    defer f.close(io);
    var buf: [256]u8 = undefined;
    var list = std.ArrayList(u8).initCapacity(allocator, 256) catch return .{ .passed = 0, .failed = 0, .skipped = 0 };
    defer list.deinit(allocator);
    var r = f.reader(io, &buf);
    var dest: [1][]u8 = .{buf[0..]};
    while (true) {
        const n = std.Io.Reader.readVec(&r.interface, &dest) catch break;
        if (n == 0) break;
        list.appendSlice(allocator, buf[0..n]) catch break;
    }
    libs_io.deleteFileAbsolute(cases_file_path) catch {};
    return parseShuTestCasesFromSlice(list.items);
}

/// 在 data 中查找 __SHU_TEST_CASES__ 行并解析 JSON 得到 passed/failed/skipped；未找到或解析失败返回全 0。
fn parseShuTestCasesFromSlice(data: []const u8) CaseSummary {
    const prefix = "__SHU_TEST_CASES__";
    var iter = std.mem.splitScalar(u8, data, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (!std.mem.startsWith(u8, trimmed, prefix)) continue;
        const json_slice = std.mem.trim(u8, trimmed[prefix.len..], " \r");
        if (json_slice.len == 0) return .{ .passed = 0, .failed = 0, .skipped = 0 };
        var passed: u32 = 0;
        var failed: u32 = 0;
        var skipped: u32 = 0;
        const keys = .{
            .{ "\"passed\":", &passed },
            .{ "\"failed\":", &failed },
            .{ "\"skipped\":", &skipped },
        };
        inline for (keys) |kv| {
            const pos = std.mem.indexOf(u8, json_slice, kv[0]);
            if (pos) |p| {
                const i = p + kv[0].len;
                var end = i;
                while (end < json_slice.len and std.ascii.isDigit(json_slice[end])) end += 1;
                parse: {
                    const val = std.fmt.parseInt(u32, json_slice[i..end], 10) catch break :parse;
                    kv[1].* = val;
                }
            }
        }
        return .{ .passed = passed, .failed = failed, .skipped = skipped };
    }
    return .{ .passed = 0, .failed = 0, .skipped = 0 };
}

/// 并行执行时的 worker 上下文；paths 与 cwd_owned、self_exe、options、permissions 在 join 前有效，由主线程保证不释放。
const TestWorkerCtx = struct {
    allocator: std.mem.Allocator,
    cwd_owned: []const u8,
    self_exe: []const u8,
    paths: []const []const u8,
    total: usize,
    next_index: std.atomic.Value(usize),
    failed_count: std.atomic.Value(u32),
    /// 用例级计数：各 worker 解析子进程 stderr 后累加。
    case_passed: std.atomic.Value(u64),
    case_failed: std.atomic.Value(u64),
    case_skipped: std.atomic.Value(u64),
    print_guard: std.atomic.Value(u32),
    io: std.Io,
    /// 测试选项（用于构建子进程 env）；只读，主线程持有。
    options: *const TestOptions,
    /// 全局解析的权限（--allow-net 等），用于构建子进程 shu run 的 argv。
    permissions: *const args.ParsedArgs,
    /// 当 options.bail_after != null 时由主线程传入；首个失败时置 true，worker 取任务前检查并退出。
    bail_requested: ?*std.atomic.Value(bool) = null,
};

/// [Allocates] 由 run_path（如 "tests/unit/shu/example.test.js"）计算对应 snapshot 文件路径：项目根下 snapshots/<dir>/<basename>.snap，与常见运行时约定一致。
fn snapshotFilePathForRunPath(allocator: std.mem.Allocator, run_path: []const u8) ![]const u8 {
    const dir = libs_io.pathDirname(run_path) orelse ".";
    const base = libs_io.pathBasename(run_path);
    var last_dot: ?usize = null;
    for (base, 0..) |c, i| {
        if (c == '.') last_dot = i;
    }
    const base_no_ext = if (last_dot) |idx| base[0..idx] else base;
    const base_dot_snap = try std.fmt.allocPrint(allocator, "{s}.snap", .{base_no_ext});
    defer allocator.free(base_dot_snap);
    return libs_io.pathJoin(allocator, &.{ "snapshots", dir, base_dot_snap });
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
        const run_path = ctx.paths[idx];
        const snap_path = snapshotFilePathForRunPath(ctx.allocator, run_path) catch {
            _ = ctx.failed_count.fetchAdd(1, .monotonic);
            continue;
        };
        defer ctx.allocator.free(snap_path);
        var passed: bool = true;
        var argv_buf: [8][]const u8 = undefined;
        argv_buf[0] = ctx.self_exe;
        argv_buf[1] = "run";
        var argv_len: usize = 2;
        if (ctx.permissions.allow_net) {
            argv_buf[argv_len] = "--allow-net";
            argv_len += 1;
        }
        argv_buf[argv_len] = "--allow-read";
        argv_len += 1;
        if (ctx.options.update_snapshots or ctx.options.coverage or ctx.permissions.allow_write) {
            argv_buf[argv_len] = "--allow-write";
            argv_len += 1;
        }
        argv_buf[argv_len] = run_path;
        argv_len += 1;
        const argv = argv_buf[0..argv_len];
        blk: {
            if (ctx.options.hasEnvOptions()) {
                var env = buildTestEnvironMap(ctx.allocator, ctx.options, snap_path) catch {
                    _ = ctx.failed_count.fetchAdd(1, .monotonic);
                    passed = false;
                    break :blk;
                };
                defer env.deinit();
                env.put("SHU_TEST_CWD", ctx.cwd_owned) catch {};
                var path_buf: [512]u8 = undefined;
                var cases_buf: [32]u8 = undefined;
                const file_path_display = std.fmt.bufPrint(&path_buf, "./{s}", .{run_path}) catch run_path;
                env.put("SHU_TEST_FILE_PATH", file_path_display) catch {};
                const cases_name = std.fmt.bufPrint(&cases_buf, ".shu-test-cases{d}", .{idx}) catch ".shu-test-cases";
                const cases_path = libs_io.pathJoin(ctx.allocator, &.{ ctx.cwd_owned, cases_name }) catch break :blk;
                defer ctx.allocator.free(cases_path);
                env.put("SHU_TEST_CASES_FILE", cases_path) catch {};
                var child = std.process.spawn(ctx.io, .{
                    .argv = argv,
                    .cwd = .{ .path = ctx.cwd_owned },
                    .environ_map = &env,
                    .stdin = .inherit,
                    .stdout = .inherit,
                    .stderr = .inherit,
                }) catch {
                    _ = ctx.failed_count.fetchAdd(1, .monotonic);
                    passed = false;
                    if (ctx.bail_requested) |bail| bail.store(true, .release);
                    break :blk;
                };
                const term = child.wait(ctx.io) catch {
                    _ = ctx.failed_count.fetchAdd(1, .monotonic);
                    passed = false;
                    if (ctx.bail_requested) |bail| bail.store(true, .release);
                    break :blk;
                };
                const cases = readCasesFile(ctx.allocator, ctx.io, cases_path);
                _ = ctx.case_passed.fetchAdd(cases.passed, .monotonic);
                _ = ctx.case_failed.fetchAdd(cases.failed, .monotonic);
                _ = ctx.case_skipped.fetchAdd(cases.skipped, .monotonic);
                switch (term) {
                    .exited => |code| {
                        if (code != 0) {
                            _ = ctx.failed_count.fetchAdd(1, .monotonic);
                            passed = false;
                            if (ctx.bail_requested) |bail| bail.store(true, .release);
                        }
                    },
                    .signal, .stopped, .unknown => {
                        _ = ctx.failed_count.fetchAdd(1, .monotonic);
                        passed = false;
                        if (ctx.bail_requested) |bail| bail.store(true, .release);
                    },
                }
            } else {
                var env = buildTestEnvironMap(ctx.allocator, ctx.options, snap_path) catch {
                    _ = ctx.failed_count.fetchAdd(1, .monotonic);
                    passed = false;
                    break :blk;
                };
                defer env.deinit();
                env.put("SHU_TEST_CWD", ctx.cwd_owned) catch {};
                var path_buf: [512]u8 = undefined;
                var cases_buf: [32]u8 = undefined;
                const file_path_display = std.fmt.bufPrint(&path_buf, "./{s}", .{run_path}) catch run_path;
                env.put("SHU_TEST_FILE_PATH", file_path_display) catch {};
                const cases_name = std.fmt.bufPrint(&cases_buf, ".shu-test-cases{d}", .{idx}) catch ".shu-test-cases";
                const cases_path = libs_io.pathJoin(ctx.allocator, &.{ ctx.cwd_owned, cases_name }) catch break :blk;
                defer ctx.allocator.free(cases_path);
                env.put("SHU_TEST_CASES_FILE", cases_path) catch {};
                var child = std.process.spawn(ctx.io, .{
                    .argv = argv,
                    .cwd = .{ .path = ctx.cwd_owned },
                    .environ_map = &env,
                    .stdin = .inherit,
                    .stdout = .inherit,
                    .stderr = .inherit,
                }) catch {
                    _ = ctx.failed_count.fetchAdd(1, .monotonic);
                    passed = false;
                    if (ctx.bail_requested) |bail| bail.store(true, .release);
                    break :blk;
                };
                const term = child.wait(ctx.io) catch {
                    _ = ctx.failed_count.fetchAdd(1, .monotonic);
                    passed = false;
                    if (ctx.bail_requested) |bail| bail.store(true, .release);
                    break :blk;
                };
                const cases = readCasesFile(ctx.allocator, ctx.io, cases_path);
                _ = ctx.case_passed.fetchAdd(cases.passed, .monotonic);
                _ = ctx.case_failed.fetchAdd(cases.failed, .monotonic);
                _ = ctx.case_skipped.fetchAdd(cases.skipped, .monotonic);
                switch (term) {
                    .exited => |code| {
                        if (code != 0) {
                            _ = ctx.failed_count.fetchAdd(1, .monotonic);
                            passed = false;
                            if (ctx.bail_requested) |bail| bail.store(true, .release);
                        }
                    },
                    .signal, .stopped, .unknown => {
                        _ = ctx.failed_count.fetchAdd(1, .monotonic);
                        passed = false;
                        if (ctx.bail_requested) |bail| bail.store(true, .release);
                    },
                }
            }
        }
        // Deno 风格：不打印每文件 path (Nms)，子进程 stderr 已 inherit，用例行直接到终端；仅最后汇总 Test cases。
    }
}

/// 默认行为：若 explicit_run_paths 非 null 则只跑这些文件；否则扫描 tests/ 下 test/spec 并执行。jobs > 1 且多文件时并行。
/// filter 仅在「未指定 explicit_run_paths」时生效；options 控制 --bail、--shard 等。permissions 为全局解析的 allow_net 等，会传给子进程 shu run。
fn runDefaultTests(allocator: std.mem.Allocator, cwd_owned: []const u8, io: std.Io, jobs: u32, filter: ?[]const u8, options: *const TestOptions, permissions: *const args.ParsedArgs, explicit_run_paths: ?*std.ArrayList([]const u8)) !void {
    var run_paths = if (explicit_run_paths) |ex|
        ex.*
    else blk: {
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
        std.mem.sort([]const u8, list.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
        var paths = std.ArrayList([]const u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
        for (list.items) |item| {
            const rp = try libs_io.pathJoin(allocator, &.{ "tests", item });
            paths.append(allocator, rp) catch {
                allocator.free(rp);
                for (paths.items) |p| allocator.free(p);
                paths.deinit(allocator);
                return error.OutOfMemory;
            };
        }
        // list 由上方 defer 在离开 blk 时统一释放，此处不再重复 free
        if (filter) |pat| {
            var write: usize = 0;
            for (paths.items) |rp| {
                if (std.mem.indexOf(u8, rp, pat) != null) {
                    paths.items[write] = rp;
                    write += 1;
                } else {
                    allocator.free(rp);
                }
            }
            paths.shrinkRetainingCapacity(write);
            if (paths.items.len == 0) {
                try printStderr(io, "shu test: no test files matching filter \"{s}\".\n", .{pat});
                for (paths.items) |p| allocator.free(p);
                paths.deinit(allocator);
                try printToStdout(io, "\n", .{});
                return;
            }
        }
        if (options.shard_total != null and options.shard_index != null) {
            const n = options.shard_total.?;
            const i = options.shard_index.?;
            var write: usize = 0;
            for (paths.items, 0..) |rp, index| {
                if (@as(u32, @intCast(index)) % n == i) {
                    paths.items[write] = rp;
                    write += 1;
                } else {
                    allocator.free(rp);
                }
            }
            paths.shrinkRetainingCapacity(write);
            if (paths.items.len == 0) {
                try printStderr(io, "shu test: no test files in shard {d}/{d}.\n", .{ i, n });
                for (paths.items) |p| allocator.free(p);
                paths.deinit(allocator);
                try printToStdout(io, "\n", .{});
                return;
            }
        }
        if (options.randomize and paths.items.len > 1) {
            const seed: u64 = options.seed orelse 0;
            var prng = std.Random.DefaultPrng.init(seed);
            prng.random().shuffle([]const u8, paths.items);
        }
        break :blk paths;
    };
    defer if (explicit_run_paths == null) {
        for (run_paths.items) |p| allocator.free(p);
        run_paths.deinit(allocator);
    };

    if (run_paths.items.len == 0) {
        try printStderr(io, "shu test: no test files to run.\n", .{});
        try printToStdout(io, "\n", .{});
        return;
    }

    const self_exe = std.process.executablePathAlloc(io, allocator) catch {
        try printStderr(io, "shu test: cannot get executable path\n", .{});
        return error.SelfExeFailed;
    };
    defer allocator.free(self_exe);

    const total = run_paths.items.len;
    const use_parallel = jobs > 1 and total > 1;
    const start_ms = nowMs(io);
    if (!use_parallel) {
        var failed_count: u32 = 0;
        var case_passed: u64 = 0;
        var case_failed: u64 = 0;
        var case_skipped: u64 = 0;
        for (run_paths.items) |run_path| {
            if (options.bail_after != null and failed_count > 0) break;
            const snap_path = try snapshotFilePathForRunPath(allocator, run_path);
            defer allocator.free(snap_path);
            var argv_buf: [8][]const u8 = undefined;
            argv_buf[0] = self_exe;
            argv_buf[1] = "run";
            var argv_len: usize = 2;
            if (permissions.allow_net) {
                argv_buf[argv_len] = "--allow-net";
                argv_len += 1;
            }
            argv_buf[argv_len] = "--allow-read";
            argv_len += 1;
            if (options.update_snapshots or options.coverage or permissions.allow_write) {
                argv_buf[argv_len] = "--allow-write";
                argv_len += 1;
            }
            argv_buf[argv_len] = run_path;
            argv_len += 1;
            const argv = argv_buf[0..argv_len];
            var passed_this: bool = true;
            if (options.hasEnvOptions()) {
                var env = try buildTestEnvironMap(allocator, options, snap_path);
                defer env.deinit();
                env.put("SHU_TEST_CWD", cwd_owned) catch {};
                var path_buf: [512]u8 = undefined;
                const file_path_display = std.fmt.bufPrint(&path_buf, "./{s}", .{run_path}) catch run_path;
                env.put("SHU_TEST_FILE_PATH", file_path_display) catch {};
                const cases_path = try libs_io.pathJoin(allocator, &.{ cwd_owned, ".shu-test-cases" });
                defer allocator.free(cases_path);
                env.put("SHU_TEST_CASES_FILE", cases_path) catch {};
                var child = try std.process.spawn(io, .{
                    .argv = argv,
                    .cwd = .{ .path = cwd_owned },
                    .environ_map = &env,
                    .stdin = .inherit,
                    .stdout = .inherit,
                    .stderr = .inherit,
                });
                const term = try child.wait(io);
                const cases = readCasesFile(allocator, io, cases_path);
                case_passed += cases.passed;
                case_failed += cases.failed;
                case_skipped += cases.skipped;
                switch (term) {
                    .exited => |code| {
                        if (code != 0) {
                            failed_count += 1;
                            passed_this = false;
                            if (options.bail_after != null) break;
                        }
                    },
                    .signal, .stopped, .unknown => {
                        failed_count += 1;
                        passed_this = false;
                        if (options.bail_after != null) break;
                    },
                }
            } else {
                var env = try buildTestEnvironMap(allocator, options, snap_path);
                defer env.deinit();
                env.put("SHU_TEST_CWD", cwd_owned) catch {};
                var path_buf: [512]u8 = undefined;
                const file_path_display = std.fmt.bufPrint(&path_buf, "./{s}", .{run_path}) catch run_path;
                env.put("SHU_TEST_FILE_PATH", file_path_display) catch {};
                const cases_path = try libs_io.pathJoin(allocator, &.{ cwd_owned, ".shu-test-cases" });
                defer allocator.free(cases_path);
                env.put("SHU_TEST_CASES_FILE", cases_path) catch {};
                var child = try std.process.spawn(io, .{
                    .argv = argv,
                    .cwd = .{ .path = cwd_owned },
                    .environ_map = &env,
                    .stdin = .inherit,
                    .stdout = .inherit,
                    .stderr = .inherit,
                });
                const term = try child.wait(io);
                const cases = readCasesFile(allocator, io, cases_path);
                case_passed += cases.passed;
                case_failed += cases.failed;
                case_skipped += cases.skipped;
                switch (term) {
                    .exited => |code| {
                        if (code != 0) {
                            failed_count += 1;
                            passed_this = false;
                            if (options.bail_after != null) break;
                        }
                    },
                    .signal, .stopped, .unknown => {
                        failed_count += 1;
                        passed_this = false;
                        if (options.bail_after != null) break;
                    },
                }
            }
        }
        const elapsed_ms = @as(u64, @intCast(@max(0, nowMs(io) - start_ms)));
        try printTestSummaryCases(io, case_passed, case_failed, case_skipped, total, elapsed_ms);
        if (failed_count > 0) return error.ScriptExitedNonZero;
        return;
    }

    const next_index = std.atomic.Value(usize).init(0);
    const failed_atomic = std.atomic.Value(u32).init(0);
    const print_guard = std.atomic.Value(u32).init(0);
    var bail_atomic = std.atomic.Value(bool).init(false);
    const n_workers = @min(jobs, total);
    const case_passed_atomic = std.atomic.Value(u64).init(0);
    const case_failed_atomic = std.atomic.Value(u64).init(0);
    const case_skipped_atomic = std.atomic.Value(u64).init(0);
    var ctx = TestWorkerCtx{
        .allocator = allocator,
        .cwd_owned = cwd_owned,
        .self_exe = self_exe,
        .paths = run_paths.items,
        .total = total,
        .next_index = next_index,
        .failed_count = failed_atomic,
        .case_passed = case_passed_atomic,
        .case_failed = case_failed_atomic,
        .case_skipped = case_skipped_atomic,
        .print_guard = print_guard,
        .io = io,
        .options = options,
        .permissions = permissions,
        .bail_requested = if (options.bail_after != null) &bail_atomic else null,
    };
    var threads = try std.ArrayList(std.Thread).initCapacity(allocator, n_workers);
    defer threads.deinit(allocator);
    for (0..n_workers) |_| {
        try threads.append(allocator, try std.Thread.spawn(.{}, testFileWorker, .{&ctx}));
    }
    for (threads.items) |t| t.join();
    const failed_count = failed_atomic.load(.monotonic);
    const case_passed = ctx.case_passed.load(.monotonic);
    const case_failed = ctx.case_failed.load(.monotonic);
    const case_skipped = ctx.case_skipped.load(.monotonic);
    const elapsed_ms = @as(u64, @intCast(@max(0, nowMs(io) - start_ms)));
    try printTestSummaryCases(io, case_passed, case_failed, case_skipped, total, elapsed_ms);
    if (failed_count > 0) return error.ScriptExitedNonZero;
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

/// 返回当前时间（毫秒），用于测试文件执行耗时。Zig 0.16 使用 std.Io.Clock。
fn nowMs(io: std.Io) i64 {
    const ns = std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds;
    return @as(i64, @intCast(@divTrunc(ns, std.time.ns_per_ms)));
}

/// ANSI 颜色（与 version.zig 一致）；仅 TTY 时使用，否则无转义。绿/红：结果；青：时间；黄：跳过。
const c_green = "\x1b[32m";
const c_red = "\x1b[31m";
const c_cyan = "\x1b[36m";
const c_yellow = "\x1b[33m";
const c_reset = "\x1b[0m";

/// 打印单条测试文件结果：路径 + 执行时间（毫秒）；与 Deno 对齐，暂不打印 ✓/✗。末尾多一空行，与下一文件输出分隔。
fn printTestFileResult(io: std.Io, run_path: []const u8, passed: bool, elapsed_ms: u64) void {
    _ = passed;
    var buf: [320]u8 = undefined;
    var w = std.Io.File.Writer.init(std.Io.File.stdout(), io, &buf);
    w.interface.print("{s} ({d}ms)\n\n", .{ run_path, elapsed_ms }) catch return;
    w.interface.flush() catch {};
}

/// 打印测试用例汇总：passed/failed/skipped、测试文件数、总耗时。TTY 下用绿/红/黄；输出为英文。
fn printTestSummaryCases(io: std.Io, passed: u64, failed: u64, skipped: u64, total_files: usize, total_ms: u64) !void {
    if (std.c.isatty(1) != 0) {
        try printToStdout(io, "\nTest cases: {s}{d}{s} passed, {s}{d}{s} failed, {s}{d}{s} skipped.\n", .{
            c_green, passed, c_reset,
            c_red, failed, c_reset,
            c_yellow, skipped, c_reset,
        });
        try printToStdout(io, "{s}{d}{s} test files, {s}{d}{s}ms total.\n\n", .{
            c_cyan, total_files, c_reset,
            c_cyan, total_ms, c_reset,
        });
    } else {
        try printToStdout(io, "\nTest cases: {d} passed, {d} failed, {d} skipped.\n", .{ passed, failed, skipped });
        try printToStdout(io, "{d} test files, {d}ms total.\n\n", .{ total_files, total_ms });
    }
}
