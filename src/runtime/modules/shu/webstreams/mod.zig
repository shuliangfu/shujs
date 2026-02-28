// shu:webstreams — 与 Web Streams API 兼容，透传 globalThis 上的流类
//
// ========== API 兼容情况 ==========
//
// | API                          | 兼容     | 说明 |
// |------------------------------|----------|------|
// | ReadableStream               | ✅ 透传  | 来自 globalThis.ReadableStream（若存在） |
// | WritableStream               | ✅ 透传  | 来自 globalThis.WritableStream |
// | TransformStream              | ✅ 透传  | 来自 globalThis.TransformStream |
// | ReadableByteStreamController | ✅ 透传  | 来自 globalThis（若存在，否则 undefined） |
// | WritableStreamDefaultController | ✅ 透传 | 同上 |
// | TransformStreamDefaultController | ✅ 透传 | 同上 |
// | ByteLengthQueuingStrategy    | ✅ 透传  | 同上 |
// | CountQueuingStrategy         | ✅ 透传  | 同上 |
//

const std = @import("std");
const jsc = @import("jsc");

fn getGlobalProp(ctx: jsc.JSContextRef, name: [*]const u8) jsc.JSValueRef {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k = jsc.JSStringCreateWithUTF8CString(name);
    defer jsc.JSStringRelease(k);
    return jsc.JSObjectGetProperty(ctx, global, k, null);
}

fn setExport(ctx: jsc.JSContextRef, exports: jsc.JSObjectRef, name: [*]const u8) void {
    const k = jsc.JSStringCreateWithUTF8CString(name);
    defer jsc.JSStringRelease(k);
    const val = getGlobalProp(ctx, name);
    _ = jsc.JSObjectSetProperty(ctx, exports, k, val, jsc.kJSPropertyAttributeNone, null);
}

pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    _ = allocator;
    const exports = jsc.JSObjectMake(ctx, null, null);
    setExport(ctx, exports, "ReadableStream");
    setExport(ctx, exports, "WritableStream");
    setExport(ctx, exports, "TransformStream");
    setExport(ctx, exports, "ReadableByteStreamController");
    setExport(ctx, exports, "WritableStreamDefaultController");
    setExport(ctx, exports, "TransformStreamDefaultController");
    setExport(ctx, exports, "ByteLengthQueuingStrategy");
    setExport(ctx, exports, "CountQueuingStrategy");
    return exports;
}
