// shu:repl — 与 node:repl API 兼容占位，纯 Zig 实现
//
// ========== API 兼容情况 ==========
//
// | API        | 兼容   | 说明 |
// |------------|--------|------|
// | start()    | ⚠ 占位 | 调用时抛 "shu:repl not implemented"；可后续实现交互式 REPL |
// | ReplServer | ⚠ 占位 | 同上，仅占位避免 require 报错 |
//

const std = @import("std");
const jsc = @import("jsc");
const node_compat = @import("../node_compat/mod.zig");

const METHOD_NAMES = [_][]const u8{ "start", "ReplServer" };

pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    return node_compat.buildStubExports(ctx, allocator, "repl", &METHOD_NAMES);
}
