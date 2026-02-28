// shu:wasi — 与 node:wasi API 兼容占位，纯 Zig 实现
//
// ========== API 兼容情况 ==========
//
// | API   | 兼容   | 说明 |
// |-------|--------|------|
// | WASI  | ⚠ 占位 | 类/构造函数，调用时抛 "shu:wasi not implemented"；可后续对接 WASI 运行时 |
//

const std = @import("std");
const jsc = @import("jsc");
const node_compat = @import("../node_compat/mod.zig");

const METHOD_NAMES = [_][]const u8{ "WASI" };

pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    return node_compat.buildStubExports(ctx, allocator, "wasi", &METHOD_NAMES);
}
