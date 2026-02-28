// JS ↔ Zig 绑定：统一入口，向 JSC 全局注册所有内置 API
// 参考：engine/BUILTINS.md、SHU_RUNTIME_ANALYSIS.md 6.1
// engine.zig 在创建上下文后只调用本模块的 registerGlobals，不再直接调用各 engine/*.register

const std = @import("std");
const jsc = @import("jsc");
const run_options = @import("../run_options.zig");

const engine_shu = @import("../engine/shu/mod.zig");
const engine_stubs = @import("../engine/stubs.zig");
const engine_bun_impl = @import("../engine/bun/mod.zig");

const shu_console = @import("../modules/shu/console/mod.zig");
const shu_timers = @import("../modules/shu/timers/mod.zig");
const shu_encoding = @import("../modules/shu/encoding/mod.zig");
const shu_text_encoding = @import("../modules/shu/text_encoding/mod.zig");
const shu_url = @import("../modules/shu/url/mod.zig");
const shu_performance = @import("../modules/shu/performance/mod.zig");
const shu_abort_controller = @import("../modules/shu/abort/mod.zig");
const shu_crypto = @import("../modules/shu/crypto/mod.zig");
const shu_process = @import("../modules/shu/process/mod.zig");
const shu_fetch = @import("../modules/shu/fetch/mod.zig");
const shu_websocket_client = @import("../modules/shu/websocket_client/mod.zig");

/// 向 JS 全局注册所有内置 API（console、timers、encoding、crypto、stubs 等；有 options 时再注册 process、Shu、fetch、Bun.file/Bun.write）
/// 由 engine.zig 在 JSC 上下文创建后调用，顺序与条件与 BUILTINS.md 一致
pub fn registerGlobals(
    ctx: jsc.JSGlobalContextRef,
    allocator: std.mem.Allocator,
    options: ?*const run_options.RunOptions,
) void {
    // 始终注册：控制台、定时器、编码、TextEncoder/TextDecoder、URL、performance、AbortController、crypto、占位（Buffer/require/WebSocket/Bun）；统一传 allocator（§1.1）
    shu_console.register(ctx, allocator);
    shu_timers.register(ctx, allocator);
    shu_encoding.register(ctx, allocator);
    shu_text_encoding.register(ctx, allocator);
    shu_url.register(ctx, allocator);
    shu_performance.register(ctx, allocator);
    shu_abort_controller.register(ctx, allocator);
    shu_crypto.register(ctx, allocator);
    engine_stubs.register(ctx, allocator);

    if (options) |opts| {
        shu_process.register(allocator, ctx, opts);
        engine_shu.register(ctx, allocator);
        shu_fetch.register(ctx, allocator);
        engine_bun_impl.register(ctx, allocator, opts);
        // WebSocket 客户端：覆盖 stubs 中的占位，需 --allow-net
        shu_websocket_client.register(ctx, allocator, opts);
    }
}
