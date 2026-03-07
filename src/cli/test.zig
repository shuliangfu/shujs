//! shu test 子命令（cli/test.zig）
//!
//! 职责
//!   - 有 scripts.test 时：用 shell 执行该脚本（runScriptInCwd）。
//!   - 无 script 时：默认从当前目录递归扫描全项目下 *.test.js/ts/jsx/tsx、*.spec.js/ts/jsx/tsx（排除 scan.default_exclude_dirs：node_modules、.git、dist、build 等），对每个文件执行 shu run；无 package.json 时仍可走默认扫描。
//!   - 多文件时按「测试文件路径字母序」依次执行，保证顺序与文件管理器中一致且可复现。
//!   - 默认**单文件顺序**执行（--jobs=1），避免多进程并发时输出交错；需多文件并发时传 **--jobs=N**（上限 64，如 --jobs=4）。
//!   - **--filter=pattern** / **--filter pattern**：仅运行完整名称中包含 pattern 的测试用例（等价 --test-name-pattern）。
//!   - 有 package.json/deno.json 时：**test.include**（glob，如 **/*.test.js）与 **test.exclude**（路径列表）会过滤扫描到的文件；无 include/exclude 时行为不变。
//!
//! 主要 API
//!   - runTest(allocator, parsed, positional)：入口；无可匹配文件时给出英文提示。
//!
//! 约定
//!   - 目录遍历与路径经 io_core；面向用户输出为英文；与 PACKAGE_DESIGN.md test 配置、deno test 对齐。

const std = @import("std");
const args = @import("args.zig");
const version = @import("version.zig");
const builtin = @import("builtin");
const libs_io = @import("libs_io");
const libs_process = @import("libs_process");
const manifest = @import("../package/manifest.zig");
const scan = @import("scan.zig");
const cli_help = @import("help.zig");

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
    /// --reporter=SPEC：SPEC 可为类型（junit/json/html/markdown）或输出路径（按后缀识别格式）。
    reporter: ?[]const u8 = null,
    /// --preload=path：跑测试前先 require 的脚本路径（SHU_TEST_PRELOAD）。
    preload: ?[]const u8 = null,
    /// --todo：只跑标记为 it.todo / test.todo 的用例（SHU_TEST_TODO_ONLY=1）。
    todo_only: bool = false,
    /// --randomize：随机化测试文件执行顺序（与 --seed 配合）。
    randomize: bool = false,
    /// --seed=N：随机化时使用的种子（SHU_TEST_SEED）；未指定时用当前时间。
    seed: ?u64 = null,
    /// --snapshots：snapshot(name, value) 文件不存在则创建，存在则更新（SHU_TEST_UPDATE_SNAPSHOTS=1）。
    update_snapshots: bool = false,
    /// --coverage / --coverage=path：启用覆盖率；不带值默认输出到 coverage，带值写入指定目录（SHU_TEST_COVERAGE=1、SHU_TEST_COVERAGE_DIR）。
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
            self.preload != null or
            self.todo_only or
            self.randomize or
            self.seed != null or
            self.update_snapshots or
            self.coverage or
            self.coverage_dir != null;
    }
};

/// reporter 类型：none 表示未启用。
const ReporterKind = enum { none, junit, json, html, markdown };

/// reporter 解析结果：kind + 输出路径（当 kind != .none 时必有默认路径或用户路径）。
const ReporterSelection = struct {
    kind: ReporterKind = .none,
    outfile: ?[]const u8 = null,
};

/// 报告运行元数据：四种 reporter 共享，保证信息口径一致。
const ReportMeta = struct {
    tool: []const u8,
    shu_version: []const u8,
    reporter: []const u8,
    command: []const u8,
    cwd: []const u8,
    platform: []const u8,
    arch: []const u8,
    ci: bool,
    started_at_ms: i64,
    ended_at_ms: i64,
    total_elapsed_ms: u64,
    jobs: u32,
    permissions: args.ParsedArgs,
    options: TestOptions,
};

/// 判断全局权限是否等价于 --allow-all（所有权限位均为 true）。
fn isAllowAllPermissions(p: *const args.ParsedArgs) bool {
    return p.allow_net and p.allow_read and p.allow_env and p.allow_write and p.allow_run and p.allow_hrtime and p.allow_ffi;
}

/// 将 reporter kind 转成子进程环境变量 SHU_TEST_REPORTER 所需字符串。
fn reporterKindToEnvString(kind: ReporterKind) []const u8 {
    return switch (kind) {
        .junit => "junit",
        .json => "json",
        .html => "html",
        .markdown => "markdown",
        .none => "",
    };
}

/// 将 reporter kind 转为报告展示字符串。
fn reporterKindToName(kind: ReporterKind) []const u8 {
    return switch (kind) {
        .junit => "junit",
        .json => "json",
        .html => "html",
        .markdown => "markdown",
        .none => "none",
    };
}

/// 解析 --reporter 的值：
/// - 传类型：junit/json/html/markdown/md
/// - 传路径：按后缀识别（.xml/.json/.html/.md）
/// 返回 kind 与输出路径；非法值返回 error.InvalidReporter。
fn resolveReporterSelection(reporter: ?[]const u8) !ReporterSelection {
    const spec = reporter orelse return .{};
    if (std.mem.eql(u8, spec, "junit")) return .{ .kind = .junit, .outfile = "report.xml" };
    if (std.mem.eql(u8, spec, "json")) return .{ .kind = .json, .outfile = "report.json" };
    if (std.mem.eql(u8, spec, "html")) return .{ .kind = .html, .outfile = "report.html" };
    if (std.mem.eql(u8, spec, "markdown") or std.mem.eql(u8, spec, "md")) return .{ .kind = .markdown, .outfile = "report.md" };

    // 作为路径时按后缀推断 reporter 类型。
    if (std.mem.endsWith(u8, spec, ".xml")) return .{ .kind = .junit, .outfile = spec };
    if (std.mem.endsWith(u8, spec, ".json")) return .{ .kind = .json, .outfile = spec };
    if (std.mem.endsWith(u8, spec, ".html") or std.mem.endsWith(u8, spec, ".htm")) return .{ .kind = .html, .outfile = spec };
    if (std.mem.endsWith(u8, spec, ".md")) return .{ .kind = .markdown, .outfile = spec };
    return error.InvalidReporter;
}

/// [Allocates] 将 --reporter=spec1,spec2,... 的整串按逗号拆成多个 spec；每段 trim 后 dupe。调用方负责 free 每段并 deinit list。
fn splitReporterSpecs(allocator: std.mem.Allocator, spec_str: []const u8) !std.ArrayList([]const u8) {
    var list = std.ArrayList([]const u8).initCapacity(allocator, 0) catch return error.OutOfMemory;
    var it = std.mem.splitScalar(u8, spec_str, ',');
    while (it.next()) |segment| {
        const trimmed = std.mem.trim(u8, segment, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        try list.append(allocator, allocator.dupe(u8, trimmed) catch return error.OutOfMemory);
    }
    return list;
}

/// 将多个 spec 解析为 ReporterSelection 列表；outfile 为路径时指向 spec 切片，调用方需保证 spec 生命周期覆盖使用期。
fn resolveReporterSelections(allocator: std.mem.Allocator, specs: []const []const u8) !std.ArrayList(ReporterSelection) {
    var list = std.ArrayList(ReporterSelection).initCapacity(allocator, specs.len) catch return error.OutOfMemory;
    for (specs) |spec| {
        try list.append(allocator, try resolveReporterSelection(spec));
    }
    return list;
}

/// [Allocates] 从 positional 解析 --filter=pattern 或 --filter pattern；该选项用于按测试名称过滤（等价 --test-name-pattern）。未指定时返回 null。调用方负责 free 返回值。
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

/// 从 test 子命令的 positional 中解析 --jobs=N 或 --jobs N。未指定时返回 null（调用方用默认 1，即单文件顺序）；指定时返回 N（上限 64）。
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

/// [Allocates] 从 positional 解析 --reporter=spec 或 --reporter spec。调用方 free。
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

/// 从 positional 解析 --snapshots；兼容 --update-snapshots / -u。存在即返回 true。
fn parseTestUpdateSnapshots(positional: []const []const u8) bool {
    for (positional) |arg| {
        if (std.mem.eql(u8, arg, "--snapshots") or std.mem.eql(u8, arg, "--update-snapshots") or std.mem.eql(u8, arg, "-u")) return true;
    }
    return false;
}

/// 从 positional 解析 --coverage 或 --coverage=path；存在即返回 true。
fn parseTestCoverage(positional: []const []const u8) bool {
    for (positional) |arg| {
        if (std.mem.eql(u8, arg, "--coverage") or std.mem.startsWith(u8, arg, "--coverage=")) return true;
    }
    return false;
}

/// [Allocates] 从 positional 解析 --coverage=path；兼容 --coverage-dir=path / --coverage-dir path。调用方 free。
fn parseTestCoverageDir(allocator: std.mem.Allocator, positional: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < positional.len) : (i += 1) {
        const arg = positional[i];
        if (std.mem.startsWith(u8, arg, "--coverage=")) {
            const rest = arg["--coverage=".len..];
            if (rest.len == 0) return null;
            return allocator.dupe(u8, rest) catch return null;
        }
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
    // Deprecated option：仅用于避免把其值误当成测试路径；实际功能已移除。
    if (std.mem.eql(u8, arg, "--reporter-outfile")) return true;
    if (std.mem.eql(u8, arg, "--preload")) return true;
    if (std.mem.eql(u8, arg, "--seed")) return true;
    if (std.mem.eql(u8, arg, "--coverage-dir")) return true;
    return false;
}

/// [Allocates] 从 positional 解析「仅跑这些文件或目录」：非选项参数视为路径。若为目录则递归收集其下 *.test.* / *.spec.*（与默认扫描扩展名一致）；若为文件则直接加入。返回相对项目根的 run_path 列表，调用方逐项 free 并 list.deinit。需 cwd_owned 与 io 以解析目录。
fn parsePositionalTestFiles(allocator: std.mem.Allocator, positional: []const []const u8, cwd_owned: []const u8, io: std.Io) ?std.ArrayList([]const u8) {
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
        // 去掉前导 ./，去掉尾随 /，得到相对项目根路径
        var raw = if (std.mem.startsWith(u8, arg, "./")) arg[2..] else arg;
        while (raw.len > 1 and raw[raw.len - 1] == '/') raw = raw[0 .. raw.len - 1];
        const abs = libs_io.pathJoin(allocator, &.{ cwd_owned, raw }) catch continue;
        defer allocator.free(abs);
        // 先尝试作为目录：递归收集测试文件（与默认扫描扩展名一致）
        var dir = libs_io.openDirAbsolute(abs, .{ .iterate = true }) catch null;
        if (dir) |*d| {
            defer d.close(io);
            var collected = scan.collectFilesRecursive(allocator, abs, &scan.test_extensions, io) catch continue;
            defer {
                for (collected.items) |p| allocator.free(p);
                collected.deinit(allocator);
            }
            for (collected.items) |rel_path| {
                const full = libs_io.pathJoin(allocator, &.{ raw, rel_path }) catch continue;
                list.append(allocator, full) catch {
                    allocator.free(full);
                };
            }
        } else {
            // 作为文件：加入列表（任意扩展名均可，便于 shu test path/to/foo.js）
            var file = libs_io.openFileAbsolute(abs, .{}) catch continue;
            file.close(io);
            const run_path = allocator.dupe(u8, raw) catch continue;
            list.append(allocator, run_path) catch {
                allocator.free(run_path);
            };
        }
    }
    if (list.items.len == 0) {
        list.deinit(allocator);
        return null;
    }
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return list;
}

