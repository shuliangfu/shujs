// shu:fs、shu:path、shu:assert、shu:events 等内置模块：供 require/import 解析到 shu:xxx 时返回
// 统一由各 shu/<name>/mod.zig 的 getExports 提供；全部使用 Zig 实现，无内嵌 JS 脚本。
//
// ========== 与 Node 兼容情况（各模块 API 逐项） ==========
//
// 【已完整实现】以下模块 API 与 node:xxx 对齐，可直接 require/import 使用：
//   fs、path、system、zlib、crypto、assert、events、util、querystring、url、string_decoder、
//   os、process、timers、console、threads、buffer、stream、server、http、https、net、tls、dgram、dns、
//   readline、vm、async_hooks、async_context、perf_hooks、module、diagnostics_channel
//
// 【API 兼容详情】
//
// | 模块            | 接口名 | 状态     | 说明 |
// |-----------------|--------|----------|------|
// | shu:diagnostics_channel | channel、subscribe、unsubscribe、hasSubscribers、Channel#subscribe/unsubscribe/publish/hasSubscribers | ✅ 已实现 | 纯 Zig |
// | shu:report      | getReport、writeReport | ✅ 已实现 | 文本报告、写文件/stdout |
// | shu:inspector   | open、close、url | ✅ 已实现 | open/close 无操作，url 返回 '' |
// | shu:tty         | isTTY、ReadStream、WriteStream | ✅ 已实现 | isTTY(fd) 用 isatty；Stream 对象含 read/write/resume/pause/setRawMode 占位 |
// | shu:permissions | has、request | ✅ 已实现 | 基于 RunOptions.permissions |
// | shu:intl        | getIntl、Segmenter | ✅ 已实现 | 透传 globalThis.Intl |
// | shu:cluster     | isPrimary、isMaster、isWorker、workers、settings、setupPrimary、disconnect | ✅ 已实现 | 单进程：isPrimary true，workers {}，fork 占位 |
// | shu:cluster     | fork   | ⚠ 占位   | 抛 not implemented |
// | shu:debugger    | port、host | ✅ 已实现 | port=0，host='' |
// | shu:tracing     | createTracing、trace | ✅ 已实现 | no-op；trace(fn) 会执行 fn |
// | shu:webcrypto   | getRandomValues、randomUUID | ✅ 已实现 | 透传 globalThis.crypto |
// | shu:webcrypto   | subtle | ⚠ 占位   | 未实现 |
// | shu:webstreams  | ReadableStream、WritableStream、TransformStream、*Controller、*QueuingStrategy | ✅ 透传 | 来自 globalThis，缺则 undefined |
// | shu:repl        | start、ReplServer | ⚠ 占位   | 抛 not implemented |
// | shu:test        | describe、it、test、before/after、mock、run、snapshot、skip、todo、only | ⚠ 占位 | 抛 not implemented |
// | shu:wasi        | WASI   | ⚠ 占位   | 抛 not implemented |
//
// v8、punycode、domain 不在此列表；node 兼容侧 node:v8 / node:punycode / node:domain 直接走 shu_stub（见 modules/node/builtin.zig）。

const std = @import("std");
const jsc = @import("jsc");
const shu_fs = @import("fs/mod.zig");
const shu_path = @import("path/mod.zig");
const shu_system = @import("system/mod.zig");
const shu_zlib = @import("zlib/mod.zig");
const shu_crypto = @import("crypto/mod.zig");
const shu_assert = @import("assert/mod.zig");
const shu_events = @import("events/mod.zig");
const shu_util = @import("util/mod.zig");
const shu_querystring = @import("querystring/mod.zig");
const shu_url = @import("url/mod.zig");
const shu_string_decoder = @import("string_decoder/mod.zig");
const shu_os = @import("os/mod.zig");
const shu_process = @import("process/mod.zig");
const shu_timers = @import("timers/mod.zig");
const shu_console = @import("console/mod.zig");
const shu_threads = @import("threads/mod.zig");
const shu_buffer = @import("buffer/mod.zig");
const shu_stream = @import("stream/mod.zig");
const shu_server = @import("server/mod.zig");
const shu_http = @import("http/mod.zig");
const shu_https = @import("https/mod.zig");
const shu_net = @import("net/mod.zig");
const shu_tls = @import("tls/mod.zig");
const shu_dgram = @import("dgram/mod.zig");
const shu_dns = @import("dns/mod.zig");
const shu_readline = @import("readline/mod.zig");
const shu_vm = @import("vm/mod.zig");
const shu_async_hooks = @import("async/async_hooks.zig");
const shu_async_context = @import("async/async_context.zig");
const shu_perf_hooks = @import("perf_hooks/mod.zig");
const shu_module = @import("module/mod.zig");
const shu_diagnostics_channel = @import("diagnostics_channel/mod.zig");
const shu_repl = @import("repl/mod.zig");
const shu_test = @import("test/mod.zig");
const shu_inspector = @import("inspector/mod.zig");
const shu_wasi = @import("wasi/mod.zig");
const shu_report = @import("report/mod.zig");
const shu_tracing = @import("tracing/mod.zig");
const shu_tty = @import("tty/mod.zig");
const shu_permissions = @import("permissions/mod.zig");
const shu_intl = @import("intl/mod.zig");
const shu_webcrypto = @import("webcrypto/mod.zig");
const shu_webstreams = @import("webstreams/mod.zig");
const shu_cluster = @import("cluster/mod.zig");
const shu_debugger = @import("debugger/mod.zig");

