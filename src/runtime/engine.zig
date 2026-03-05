// JSC 封装与生命周期（创建/销毁 VM、上下文）
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1、engine/BUILTINS.md 跨平台方案
// macOS 使用系统 JavaScriptCore；Linux/Windows 可通过 -Djsc_prefix 链接 WebKit JSC
// 各全局 API 注册拆到 runtime/engine/ 下独立文件：console、process、shu、fetch、timers
//
// === 内置函数与全局 API 总清单（全部在此登记，详见 engine/BUILTINS.md）===
// 【已实现并注册】
//   全局: console.log, console.warn, console.error, console.info, console.debug
//   全局: setTimeout(cb, ms), setInterval(cb, ms), clearTimeout(id), clearInterval(id), setImmediate(cb), clearImmediate(id), queueMicrotask(fn)
//   全局: fetch(url)           [需 --allow-net]
//   全局: atob(str) / btoa(str) [Base64，encoding.zig]
//   全局: crypto 由 modules/shu/crypto 实现，bindings 调 shu_crypto.register；Shu.crypto 由 engine/shu/mod.zig 中 attachToShu 挂载
//   全局: process (cwd, argv, env), __dirname, __filename  [process.env 需 --allow-env]
//   Shu:  Shu.fs.read(path) / Shu.fs.readSync(path)、Shu.path.join() 等 [需 --allow-read / --allow-write]
// 【占位注册】engine/stubs.zig：调用时抛 "Not implemented"
//   全局: Buffer, require(id), WebSocket
//   Bun:  Bun.serve, Bun.file, Bun.write
// 【计划中 / 未注册】
//   Node: module, exports；node:fs, node:path, node:http
//   Shu:  shu:env, shu:fs 等协议；Deno: deno: 协议、Import Map；SQLite 等（P2）

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const run_options_mod = @import("run_options.zig");

/// 当前构建是否具备 JSC（macOS 系统 JSC 或 Linux/Windows 下已链接的 WebKit JSC）
const have_jsc = builtin.os.tag == .macos or build_options.have_webkit_jsc;
const engine_globals = @import("globals.zig");
const timer_state = @import("modules/shu/timers/state.zig");
const bindings = @import("bindings/mod.zig");
const require_mod = @import("modules/shu/require/mod.zig");
const libs_io = @import("libs_io");
const esm_loader = @import("modules/shu/esm_loader/mod.zig");
// 拉入 libs_io 参与构建（高性能 I/O 工具层，供 server 等后续接入）
const _ = libs_io;

/// 引擎句柄；在具备 JSC 的平台下持有 group 与 global context
pub const Engine = struct {
    allocator: std.mem.Allocator,
    group: ?*anyopaque = null,
    ctx: ?*anyopaque = null,
    run_options: ?*const run_options_mod.RunOptions = null,
    timer_state: timer_state.TimerState = undefined,

    /// 创建引擎；options 非 null 时注册 process、Shu、fetch 等；仅当 have_jsc 时初始化 JSC
    pub fn init(allocator: std.mem.Allocator, options: ?*const run_options_mod.RunOptions) !Engine {
        var self = Engine{
            .allocator = allocator,
            .run_options = options,
            .timer_state = try timer_state.TimerState.init(allocator),
        };
        if (have_jsc) {
            const jsc = @import("jsc");
            self.group = jsc.JSContextGroupCreate();
            self.ctx = jsc.JSGlobalContextCreateInGroup(@ptrCast(self.group), null);
            const ctx_ref: jsc.JSGlobalContextRef = @ptrCast(self.ctx.?);
            bindings.registerGlobals(ctx_ref, allocator, options);
        }
        return self;
    }

    /// 释放 JSC 上下文与定时器状态
    pub fn deinit(self: *Engine) void {
        if (have_jsc and self.ctx != null) {
            const jsc = @import("jsc");
            jsc.JSGlobalContextRelease(@ptrCast(self.ctx));
            jsc.JSContextGroupRelease(@ptrCast(self.group));
            self.ctx = null;
            self.group = null;
        }
        self.timer_state.deinit();
    }

    /// 执行一段 JS 源码；执行前设置线程局部状态，脚本结束后运行定时器事件循环；无 JSC 时直接 return
    pub fn evaluate(self: *Engine, source: []const u8) !void {
        if (!have_jsc or self.ctx == null) return;
        engine_globals.current_run_options = self.run_options;
        engine_globals.current_allocator = self.allocator;
        engine_globals.current_timer_state = &self.timer_state;
        defer {
            engine_globals.current_run_options = null;
            engine_globals.current_allocator = null;
            engine_globals.current_timer_state = null;
        }
        const jsc = @import("jsc");
        const script_z = try self.allocator.dupeZ(u8, source);
        defer self.allocator.free(script_z);
        const script_ref = jsc.JSStringCreateWithUTF8CString(script_z.ptr);
        defer jsc.JSStringRelease(script_ref);
        _ = jsc.JSEvaluateScript(@ptrCast(self.ctx), script_ref, null, null, 1, null);
        if (engine_globals.drain_async_file_io) |drain| drain(@ptrCast(self.ctx.?));
        if (engine_globals.drain_fs_watch) |drain| drain(@ptrCast(self.ctx.?));
        self.timer_state.runMicrotasks(@ptrCast(self.ctx.?));
        self.timer_state.runLoop(@ptrCast(self.ctx.?));
    }

    /// 以 CJS 模块方式执行入口：注入 module、exports、require、__filename、__dirname 后执行；需 --allow-read
    pub fn runAsModule(self: *Engine, entry_path: []const u8, source: []const u8) !void {
        if (!have_jsc or self.ctx == null) return;
        engine_globals.current_run_options = self.run_options;
        engine_globals.current_allocator = self.allocator;
        engine_globals.current_timer_state = &self.timer_state;
        defer {
            engine_globals.current_run_options = null;
            engine_globals.current_allocator = null;
            engine_globals.current_timer_state = null;
        }
        require_mod.runAsModule(@ptrCast(self.ctx.?), self.allocator, entry_path, source);
        self.timer_state.runMicrotasks(@ptrCast(self.ctx.?));
        self.timer_state.runLoop(@ptrCast(self.ctx.?));
    }

    /// 以 ESM 方式执行入口：解析 import/export、按依赖顺序执行；入口为 .mjs/.mts 时由此调用，需 --allow-read
    pub fn runAsEsmModule(self: *Engine, entry_path: []const u8, source: []const u8) !void {
        if (!have_jsc or self.ctx == null) return;
        engine_globals.current_run_options = self.run_options;
        engine_globals.current_allocator = self.allocator;
        engine_globals.current_timer_state = &self.timer_state;
        defer {
            engine_globals.current_run_options = null;
            engine_globals.current_allocator = null;
            engine_globals.current_timer_state = null;
        }
        esm_loader.runAsEsmModule(@ptrCast(self.ctx.?), self.allocator, entry_path, source);
        if (engine_globals.drain_async_file_io) |drain| drain(@ptrCast(self.ctx.?));
        if (engine_globals.drain_fs_watch) |drain| drain(@ptrCast(self.ctx.?));
        self.timer_state.runMicrotasks(@ptrCast(self.ctx.?));
        self.timer_state.runLoop(@ptrCast(self.ctx.?));
    }
};