/// [Allocates] 从 positional 汇总解析 TestOptions。调用方负责对返回结构体中的字符串字段 free。
fn parseTestOptions(allocator: std.mem.Allocator, positional: []const []const u8) TestOptions {
    const shard = parseTestShard(allocator, positional);
    // --filter 与 --test-name-pattern 语义统一：都按测试完整名称过滤；若二者同时给出，以 --test-name-pattern 为准。
    const name_pattern = parseTestNamePattern(allocator, positional);
    const filter_pattern = if (name_pattern == null) parseTestFilter(allocator, positional) else null;
    const coverage_dir = parseTestCoverageDir(allocator, positional);
    const coverage_flag = parseTestCoverage(positional);
    return .{
        .bail_after = parseTestBail(allocator, positional),
        .shard_index = if (shard) |s| s[0] else null,
        .shard_total = if (shard) |s| s[1] else null,
        .test_name_pattern = if (name_pattern != null) name_pattern else filter_pattern,
        .test_skip_pattern = parseTestSkipPattern(allocator, positional),
        .timeout_ms = parseTestTimeout(positional),
        .retry = parseTestRetry(positional),
        .reporter = parseTestReporter(allocator, positional),
        .preload = parseTestPreload(allocator, positional),
        .todo_only = parseTestTodo(positional),
        .randomize = parseTestRandomize(positional),
        .seed = parseTestSeed(positional),
        .update_snapshots = parseTestUpdateSnapshots(positional),
        .coverage = coverage_flag or coverage_dir != null,
        .coverage_dir = coverage_dir,
    };
}

/// 打印 shu test 子命令帮助（Usage + Options）；供 main 在 shu test --help / -h 时调用。输出为英文；TTY 下与全局 help 一致使用 ANSI 颜色（青/黄/灰）。
pub fn printTestHelp(io: std.Io) !void {
    var buf: [512]u8 = undefined;
    var w = std.Io.File.Writer.init(std.Io.File.stdout(), io, &buf);
    const out = &w.interface;
    const sgr = cli_help.getHelpSgr();

    try out.print("{s}Discover and run tests.{s}\n\n", .{ sgr.dim, sgr.reset });
    try out.print("{s}Usage{s}: {s}shu test [OPTIONS] [files or dirs...]{s}\n\n", .{ sgr.cyan, sgr.reset, sgr.dim, sgr.reset });
    try out.print("  {s}By default scans all directories for *.test.js/ts/jsx/tsx, *.spec.js/ts/jsx/tsx (excludes node_modules, .git, dist, build, etc.).{s}\n", .{ sgr.dim, sgr.reset });
    try out.print("  {s}You may pass file paths (e.g. tests/unit/foo.test.js) or directories (e.g. tests/unit/shu); directories are scanned recursively for test files.{s}\n", .{ sgr.dim, sgr.reset });
    try out.print("  {s}Respects package.json / deno.json \"test\".include and \"test\".exclude when present.{s}\n\n", .{ sgr.dim, sgr.reset });
    try out.print("{s}Options{s}:\n", .{ sgr.cyan, sgr.reset });
    try out.print("  {s}--jobs=N{s}                 Run N test files in parallel (default: 1). Use --jobs=1 for sequential output.\n", .{ sgr.yellow, sgr.reset });
    try out.print("  {s}--filter=PATTERN{s}         Only run tests whose full name contains PATTERN.\n", .{ sgr.yellow, sgr.reset });
    try out.print("  {s}--test-name-pattern, -t{s}  Only run tests whose full name contains the given substring.\n", .{ sgr.yellow, sgr.reset });
    try out.print("  {s}--test-skip-pattern{s}      Skip tests whose full name contains the given substring.\n", .{ sgr.yellow, sgr.reset });
    try out.print("  {s}--bail, --fail-fast{s}      Stop after first failure.\n", .{ sgr.yellow, sgr.reset });
    try out.print("  {s}--shard=INDEX/TOTAL{s}      Run only the INDEX-th shard of TOTAL (for CI).\n", .{ sgr.yellow, sgr.reset });
    try out.print("  {s}--timeout=N{s}              Default test timeout in milliseconds.\n", .{ sgr.yellow, sgr.reset });
    try out.print("  {s}--retry=N{s}                Retry failed tests N times.\n", .{ sgr.yellow, sgr.reset });
    try out.print("  {s}--reporter=SPEC{s}          SPEC is type (junit/json/html/markdown) or path (*.xml/*.json/*.html/*.md). Comma-separated for multiple: --reporter=./report.md,./report.html\n", .{ sgr.yellow, sgr.reset });
    try out.print("  {s}--preload=PATH{s}           Require PATH before each test file.\n", .{ sgr.yellow, sgr.reset });
    try out.print("  {s}--randomize{s}              Shuffle test file execution order.\n", .{ sgr.yellow, sgr.reset });
    try out.print("  {s}--seed=N{s}                 Seed for --randomize (deterministic order).\n", .{ sgr.yellow, sgr.reset });
    try out.print("  {s}--coverage[=PATH]{s}        Enable coverage; default dir is coverage.\n", .{ sgr.yellow, sgr.reset });
    try out.print("  {s}--snapshots{s}              Create snapshots if missing, update if present.\n", .{ sgr.yellow, sgr.reset });
    try out.print("  {s}--todo{s}                   Run only it.todo / test.todo tests.\n\n", .{ sgr.yellow, sgr.reset });
    try out.print("{s}Global options{s}: {s}--allow-all (-A), --allow-net, --allow-read, --allow-env, --allow-write, --allow-run, --allow-hrtime, --allow-ffi{s}\n\n", .{ sgr.cyan, sgr.reset, sgr.dim, sgr.reset });
    w.flush() catch {};
}

