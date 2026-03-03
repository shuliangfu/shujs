//! shu:archive 归档模块：tar / zip 打包与解包
//! 供 require("shu:archive")、package 等使用；路径须为绝对路径，pack 返回的 slice 调用方 free。

const std = @import("std");
const jsc = @import("jsc");
const globals = @import("../../../globals.zig");
const tar_mod = @import("tar.zig");
const zip_mod = @import("zip.zig");

pub const packTarFromDir = tar_mod.packTarFromDir;
pub const extractTarToDir = tar_mod.extractTarToDir;
pub const packZipFromDir = zip_mod.packZipFromDir;
pub const extractZipToDir = zip_mod.extractZipToDir;

/// 返回 Shu.archive 的 exports 对象（供 shu:archive 内置与引擎挂载）
pub fn getExports(ctx: jsc.JSContextRef, _: std.mem.Allocator) jsc.JSValueRef {
    return jsc.JSObjectMake(ctx, null, null);
}

/// 向 shu_obj 上注册 Shu.archive 子对象
pub fn register(ctx: jsc.JSGlobalContextRef, shu_obj: jsc.JSObjectRef) void {
    const allocator = globals.current_allocator orelse return;
    const name_archive = jsc.JSStringCreateWithUTF8CString("archive");
    defer jsc.JSStringRelease(name_archive);
    _ = jsc.JSObjectSetProperty(ctx, shu_obj, name_archive, getExports(ctx, allocator), jsc.kJSPropertyAttributeNone, null);
}
