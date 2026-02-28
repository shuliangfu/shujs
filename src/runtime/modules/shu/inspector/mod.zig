// shu:inspector — 与 node:inspector API 兼容，纯 Zig 实现
//
// ========== API 兼容情况 ==========
//
// | API | 兼容 | 说明 |
// |-----|------|------|
// | open([port]) | ✅ 已实现 | 无操作（本运行时无 V8/DevTools 协议），不抛错 |
// | close() | ✅ 已实现 | 无操作 |
// | url() | ✅ 已实现 | 返回空字符串（无 inspector 时） |
//

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");

fn openCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    return jsc.JSValueMakeUndefined(ctx);
}

fn closeCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    return jsc.JSValueMakeUndefined(ctx);
}

fn urlCallback(ctx: jsc.JSContextRef, _: jsc.JSObjectRef, _: jsc.JSObjectRef, _: usize, _: [*]const jsc.JSValueRef, _: [*]jsc.JSValueRef) callconv(.c) jsc.JSValueRef {
    const empty = jsc.JSStringCreateWithUTF8CString("");
    defer jsc.JSStringRelease(empty);
    return jsc.JSValueMakeString(ctx, empty);
}

pub fn getExports(ctx: jsc.JSContextRef, _: std.mem.Allocator) jsc.JSValueRef {
    const exports = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, exports, "open", openCallback);
    common.setMethod(ctx, exports, "close", closeCallback);
    common.setMethod(ctx, exports, "url", urlCallback);
    return exports;
}
