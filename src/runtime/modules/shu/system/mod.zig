// Shu.system 聚合：exec/execSync、run/runSync、spawn/spawnSync、fork；子模块按类分文件
// 供 shu:system 内置与引擎挂载：getExports 返回系统 API 对象，引擎通过 getShuBuiltin("shu:system") 挂到 Shu.system

const std = @import("std");
const jsc = @import("jsc");
const exec = @import("exec.zig");
const run = @import("run.zig");
const spawn = @import("spawn.zig");
const fork = @import("fork.zig");
const system_allocator = @import("allocator.zig");

/// 返回 shu:system 的 exports（exec、execSync、run、runSync、spawn、spawnSync、fork）；引擎与 require('shu:system') 共用
/// §1.1 显式 allocator：注入 system_allocator，供 spawn/run/exec/fork 回调使用
pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    system_allocator.set(allocator);
    const system_obj = jsc.JSObjectMake(ctx, null, null);
    exec.register(ctx, system_obj);
    run.register(ctx, system_obj);
    spawn.register(ctx, system_obj);
    fork.register(ctx, system_obj);
    return system_obj;
}

/// 向 shu_obj 上注册 Shu.system 子对象（已废弃：引擎应通过 getShuBuiltin(ctx, allocator, "shu:system") 挂载）
/// allocator 传入时注入 system_allocator（§1.1）
pub fn register(ctx: jsc.JSGlobalContextRef, shu_obj: jsc.JSObjectRef, allocator: ?std.mem.Allocator) void {
    if (allocator) |a| system_allocator.set(a);
    const name_system = jsc.JSStringCreateWithUTF8CString("system");
    defer jsc.JSStringRelease(name_system);
    const a = allocator orelse @import("../../../globals.zig").current_allocator orelse return;
    const system_val = getExports(ctx, a);
    _ = jsc.JSObjectSetProperty(ctx, shu_obj, name_system, system_val, jsc.kJSPropertyAttributeNone, null);
}