/// 执行 shu test：有 scripts.test 则用 shell 执行；否则默认从当前目录递归扫描全项目 *.test.js/ts/jsx/tsx、*.spec.js/ts/jsx/tsx（排除 default_exclude_dirs），对每个文件执行 shu run。
/// 支持 positional 中的 --jobs=N；默认 1（单文件顺序），传 N>1 时多文件并行。
pub fn runTest(allocator: std.mem.Allocator, parsed: args.ParsedArgs, positional: []const []const u8, io: std.Io) !void {
    // 默认 1：单文件顺序执行，输出不交错；显式传 --jobs=N 时多文件并发。
    const default_jobs: u32 = 1;
    const jobs = @min(parseTestJobs(positional) orelse default_jobs, 64);
    try version.printCommandHeader(io, "test");
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = libs_io.realpath(".", &cwd_buf) catch {
        try printStderr(io, "shu test: cannot get current directory\n", .{});
        return error.CwdFailed;
    };
    const cwd_owned = allocator.dupe(u8, cwd) catch return;
    defer allocator.free(cwd_owned);

    var options = parseTestOptions(allocator, positional);
    defer {
        if (options.test_name_pattern) |p| allocator.free(p);
        if (options.test_skip_pattern) |p| allocator.free(p);
        if (options.reporter) |p| allocator.free(p);
        if (options.preload) |p| allocator.free(p);
        if (options.coverage_dir) |p| allocator.free(p);
    }
    // 支持 --reporter=spec1,spec2,... 逗号分隔多输出；拆成多个 ReporterSelection 传入 runDefaultTests。
    // 生命周期：segments/selections 必须活到 runDefaultTests 返回后再释放，故 defer 放在函数作用域而非 if 块内。
    var reporter_selections: []const ReporterSelection = &[_]ReporterSelection{};
    var segments_opt: ?std.ArrayList([]const u8) = null;
    var selections_opt: ?std.ArrayList(ReporterSelection) = null;
    if (options.reporter) |reporter_str| {
        segments_opt = splitReporterSpecs(allocator, reporter_str) catch return error.OutOfMemory;
        selections_opt = resolveReporterSelections(allocator, segments_opt.?.items) catch {
            if (segments_opt) |*seg| {
                for (seg.items) |s| allocator.free(s);
                seg.deinit(allocator);
            }
            try printStderr(io, "shu test: invalid --reporter spec. Supported types: junit, json, html, markdown; or path suffix: .xml, .json, .html, .md\n", .{});
            return error.InvalidReporter;
        };
        reporter_selections = selections_opt.?.items;
    }
    defer if (segments_opt) |*seg| {
        for (seg.items) |s| allocator.free(s);
        seg.deinit(allocator);
    };
    defer if (selections_opt) |*sel| sel.deinit(allocator);

    var loaded = manifest.Manifest.load(allocator, cwd_owned) catch |e| {
        if (e == error.ManifestNotFound) {
            var explicit = parsePositionalTestFiles(allocator, positional, cwd_owned, io);
            defer if (explicit) |*list| {
                for (list.items) |p| allocator.free(p);
                list.deinit(allocator);
            };
            return runDefaultTests(allocator, cwd_owned, io, jobs, positional, &options, reporter_selections, &parsed, if (explicit) |*list_ptr| list_ptr else null, null);
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

    var explicit = parsePositionalTestFiles(allocator, positional, cwd_owned, io);
    defer if (explicit) |*list| {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    };
    return runDefaultTests(allocator, cwd_owned, io, jobs, positional, &options, reporter_selections, &parsed, if (explicit) |*list_ptr| list_ptr else null, m.test_value);
}

/// 子进程 stderr 中 __SHU_TEST_CASES__ 行的解析结果；未找到时全为 0。
const CaseSummary = struct { passed: u32, failed: u32, skipped: u32 };

/// 单条用例明细（来自子进程 SHU_TEST_DETAILS_FILE），用于 reporter=json 聚合输出。
const CaseDetail = struct {
    file: []const u8,
    name: []const u8,
    status: []const u8,
    elapsed_ms: i64,
    /// 失败用例错误信息；passed/skipped 为 null。
    error_message: ?[]const u8 = null,
    /// 失败用例栈信息；passed/skipped 为 null。
    error_stack: ?[]const u8 = null,
};

/// 子进程单文件明细 JSON 的解码结构：
/// { "file": "...", "totalMs": 12, "cases": [{ "name":"...", "status":"passed", "elapsedMs":1, "errorMessage":"...", "errorStack":"..." }] }
const CaseDetailFile = struct {
    file: []const u8,
    totalMs: i64,
    cases: []struct {
        name: []const u8,
        status: []const u8,
        elapsedMs: i64,
        errorMessage: ?[]const u8 = null,
        errorStack: ?[]const u8 = null,
    },
};

/// 从子进程写入的 SHU_TEST_CASES_FILE 路径读取一行并解析用例数；文件不存在或解析失败返回全 0。读后删除该文件。Deno 风格下子进程 stderr 已 inherit，用例数通过文件回传。经 libs_io 打开/读/删。
fn readCasesFile(allocator: std.mem.Allocator, io: std.Io, cases_file_path: []const u8) CaseSummary {
    var f = libs_io.openFileAbsolute(cases_file_path, .{ .mode = .read_only }) catch return .{ .passed = 0, .failed = 0, .skipped = 0 };
    defer f.close(io);
    // 读取缓冲与目标缓冲分离，避免 readVec 内部 memcpy 发生别名重叠。
    var reader_buf: [256]u8 = undefined;
    var chunk_buf: [256]u8 = undefined;
    var list = std.ArrayList(u8).initCapacity(allocator, 256) catch return .{ .passed = 0, .failed = 0, .skipped = 0 };
    defer list.deinit(allocator);
    var r = f.reader(io, &reader_buf);
    var dest: [1][]u8 = .{chunk_buf[0..]};
    while (true) {
        const n = std.Io.Reader.readVec(&r.interface, &dest) catch break;
        if (n == 0) break;
        list.appendSlice(allocator, chunk_buf[0..n]) catch break;
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

/// JSON 字符串转义并追加到 out（用于 reporter=json 输出）。
fn appendJsonEscaped(out: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) void {
    for (input) |ch| switch (ch) {
        '"' => out.appendSlice(allocator, "\\\"") catch return,
        '\\' => out.appendSlice(allocator, "\\\\") catch return,
        '\n' => out.appendSlice(allocator, "\\n") catch return,
        '\r' => out.appendSlice(allocator, "\\r") catch return,
        '\t' => out.appendSlice(allocator, "\\t") catch return,
        else => {
            if (ch < 0x20) {
                var esc: [6]u8 = undefined;
                const s = std.fmt.bufPrint(&esc, "\\u{X:0>4}", .{@as(u32, ch)}) catch return;
                out.appendSlice(allocator, s) catch return;
            } else out.append(allocator, ch) catch return;
        },
    };
}

/// 读取子进程写入的 SHU_TEST_DETAILS_FILE，解析并追加到 all_details；读后删除文件。
/// [Allocates] 会复制每条 case 的 file/name/status/errorMessage/errorStack 到 all_details，调用方负责统一释放。
fn readCaseDetailsFileAndAppend(allocator: std.mem.Allocator, io: std.Io, details_path: []const u8, all_details: *std.ArrayList(CaseDetail)) void {
    var f = libs_io.openFileAbsolute(details_path, .{ .mode = .read_only }) catch return;
    defer f.close(io);

    // 读取缓冲与目标缓冲分离，避免 readVec 内部 memcpy 发生别名重叠。
    var reader_buf: [512]u8 = undefined;
    var chunk_buf: [512]u8 = undefined;
    var list = std.ArrayList(u8).initCapacity(allocator, 512) catch return;
    defer list.deinit(allocator);
    var r = f.reader(io, &reader_buf);
    var dest: [1][]u8 = .{chunk_buf[0..]};
    while (true) {
        const n = std.Io.Reader.readVec(&r.interface, &dest) catch break;
        if (n == 0) break;
        list.appendSlice(allocator, chunk_buf[0..n]) catch break;
    }
    libs_io.deleteFileAbsolute(details_path) catch {};
    if (list.items.len == 0) return;

    var parsed = std.json.parseFromSlice(CaseDetailFile, allocator, list.items, .{ .allocate = .alloc_always }) catch return;
    defer parsed.deinit();
    for (parsed.value.cases) |c| {
        const file_owned = allocator.dupe(u8, parsed.value.file) catch continue;
        errdefer allocator.free(file_owned);
        const name_owned = allocator.dupe(u8, c.name) catch continue;
        errdefer allocator.free(name_owned);
        const status_owned = allocator.dupe(u8, c.status) catch continue;
        errdefer allocator.free(status_owned);
        const error_message_owned = if (c.errorMessage) |m| allocator.dupe(u8, m) catch null else null;
        const error_stack_owned = if (c.errorStack) |s| allocator.dupe(u8, s) catch null else null;
        all_details.append(allocator, .{
            .file = file_owned,
            .name = name_owned,
            .status = status_owned,
            .elapsed_ms = c.elapsedMs,
            .error_message = error_message_owned,
            .error_stack = error_stack_owned,
        }) catch {
            allocator.free(file_owned);
            allocator.free(name_owned);
            allocator.free(status_owned);
            if (error_message_owned) |m| allocator.free(m);
            if (error_stack_owned) |s| allocator.free(s);
        };
    }
}

/// 将聚合后的测试结果写为 JSON 报告：
/// summary: totalCases/passed/failed/skipped/totalTestFiles/startedAtMs/endedAtMs/totalElapsedMs
/// files:   [{ file,totalCases,passed,failed,skipped,totalElapsedMs,cases:[{ name,status,elapsedMs,errorMessage?,errorStack? }] }]
/// 说明：JSON 作为最完整机器可读格式，优先保留失败详情与时间元信息，便于 CI/可视化系统消费。
fn writeJsonTestReport(
    allocator: std.mem.Allocator,
    io: std.Io,
    outfile: []const u8,
    total_files: usize,
    total_elapsed_ms: u64,
    passed: u64,
    failed: u64,
    skipped: u64,
    details: []const CaseDetail,
    meta: *const ReportMeta,
) !void {
    var out = try std.ArrayList(u8).initCapacity(allocator, 4096);
    defer out.deinit(allocator);

    out.appendSlice(allocator, "{\n  \"summary\": {\n") catch return;
    var num_buf: [64]u8 = undefined;
    const total_cases = passed + failed + skipped;
    out.appendSlice(allocator, "    \"schemaVersion\": 2,\n") catch return;
    out.appendSlice(allocator, "    \"tool\": \"") catch return;
    appendJsonEscaped(&out, allocator, meta.tool);
    out.appendSlice(allocator, "\",\n    \"shuVersion\": \"") catch return;
    appendJsonEscaped(&out, allocator, meta.shu_version);
    out.appendSlice(allocator, "\",\n    \"reporter\": \"") catch return;
    appendJsonEscaped(&out, allocator, meta.reporter);
    out.appendSlice(allocator, "\",\n    \"command\": \"") catch return;
    appendJsonEscaped(&out, allocator, meta.command);
    out.appendSlice(allocator, "\",\n    \"cwd\": \"") catch return;
    appendJsonEscaped(&out, allocator, meta.cwd);
    out.appendSlice(allocator, "\",\n    \"platform\": \"") catch return;
    appendJsonEscaped(&out, allocator, meta.platform);
    out.appendSlice(allocator, "\",\n    \"arch\": \"") catch return;
    appendJsonEscaped(&out, allocator, meta.arch);
    out.appendSlice(allocator, "\",\n    \"ci\": ") catch return;
    out.appendSlice(allocator, if (meta.ci) "true" else "false") catch return;
    out.appendSlice(allocator, ",\n    \"jobs\": ") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{meta.jobs}) catch return) catch return;
    out.appendSlice(allocator, ",\n    \"permissions\": {\"allowAll\": ") catch return;
    out.appendSlice(allocator, if (isAllowAllPermissions(&meta.permissions)) "true" else "false") catch return;
    out.appendSlice(allocator, ", \"allowNet\": ") catch return;
    out.appendSlice(allocator, if (meta.permissions.allow_net) "true" else "false") catch return;
    out.appendSlice(allocator, ", \"allowRead\": ") catch return;
    out.appendSlice(allocator, if (meta.permissions.allow_read) "true" else "false") catch return;
    out.appendSlice(allocator, ", \"allowEnv\": ") catch return;
    out.appendSlice(allocator, if (meta.permissions.allow_env) "true" else "false") catch return;
    out.appendSlice(allocator, ", \"allowWrite\": ") catch return;
    out.appendSlice(allocator, if (meta.permissions.allow_write) "true" else "false") catch return;
    out.appendSlice(allocator, ", \"allowRun\": ") catch return;
    out.appendSlice(allocator, if (meta.permissions.allow_run) "true" else "false") catch return;
    out.appendSlice(allocator, ", \"allowHrtime\": ") catch return;
    out.appendSlice(allocator, if (meta.permissions.allow_hrtime) "true" else "false") catch return;
    out.appendSlice(allocator, ", \"allowFfi\": ") catch return;
    out.appendSlice(allocator, if (meta.permissions.allow_ffi) "true" else "false") catch return;
    out.appendSlice(allocator, "},\n    \"options\": {\"bail\": ") catch return;
    out.appendSlice(allocator, if (meta.options.bail_after != null) "true" else "false") catch return;
    out.appendSlice(allocator, ", \"retry\": ") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{meta.options.retry orelse 0}) catch return) catch return;
    out.appendSlice(allocator, ", \"timeoutMs\": ") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{meta.options.timeout_ms orelse 0}) catch return) catch return;
    out.appendSlice(allocator, ", \"randomize\": ") catch return;
    out.appendSlice(allocator, if (meta.options.randomize) "true" else "false") catch return;
    out.appendSlice(allocator, ", \"seed\": ") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{meta.options.seed orelse 0}) catch return) catch return;
    out.appendSlice(allocator, ", \"coverage\": ") catch return;
    out.appendSlice(allocator, if (meta.options.coverage) "true" else "false") catch return;
    out.appendSlice(allocator, ", \"snapshots\": ") catch return;
    out.appendSlice(allocator, if (meta.options.update_snapshots) "true" else "false") catch return;
    out.appendSlice(allocator, ", \"todoOnly\": ") catch return;
    out.appendSlice(allocator, if (meta.options.todo_only) "true" else "false") catch return;
    out.appendSlice(allocator, "},\n    \"totalCases\": ") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{total_cases}) catch return) catch return;
    out.appendSlice(allocator, ",\n    \"passed\": ") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{passed}) catch return) catch return;
    out.appendSlice(allocator, ",\n    \"failed\": ") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{failed}) catch return) catch return;
    out.appendSlice(allocator, ",\n    \"skipped\": ") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{skipped}) catch return) catch return;
    out.appendSlice(allocator, ",\n    \"totalTestFiles\": ") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{total_files}) catch return) catch return;
    out.appendSlice(allocator, ",\n    \"startedAtMs\": ") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{meta.started_at_ms}) catch return) catch return;
    out.appendSlice(allocator, ",\n    \"endedAtMs\": ") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{meta.ended_at_ms}) catch return) catch return;
    out.appendSlice(allocator, ",\n    \"totalElapsedMs\": ") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{total_elapsed_ms}) catch return) catch return;
    out.appendSlice(allocator, "\n  },\n  \"files\": [\n") catch return;
    if (details.len > 0) {
        // 按文件分组输出，统一与 markdown/html/junit 的结构。
        var file_order = std.ArrayList([]const u8).initCapacity(allocator, 0) catch return;
        defer file_order.deinit(allocator);
        for (details) |d| {
            var exists = false;
            for (file_order.items) |f| {
                if (std.mem.eql(u8, f, d.file)) {
                    exists = true;
                    break;
                }
            }
            if (!exists) file_order.append(allocator, d.file) catch return;
        }
        for (file_order.items, 0..) |file_path, file_idx| {
            if (file_idx != 0) out.appendSlice(allocator, ",\n") catch return;
            var file_total: u64 = 0;
            var file_passed: u64 = 0;
            var file_failed: u64 = 0;
            var file_skipped: u64 = 0;
            var file_elapsed_ms: i64 = 0;
            for (details) |d| {
                if (!std.mem.eql(u8, d.file, file_path)) continue;
                file_total += 1;
                file_elapsed_ms += d.elapsed_ms;
                if (std.mem.eql(u8, d.status, "failed")) {
                    file_failed += 1;
                } else if (std.mem.eql(u8, d.status, "skipped")) {
                    file_skipped += 1;
                } else {
                    file_passed += 1;
                }
            }
            out.appendSlice(allocator, "    {\"file\": \"") catch return;
            appendJsonEscaped(&out, allocator, file_path);
            out.appendSlice(allocator, "\", \"totalCases\": ") catch return;
            out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{file_total}) catch return) catch return;
            out.appendSlice(allocator, ", \"passed\": ") catch return;
            out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{file_passed}) catch return) catch return;
            out.appendSlice(allocator, ", \"failed\": ") catch return;
            out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{file_failed}) catch return) catch return;
            out.appendSlice(allocator, ", \"skipped\": ") catch return;
            out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{file_skipped}) catch return) catch return;
            out.appendSlice(allocator, ", \"totalElapsedMs\": ") catch return;
            out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{file_elapsed_ms}) catch return) catch return;
            out.appendSlice(allocator, ", \"cases\": [") catch return;
            var case_idx: usize = 0;
            for (details) |d| {
                if (!std.mem.eql(u8, d.file, file_path)) continue;
                if (case_idx != 0) out.appendSlice(allocator, ", ") catch return;
                out.appendSlice(allocator, "{\"name\": \"") catch return;
                appendJsonEscaped(&out, allocator, d.name);
                out.appendSlice(allocator, "\", \"status\": \"") catch return;
                appendJsonEscaped(&out, allocator, d.status);
                out.appendSlice(allocator, "\", \"elapsedMs\": ") catch return;
                out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{d.elapsed_ms}) catch return) catch return;
                if (d.error_message) |msg| {
                    out.appendSlice(allocator, ", \"errorMessage\": \"") catch return;
                    appendJsonEscaped(&out, allocator, msg);
                    out.appendSlice(allocator, "\"") catch return;
                }
                if (d.error_stack) |stk| {
                    out.appendSlice(allocator, ", \"errorStack\": \"") catch return;
                    appendJsonEscaped(&out, allocator, stk);
                    out.appendSlice(allocator, "\"") catch return;
                }
                out.appendSlice(allocator, "}") catch return;
                case_idx += 1;
            }
            out.appendSlice(allocator, "]}") catch return;
        }
    }
    out.appendSlice(allocator, "\n  ]\n}\n") catch return;

    var file = try libs_io.createFileAbsolute(outfile, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, out.items);
}

