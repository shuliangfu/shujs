// shu 占位模块：对尚未实现的 node: 对应能力返回空对象，便于 node:xxx 统一走 getShuBuiltin
// 如 shu:buffer、shu:stream、shu:http 等，require 不报错，运行时按需实现

const std = @import("std");
const jsc = @import("jsc");

/// 返回占位模块的 exports（空对象，可选带 __stub 标记）；shortName 仅用于将来扩展
pub fn getExports(ctx: jsc.JSContextRef, _: std.mem.Allocator, shortName: []const u8) jsc.JSValueRef {
    _ = shortName;
    const obj = jsc.JSObjectMake(ctx, null, null);
    const k = jsc.JSStringCreateWithUTF8CString("__stub");
    defer jsc.JSStringRelease(k);
    _ = jsc.JSObjectSetProperty(ctx, obj, k, jsc.JSValueMakeBoolean(ctx, true), jsc.kJSPropertyAttributeNone, null);
    return obj;
}
