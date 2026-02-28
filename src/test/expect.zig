// 断言实现（equal、ok、throws 等）
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1

const std = @import("std");

/// 断言相等（占位，供 jest_api 或 runner 调用）
pub fn equal(actual: anytype, expected: @TypeOf(actual)) bool {
    _ = actual;
    _ = expected;
    return true;
}

/// 断言为真（占位）
pub fn ok(cond: bool) bool {
    return cond;
}