/// 支持的 shu: 说明符列表（与 BUILTINS.md 一致）。此处“支持”表示 require/import 可解析到本 builtin，不报错；部分为占位（见下方注释）。v8/punycode/domain 由 node 兼容侧直接走 shu_stub。
pub const SUPPORTED: []const []const u8 = &.{
    "shu:fs",
    "shu:path",
    "shu:process",
    "shu:timers",
    "shu:console",
    "shu:system",
    "shu:zlib",
    "shu:crypto",
    "shu:assert",
    "shu:os",
    "shu:events",
    "shu:util",
    "shu:querystring",
    "shu:url",
    "shu:string_decoder",
    "shu:threads",
    "shu:buffer",
    "shu:stream",
    "shu:http",
    "shu:https",
    "shu:net",
    "shu:tls",
    "shu:dgram",
    "shu:dns",
    "shu:readline",
    "shu:vm",
    "shu:async_hooks",
    "shu:async_context",
    "shu:perf_hooks",
    "shu:module",
    "shu:repl",
    "shu:test",
    "shu:inspector",
    "shu:wasi",
    "shu:diagnostics_channel",
    "shu:report",
    "shu:tracing",
    "shu:tty",
    "shu:permissions",
    "shu:intl",
    "shu:webcrypto",
    "shu:webstreams",
    "shu:cluster",
    "shu:debugger",
};

/// 判断是否为已支持的 shu: 内置说明符（用于 require/import 分支）
pub fn isSupportedShuBuiltin(specifier: []const u8) bool {
    for (SUPPORTED) |s| {
        if (std.mem.eql(u8, specifier, s)) return true;
    }
    return false;
}

