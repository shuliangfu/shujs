// 单元测试入口：按目录组织，拉取各子目录的 test 块
// 运行：zig build test（与 test-server 一起执行）
// 目录约定：src/tests/transpiler/*.zig 测 transpiler，src/tests/runtime/*.zig 测 runtime/modules/shu，src/tests/libs 测 libs

const strip_types_tests = @import("transpiler/strip_types.zig");
const jsx_tests = @import("transpiler/jsx.zig");
const http2_tests = @import("runtime/modules/shu/server/http2.zig");
const websocket_tests = @import("runtime/modules/shu/server/websocket.zig");
const path_tests = @import("runtime/modules/shu/path.zig");
const fs_tests = @import("runtime/modules/shu/fs.zig");
const hpack_huffman_tests = @import("runtime/modules/shu/server/hpack_huffman_tests.zig");
const server_integration_tests = @import("runtime/modules/shu/server/server_integration.zig");
const package_tests = @import("package.zig");
const querystring_tests = @import("runtime/modules/shu/querystring.zig");
const url_tests = @import("runtime/modules/shu/url.zig");
// libs/simd_scan.zig 自带 test 块，拉入即跑
// libs/simd_scan 通过 libs_io 暴露，在 tests/libs/simd_scan.zig 中测
const simd_scan_tests = @import("libs/simd_scan.zig");

test "test harness: suites loaded" {
    _ = strip_types_tests;
    _ = jsx_tests;
    _ = http2_tests;
    _ = websocket_tests;
    _ = path_tests;
    _ = fs_tests;
    _ = hpack_huffman_tests;
    _ = server_integration_tests;
    _ = package_tests;
    _ = querystring_tests;
    _ = url_tests;
    _ = simd_scan_tests;
}
