// 完整 TS 转译（类型擦除 + 可选类型检查）
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1
// 当前实现：复用 strip_types 做类型擦除；check_types 为 true 时暂不执行类型检查，仅做擦除。

const std = @import("std");
const strip_types = @import("strip_types.zig");

/// 将 TypeScript 源码转译为 JavaScript（类型擦除）。
/// 可选类型检查（check_types == true）当前未实现，仅做擦除，后续可接入独立类型检查器。
///
/// - allocator: 用于分配返回的 JS 源码缓冲区。
/// - source: 原始 TS/TSX 源码。
/// - check_types: 为 true 时预留类型检查扩展点，当前与 false 行为一致（仅擦除）。
/// - 返回: 擦除类型后的 JS 源码切片；由调用方使用同一 allocator 负责 free。
pub fn transpile(allocator: std.mem.Allocator, source: []const u8, check_types: bool) ![]const u8 {
    _ = check_types; // 类型检查占位，后续可在此处调用类型检查器并在失败时返回错误
    return strip_types.strip(allocator, source);
}