/// Markdown 文本转义（表格列场景）：转义 `|` 与换行，避免破坏表结构。
fn appendMarkdownEscaped(out: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) void {
    for (input) |ch| switch (ch) {
        '|' => out.appendSlice(allocator, "\\|") catch return,
        '\n', '\r' => out.appendSlice(allocator, " ") catch return,
        else => out.append(allocator, ch) catch return,
    };
}

/// HTML 文本转义：最小集转义，避免标签注入并保证报告可读。
fn appendHtmlEscaped(out: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) void {
    for (input) |ch| switch (ch) {
        '&' => out.appendSlice(allocator, "&amp;") catch return,
        '<' => out.appendSlice(allocator, "&lt;") catch return,
        '>' => out.appendSlice(allocator, "&gt;") catch return,
        '"' => out.appendSlice(allocator, "&quot;") catch return,
        '\'' => out.appendSlice(allocator, "&#39;") catch return,
        else => out.append(allocator, ch) catch return,
    };
}

/// XML 属性/文本转义：用于 JUnit 报告，避免非法字符破坏 XML 结构。
fn appendXmlEscaped(out: *std.ArrayList(u8), allocator: std.mem.Allocator, input: []const u8) void {
    for (input) |ch| switch (ch) {
        '&' => out.appendSlice(allocator, "&amp;") catch return,
        '<' => out.appendSlice(allocator, "&lt;") catch return,
        '>' => out.appendSlice(allocator, "&gt;") catch return,
        '"' => out.appendSlice(allocator, "&quot;") catch return,
        '\'' => out.appendSlice(allocator, "&apos;") catch return,
        else => out.append(allocator, ch) catch return,
    };
}

/// 写 JUnit XML 测试报告（按测试文件分 testsuite，每个 testsuite 下是该文件的 testcase）。
fn writeJunitTestReport(
    allocator: std.mem.Allocator,
    io: std.Io,
    outfile: []const u8,
    _: usize,
    _: u64,
    passed: u64,
    failed: u64,
    skipped: u64,
    details: []const CaseDetail,
    meta: *const ReportMeta,
) !void {
    var out = try std.ArrayList(u8).initCapacity(allocator, 6144);
    defer out.deinit(allocator);
    var num_buf: [64]u8 = undefined;
    const total_cases = passed + failed + skipped;

    out.appendSlice(allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<testsuites tests=\"") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{total_cases}) catch return) catch return;
    out.appendSlice(allocator, "\" failures=\"") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{failed}) catch return) catch return;
    out.appendSlice(allocator, "\" skipped=\"") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{skipped}) catch return) catch return;
    out.appendSlice(allocator, "\" errors=\"0\">\n") catch return;
    out.appendSlice(allocator, "  <properties>\n") catch return;
    out.appendSlice(allocator, "    <property name=\"tool\" value=\"") catch return;
    appendXmlEscaped(&out, allocator, meta.tool);
    out.appendSlice(allocator, "\"/>\n    <property name=\"shuVersion\" value=\"") catch return;
    appendXmlEscaped(&out, allocator, meta.shu_version);
    out.appendSlice(allocator, "\"/>\n    <property name=\"reporter\" value=\"") catch return;
    appendXmlEscaped(&out, allocator, meta.reporter);
    out.appendSlice(allocator, "\"/>\n    <property name=\"command\" value=\"") catch return;
    appendXmlEscaped(&out, allocator, meta.command);
    out.appendSlice(allocator, "\"/>\n    <property name=\"cwd\" value=\"") catch return;
    appendXmlEscaped(&out, allocator, meta.cwd);
    out.appendSlice(allocator, "\"/>\n    <property name=\"platform\" value=\"") catch return;
    appendXmlEscaped(&out, allocator, meta.platform);
    out.appendSlice(allocator, "\"/>\n    <property name=\"arch\" value=\"") catch return;
    appendXmlEscaped(&out, allocator, meta.arch);
    out.appendSlice(allocator, "\"/>\n  </properties>\n") catch return;

    if (details.len > 0) {
        // 按文件分组，输出多个 testsuite，结构与其他 reporter 分组保持一致。
        var file_order = std.ArrayList([]const u8).initCapacity(allocator, 0) catch return;
        defer file_order.deinit(allocator);
        for (details) |d| {
            var exists = false;
            for (file_order.items) |f| {
                if (std.mem.eql(u8, f, d.file)) {
                    exists = true;
                    break;
                }
            }
            if (!exists) file_order.append(allocator, d.file) catch return;
        }
        for (file_order.items) |file_path| {
            var suite_total: u64 = 0;
            var suite_failed: u64 = 0;
            var suite_skipped: u64 = 0;
            for (details) |d| {
                if (!std.mem.eql(u8, d.file, file_path)) continue;
                suite_total += 1;
                if (std.mem.eql(u8, d.status, "failed")) suite_failed += 1;
                if (std.mem.eql(u8, d.status, "skipped")) suite_skipped += 1;
            }
            out.appendSlice(allocator, "  <testsuite name=\"") catch return;
            appendXmlEscaped(&out, allocator, file_path);
            out.appendSlice(allocator, "\" tests=\"") catch return;
            out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{suite_total}) catch return) catch return;
            out.appendSlice(allocator, "\" failures=\"") catch return;
            out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{suite_failed}) catch return) catch return;
            out.appendSlice(allocator, "\" skipped=\"") catch return;
            out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{suite_skipped}) catch return) catch return;
            out.appendSlice(allocator, "\" errors=\"0\">\n") catch return;
            for (details) |d| {
                if (!std.mem.eql(u8, d.file, file_path)) continue;
                out.appendSlice(allocator, "    <testcase name=\"") catch return;
                appendXmlEscaped(&out, allocator, d.name);
                out.appendSlice(allocator, "\" classname=\"") catch return;
                appendXmlEscaped(&out, allocator, d.file);
                out.appendSlice(allocator, "\" time=\"") catch return;
                const elapsed_s = @as(f64, @floatFromInt(d.elapsed_ms)) / 1000.0;
                out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d:.3}", .{elapsed_s}) catch return) catch return;
                if (std.mem.eql(u8, d.status, "failed")) {
                    const failure_message = d.error_message orelse "failed";
                    out.appendSlice(allocator, "\"><failure message=\"") catch return;
                    appendXmlEscaped(&out, allocator, failure_message);
                    out.appendSlice(allocator, "\">") catch return;
                    if (d.error_stack) |stk| appendXmlEscaped(&out, allocator, stk);
                    out.appendSlice(allocator, "</failure></testcase>\n") catch return;
                } else if (std.mem.eql(u8, d.status, "skipped")) {
                    out.appendSlice(allocator, "\"><skipped/></testcase>\n") catch return;
                } else {
                    out.appendSlice(allocator, "\"/>\n") catch return;
                }
            }
            out.appendSlice(allocator, "  </testsuite>\n") catch return;
        }
    }
    out.appendSlice(allocator, "</testsuites>\n") catch return;

    var file = try libs_io.createFileAbsolute(outfile, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, out.items);
}

