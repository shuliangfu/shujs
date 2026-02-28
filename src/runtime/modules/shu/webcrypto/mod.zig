// shu:webcrypto — 与 Web Crypto API / node:crypto 兼容，透传 globalThis.crypto
//
// ========== API 兼容情况 ==========
//
// | API             | 兼容     | 说明 |
// |-----------------|----------|------|
// | getRandomValues | ✅ 已实现 | 透传 globalThis.crypto.getRandomValues（shu:crypto 已实现） |
// | randomUUID      | ✅ 已实现 | 透传 globalThis.crypto.randomUUID |
// | subtle           | ⚠ 占位   | 当前为 undefined；后续可对接 shu:crypto 或 JSC 的 SubtleCrypto |
//

const std = @import("std");
const jsc = @import("jsc");

/// 返回与 globalThis.crypto 同一引用，保证 getRandomValues、randomUUID 可用；subtle 未实现则为 undefined
pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    _ = allocator;
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k = jsc.JSStringCreateWithUTF8CString("crypto");
    defer jsc.JSStringRelease(k);
    const crypto = jsc.JSObjectGetProperty(ctx, global, k, null);
    if (jsc.JSValueIsUndefined(ctx, crypto) or jsc.JSValueIsNull(ctx, crypto)) {
        return jsc.JSValueMakeUndefined(ctx);
    }
    return crypto;
}
