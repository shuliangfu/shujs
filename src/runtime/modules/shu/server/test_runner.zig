// Server 模块单元测试入口：拉取 websocket.zig 与 http2.zig 的 test 块，由 zig build test-server 运行
// 不依赖 JSC、不启动真实 listen，仅测协议解析与帧逻辑

const ws = @import("websocket.zig");
const h2 = @import("http2.zig");

test "server modules: websocket and http2 import" {
    _ = ws;
    _ = h2;
}