/// 写 Markdown 测试报告（含 summary + 按测试文件分组的 cases）；美化版：顶部概览、状态徽章、分节与错误代码块。
fn writeMarkdownTestReport(
    allocator: std.mem.Allocator,
    io: std.Io,
    outfile: []const u8,
    total_files: usize,
    total_elapsed_ms: u64,
    passed: u64,
    failed: u64,
    skipped: u64,
    details: []const CaseDetail,
    meta: *const ReportMeta,
) !void {
    var out = try std.ArrayList(u8).initCapacity(allocator, 8192);
    defer out.deinit(allocator);
    var num_buf: [64]u8 = undefined;
    const total_cases = passed + failed + skipped;
    const elapsed_sec = total_elapsed_ms / 1000;
    const elapsed_frac = (total_elapsed_ms % 1000) / 10;

    // 顶部一行概览：passed · failed · skipped — 耗时；章节标题带 emoji 图标
    out.appendSlice(allocator, "# 🧪 Test Report\n\n") catch return;
    out.appendSlice(allocator, "**") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{passed}) catch return) catch return;
    out.appendSlice(allocator, "** passed · **") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{failed}) catch return) catch return;
    out.appendSlice(allocator, "** failed · **") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{skipped}) catch return) catch return;
    out.appendSlice(allocator, "** skipped — ") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}.{d:0>2}", .{ elapsed_sec, elapsed_frac }) catch return) catch return;
    out.appendSlice(allocator, "s\n\n---\n\n## 📊 Summary\n\n") catch return;
    out.appendSlice(allocator, "| Metric | Value |\n|---|---:|\n") catch return;
    out.appendSlice(allocator, "| Total Cases | ") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{total_cases}) catch return) catch return;
    out.appendSlice(allocator, " |\n| Passed | ") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{passed}) catch return) catch return;
    out.appendSlice(allocator, " |\n| Failed | ") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{failed}) catch return) catch return;
    out.appendSlice(allocator, " |\n| Skipped | ") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{skipped}) catch return) catch return;
    out.appendSlice(allocator, " |\n| Total Test Files | ") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{total_files}) catch return) catch return;
    out.appendSlice(allocator, " |\n| Tool | ") catch return;
    appendMarkdownEscaped(&out, allocator, meta.tool);
    out.appendSlice(allocator, " |\n| Shu Version | ") catch return;
    appendMarkdownEscaped(&out, allocator, meta.shu_version);
    out.appendSlice(allocator, " |\n| Reporter | ") catch return;
    appendMarkdownEscaped(&out, allocator, meta.reporter);
    out.appendSlice(allocator, " |\n| Command | ") catch return;
    appendMarkdownEscaped(&out, allocator, meta.command);
    out.appendSlice(allocator, " |\n| CWD | ") catch return;
    appendMarkdownEscaped(&out, allocator, meta.cwd);
    out.appendSlice(allocator, " |\n| Platform | ") catch return;
    appendMarkdownEscaped(&out, allocator, meta.platform);
    out.appendSlice(allocator, " |\n| Arch | ") catch return;
    appendMarkdownEscaped(&out, allocator, meta.arch);
    out.appendSlice(allocator, " |\n| CI | ") catch return;
    out.appendSlice(allocator, if (meta.ci) "true" else "false") catch return;
    out.appendSlice(allocator, " |\n| Jobs | ") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{meta.jobs}) catch return) catch return;
    out.appendSlice(allocator, " |\n| Permissions | ") catch return;
    out.appendSlice(allocator, if (isAllowAllPermissions(&meta.permissions)) "all" else "granular") catch return;
    out.appendSlice(allocator, " |\n| allow-net/read/env/write/run/hrtime/ffi | ") catch return;
    out.appendSlice(allocator, if (meta.permissions.allow_net) "1" else "0") catch return;
    out.appendSlice(allocator, "/") catch return;
    out.appendSlice(allocator, if (meta.permissions.allow_read) "1" else "0") catch return;
    out.appendSlice(allocator, "/") catch return;
    out.appendSlice(allocator, if (meta.permissions.allow_env) "1" else "0") catch return;
    out.appendSlice(allocator, "/") catch return;
    out.appendSlice(allocator, if (meta.permissions.allow_write) "1" else "0") catch return;
    out.appendSlice(allocator, "/") catch return;
    out.appendSlice(allocator, if (meta.permissions.allow_run) "1" else "0") catch return;
    out.appendSlice(allocator, "/") catch return;
    out.appendSlice(allocator, if (meta.permissions.allow_hrtime) "1" else "0") catch return;
    out.appendSlice(allocator, "/") catch return;
    out.appendSlice(allocator, if (meta.permissions.allow_ffi) "1" else "0") catch return;
    out.appendSlice(allocator, " |\n| Options (bail/retry/timeout/randomize/seed/coverage/snapshots/todo) | ") catch return;
    out.appendSlice(allocator, if (meta.options.bail_after != null) "1" else "0") catch return;
    out.appendSlice(allocator, "/") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{meta.options.retry orelse 0}) catch return) catch return;
    out.appendSlice(allocator, "/") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{meta.options.timeout_ms orelse 0}) catch return) catch return;
    out.appendSlice(allocator, "/") catch return;
    out.appendSlice(allocator, if (meta.options.randomize) "1" else "0") catch return;
    out.appendSlice(allocator, "/") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{meta.options.seed orelse 0}) catch return) catch return;
    out.appendSlice(allocator, "/") catch return;
    out.appendSlice(allocator, if (meta.options.coverage) "1" else "0") catch return;
    out.appendSlice(allocator, "/") catch return;
    out.appendSlice(allocator, if (meta.options.update_snapshots) "1" else "0") catch return;
    out.appendSlice(allocator, "/") catch return;
    out.appendSlice(allocator, if (meta.options.todo_only) "1" else "0") catch return;
    out.appendSlice(allocator, " |\n| Started At (ms) | ") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{meta.started_at_ms}) catch return) catch return;
    out.appendSlice(allocator, " |\n| Ended At (ms) | ") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{meta.ended_at_ms}) catch return) catch return;
    out.appendSlice(allocator, " |\n| Total Elapsed (ms) | ") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{total_elapsed_ms}) catch return) catch return;
    out.appendSlice(allocator, " |\n\n## 📁 Cases\n\n") catch return;
    if (details.len == 0) {
        out.appendSlice(allocator, "_No case details available._\n") catch return;
    } else {
        // 按文件分组输出：每个文件一个小章节，分组表格不再重复输出 File 列。
        var file_order = std.ArrayList([]const u8).initCapacity(allocator, 0) catch return;
        defer file_order.deinit(allocator);
        for (details) |d| {
            var exists = false;
            for (file_order.items) |f| {
                if (std.mem.eql(u8, f, d.file)) {
                    exists = true;
                    break;
                }
            }
            if (!exists) file_order.append(allocator, d.file) catch return;
        }
        for (file_order.items) |file_path| {
            var file_total: u64 = 0;
            var file_passed: u64 = 0;
            var file_failed: u64 = 0;
            var file_skipped: u64 = 0;
            var file_elapsed_ms: i64 = 0;
            for (details) |d| {
                if (!std.mem.eql(u8, d.file, file_path)) continue;
                file_total += 1;
                file_elapsed_ms += d.elapsed_ms;
                if (std.mem.eql(u8, d.status, "failed")) {
                    file_failed += 1;
                } else if (std.mem.eql(u8, d.status, "skipped")) {
                    file_skipped += 1;
                } else {
                    file_passed += 1;
                }
            }
            out.appendSlice(allocator, "### 📄 ") catch return;
            appendMarkdownEscaped(&out, allocator, file_path);
            out.appendSlice(allocator, "\n\n") catch return;
            out.appendSlice(allocator, "- Total: ") catch return;
            out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{file_total}) catch return) catch return;
            out.appendSlice(allocator, ", Passed: ") catch return;
            out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{file_passed}) catch return) catch return;
            out.appendSlice(allocator, ", Failed: ") catch return;
            out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{file_failed}) catch return) catch return;
            out.appendSlice(allocator, ", Skipped: ") catch return;
            out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{file_skipped}) catch return) catch return;
            out.appendSlice(allocator, ", Elapsed(ms): ") catch return;
            out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{file_elapsed_ms}) catch return) catch return;
            out.appendSlice(allocator, "\n\n| Name | Status | Time (ms) | Error |\n|---|---|---:|---|\n") catch return;
            for (details) |d| {
                if (!std.mem.eql(u8, d.file, file_path)) continue;
                out.appendSlice(allocator, "| ") catch return;
                appendMarkdownEscaped(&out, allocator, d.name);
                out.appendSlice(allocator, " | ") catch return;
                if (std.mem.eql(u8, d.status, "passed")) {
                    out.appendSlice(allocator, "**passed**") catch return;
                } else if (std.mem.eql(u8, d.status, "failed")) {
                    out.appendSlice(allocator, "**failed**") catch return;
                } else {
                    out.appendSlice(allocator, "_skipped_") catch return;
                }
                out.appendSlice(allocator, " | ") catch return;
                out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{d.elapsed_ms}) catch return) catch return;
                out.appendSlice(allocator, " | ") catch return;
                if (d.error_message) |msg| {
                    appendMarkdownEscaped(&out, allocator, msg);
                } else {
                    out.appendSlice(allocator, "—") catch return;
                }
                out.appendSlice(allocator, " |\n") catch return;
                if (d.error_stack) |stk| {
                    out.appendSlice(allocator, "|  |  |  | ") catch return;
                    out.appendSlice(allocator, "`") catch return;
                    appendMarkdownEscaped(&out, allocator, stk);
                    out.appendSlice(allocator, "` |\n") catch return;
                }
            }
            out.appendSlice(allocator, "\n---\n\n") catch return;
        }
    }

    var file = try libs_io.createFileAbsolute(outfile, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, out.items);
}

