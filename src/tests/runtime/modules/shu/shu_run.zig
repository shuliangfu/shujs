//! 测试辅助：运行 zig-out 下的 shu 可执行文件，用于 path/fs 等需完整运行时的测试。
//! 约定：zig build test 前会先 install，故 zig-out/bin/shu 存在；测试进程 cwd 为项目根。

const std = @import("std");
const builtin = @import("builtin");

/// 返回当前平台下 shu 可执行路径（相对项目根：zig-out/bin/shu 或 zig-out\bin\shu.exe）
pub fn shuExePath(allocator: std.mem.Allocator) []const u8 {
    if (builtin.os.tag == .windows) {
        return allocator.dupe(u8, "zig-out\\bin\\shu.exe") catch "zig-out\\bin\\shu.exe";
    }
    return allocator.dupe(u8, "zig-out/bin/shu") catch "zig-out/bin/shu";
}

/// 执行 shu [extra_args...] -e "script"；cwd 为 null 时用 "."（项目根）。返回 stdout 的 trim 结果。
pub fn runShuWithScript(allocator: std.mem.Allocator, script: []const u8, extra_args: []const []const u8) ![]const u8 {
    return runShuWithScriptInDir(allocator, script, extra_args, null);
}

/// 同上，可指定工作目录（用于 fs 测试的临时目录）
pub fn runShuWithScriptInDir(allocator: std.mem.Allocator, script: []const u8, extra_args: []const []const u8, cwd: ?[]const u8) ![]const u8 {
    const exe = try allocator.dupe(u8, if (builtin.os.tag == .windows) "zig-out\\bin\\shu.exe" else "zig-out/bin/shu");
    defer allocator.free(exe);
    var argv = std.ArrayList([]const u8).initCapacity(allocator, 4 + extra_args.len) catch return error.OutOfMemory;
    defer argv.deinit(allocator);
    argv.append(allocator, exe) catch return error.OutOfMemory;
    for (extra_args) |arg| {
        argv.append(allocator, arg) catch return error.OutOfMemory;
    }
    argv.append(allocator, "-e") catch return error.OutOfMemory;
    argv.append(allocator, script) catch return error.OutOfMemory;
    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.cwd = if (cwd) |d| d else ".";
    try child.spawn();
    const stdout = child.stdout.?.reader().readAllAlloc(allocator, 1024 * 1024) catch {
        _ = child.wait() catch {};
        return error.ReadStdout;
    };
    defer allocator.free(stdout);
    _ = child.wait() catch {};
    // 去掉末尾换行
    var end = stdout.len;
    while (end > 0 and (stdout[end - 1] == '\n' or stdout[end - 1] == '\r')) end -= 1;
    return allocator.dupe(u8, stdout[0..end]);
}

/// 后台启动 shu [extra_args...] -e "script"；不等待结束，返回 Child，调用方须在结束后 child.kill() 或 child.wait()
pub fn spawnShuBackground(allocator: std.mem.Allocator, script: []const u8, extra_args: []const []const u8) !std.process.Child {
    const exe = try allocator.dupe(u8, if (builtin.os.tag == .windows) "zig-out\\bin\\shu.exe" else "zig-out/bin/shu");
    defer allocator.free(exe);
    var argv = std.ArrayList([]const u8).initCapacity(allocator, 4 + extra_args.len) catch return error.OutOfMemory;
    defer argv.deinit(allocator);
    argv.append(allocator, exe) catch return error.OutOfMemory;
    for (extra_args) |arg| {
        argv.append(allocator, arg) catch return error.OutOfMemory;
    }
    argv.append(allocator, "-e") catch return error.OutOfMemory;
    argv.append(allocator, script) catch return error.OutOfMemory;
    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.cwd = ".";
    try child.spawn();
    return child;
}
