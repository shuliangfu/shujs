// deno:xxx 内置模块说明与兼容规划（与 compat/deno 配合）
//
// ========== Deno 模块体系说明 ==========
//
// Deno 官方标准库以 JSR @std 形式发布（如 @std/fs、@std/path），使用 jsr:@std/xxx 或 npm 安装，
// 而非 deno: 前缀。Deno 运行时支持 node: 说明符与 Node 内置兼容。
// 本文件列出「若支持 deno: 协议」时可规划的 deno: 说明符与 @std / Node 对应关系；当前为占位，未实现解析。
//
// ========== 可规划的 deno: 说明符（与 @std / node: 对应） ==========
//
// | deno: 说明符   | 对应 @std / Node       | 说明 |
// |----------------|------------------------|------|
// | deno:assert    | @std/assert            | 断言，类似 node:assert |
// | deno:async     | @std/async             | delay、debounce、pool 等异步工具 |
// | deno:bytes     | @std/bytes             | Uint8Array 操作 |
// | deno:encoding  | @std/encoding           | hex、base64、varint 等编解码 |
// | deno:fs        | @std/fs                | 文件系统，与 node:fs / shu:fs 语义接近 |
// | deno:path      | @std/path              | 路径处理，与 node:path / shu:path 接近 |
// | deno:crypto    | @std/crypto + Web Crypto | 加密扩展 |
// | deno:fmt       | @std/fmt               | 格式化、颜色、duration、printf |
// | deno:http      | @std/http              | HTTP 服务端工具 |
// | deno:io        | @std/io                | Reader/Writer 等 I/O 抽象 |
// | deno:json      | @std/json              | 流式 JSON 解析 |
// | deno:log       | @std/log               | 可配置日志 |
// | deno:net       | @std/net               | 网络工具 |
// | deno:node      | Node 兼容层            | 暴露 node: 模块的 Deno 封装 |
// | deno:permissions| 运行时权限 API         | 查询/请求权限 |
// | deno:streams   | @std/streams           | Web Streams 工具 |
// | deno:testing   | @std/testing           | 测试、快照、时间 mock |
// | deno:timers    | 全局 setTimeout 等     | 与 node:timers 接近 |
// | deno:url       | URL / URLSearchParams  | 与 node:url / 标准 URL 接近 |
// | deno:web        | 标准 Web API           | 标准 Web 能力 |
// | deno:worker    | Worker 全局            | 与 Web Worker 一致 |
// | deno:dotenv     | @std/dotenv            | .env 解析 |
// | deno:html       | @std/html              | HTML 转义等 |
// | deno:csv        | @std/csv               | CSV 读写 |
// | deno:yaml       | @std/yaml              | YAML 解析 |
// | deno:toml       | @std/toml              | TOML 解析 |
// | deno:uuid       | @std/uuid              | UUID 生成与校验 |
// | deno:semver     | @std/semver            | 语义化版本 |
// | deno:collections| @std/collections       | 集合工具 |
// | deno:cli        | @std/cli               | 交互式 CLI 工具 |
// | deno:media-types| @std/media-types      | MIME 类型工具 |
// | deno:front-matter | @std/front-matter   | Front matter 解析 |
// | deno:expect     | @std/expect            | Jest 风格 expect |
//
// 当前状态：deno: 协议在 require/import 解析中被识别为内置协议，不落盘解析；具体 deno:xxx 到 shu:xxx 或 @std 的
// 映射与实现见 compat/deno 与后续 P2 规划。完整 Node 内置见 modules/node/builtin.zig。

const std = @import("std");
const jsc = @import("jsc");

/// 当前支持的 deno: 内置说明符列表（占位，空或按需扩展）；与 getDenoBuiltin / isSupportedDenoBuiltin 一致
pub const DENO_BUILTIN_NAMES: []const []const u8 = &.{};

/// 返回 deno:xxx 的 exports；当前未实现，统一返回 undefined
pub fn getDenoBuiltin(ctx: jsc.JSContextRef, allocator: std.mem.Allocator, specifier: []const u8) jsc.JSValueRef {
    _ = ctx;
    _ = allocator;
    _ = specifier;
    return jsc.JSValueMakeUndefined(ctx);
}

/// 判断是否为已支持的 deno: 内置说明符；当前无支持项
pub fn isSupportedDenoBuiltin(specifier: []const u8) bool {
    for (DENO_BUILTIN_NAMES) |name| {
        if (std.mem.eql(u8, specifier, name)) return true;
    }
    return false;
}