/// 写 HTML 测试报告（含 summary + 按测试文件分组的 cases）；美化版：卡片式概览、徽章、斑马纹表格与错误代码块样式。
fn writeHtmlTestReport(
    allocator: std.mem.Allocator,
    io: std.Io,
    outfile: []const u8,
    total_files: usize,
    total_elapsed_ms: u64,
    passed: u64,
    failed: u64,
    skipped: u64,
    details: []const CaseDetail,
    meta: *const ReportMeta,
) !void {
    var out = try std.ArrayList(u8).initCapacity(allocator, 16384);
    defer out.deinit(allocator);
    var num_buf: [64]u8 = undefined;
    const total_cases = passed + failed + skipped;
    const elapsed_sec = total_elapsed_ms / 1000;
    const elapsed_frac = (total_elapsed_ms % 1000) / 10;

    out.appendSlice(allocator, "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>Test Report</title><style>") catch return;
    out.appendSlice(allocator, ":root{--passed:#15803d;--failed:#b91c1c;--skipped:#a16207;--bg:#f8fafc;--card:#fff;--border:#e2e8f0;--muted:#64748b;}") catch return;
    out.appendSlice(allocator, "body{font-family:ui-sans-serif,system-ui,\"Segoe UI\",Roboto,sans-serif;line-height:1.5;color:#0f172a;background:var(--bg);margin:0;padding:24px;}") catch return;
    out.appendSlice(allocator, ".wrap{max-width:960px;margin:0 auto;}") catch return;
    out.appendSlice(allocator, "h1{font-size:1.75rem;font-weight:700;margin:0 0 1rem;}") catch return;
    out.appendSlice(allocator, "h2{font-size:1.25rem;font-weight:600;margin:1.5rem 0 0.75rem;}") catch return;
    out.appendSlice(allocator, "h3{font-size:1rem;font-weight:600;margin:1.25rem 0 0.5rem;color:var(--muted);}") catch return;
    out.appendSlice(allocator, ".cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:12px;margin-bottom:1.5rem;}") catch return;
    out.appendSlice(allocator, ".card{background:var(--card);border:1px solid var(--border);border-radius:8px;padding:12px 16px;box-shadow:0 1px 2px rgba(0,0,0,.04);}") catch return;
    out.appendSlice(allocator, ".card .val{font-size:1.5rem;font-weight:700;}.card.passed .val{color:var(--passed);}.card.failed .val{color:var(--failed);}.card.skipped .val{color:var(--skipped);}.card .lbl{font-size:0.75rem;color:var(--muted);text-transform:uppercase;margin-top:2px;}") catch return;
    out.appendSlice(allocator, "table{border-collapse:collapse;width:100%;margin:12px 0;background:var(--card);border-radius:8px;overflow:hidden;box-shadow:0 1px 2px rgba(0,0,0,.04);}") catch return;
    out.appendSlice(allocator, "th,td{border:1px solid var(--border);padding:10px 12px;text-align:left;}") catch return;
    out.appendSlice(allocator, "th{background:#f1f5f9;font-weight:600;font-size:0.875rem;}") catch return;
    out.appendSlice(allocator, "tbody tr:nth-child(even){background:#f8fafc;}tbody tr:hover{background:#f1f5f9;}") catch return;
    out.appendSlice(allocator, ".num{text-align:right;font-variant-numeric:tabular-nums;}") catch return;
    out.appendSlice(allocator, ".badge{display:inline-block;padding:2px 8px;border-radius:4px;font-size:0.75rem;font-weight:600;}.badge-passed{background:#dcfce7;color:var(--passed);}.badge-failed{background:#fee2e2;color:var(--failed);}.badge-skipped{background:#fef3c7;color:var(--skipped);}") catch return;
    out.appendSlice(allocator, ".error-cell{white-space:pre-wrap;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px;background:#fef2f2;border-radius:4px;padding:8px;max-height:200px;overflow:auto;}") catch return;
    out.appendSlice(allocator, ".meta-table td:first-child{color:var(--muted);width:180px;}.meta-table td:nth-child(2){text-align:right;}") catch return;
    out.appendSlice(allocator, ".meta-table .mono{font-family:ui-monospace,Menlo,monospace;font-size:12px;word-break:break-all;}") catch return;
    out.appendSlice(allocator, "</style></head><body><div class=\"wrap\"><h1>Test Report</h1>") catch return;

    // 卡片：passed / failed / skipped / time
    out.appendSlice(allocator, "<div class=\"cards\"><div class=\"card passed\"><div class=\"val\">") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{passed}) catch return) catch return;
    out.appendSlice(allocator, "</div><div class=\"lbl\">Passed</div></div><div class=\"card failed\"><div class=\"val\">") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{failed}) catch return) catch return;
    out.appendSlice(allocator, "</div><div class=\"lbl\">Failed</div></div><div class=\"card skipped\"><div class=\"val\">") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{skipped}) catch return) catch return;
    out.appendSlice(allocator, "</div><div class=\"lbl\">Skipped</div></div><div class=\"card\"><div class=\"val\">") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}.{d:0>2}s", .{ elapsed_sec, elapsed_frac }) catch return) catch return;
    out.appendSlice(allocator, "</div><div class=\"lbl\">Time</div></div></div>") catch return;

    out.appendSlice(allocator, "<h2>Run info</h2><table class=\"meta-table\"><thead><tr><th>Metric</th><th>Value</th></tr></thead><tbody>") catch return;
    out.appendSlice(allocator, "<tr><td>Total Cases</td><td class=\"num\">") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{total_cases}) catch return) catch return;
    out.appendSlice(allocator, "</td></tr><tr><td>Passed</td><td class=\"num passed\">") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{passed}) catch return) catch return;
    out.appendSlice(allocator, "</td></tr><tr><td>Failed</td><td class=\"num failed\">") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{failed}) catch return) catch return;
    out.appendSlice(allocator, "</td></tr><tr><td>Skipped</td><td class=\"num skipped\">") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{skipped}) catch return) catch return;
    out.appendSlice(allocator, "</td></tr><tr><td>Total Test Files</td><td class=\"num\">") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{total_files}) catch return) catch return;
    out.appendSlice(allocator, "</td></tr><tr><td>Tool</td><td>") catch return;
    appendHtmlEscaped(&out, allocator, meta.tool);
    out.appendSlice(allocator, "</td></tr><tr><td>Shu Version</td><td>") catch return;
    appendHtmlEscaped(&out, allocator, meta.shu_version);
    out.appendSlice(allocator, "</td></tr><tr><td>Reporter</td><td>") catch return;
    appendHtmlEscaped(&out, allocator, meta.reporter);
    out.appendSlice(allocator, "</td></tr><tr><td>Command</td><td class=\"mono\">") catch return;
    appendHtmlEscaped(&out, allocator, meta.command);
    out.appendSlice(allocator, "</td></tr><tr><td>CWD</td><td class=\"mono\">") catch return;
    appendHtmlEscaped(&out, allocator, meta.cwd);
    out.appendSlice(allocator, "</td></tr><tr><td>Platform</td><td>") catch return;
    appendHtmlEscaped(&out, allocator, meta.platform);
    out.appendSlice(allocator, "</td></tr><tr><td>Arch</td><td>") catch return;
    appendHtmlEscaped(&out, allocator, meta.arch);
    out.appendSlice(allocator, "</td></tr><tr><td>CI</td><td>") catch return;
    out.appendSlice(allocator, if (meta.ci) "true" else "false") catch return;
    out.appendSlice(allocator, "</td></tr><tr><td>Jobs</td><td class=\"num\">") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{meta.jobs}) catch return) catch return;
    out.appendSlice(allocator, "</td></tr><tr><td>Permissions</td><td class=\"mono\">") catch return;
    out.appendSlice(allocator, if (isAllowAllPermissions(&meta.permissions)) "allow-all" else "granular permissions") catch return;
    out.appendSlice(allocator, " (net/read/env/write/run/hrtime/ffi: ") catch return;
    out.appendSlice(allocator, if (meta.permissions.allow_net) "1" else "0") catch return;
    out.appendSlice(allocator, "/") catch return;
    out.appendSlice(allocator, if (meta.permissions.allow_read) "1" else "0") catch return;
    out.appendSlice(allocator, "/") catch return;
    out.appendSlice(allocator, if (meta.permissions.allow_env) "1" else "0") catch return;
    out.appendSlice(allocator, "/") catch return;
    out.appendSlice(allocator, if (meta.permissions.allow_write) "1" else "0") catch return;
    out.appendSlice(allocator, "/") catch return;
    out.appendSlice(allocator, if (meta.permissions.allow_run) "1" else "0") catch return;
    out.appendSlice(allocator, "/") catch return;
    out.appendSlice(allocator, if (meta.permissions.allow_hrtime) "1" else "0") catch return;
    out.appendSlice(allocator, "/") catch return;
    out.appendSlice(allocator, if (meta.permissions.allow_ffi) "1" else "0") catch return;
    out.appendSlice(allocator, ")") catch return;
    out.appendSlice(allocator, "</td></tr><tr><td>Options</td><td class=\"mono\">") catch return;
    out.appendSlice(allocator, "bail=") catch return;
    out.appendSlice(allocator, if (meta.options.bail_after != null) "1" else "0") catch return;
    out.appendSlice(allocator, ", retry=") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{meta.options.retry orelse 0}) catch return) catch return;
    out.appendSlice(allocator, ", timeoutMs=") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{meta.options.timeout_ms orelse 0}) catch return) catch return;
    out.appendSlice(allocator, ", randomize=") catch return;
    out.appendSlice(allocator, if (meta.options.randomize) "1" else "0") catch return;
    out.appendSlice(allocator, ", seed=") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{meta.options.seed orelse 0}) catch return) catch return;
    out.appendSlice(allocator, ", coverage=") catch return;
    out.appendSlice(allocator, if (meta.options.coverage) "1" else "0") catch return;
    out.appendSlice(allocator, ", snapshots=") catch return;
    out.appendSlice(allocator, if (meta.options.update_snapshots) "1" else "0") catch return;
    out.appendSlice(allocator, ", todoOnly=") catch return;
    out.appendSlice(allocator, if (meta.options.todo_only) "1" else "0") catch return;
    out.appendSlice(allocator, "</td></tr><tr><td>Started At (ms)</td><td class=\"num\">") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{meta.started_at_ms}) catch return) catch return;
    out.appendSlice(allocator, "</td></tr><tr><td>Ended At (ms)</td><td class=\"num\">") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{meta.ended_at_ms}) catch return) catch return;
    out.appendSlice(allocator, "</td></tr><tr><td>Total Elapsed (ms)</td><td class=\"num\">") catch return;
    out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{total_elapsed_ms}) catch return) catch return;
    out.appendSlice(allocator, "</td></tr></tbody></table>") catch return;

    out.appendSlice(allocator, "<h2>Cases</h2>") catch return;
    if (details.len == 0) {
        out.appendSlice(allocator, "<p><em>No case details available.</em></p>") catch return;
    } else {
        // 按文件分组输出：每个文件一个小章节，分组表格不再重复输出 File 列。
        var file_order = std.ArrayList([]const u8).initCapacity(allocator, 0) catch return;
        defer file_order.deinit(allocator);
        for (details) |d| {
            var exists = false;
            for (file_order.items) |f| {
                if (std.mem.eql(u8, f, d.file)) {
                    exists = true;
                    break;
                }
            }
            if (!exists) file_order.append(allocator, d.file) catch return;
        }
        for (file_order.items) |file_path| {
            var file_total: u64 = 0;
            var file_passed: u64 = 0;
            var file_failed: u64 = 0;
            var file_skipped: u64 = 0;
            var file_elapsed_ms: i64 = 0;
            for (details) |d| {
                if (!std.mem.eql(u8, d.file, file_path)) continue;
                file_total += 1;
                file_elapsed_ms += d.elapsed_ms;
                if (std.mem.eql(u8, d.status, "failed")) {
                    file_failed += 1;
                } else if (std.mem.eql(u8, d.status, "skipped")) {
                    file_skipped += 1;
                } else {
                    file_passed += 1;
                }
            }
            out.appendSlice(allocator, "<h3>") catch return;
            appendHtmlEscaped(&out, allocator, file_path);
            out.appendSlice(allocator, "</h3><p>Total: ") catch return;
            out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{file_total}) catch return) catch return;
            out.appendSlice(allocator, ", Passed: ") catch return;
            out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{file_passed}) catch return) catch return;
            out.appendSlice(allocator, ", Failed: ") catch return;
            out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{file_failed}) catch return) catch return;
            out.appendSlice(allocator, ", Skipped: ") catch return;
            out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{file_skipped}) catch return) catch return;
            out.appendSlice(allocator, ", Elapsed(ms): ") catch return;
            out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{file_elapsed_ms}) catch return) catch return;
            out.appendSlice(allocator, "</p><table><thead><tr><th>Name</th><th>Status</th><th>Time (ms)</th><th>Error</th></tr></thead><tbody>") catch return;
            for (details) |d| {
                if (!std.mem.eql(u8, d.file, file_path)) continue;
                out.appendSlice(allocator, "<tr><td>") catch return;
                appendHtmlEscaped(&out, allocator, d.name);
                out.appendSlice(allocator, "</td><td><span class=\"badge badge-") catch return;
                appendHtmlEscaped(&out, allocator, d.status);
                out.appendSlice(allocator, "\">") catch return;
                appendHtmlEscaped(&out, allocator, d.status);
                out.appendSlice(allocator, "</span></td><td class=\"num\">") catch return;
                out.appendSlice(allocator, std.fmt.bufPrint(&num_buf, "{d}", .{d.elapsed_ms}) catch return) catch return;
                out.appendSlice(allocator, "</td><td class=\"error-cell\">") catch return;
                if (d.error_message) |msg| {
                    appendHtmlEscaped(&out, allocator, msg);
                    if (d.error_stack) |stk| {
                        out.appendSlice(allocator, "\n") catch return;
                        appendHtmlEscaped(&out, allocator, stk);
                    }
                } else {
                    out.appendSlice(allocator, "—") catch return;
                }
                out.appendSlice(allocator, "</td></tr>") catch return;
            }
            out.appendSlice(allocator, "</tbody></table>") catch return;
        }
    }
    out.appendSlice(allocator, "</div></body></html>\n") catch return;

    var file = try libs_io.createFileAbsolute(outfile, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, out.items);
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
    /// 解析后的 reporter 列表（可为多输出）；用于设置子进程 SHU_TEST_REPORTER* / SHU_TEST_DETAILS_FILE。
    reporter_selections: []const ReporterSelection,
    /// 全局解析的权限（--allow-net 等），用于构建子进程 shu run 的 argv。
    permissions: *const args.ParsedArgs,
    /// 当 options.bail_after != null 时由主线程传入；首个失败时置 true，worker 取任务前检查并退出。
    bail_requested: ?*std.atomic.Value(bool) = null,
};

