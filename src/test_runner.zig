// 单元测试入口：根在 src/，以便 tests/*.zig 里可直接 @import("../../transpiler/xxx.zig")
// 运行：zig build test（与 test-server 一起执行）
const _ = @import("tests/main.zig");

test "test harness: suites loaded" {}
