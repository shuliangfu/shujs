// shu:intl — 与 node:intl API 兼容，透传全局 Intl，纯 Zig 实现
//
// ========== API 兼容情况 ==========
//
// | API | 兼容 | 说明 |
// |-----|------|------|
// | getIntl() | ✅ 已实现 | 返回 globalThis.Intl（宿主提供的 Intl 对象） |
// | Segmenter | ✅ 已实现 | 返回 globalThis.Intl.Segmenter（若存在），否则 undefined |
//

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");

/// getIntl()：返回 globalThis.Intl
fn getIntlCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k = jsc.JSStringCreateWithUTF8CString("Intl");
    defer jsc.JSStringRelease(k);
    return jsc.JSObjectGetProperty(ctx, global, k, null);
}

/// 取 globalThis.Intl.Segmenter（类引用），若不存在则为 undefined
fn getIntlSegmenter(ctx: jsc.JSContextRef) jsc.JSValueRef {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_intl = jsc.JSStringCreateWithUTF8CString("Intl");
    defer jsc.JSStringRelease(k_intl);
    const intl_val = jsc.JSObjectGetProperty(ctx, global, k_intl, null);
    if (jsc.JSValueIsUndefined(ctx, intl_val)) return intl_val;
    const intl_obj = jsc.JSValueToObject(ctx, intl_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const k_seg = jsc.JSStringCreateWithUTF8CString("Segmenter");
    defer jsc.JSStringRelease(k_seg);
    return jsc.JSObjectGetProperty(ctx, intl_obj, k_seg, null);
}

pub fn getExports(ctx: jsc.JSContextRef, _: std.mem.Allocator) jsc.JSValueRef {
    const exports = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, exports, "getIntl", getIntlCallback);
    const k_seg = jsc.JSStringCreateWithUTF8CString("Segmenter");
    defer jsc.JSStringRelease(k_seg);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_seg, getIntlSegmenter(ctx), jsc.kJSPropertyAttributeNone, null);
    return exports;
}