/// 判断 run_path（如 tests/unit/shu/foo.test.js 或 src/foo.test.js）是否匹配 test.include 的单个 pattern（如 **/*.test.js 或 tests/**/*.test.js）。
/// 支持 "prefix**/segment"：path 须以 prefix 开头；segment 若以 * 开头则用其后扩展名做 endsWith（如 *.test.js => .test.js），否则整段做 endsWith。
fn pathMatchesInclude(run_path: []const u8, pattern: []const u8) bool {
    if (std.mem.indexOf(u8, pattern, "**")) |idx| {
        const prefix = pattern[0..idx];
        const after_glob = pattern[idx + 2 ..];
        var suffix = if (std.mem.lastIndexOf(u8, after_glob, "/")) |last_slash|
            after_glob[last_slash + 1 ..]
        else
            after_glob;
        if (suffix.len > 0 and suffix[0] == '*') suffix = suffix[1..];
        return (prefix.len == 0 or std.mem.startsWith(u8, run_path, prefix)) and
            (suffix.len == 0 or std.mem.endsWith(u8, run_path, suffix));
    }
    return std.mem.eql(u8, run_path, pattern) or std.mem.endsWith(u8, run_path, pattern);
}

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
/// 仅当 reporter_selections 长度为 1 且非 junit 时设置 SHU_TEST_REPORTER/OUTFILE（子进程写单文件）；多 reporter 或 junit 时由父进程从 details 聚合写。
fn buildTestEnvironMap(allocator: std.mem.Allocator, options: *const TestOptions, reporter_selections: []const ReporterSelection, snapshot_file_path: ?[]const u8) !std.process.Environ.Map {
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
    // 仅当单一 reporter 且非 junit 时让子进程写该文件；多 reporter 或 junit 由父进程从 details 写。
    if (reporter_selections.len == 1 and reporter_selections[0].kind != .none and reporter_selections[0].kind != .junit) {
        const sel = &reporter_selections[0];
        try env.put("SHU_TEST_REPORTER", reporterKindToEnvString(sel.kind));
        if (sel.outfile) |p| try env.put("SHU_TEST_REPORTER_OUTFILE", p);
    }
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

/// Worker 线程入口：从 next_index 取任务，执行 shu run <run_path>（run_path 为相对项目根）；支持 --bail 与 SHU_TEST_* 环境变量。
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
        // 子进程权限参数与用户显式输入保持一致：不自动补任何 --allow-*。
        // 预留足够容量容纳全部权限标志（--allow-net/read/env/write/run/hrtime/ffi）。
        var argv_buf: [16][]const u8 = undefined;
        argv_buf[0] = ctx.self_exe;
        argv_buf[1] = "run";
        var argv_len: usize = 2;
        if (ctx.permissions.allow_net) {
            argv_buf[argv_len] = "--allow-net";
            argv_len += 1;
        }
        if (ctx.permissions.allow_read) {
            argv_buf[argv_len] = "--allow-read";
            argv_len += 1;
        }
        if (ctx.permissions.allow_env) {
            argv_buf[argv_len] = "--allow-env";
            argv_len += 1;
        }
        if (ctx.permissions.allow_write) {
            argv_buf[argv_len] = "--allow-write";
            argv_len += 1;
        }
        if (ctx.permissions.allow_run) {
            argv_buf[argv_len] = "--allow-run";
            argv_len += 1;
        }
        if (ctx.permissions.allow_hrtime) {
            argv_buf[argv_len] = "--allow-hrtime";
            argv_len += 1;
        }
        if (ctx.permissions.allow_ffi) {
            argv_buf[argv_len] = "--allow-ffi";
            argv_len += 1;
        }
        argv_buf[argv_len] = run_path;
        argv_len += 1;
        const argv = argv_buf[0..argv_len];
        blk: {
            if (ctx.options.hasEnvOptions()) {
                var env = buildTestEnvironMap(ctx.allocator, ctx.options, ctx.reporter_selections, snap_path) catch {
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
                // 先删除旧文件，避免子进程异常提前退出时父进程读到历史统计。
                libs_io.deleteFileAbsolute(cases_path) catch {};
                env.put("SHU_TEST_CASES_FILE", cases_path) catch {};
                var details_buf: [32]u8 = undefined;
                const details_name = std.fmt.bufPrint(&details_buf, ".shu-test-details{d}", .{idx}) catch ".shu-test-details";
                const details_path = libs_io.pathJoin(ctx.allocator, &.{ ctx.cwd_owned, details_name }) catch break :blk;
                defer ctx.allocator.free(details_path);
                libs_io.deleteFileAbsolute(details_path) catch {};
                const need_details = for (ctx.reporter_selections) |sel| {
                    if (sel.kind == .junit or sel.kind == .json or sel.kind == .html or sel.kind == .markdown) break true;
                } else false;
                if (need_details) env.put("SHU_TEST_DETAILS_FILE", details_path) catch {};
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
                var env = buildTestEnvironMap(ctx.allocator, ctx.options, ctx.reporter_selections, snap_path) catch {
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
                // 先删除旧文件，避免子进程异常提前退出时父进程读到历史统计。
                libs_io.deleteFileAbsolute(cases_path) catch {};
                env.put("SHU_TEST_CASES_FILE", cases_path) catch {};
                var details_buf: [32]u8 = undefined;
                const details_name = std.fmt.bufPrint(&details_buf, ".shu-test-details{d}", .{idx}) catch ".shu-test-details";
                const details_path = libs_io.pathJoin(ctx.allocator, &.{ ctx.cwd_owned, details_name }) catch break :blk;
                defer ctx.allocator.free(details_path);
                libs_io.deleteFileAbsolute(details_path) catch {};
                const need_details = for (ctx.reporter_selections) |sel| {
                    if (sel.kind == .junit or sel.kind == .json or sel.kind == .html or sel.kind == .markdown) break true;
                } else false;
                if (need_details) env.put("SHU_TEST_DETAILS_FILE", details_path) catch {};
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

/// 默认行为：若 explicit_run_paths 非 null 则只跑这些文件；否则从当前目录递归扫描全项目下 *.test.js/ts/jsx/tsx、*.spec.js/ts/jsx/tsx（排除 node_modules、.git、dist、build 等），并执行。jobs > 1 且多文件时并行。
/// 用例级过滤由 options.test_name_pattern / options.test_skip_pattern 在子进程内生效；test_value 为 package.json/deno.json 的 test 配置，用于 include/exclude 过滤。
fn runDefaultTests(allocator: std.mem.Allocator, cwd_owned: []const u8, io: std.Io, jobs: u32, positional: []const []const u8, options: *const TestOptions, reporter_selections: []const ReporterSelection, permissions: *const args.ParsedArgs, explicit_run_paths: ?*std.ArrayList([]const u8), test_value: ?std.json.Value) !void {
    var run_paths = if (explicit_run_paths) |ex|
        ex.*
    else blk: {
        // 从项目根（cwd）递归扫描，排除 scan.default_exclude_dirs（node_modules、.git、dist、build 等）
        var list = try scan.collectFilesRecursive(allocator, cwd_owned, &scan.test_extensions, io);
        defer {
            for (list.items) |p| allocator.free(p);
            list.deinit(allocator);
        }
        if (list.items.len == 0) {
            try printStderr(io, "shu test: no test files found (*.test.js/ts/jsx/tsx, *.spec.js/ts/jsx/tsx). Excluded dirs: node_modules, .git, dist, build, etc.\n", .{});
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
            const rp = try allocator.dupe(u8, item);
            paths.append(allocator, rp) catch {
                allocator.free(rp);
                for (paths.items) |p| allocator.free(p);
                paths.deinit(allocator);
                return error.OutOfMemory;
            };
        }
        // --filter 语义已迁移为用例名过滤（options.test_name_pattern），这里不再做文件路径过滤。
        // package.json / deno.json test.include 与 test.exclude 过滤
        if (test_value) |tv| {
            if (tv == .object) {
                const obj = tv.object;
                if (obj.get("exclude")) |ex_val| {
                    if (ex_val == .array) {
                        var write: usize = 0;
                        for (paths.items) |rp| {
                            var excluded = false;
                            for (ex_val.array.items) |item| {
                                if (item == .string and std.mem.eql(u8, rp, item.string)) {
                                    excluded = true;
                                    break;
                                }
                            }
                            if (!excluded) {
                                paths.items[write] = rp;
                                write += 1;
                            } else {
                                allocator.free(rp);
                            }
                        }
                        paths.shrinkRetainingCapacity(write);
                    }
                }
                if (obj.get("include")) |in_val| {
                    if (in_val == .array and in_val.array.items.len > 0) {
                        var write: usize = 0;
                        for (paths.items) |rp| {
                            var included = false;
                            for (in_val.array.items) |item| {
                                if (item == .string and pathMatchesInclude(rp, item.string)) {
                                    included = true;
                                    break;
                                }
                            }
                            if (included) {
                                paths.items[write] = rp;
                                write += 1;
                            } else {
                                allocator.free(rp);
                            }
                        }
                        paths.shrinkRetainingCapacity(write);
                    }
                }
            }
            if (paths.items.len == 0) {
                try printStderr(io, "shu test: no test files after applying package test.include/exclude.\n", .{});
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
    var command_buf = std.ArrayList(u8).initCapacity(allocator, 128) catch return error.OutOfMemory;
    defer command_buf.deinit(allocator);
    command_buf.appendSlice(allocator, "shu test") catch return error.OutOfMemory;
    for (positional) |arg| {
        command_buf.append(allocator, ' ') catch return error.OutOfMemory;
        command_buf.appendSlice(allocator, arg) catch return error.OutOfMemory;
    }
    const want_detail_report = for (reporter_selections) |sel| {
        if (sel.kind == .junit or sel.kind == .json or sel.kind == .html or sel.kind == .markdown) break true;
    } else false;
    var all_details = std.ArrayList(CaseDetail).initCapacity(allocator, 0) catch return error.OutOfMemory;
    defer {
        for (all_details.items) |d| {
            allocator.free(d.file);
            allocator.free(d.name);
            allocator.free(d.status);
            if (d.error_message) |m| allocator.free(m);
            if (d.error_stack) |s| allocator.free(s);
        }
        all_details.deinit(allocator);
    }
    if (!use_parallel) {
        var failed_count: u32 = 0;
        var case_passed: u64 = 0;
        var case_failed: u64 = 0;
        var case_skipped: u64 = 0;
        for (run_paths.items) |run_path| {
            if (options.bail_after != null and failed_count > 0) break;
            const snap_path = try snapshotFilePathForRunPath(allocator, run_path);
            defer allocator.free(snap_path);
            // 子进程权限参数与用户显式输入保持一致：不自动补任何 --allow-*。
            // 预留足够容量容纳全部权限标志（--allow-net/read/env/write/run/hrtime/ffi）。
            var argv_buf: [16][]const u8 = undefined;
            argv_buf[0] = self_exe;
            argv_buf[1] = "run";
            var argv_len: usize = 2;
            if (permissions.allow_net) {
                argv_buf[argv_len] = "--allow-net";
                argv_len += 1;
            }
            if (permissions.allow_read) {
                argv_buf[argv_len] = "--allow-read";
                argv_len += 1;
            }
            if (permissions.allow_env) {
                argv_buf[argv_len] = "--allow-env";
                argv_len += 1;
            }
            if (permissions.allow_write) {
                argv_buf[argv_len] = "--allow-write";
                argv_len += 1;
            }
            if (permissions.allow_run) {
                argv_buf[argv_len] = "--allow-run";
                argv_len += 1;
            }
            if (permissions.allow_hrtime) {
                argv_buf[argv_len] = "--allow-hrtime";
                argv_len += 1;
            }
            if (permissions.allow_ffi) {
                argv_buf[argv_len] = "--allow-ffi";
                argv_len += 1;
            }
            argv_buf[argv_len] = run_path;
            argv_len += 1;
            const argv = argv_buf[0..argv_len];
            var passed_this: bool = true;
            if (options.hasEnvOptions()) {
                var env = try buildTestEnvironMap(allocator, options, reporter_selections, snap_path);
                defer env.deinit();
                env.put("SHU_TEST_CWD", cwd_owned) catch {};
                var path_buf: [512]u8 = undefined;
                const file_path_display = std.fmt.bufPrint(&path_buf, "./{s}", .{run_path}) catch run_path;
                env.put("SHU_TEST_FILE_PATH", file_path_display) catch {};
                const cases_path = try libs_io.pathJoin(allocator, &.{ cwd_owned, ".shu-test-cases" });
                defer allocator.free(cases_path);
                // 先删除旧文件，避免子进程异常提前退出时父进程读到历史统计。
                libs_io.deleteFileAbsolute(cases_path) catch {};
                env.put("SHU_TEST_CASES_FILE", cases_path) catch {};
                const details_path = try libs_io.pathJoin(allocator, &.{ cwd_owned, ".shu-test-details" });
                defer allocator.free(details_path);
                libs_io.deleteFileAbsolute(details_path) catch {};
                if (want_detail_report) env.put("SHU_TEST_DETAILS_FILE", details_path) catch {};
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
                if (want_detail_report) readCaseDetailsFileAndAppend(allocator, io, details_path, &all_details);
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
                var env = try buildTestEnvironMap(allocator, options, reporter_selections, snap_path);
                defer env.deinit();
                env.put("SHU_TEST_CWD", cwd_owned) catch {};
                var path_buf: [512]u8 = undefined;
                const file_path_display = std.fmt.bufPrint(&path_buf, "./{s}", .{run_path}) catch run_path;
                env.put("SHU_TEST_FILE_PATH", file_path_display) catch {};
                const cases_path = try libs_io.pathJoin(allocator, &.{ cwd_owned, ".shu-test-cases" });
                defer allocator.free(cases_path);
                // 先删除旧文件，避免子进程异常提前退出时父进程读到历史统计。
                libs_io.deleteFileAbsolute(cases_path) catch {};
                env.put("SHU_TEST_CASES_FILE", cases_path) catch {};
                const details_path = try libs_io.pathJoin(allocator, &.{ cwd_owned, ".shu-test-details" });
                defer allocator.free(details_path);
                libs_io.deleteFileAbsolute(details_path) catch {};
                if (want_detail_report) env.put("SHU_TEST_DETAILS_FILE", details_path) catch {};
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
                if (want_detail_report) readCaseDetailsFileAndAppend(allocator, io, details_path, &all_details);
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
        const ended_ms = start_ms + @as(i64, @intCast(elapsed_ms));
        var reporter_name_buf: [64]u8 = undefined;
        const reporter_str = if (reporter_selections.len == 0) "none" else if (reporter_selections.len == 1) reporterKindToName(reporter_selections[0].kind) else blk: {
            var n: usize = 0;
            for (reporter_selections) |sel| {
                if (n > 0) {
                    reporter_name_buf[n] = ',';
                    n += 1;
                }
                const name = reporterKindToName(sel.kind);
                @memcpy(reporter_name_buf[n..][0..name.len], name);
                n += name.len;
            }
            break :blk reporter_name_buf[0..n];
        };
        const meta: ReportMeta = .{
            .tool = "shu:test",
            .shu_version = version.VERSION,
            .reporter = reporter_str,
            .command = command_buf.items,
            .cwd = cwd_owned,
            .platform = @tagName(builtin.os.tag),
            .arch = @tagName(builtin.cpu.arch),
            .ci = std.c.getenv("CI") != null,
            .started_at_ms = start_ms,
            .ended_at_ms = ended_ms,
            .total_elapsed_ms = elapsed_ms,
            .jobs = jobs,
            .permissions = permissions.*,
            .options = options.*,
        };
        if (want_detail_report) {
            for (reporter_selections) |sel| {
                switch (sel.kind) {
                    .junit => try writeJunitTestReport(allocator, io, sel.outfile orelse "report.xml", total, elapsed_ms, case_passed, case_failed, case_skipped, all_details.items, &meta),
                    .json => try writeJsonTestReport(allocator, io, sel.outfile orelse "report.json", total, elapsed_ms, case_passed, case_failed, case_skipped, all_details.items, &meta),
                    .html => try writeHtmlTestReport(allocator, io, sel.outfile orelse "report.html", total, elapsed_ms, case_passed, case_failed, case_skipped, all_details.items, &meta),
                    .markdown => try writeMarkdownTestReport(allocator, io, sel.outfile orelse "report.md", total, elapsed_ms, case_passed, case_failed, case_skipped, all_details.items, &meta),
                    .none => {},
                }
            }
        }
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
        .reporter_selections = reporter_selections,
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
    const ended_ms = start_ms + @as(i64, @intCast(elapsed_ms));
    var reporter_name_buf_par: [64]u8 = undefined;
    const reporter_str_par = if (reporter_selections.len == 0) "none" else if (reporter_selections.len == 1) reporterKindToName(reporter_selections[0].kind) else blk: {
        var n: usize = 0;
        for (reporter_selections) |sel| {
            if (n > 0) {
                reporter_name_buf_par[n] = ',';
                n += 1;
            }
            const name = reporterKindToName(sel.kind);
            @memcpy(reporter_name_buf_par[n..][0..name.len], name);
            n += name.len;
        }
        break :blk reporter_name_buf_par[0..n];
    };
    const meta: ReportMeta = .{
        .tool = "shu:test",
        .shu_version = version.VERSION,
        .reporter = reporter_str_par,
        .command = command_buf.items,
        .cwd = cwd_owned,
        .platform = @tagName(builtin.os.tag),
        .arch = @tagName(builtin.cpu.arch),
        .ci = std.c.getenv("CI") != null,
        .started_at_ms = start_ms,
        .ended_at_ms = ended_ms,
        .total_elapsed_ms = elapsed_ms,
        .jobs = jobs,
        .permissions = permissions.*,
        .options = options.*,
    };
    if (want_detail_report) {
        // 并行模式下每个 worker 使用 .shu-test-details{idx}，主线程统一汇总。
        for (0..total) |idx| {
            var details_name_buf: [32]u8 = undefined;
            const details_name = std.fmt.bufPrint(&details_name_buf, ".shu-test-details{d}", .{idx}) catch continue;
            const details_path = libs_io.pathJoin(allocator, &.{ cwd_owned, details_name }) catch continue;
            defer allocator.free(details_path);
            readCaseDetailsFileAndAppend(allocator, io, details_path, &all_details);
        }
        for (reporter_selections) |sel| {
            switch (sel.kind) {
                .junit => try writeJunitTestReport(allocator, io, sel.outfile orelse "report.xml", total, elapsed_ms, case_passed, case_failed, case_skipped, all_details.items, &meta),
                .json => try writeJsonTestReport(allocator, io, sel.outfile orelse "report.json", total, elapsed_ms, case_passed, case_failed, case_skipped, all_details.items, &meta),
                .html => try writeHtmlTestReport(allocator, io, sel.outfile orelse "report.html", total, elapsed_ms, case_passed, case_failed, case_skipped, all_details.items, &meta),
                .markdown => try writeMarkdownTestReport(allocator, io, sel.outfile orelse "report.md", total, elapsed_ms, case_passed, case_failed, case_skipped, all_details.items, &meta),
                .none => {},
            }
        }
    }
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
            c_green,  passed,  c_reset,
            c_red,    failed,  c_reset,
            c_yellow, skipped, c_reset,
        });
        try printToStdout(io, "{s}{d}{s} test files, {s}{d}{s}ms total.\n\n", .{
            c_cyan, total_files, c_reset,
            c_cyan, total_ms,    c_reset,
        });
    } else {
        try printToStdout(io, "\nTest cases: {d} passed, {d} failed, {d} skipped.\n", .{ passed, failed, skipped });
        try printToStdout(io, "{d} test files, {d}ms total.\n\n", .{ total_files, total_ms });
    }
}
