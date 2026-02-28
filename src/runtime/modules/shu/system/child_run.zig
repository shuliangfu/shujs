// Shu.system 公共：使用 std.process.Child.run 执行子进程并收集 stdout/stderr
// 供 exec.zig、run.zig、spawn.zig 复用

const std = @import("std");

/// 执行子进程后的结果（stdout/stderr 由 Child.run 分配，调用方需 free）
pub const RunOutput = struct {
    stdout: []const u8,
    stderr: []const u8,
    /// 退出码：正常退出为 0..=255；被信号终止等用 255 表示
    code: u8,
};

/// 使用给定 argv、可选 cwd 执行子进程，收集 stdout/stderr，返回 RunOutput
/// 返回的 stdout/stderr 由 allocator 分配，调用方需 free
pub fn runProcess(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
) !RunOutput {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = 256 * 1024,
    });
    const code: u8 = switch (result.term) {
        .Exited => |c| c,
        else => 255,
    };
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .code = code,
    };
}
