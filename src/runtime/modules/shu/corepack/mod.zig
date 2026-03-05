// shu:corepack — 与 node:corepack 兼容；Corepack 为 Node 包管理器 CLI 支持，程序化 API 极少，此处提供 no-op 占位
//
// ========== API 兼容情况 ==========
//
// | API     | 兼容 | 说明 |
// |---------|------|------|
// | enable  | ✓    | no-op，返回 undefined |
// | disable | ✓    | no-op，返回 undefined |
// | run     | ✓    | no-op，返回 undefined；CLI 行为由引擎另行处理 |

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");

/// corepack.enable()：占位，无操作
fn enableCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    return jsc.JSValueMakeUndefined(ctx);
}

/// corepack.disable()：占位，无操作
fn disableCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    return jsc.JSValueMakeUndefined(ctx);
}

/// corepack.run()：占位，无操作；CLI 入口由引擎处理
fn runCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    return jsc.JSValueMakeUndefined(ctx);
}

/// 返回 shu:corepack 的 exports：enable、disable、run（均为 no-op）
pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    _ = allocator;
    const exports = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, exports, "enable", enableCallback);
    common.setMethod(ctx, exports, "disable", disableCallback);
    common.setMethod(ctx, exports, "run", runCallback);
    return exports;
}
