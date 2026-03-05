// 运行时执行期线程局部状态，供 C 回调（Shu.fs.read、fetch、setTimeout 等）读取
// 由 engine.zig 在 evaluate() 入口设置、出口清空；放在 runtime/ 便于 engine 与 modules 共用

const std = @import("std");
const jsc = @import("jsc");
const run_options_mod = @import("run_options.zig");
const timer_state = @import("modules/shu/timers/state.zig");
const libs_io = @import("libs_io");

/// 当前执行的 RunOptions（权限、cwd 等）
pub threadlocal var current_run_options: ?*const run_options_mod.RunOptions = null;
/// 当前分配的 Allocator
pub threadlocal var current_allocator: ?std.mem.Allocator = null;
/// 当前定时器状态，供 setTimeout/setInterval 入队
pub threadlocal var current_timer_state: ?*timer_state.TimerState = null;

/// 异步文件 I/O 实例：由 fs 模块在首次 Shu.fs.read/Shu.fs.write（异步）时按需创建，供 submitReadFile/submitWriteFile 与 drain 使用
pub threadlocal var current_async_file_io: ?*libs_io.AsyncFileIO = null;
/// 每轮事件循环需调用的 drain：收割 AsyncFileIO 完成项并 resolve/reject 对应 Promise；由 fs 在创建 AsyncFileIO 时注册
pub threadlocal var drain_async_file_io: ?*const fn (jsc.JSContextRef) void = null;
/// 每轮事件循环需调用的 drain：收割 fetch worker 完成项并 resolve/reject 对应 Promise；由 fetch 模块在 register 时注册
pub threadlocal var drain_fetch_results: ?*const fn (jsc.JSContextRef) void = null;
/// 每轮事件循环需调用的 drain：处理 cmd 异步完成项（当前未使用，预留）
pub threadlocal var drain_cmd_results: ?*const fn (jsc.JSContextRef) void = null;
