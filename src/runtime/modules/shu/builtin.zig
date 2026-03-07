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
// | shu:webcrypto   | subtle | ✅ 由 shu:crypto 挂载 | digest 已实现，其余占位 |
// | shu:webstreams  | ReadableStream、WritableStream、TransformStream、*Controller、*QueuingStrategy | ✅ 透传 | 来自 globalThis，缺则 undefined |
// | shu:repl        | start、ReplServer、REPL_MODE_* | ✅ 已实现 | readline + vm.runInContext |
// | shu:test        | describe、it、test、before/after、mock、run、snapshot、skip、todo、only | ✅ 已实现 | 与 node:test 语义接近 |
// | shu:wasi        | WASI、getImportObject、start | ✅ 已实现 | start() 暂抛 not implemented（待 WASM 运行时） |
//
// v8、punycode、domain 不在此列表；node 兼容侧 node:v8 / node:punycode / node:domain 直接走 shu_stub（见 modules/node/builtin.zig）。

const std = @import("std");
const jsc = @import("jsc");
const shu_fs = @import("fs/mod.zig");
const shu_path = @import("path/mod.zig");
const shu_cmd = @import("cmd/mod.zig");
const shu_zlib = @import("zlib/mod.zig");
const shu_archive = @import("archive/mod.zig");
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
const shu_http2 = @import("http2/mod.zig");
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
const shu_errors = @import("errors/mod.zig");
const shu_corepack = @import("corepack/mod.zig");
const shu_sql = @import("sql/mod.zig");
const shu_mongo = @import("mongo/mod.zig");
const shu_kv = @import("kv/mod.zig");

/// 取 specifier 前 8 字节转 u64（不足零填充），用于与 comptime 常量整型比较（00 §2.1）
fn specPrefix(specifier: []const u8) u64 {
    var buf: [8]u8 = [_]u8{0} ** 8;
    const n = @min(8, specifier.len);
    @memcpy(buf[0..n], specifier[0..n]);
    return @as(u64, @bitCast(buf));
}
/// comptime 字符串前 8 字节转 u64
fn prefix8(comptime s: []const u8) u64 {
    var buf: [8]u8 = [_]u8{0} ** 8;
    const n = @min(8, s.len);
    for (s[0..n], buf[0..n]) |a, *b| b.* = a;
    return @as(u64, @bitCast(buf));
}

/// 内置模块标签，用于 getShuBuiltin 的 (len,prefix) 表 + switch 分派（00 §2.1）
const ShuBuiltinTag = enum {
    fs,
    path,
    cmd,
    zlib,
    archive,
    crypto,
    assert,
    events,
    util,
    querystring,
    url,
    string_decoder,
    os,
    process,
    timers,
    console,
    threads,
    buffer,
    stream,
    server,
    http,
    https,
    http2,
    net,
    tls,
    dgram,
    dns,
    readline,
    vm,
    async_hooks,
    async_context,
    perf_hooks,
    module,
    diagnostics_channel,
    repl,
    test_runner,
    inspector,
    wasi,
    report,
    tracing,
    tty,
    permissions,
    intl,
    webcrypto,
    webstreams,
    cluster,
    debugger,
    errors,
    corepack,
    sqlite,
    sql,
    mongo,
    kv,
};

/// (len, u64 前缀) -> tag 表，comptime 生成；运行时一次整型比较匹配（00 §2.1）
const SPEC_TABLE = blk: {
    const Entry = struct { len: usize, prefix: u64, tag: ShuBuiltinTag };
    var list: [53]Entry = undefined;
    const specs = .{
        .{ "shu:fs", .fs },
        .{ "shu:path", .path },
        .{ "shu:cmd", .cmd },
        .{ "shu:zlib", .zlib },
        .{ "shu:archive", .archive },
        .{ "shu:crypto", .crypto },
        .{ "shu:assert", .assert },
        .{ "shu:events", .events },
        .{ "shu:util", .util },
        .{ "shu:querystring", .querystring },
        .{ "shu:url", .url },
        .{ "shu:string_decoder", .string_decoder },
        .{ "shu:os", .os },
        .{ "shu:process", .process },
        .{ "shu:timers", .timers },
        .{ "shu:console", .console },
        .{ "shu:threads", .threads },
        .{ "shu:buffer", .buffer },
        .{ "shu:stream", .stream },
        .{ "shu:server", .server },
        .{ "shu:http", .http },
        .{ "shu:https", .https },
        .{ "shu:http2", .http2 },
        .{ "shu:net", .net },
        .{ "shu:tls", .tls },
        .{ "shu:dgram", .dgram },
        .{ "shu:dns", .dns },
        .{ "shu:readline", .readline },
        .{ "shu:vm", .vm },
        .{ "shu:async_hooks", .async_hooks },
        .{ "shu:async_context", .async_context },
        .{ "shu:perf_hooks", .perf_hooks },
        .{ "shu:module", .module },
        .{ "shu:diagnostics_channel", .diagnostics_channel },
        .{ "shu:repl", .repl },
        .{ "shu:test", .test_runner },
        .{ "shu:inspector", .inspector },
        .{ "shu:wasi", .wasi },
        .{ "shu:report", .report },
        .{ "shu:tracing", .tracing },
        .{ "shu:tty", .tty },
        .{ "shu:permissions", .permissions },
        .{ "shu:intl", .intl },
        .{ "shu:webcrypto", .webcrypto },
        .{ "shu:webstreams", .webstreams },
        .{ "shu:cluster", .cluster },
        .{ "shu:debugger", .debugger },
        .{ "shu:errors", .errors },
        .{ "shu:corepack", .corepack },
        .{ "shu:sqlite", .sqlite },
        .{ "shu:sql", .sql },
        .{ "shu:mongo", .mongo },
        .{ "shu:kv", .kv },
    };
    for (specs, 0..) |s, i| {
        list[i] = .{ .len = s.@"0".len, .prefix = prefix8(s.@"0"), .tag = s.@"1" };
    }
    break :blk list;
};

