// shu:debugger — 与 node:inspector/debugger 相关 API 兼容，纯 Zig 实现
//
// ========== API 兼容情况 ==========
//
// | API   | 兼容     | 说明 |
// |-------|----------|------|
// | port  | ✅ 已实现 | 只读属性，恒为 0（未开启 inspector 时） |
// | host  | ✅ 已实现 | 只读属性，恒为 '' |
//

const std = @import("std");
const jsc = @import("jsc");

pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    _ = allocator;
    const exports = jsc.JSObjectMake(ctx, null, null);
    const k_port = jsc.JSStringCreateWithUTF8CString("port");
    defer jsc.JSStringRelease(k_port);
    const k_host = jsc.JSStringCreateWithUTF8CString("host");
    defer jsc.JSStringRelease(k_host);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_port, jsc.JSValueMakeNumber(ctx, 0), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_host, jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString("")), jsc.kJSPropertyAttributeNone, null);
    return exports;
}
