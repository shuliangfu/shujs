// §1.1 显式 allocator 收敛：system 子模块（spawn/run/exec/fork_child）共用
// mod.zig 在 getExports/register 时注入，子模块回调优先使用，未注入时回退 current_allocator

const std = @import("std");
const globals = @import("../../../globals.zig");

threadlocal var g_system_allocator: ?std.mem.Allocator = null;

/// 由 system/mod.zig 的 getExports 或 register 调用，注入显式 allocator
pub fn set(allocator: std.mem.Allocator) void {
    g_system_allocator = allocator;
}

/// 子模块回调内使用：优先返回注入的 allocator，否则 current_allocator
pub fn get() ?std.mem.Allocator {
    return g_system_allocator orelse globals.current_allocator;
}
