// 执行上下文、全局对象（console、定时器等）
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1

const std = @import("std");
const engine = @import("engine.zig");
const run_options = @import("run_options.zig");

/// VM 占位：持有引擎与全局对象，供执行脚本时使用
pub const VM = struct {
    allocator: std.mem.Allocator,
    eng: engine.Engine,

    /// 创建 VM；options 可为 null（仅 console），非 null 时注入 process / __dirname / __filename
    pub fn init(allocator: std.mem.Allocator, options: ?*const run_options.RunOptions) !VM {
        return .{
            .allocator = allocator,
            .eng = try engine.Engine.init(allocator, options),
        };
    }

    /// 释放引擎占用的资源（JSC 上下文、定时器队列等）
    pub fn deinit(self: *VM) void {
        self.eng.deinit();
    }

    /// 执行一段 JS 源码；macOS 下由 JSC 执行并已注入 console.log（及可选的 process 等）
    /// 若 entry_path 非 null：.mjs/.mts 走 ESM（import/export），否则走 CJS（require）；无路径则直接 evaluate
    pub fn run(self: *VM, source: []const u8, entry_path: ?[]const u8) !void {
        if (entry_path) |path| {
            if (isEsmEntry(path))
                try self.eng.runAsEsmModule(path, source)
            else
                try self.eng.runAsModule(path, source);
        } else {
            try self.eng.evaluate(source);
        }
    }
};

/// 根据入口路径判断是否按 ESM 执行（.mjs / .mts）
fn isEsmEntry(path: []const u8) bool {
    if (path.len >= 4 and std.mem.eql(u8, path[path.len - 4 ..], ".mjs")) return true;
    if (path.len >= 4 and std.mem.eql(u8, path[path.len - 4 ..], ".mts")) return true;
    return false;
}