/// 根据 tag 调用对应模块 getExports（00 §2.1 单 switch 分派）
fn getExportsByTag(tag: ShuBuiltinTag, ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    return switch (tag) {
        .fs => shu_fs.getExports(ctx, allocator),
        .path => shu_path.getExports(ctx, allocator),
        .cmd => shu_cmd.getExports(ctx, allocator),
        .zlib => shu_zlib.getExports(ctx, allocator),
        .archive => shu_archive.getExports(ctx, allocator),
        .crypto => shu_crypto.getExports(ctx, allocator),
        .assert => shu_assert.getExports(ctx, allocator),
        .events => shu_events.getExports(ctx, allocator),
        .util => shu_util.getExports(ctx, allocator),
        .querystring => shu_querystring.getExports(ctx, allocator),
        .url => shu_url.getExports(ctx, allocator),
        .string_decoder => shu_string_decoder.getExports(ctx, allocator),
        .os => shu_os.getExports(ctx, allocator),
        .process => shu_process.getExports(ctx, allocator),
        .timers => shu_timers.getExports(ctx, allocator),
        .console => shu_console.getExports(ctx, allocator),
        .threads => shu_threads.getExports(ctx, allocator),
        .buffer => shu_buffer.getExports(ctx, allocator),
        .stream => shu_stream.getExports(ctx, allocator),
        .server => shu_server.getExports(ctx, allocator),
        .http => shu_http.getExports(ctx, allocator),
        .https => shu_https.getExports(ctx, allocator),
        .http2 => shu_http2.getExports(ctx, allocator),
        .net => shu_net.getExports(ctx, allocator),
        .tls => shu_tls.getExports(ctx, allocator),
        .dgram => shu_dgram.getExports(ctx, allocator),
        .dns => shu_dns.getExports(ctx, allocator),
        .readline => shu_readline.getExports(ctx, allocator),
        .vm => shu_vm.getExports(ctx, allocator),
        .async_hooks => shu_async_hooks.getExports(ctx, allocator),
        .async_context => shu_async_context.getExports(ctx, allocator),
        .perf_hooks => shu_perf_hooks.getExports(ctx, allocator),
        .module => shu_module.getExports(ctx, allocator),
        .diagnostics_channel => shu_diagnostics_channel.getExports(ctx, allocator),
        .repl => shu_repl.getExports(ctx, allocator),
        .test_runner => shu_test.getExports(ctx, allocator),
        .inspector => shu_inspector.getExports(ctx, allocator),
        .wasi => shu_wasi.getExports(ctx, allocator),
        .report => shu_report.getExports(ctx, allocator),
        .tracing => shu_tracing.getExports(ctx, allocator),
        .tty => shu_tty.getExports(ctx, allocator),
        .permissions => shu_permissions.getExports(ctx, allocator),
        .intl => shu_intl.getExports(ctx, allocator),
        .webcrypto => shu_webcrypto.getExports(ctx, allocator),
        .webstreams => shu_webstreams.getExports(ctx, allocator),
        .cluster => shu_cluster.getExports(ctx, allocator),
        .debugger => shu_debugger.getExports(ctx, allocator),
        .errors => shu_errors.getExports(ctx, allocator),
        .corepack => shu_corepack.getExports(ctx, allocator),
        .sqlite => shu_sql.getSqliteExports(ctx, allocator),
        .sql => shu_sql.getExports(ctx, allocator),
        .mongo => shu_mongo.getExports(ctx, allocator),
        .kv => shu_kv.getExports(ctx, allocator),
    };
}

/// 支持的 shu: 说明符列表（与 BUILTINS.md 一致）。此处“支持”表示 require/import 可解析到本 builtin，不报错；部分为占位（见下方注释）。v8/punycode/domain 由 node 兼容侧直接走 shu_stub。
pub const SUPPORTED: []const []const u8 = &.{
    "shu:fs",
    "shu:path",
    "shu:process",
    "shu:timers",
    "shu:console",
    "shu:cmd",
    "shu:zlib",
    "shu:archive",
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
    "shu:http2",
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
    "shu:errors",
    "shu:corepack",
    "shu:sqlite",
    "shu:sql",
    "shu:mongo",
    "shu:kv",
};

/// 判断是否为已支持的 shu: 内置说明符（用于 require/import 分支）；(len, u64) 表匹配（00 §2.1）
pub fn isSupportedShuBuiltin(specifier: []const u8) bool {
    const p = specPrefix(specifier);
    for (SPEC_TABLE) |e| {
        if (specifier.len == e.len and p == e.prefix) return true;
    }
    return false;
}

/// 返回 shu:xxx 的 exports：各模块 getExports(ctx, allocator)；调用方负责 JSValueProtect 若需长期缓存。00 §2.1 (len,u64) 表 + switch 分派。
pub fn getShuBuiltin(ctx: jsc.JSContextRef, allocator: std.mem.Allocator, specifier: []const u8) jsc.JSValueRef {
    const p = specPrefix(specifier);
    for (SPEC_TABLE) |e| {
        if (specifier.len == e.len and p == e.prefix) return getExportsByTag(e.tag, ctx, allocator);
    }
    return jsc.JSValueMakeUndefined(ctx);
}
