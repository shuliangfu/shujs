// shu:webcrypto — 与 Web Crypto API / node:webcrypto 兼容，透传 globalThis.crypto
//
// ========== API 兼容情况 ==========
//
// | API             | 兼容     | 说明 |
// |-----------------|----------|------|
// | getRandomValues | ✅ 已实现 | 透传 globalThis.crypto.getRandomValues（shu:crypto 已实现） |
// | randomUUID      | ✅ 已实现 | 透传 globalThis.crypto.randomUUID |
// | subtle          | ✅ 已实现 | 由 shu:crypto 在 register 时挂到 globalThis.crypto；digest 已实现，sign/verify/encrypt/decrypt 等占位 |
//

const std = @import("std");
const jsc = @import("jsc");

/// 返回与 globalThis.crypto 同一引用，保证 getRandomValues、randomUUID、subtle 可用（subtle 由 shu:crypto 挂载）
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
