// bun:xxx 内置模块说明与兼容规划（与 compat/bun、Bun 全局 API 配合）
//
// ========== Bun 模块体系说明 ==========
//
// Bun 通过全局 Bun 对象提供大部分能力（Bun.serve、Bun.file、Bun.spawn 等），内置说明符 bun:xxx 仅用于少数
// 原生模块。本文件列出所有 bun: 说明符及 Bun 全局 API 分类，便于与 node: / shu: 对照；当前为占位，未实现解析。
//
// ========== bun: 内置说明符（Bun 官方） ==========
//
// | bun: 说明符   | 说明 |
// |---------------|------|
// | bun:ffi       | 外部函数接口，调用 C/C++ 动态库 |
// | bun:sqlite    | SQLite 绑定，Database/Statement 等 |
// | bun:test      | 内置测试框架，describe/test/expect |
// | bun:jsc       | JavaScriptCore 底层 API（Bun 基于 JSC） |
//
// ========== Bun 全局 API 分类（非 bun: 说明符，列全便于对照） ==========
//
// | 分类           | API |
// |----------------|-----|
// | HTTP 服务      | Bun.serve |
// | Shell          | $ (shell) |
// | 打包           | Bun.build |
// | 文件 I/O       | Bun.file, Bun.write, Bun.stdin, Bun.stdout, Bun.stderr |
// | 子进程         | Bun.spawn, Bun.spawnSync |
// | TCP            | Bun.listen, Bun.connect |
// | UDP            | Bun.udpSocket |
// | WebSocket      | new WebSocket (client), Bun.serve (server) |
// | 转译           | Bun.Transpiler |
// | 路由           | Bun.FileSystemRouter |
// | HTML 流        | HTMLRewriter |
// | 哈希/密码      | Bun.password, Bun.hash, Bun.CryptoHasher, Bun.sha |
// | SQL            | Bun.SQL, Bun.sql（PostgreSQL/MySQL/SQLite） |
// | Redis          | Bun.RedisClient, Bun.redis |
// | DNS            | Bun.dns.lookup, Bun.dns.prefetch, Bun.dns.getCacheStats |
// | Worker         | new Worker() |
// | 插件           | Bun.plugin |
// | Glob           | Bun.Glob |
// | Cookie         | Bun.Cookie, Bun.CookieMap |
// | 工具           | Bun.version, Bun.revision, Bun.env, Bun.main |
// | 睡眠/计时      | Bun.sleep, Bun.sleepSync, Bun.nanoseconds |
// | 随机           | Bun.randomUUIDv7 |
// | 系统           | Bun.which |
// | 比较/检查      | Bun.peek, Bun.deepEquals, Bun.deepMatch, Bun.inspect |
// | 字符串         | Bun.escapeHTML, Bun.stringWidth, Bun.indexOfLine |
// | URL/路径       | Bun.fileURLToPath, Bun.pathToFileURL |
// | 压缩           | Bun.gzipSync, Bun.gunzipSync, Bun.deflateSync, Bun.inflateSync, Bun.zstd* |
// | 流             | Bun.readableStreamTo*, Bun.readableStreamToBytes/Blob/FormData/JSON/Array |
// | 内存/缓冲     | Bun.ArrayBufferSink, Bun.allocUnsafe, Bun.concatArrayBuffers |
// | 模块解析      | Bun.resolveSync |
// | 解析/格式化   | Bun.semver, Bun.TOML.parse, Bun.markdown, Bun.color |
// | 底层/内部     | Bun.mmap, Bun.gc, Bun.generateHeapSnapshot, bun:jsc |
//
// 当前状态：bun: 协议在 require/import 解析中被识别为内置协议，不落盘解析；具体 bun:xxx 到 shu:xxx 或
// Bun 全局的映射与实现见 compat/bun 与后续规划。Node 内置见 modules/node/builtin.zig，shu 内置见 modules/shu/builtin.zig。

const std = @import("std");
const jsc = @import("jsc");

/// 当前支持的 bun: 内置说明符列表（占位，空或按需扩展）；与 getBunBuiltin / isSupportedBunBuiltin 一致
pub const BUN_BUILTIN_NAMES: []const []const u8 = &.{};

/// 返回 bun:xxx 的 exports；当前未实现，统一返回 undefined
pub fn getBunBuiltin(ctx: jsc.JSContextRef, allocator: std.mem.Allocator, specifier: []const u8) jsc.JSValueRef {
    _ = ctx;
    _ = allocator;
    _ = specifier;
    return jsc.JSValueMakeUndefined(ctx);
}

/// 判断是否为已支持的 bun: 内置说明符；当前无支持项
pub fn isSupportedBunBuiltin(specifier: []const u8) bool {
    for (BUN_BUILTIN_NAMES) |name| {
        if (std.mem.eql(u8, specifier, name)) return true;
    }
    return false;
}
