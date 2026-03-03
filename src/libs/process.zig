//! 进程级状态：std.Io 与 std.process.Environ，由 main 启动时设置。
//! 供 CLI、io_core、runtime（无 Io/Environ 参数的调用）使用。

const std = @import("std");

var process_io: ?std.Io = null;
var process_environ: ?std.process.Environ = null;

/// 设置进程级 io（main 入口处调用 setProcessIo(init.io)）
pub fn setProcessIo(io: std.Io) void {
    process_io = io;
}

/// 返回进程级 io；未设置时返回 null。
pub fn getProcessIo() ?std.Io {
    return process_io;
}

/// 设置进程级 environ（main 入口处调用 setProcessEnviron(init.minimal.environ)）
pub fn setProcessEnviron(environ: std.process.Environ) void {
    process_environ = environ;
}

/// 返回进程级 environ；未设置时返回 null。
pub fn getProcessEnviron() ?std.process.Environ {
    return process_environ;
}
