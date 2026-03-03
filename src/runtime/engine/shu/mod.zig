// 全局 Shu 聚合注册：Shu.fs、Shu.path、Shu.system、Shu.crond/crondClear、Shu.thread 等均来自 modules/shu
// §1.1 显式 allocator：传入时注入 system/crond，供子模块回调使用

const std = @import("std");
const jsc = @import("jsc");
const shu_fs = @import("../../modules/shu/fs/mod.zig");
const shu_path = @import("../../modules/shu/path/mod.zig");
const shu_system = @import("../../modules/shu/system/mod.zig");
const shu_zlib = @import("../../modules/shu/zlib/mod.zig");
const shu_archive = @import("../../modules/shu/archive/mod.zig");
const shu_crypto = @import("../../modules/shu/crypto/mod.zig");
const shu_server = @import("../../modules/shu/server/mod.zig");
const shu_threads = @import("../../modules/shu/threads/mod.zig");
const shu_crond = @import("../../modules/shu/crond/mod.zig");

/// 向全局对象注册 Shu：各子模块由 modules/shu 下 file/path/system/zlib/crypto/server/threads/crond 提供
/// allocator 可选；传入时注入 system、crond，§1.1 显式 allocator 收敛
pub fn register(ctx: jsc.JSGlobalContextRef, allocator: ?std.mem.Allocator) void {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const name_shu = jsc.JSStringCreateWithUTF8CString("Shu");
    defer jsc.JSStringRelease(name_shu);
    const shu_obj = jsc.JSObjectMake(ctx, null, null);
    shu_fs.register(ctx, shu_obj);
    shu_path.register(ctx, shu_obj);
    shu_system.register(ctx, shu_obj, allocator);
    shu_zlib.register(ctx, shu_obj);
    shu_archive.register(ctx, shu_obj);
    shu_crypto.attachToShu(ctx, shu_obj);
    shu_server.register(ctx, shu_obj);
    shu_threads.register(ctx, shu_obj);
    shu_crond.register(ctx, shu_obj, allocator);
    _ = jsc.JSObjectSetProperty(ctx, global, name_shu, shu_obj, jsc.kJSPropertyAttributeNone, null);
}