/// 返回 shu:xxx 的 exports：各模块 getExports(ctx, allocator)；调用方负责 JSValueProtect 若需长期缓存
pub fn getShuBuiltin(ctx: jsc.JSContextRef, allocator: std.mem.Allocator, specifier: []const u8) jsc.JSValueRef {
    // --- 已实现模块（对应 Node 内置，可直接使用）---

    // shu:fs — 文件系统。读写文件、目录操作、流式 read/write、exists、stat、mkdir 等。对应 node:fs/deno:fs，用于脚本里读配置、写日志、遍历目录等。
    if (std.mem.eql(u8, specifier, "shu:fs")) return shu_fs.getExports(ctx, allocator);
    // shu:path — 路径处理。join、resolve、dirname、basename、extname、normalize 等，跨平台路径拼接与解析。对应 node:path。
    if (std.mem.eql(u8, specifier, "shu:path")) return shu_path.getExports(ctx, allocator);
    // shu:system — 子进程与系统命令。spawn、exec、run 等执行外部程序、管道、获取输出。对应 node:child_process。
    if (std.mem.eql(u8, specifier, "shu:system")) return shu_system.getExports(ctx, allocator);
    // shu:zlib — 压缩/解压。gzip、deflate、brotli 等，用于 HTTP 响应压缩或文件压缩。对应 node:zlib。
    if (std.mem.eql(u8, specifier, "shu:zlib")) return shu_zlib.getExports(ctx, allocator);
    // shu:crypto — 加密与哈希。randomBytes、createHash、createHmac、scrypt、pbkdf2 等，用于密码、签名、随机数。对应 node:crypto。
    if (std.mem.eql(u8, specifier, "shu:crypto")) return shu_crypto.getExports(ctx, allocator);
    // shu:assert — 断言。ok、equal、strictEqual、throws 等，测试中做条件检查。对应 node:assert。
    if (std.mem.eql(u8, specifier, "shu:assert")) return shu_assert.getExports(ctx, allocator);
    // shu:events — 事件与发布订阅。EventEmitter、on/emit/once，自定义事件流。对应 node:events。
    if (std.mem.eql(u8, specifier, "shu:events")) return shu_events.getExports(ctx, allocator);
    // shu:util — 工具函数。inspect、format、deprecate、types 等，调试与格式化。对应 node:util。
    if (std.mem.eql(u8, specifier, "shu:util")) return shu_util.getExports(ctx, allocator);
    // shu:querystring — URL 查询字符串。parse、stringify，解析 ?key=value&... 或序列化对象。对应 node:querystring。
    if (std.mem.eql(u8, specifier, "shu:querystring")) return shu_querystring.getExports(ctx, allocator);
    // shu:url — URL 解析与构造。URL 类、pathname、search、host 等，处理完整 URL。对应 node:url。
    if (std.mem.eql(u8, specifier, "shu:url")) return shu_url.getExports(ctx, allocator);
    // shu:string_decoder — 字节到字符串解码。按 UTF-8 等编码把 Buffer 转字符串，避免乱码。对应 node:string_decoder。
    if (std.mem.eql(u8, specifier, "shu:string_decoder")) return shu_string_decoder.getExports(ctx, allocator);
    // shu:os — 操作系统信息。platform、hostname、cpus、freemem、totalmem、tmpdir 等。对应 node:os。
    if (std.mem.eql(u8, specifier, "shu:os")) return shu_os.getExports(ctx, allocator);
    // shu:process — 当前进程。env、cwd、argv、exit、stdin/stdout/stderr、version 等。对应 node:process。
    if (std.mem.eql(u8, specifier, "shu:process")) return shu_process.getExports(ctx, allocator);
    // shu:timers — 定时器。setTimeout、setInterval、setImmediate、clearTimeout 等。对应 node:timers。
    if (std.mem.eql(u8, specifier, "shu:timers")) return shu_timers.getExports(ctx, allocator);
    // shu:console — 控制台。log、error、warn、dir、time/timeEnd、trace 等。对应 node:console。
    if (std.mem.eql(u8, specifier, "shu:console")) return shu_console.getExports(ctx, allocator);
    // shu:threads — 工作线程。Worker、isMainThread、parentPort、workerData 等，多线程并行。对应 node:worker_threads。
    if (std.mem.eql(u8, specifier, "shu:threads")) return shu_threads.getExports(ctx, allocator);
    // shu:buffer — 二进制缓冲区。Buffer.alloc/from/concat/isBuffer、读写字节。对应 node:buffer。
    if (std.mem.eql(u8, specifier, "shu:buffer")) return shu_buffer.getExports(ctx, allocator);
    // shu:stream — 流抽象。Readable、Writable、Transform、Duplex、pipeline、finished，处理大文件或网络数据。对应 node:stream。
    if (std.mem.eql(u8, specifier, "shu:stream")) return shu_stream.getExports(ctx, allocator);
    // shu:server — HTTP/HTTPS 服务端底层。Shu.server(options) 的同一实现，require 得到 { server, default }，供 shu:http/https 内部使用。
    if (std.mem.eql(u8, specifier, "shu:server")) return shu_server.getExports(ctx, allocator);
    // shu:http — HTTP 服务与客户端。createServer、listen(port)、request 等，建 HTTP 服务或发 HTTP 请求。对应 node:http。
    if (std.mem.eql(u8, specifier, "shu:http")) return shu_http.getExports(ctx, allocator);
    // shu:https — HTTPS 服务与客户端。createServer(options)、listen，options 含 key/cert 等 TLS 配置。对应 node:https。
    if (std.mem.eql(u8, specifier, "shu:https")) return shu_https.getExports(ctx, allocator);
    // shu:net — TCP/Unix Socket。createServer(connectionListener)、listen、createConnection，底层网络。对应 node:net。
    if (std.mem.eql(u8, specifier, "shu:net")) return shu_net.getExports(ctx, allocator);
    // shu:tls — TLS/SSL 封装。createSecureContext、createServer(options)，在 TCP 上加密。对应 node:tls。
    if (std.mem.eql(u8, specifier, "shu:tls")) return shu_tls.getExports(ctx, allocator);
    // shu:dgram — UDP 数据报。createSocket、bind、send、on('message')，UDP 收发。对应 node:dgram。
    if (std.mem.eql(u8, specifier, "shu:dgram")) return shu_dgram.getExports(ctx, allocator);
    // shu:dns — DNS 解析。lookup、resolve/resolve4/resolve6、reverse、setServers，域名↔IP、反向解析。对应 node:dns。
    if (std.mem.eql(u8, specifier, "shu:dns")) return shu_dns.getExports(ctx, allocator);
    // shu:readline — 逐行读取与交互。createInterface、question、on('line'/'close')、clearLine、cursorTo，CLI 输入与 TTY 控制。对应 node:readline。
    if (std.mem.eql(u8, specifier, "shu:readline")) return shu_readline.getExports(ctx, allocator);

    // shu:vm — 沙箱执行 JS。createContext、runInContext、runInNewContext、runInThisContext、isContext、Script。对应 node:vm。
    if (std.mem.eql(u8, specifier, "shu:vm")) return shu_vm.getExports(ctx, allocator);
    // shu:async_hooks — 异步资源钩子，纯 Zig 实现，对应 node:async_hooks。
    if (std.mem.eql(u8, specifier, "shu:async_hooks")) return shu_async_hooks.getExports(ctx, allocator);
    // shu:async_context — AsyncLocalStorage，对应 node:async_context。
    if (std.mem.eql(u8, specifier, "shu:async_context")) return shu_async_context.getExports(ctx, allocator);
    // shu:perf_hooks — 性能测量（高精度时间、mark/measure、PerformanceObserver、timerify 等），纯 Zig 实现，对应 node:perf_hooks。
    if (std.mem.eql(u8, specifier, "shu:perf_hooks")) return shu_perf_hooks.getExports(ctx, allocator);
    // shu:module — 模块加载 API。builtinModules、createRequire、isBuiltin，对应 node:module。
    if (std.mem.eql(u8, specifier, "shu:module")) return shu_module.getExports(ctx, allocator);

    // shu:diagnostics_channel — 命名通道 pub/sub，与 node:diagnostics_channel API 一致，纯 Zig 实现。
    if (std.mem.eql(u8, specifier, "shu:diagnostics_channel")) return shu_diagnostics_channel.getExports(ctx, allocator);
    // shu:repl — 交互式 REPL；API 兼容占位（start、ReplServer），调用抛 Not implemented。
    if (std.mem.eql(u8, specifier, "shu:repl")) return shu_repl.getExports(ctx, allocator);
    // shu:test — 内置测试运行器；API 兼容占位（describe/it/mock/run 等）。
    if (std.mem.eql(u8, specifier, "shu:test")) return shu_test.getExports(ctx, allocator);
    // shu:inspector — 调试器协议；API 兼容占位（open/close/url）。
    if (std.mem.eql(u8, specifier, "shu:inspector")) return shu_inspector.getExports(ctx, allocator);
    // shu:wasi — WASI；API 兼容占位（WASI 类）。
    if (std.mem.eql(u8, specifier, "shu:wasi")) return shu_wasi.getExports(ctx, allocator);
    // shu:report — 进程报告；API 兼容占位（writeReport/getReport）。
    if (std.mem.eql(u8, specifier, "shu:report")) return shu_report.getExports(ctx, allocator);
    // shu:tracing — 追踪；API 兼容占位。
    if (std.mem.eql(u8, specifier, "shu:tracing")) return shu_tracing.getExports(ctx, allocator);
    // shu:tty — TTY；API 兼容占位（isTTY、ReadStream、WriteStream）。
    if (std.mem.eql(u8, specifier, "shu:tty")) return shu_tty.getExports(ctx, allocator);
    // shu:permissions — 权限策略；API 兼容占位（has/request）。
    if (std.mem.eql(u8, specifier, "shu:permissions")) return shu_permissions.getExports(ctx, allocator);
    // shu:intl — 国际化；API 兼容占位（getIntl、Segmenter）。
    if (std.mem.eql(u8, specifier, "shu:intl")) return shu_intl.getExports(ctx, allocator);
    // shu:webcrypto — Web Crypto；API 兼容占位（getRandomValues、randomUUID、subtle）。
    if (std.mem.eql(u8, specifier, "shu:webcrypto")) return shu_webcrypto.getExports(ctx, allocator);
    // shu:webstreams — Web Streams；API 兼容占位（ReadableStream/WritableStream/TransformStream 等）。
    if (std.mem.eql(u8, specifier, "shu:webstreams")) return shu_webstreams.getExports(ctx, allocator);
    // shu:cluster — 集群多进程；API 兼容占位（fork、isMaster、isWorker 等）。
    if (std.mem.eql(u8, specifier, "shu:cluster")) return shu_cluster.getExports(ctx, allocator);
    // shu:debugger — 调试器入口；API 兼容占位（port、host）。
    if (std.mem.eql(u8, specifier, "shu:debugger")) return shu_debugger.getExports(ctx, allocator);

    return jsc.JSValueMakeUndefined(ctx);
}
