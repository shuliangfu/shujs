// node:xxx 内置：统一复用 shu:xxx（node:fs -> shu:fs, node:path -> shu:path 等），参考 engine/BUILTINS.md
//
// ========== node:xxx -> shu:xxx 兼容映射 ==========
//
// 当前支持的 node: 说明符及其对应的 shu: 模块（见下方 NODE_BUILTIN_NAMES / getNodeBuiltin）：
//
// | node: 说明符       | 对应 shu: 模块 | 兼容说明 |
// |--------------------|----------------|----------|
// | node:path          | shu:path       | ✅ 已实现，与 node:path API 对齐 |
// | node:fs            | shu:fs         | ✅ 已实现 |
// | node:fs/promises   | shu:fs         | ✅ 已实现（Promise 形态 API，util.promisify 包装） |
// | node:zlib          | shu:zlib       | ✅ 已实现 |
// | node:assert        | shu:assert     | ✅ 已实现 |
// | node:events        | shu:events     | ✅ 已实现 |
// | node:util          | shu:util       | ✅ 已实现 |
// | node:querystring   | shu:querystring| ✅ 已实现 |
// | node:url           | shu:url        | ✅ 已实现 |
// | node:string_decoder| shu:string_decoder | ✅ 已实现 |
// | node:crypto        | shu:crypto     | ✅ 已实现（getRandomValues、randomUUID、digest 等） |
// | node:os            | shu:os         | ✅ 已实现 |
// | node:process       | shu:process     | ✅ 已实现 |
// | node:timers        | shu:timers     | ✅ 已实现 |
// | node:console       | shu:console    | ✅ 已实现 |
// | node:child_process | shu:system     | ✅ 已实现（Shu.system 同一实现） |
// | node:worker_threads| shu:threads    | ✅ 已实现（Shu.thread 同一实现） |
// | node:buffer        | shu:buffer     | ✅ 已实现 |
// | node:stream        | shu:stream     | ✅ 已实现 |
// | node:http          | shu:http       | ✅ 已实现 |
// | node:https         | shu:https      | ✅ 已实现 |
// | node:net           | shu:net        | ✅ 已实现 |
// | node:tls           | shu:tls        | ✅ 已实现 |
// | node:dgram         | shu:dgram      | ✅ 已实现 |
// | node:dns           | shu:dns        | ✅ 已实现 |
// | node:readline      | shu:readline   | ✅ 已实现 |
// | node:vm            | shu:vm         | ✅ 已实现 |
// | node:async_hooks   | shu:async_hooks    | ✅ 已实现 |
// | node:async_context | shu:async_context | ✅ 已实现（AsyncLocalStorage） |
// | node:perf_hooks    | shu:perf_hooks | ✅ 已实现 |
// | node:module        | shu:module     | ✅ 已实现 |
// | node:diagnostics_channel | shu:diagnostics_channel | ✅ 已实现 |
// | node:report        | shu:report     | ✅ 已实现 |
// | node:inspector     | shu:inspector  | ✅ 已实现（open/close/url 无操作） |
// | node:tracing       | shu:tracing    | ✅ 已实现（no-op） |
// | node:tty           | shu:tty        | ✅ 已实现（isTTY、ReadStream/WriteStream） |
// | node:permissions   | shu:permissions| ✅ 已实现 |
// | node:intl          | shu:intl       | ✅ 已实现（getIntl、Segmenter） |
// | node:webcrypto     | shu:webcrypto  | ✅ 已实现（透传 globalThis.crypto） |
// | node:webstreams    | shu:webstreams | ✅ 已实现（透传 globalThis 流类） |
// | node:cluster       | shu:cluster    | ✅ 已实现（单进程，fork 占位） |
// | node:repl          | shu:repl       | ⚠ 占位（start/ReplServer 抛 not implemented） |
// | node:test          | shu:test       | ✅ 已实现（describe/it/run 等与 node:test 语义接近） |
// | node:wasi          | shu:wasi       | ⚠ 占位（WASI 类抛 not implemented） |
// | node:debugger      | shu:debugger   | ✅ 已实现（port/host） |
// | node:v8            | shu_stub       | ⚠ 占位（JSC 无 V8，直接走 shu_stub） |
// | node:punycode      | shu_stub       | ⚠ 占位（Node 已弃用，直接走 shu_stub） |
// | node:domain        | shu_stub       | ⚠ 占位（Node 已弃用，直接走 shu_stub） |
// | node:errors        | shu:errors     | ✅ 已实现（SystemError、codes 与 node:errors 对齐） |
// | node:corepack      | shu_stub       | ⚠ 占位（实验性包管理，可占位） |
// | node:sqlite        | shu_stub       | ⚠ 占位（Node 22+ SQLite，可占位） |
//
// shu: 侧完整 API 兼容情况见 modules/shu/builtin.zig 顶部。注：node:server 在 Node 中为内部模块，不暴露，故不映射。

const std = @import("std");
const jsc = @import("jsc");
const shu_builtin = @import("../shu/builtin.zig");
const shu_stub = @import("../shu/stub/mod.zig");

/// 当前支持的 node: 内置说明符列表（与 getNodeBuiltin / isSupportedNodeBuiltin 一致）；供 shu:module 的 builtinModules 等动态读取；与 shu:xxx 一一对应兼容
pub const NODE_BUILTIN_NAMES: []const []const u8 = &.{
    "node:path",
    "node:fs",
    "node:fs/promises",
    "node:zlib",
    "node:assert",
    "node:events",
    "node:util",
    "node:querystring",
    "node:url",
    "node:string_decoder",
    "node:crypto",
    "node:os",
    "node:process",
    "node:timers",
    "node:console",
    "node:child_process",
    "node:worker_threads",
    "node:buffer",
    "node:stream",
    "node:http",
    "node:https",
    "node:net",
    "node:tls",
    "node:dgram",
    "node:dns",
    "node:readline",
    "node:vm",
    "node:async_hooks",
    "node:async_context",
    "node:perf_hooks",
    "node:module",
    "node:diagnostics_channel",
    "node:report",
    "node:inspector",
    "node:tracing",
    "node:tty",
    "node:permissions",
    "node:intl",
    "node:webcrypto",
    "node:webstreams",
    "node:cluster",
    "node:repl",
    "node:test",
    "node:wasi",
    "node:debugger",
    "node:v8",
    "node:punycode",
    "node:domain",
    "node:errors",
    "node:corepack",
    "node:sqlite",
    // 裸说明符 require("fs/promises") 与 node:fs/promises 同源
    "fs/promises",
};

/// 返回 node:fs/promises 与 fs/promises 的 exports：基于 shu:fs + shu:util.promisify 生成 Promise 形态 API 对象。[Borrows] 返回值由 JSC 管理，调用方勿 free。
fn getFsPromisesExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    const fs_exports = shu_builtin.getShuBuiltin(ctx, allocator, "shu:fs");
    if (jsc.JSValueIsUndefined(ctx, fs_exports) or jsc.JSValueIsNull(ctx, fs_exports)) return jsc.JSValueMakeUndefined(ctx);
    const util_exports = shu_builtin.getShuBuiltin(ctx, allocator, "shu:util");
    if (jsc.JSValueIsUndefined(ctx, util_exports) or jsc.JSValueIsNull(ctx, util_exports)) return jsc.JSValueMakeUndefined(ctx);
    const k_promisify = jsc.JSStringCreateWithUTF8CString("promisify");
    defer jsc.JSStringRelease(k_promisify);
    const promisify_fn = jsc.JSObjectGetProperty(ctx, util_exports, k_promisify, null);
    if (jsc.JSValueIsUndefined(ctx, promisify_fn) or !jsc.JSObjectIsFunction(ctx, promisify_fn)) return jsc.JSValueMakeUndefined(ctx);
    const promises_obj = jsc.JSObjectMake(ctx, null, null);
    // node:fs/promises 与 Node 对齐的异步方法名（与 shu:fs 上命名一致）
    const method_names = [_][]const u8{
        "readFile", "writeFile", "appendFile",     "copyFile",         "readdir",    "stat", "lstat",    "realpath",
        "mkdir",    "access",    "unlink",         "rmdir",            "rename",     "copy", "truncate", "symlink",
        "readlink", "exists",    "mkdirRecursive", "rmdirRecursive",   "ensureDir",  "read", "write",    "isEmptyDir",
        "size",     "isFile",    "isDirectory",    "readdirWithStats", "ensureFile",
    };
    for (method_names) |name| {
        const name_ref = jsc.JSStringCreateWithUTF8CString(name.ptr);
        defer jsc.JSStringRelease(name_ref);
        const fs_fn = jsc.JSObjectGetProperty(ctx, fs_exports, name_ref, null);
        if (jsc.JSValueIsUndefined(ctx, fs_fn) or !jsc.JSObjectIsFunction(ctx, fs_fn)) continue;
        var args = [_]jsc.JSValueRef{fs_fn};
        const wrapped = jsc.JSObjectCallAsFunction(ctx, promisify_fn, null, 1, &args, null);
        if (jsc.JSValueIsUndefined(ctx, wrapped)) continue;
        _ = jsc.JSObjectSetProperty(ctx, promises_obj, name_ref, wrapped, jsc.kJSPropertyAttributeNone, null);
    }
    return promises_obj;
}

/// 返回 node:xxx 的 exports；统一走 getShuBuiltin(ctx, allocator, "shu:yyy")，与 NODE_BUILTIN_NAMES 一一对应
pub fn getNodeBuiltin(ctx: jsc.JSContextRef, allocator: std.mem.Allocator, specifier: []const u8) jsc.JSValueRef {
    if (std.mem.eql(u8, specifier, "node:fs/promises") or std.mem.eql(u8, specifier, "fs/promises")) return getFsPromisesExports(ctx, allocator);
    if (std.mem.eql(u8, specifier, "node:path")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:path");
    if (std.mem.eql(u8, specifier, "node:fs")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:fs");
    if (std.mem.eql(u8, specifier, "node:zlib")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:zlib");
    if (std.mem.eql(u8, specifier, "node:assert")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:assert");
    if (std.mem.eql(u8, specifier, "node:events")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:events");
    if (std.mem.eql(u8, specifier, "node:util")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:util");
    if (std.mem.eql(u8, specifier, "node:querystring")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:querystring");
    if (std.mem.eql(u8, specifier, "node:url")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:url");
    if (std.mem.eql(u8, specifier, "node:string_decoder")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:string_decoder");
    if (std.mem.eql(u8, specifier, "node:crypto")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:crypto");
    if (std.mem.eql(u8, specifier, "node:os")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:os");
    if (std.mem.eql(u8, specifier, "node:process")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:process");
    if (std.mem.eql(u8, specifier, "node:timers")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:timers");
    if (std.mem.eql(u8, specifier, "node:console")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:console");
    if (std.mem.eql(u8, specifier, "node:child_process")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:cmd");
    if (std.mem.eql(u8, specifier, "node:worker_threads")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:threads");
    if (std.mem.eql(u8, specifier, "node:buffer")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:buffer");
    if (std.mem.eql(u8, specifier, "node:stream")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:stream");
    if (std.mem.eql(u8, specifier, "node:http")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:http");
    if (std.mem.eql(u8, specifier, "node:https")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:https");
    if (std.mem.eql(u8, specifier, "node:net")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:net");
    if (std.mem.eql(u8, specifier, "node:tls")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:tls");
    if (std.mem.eql(u8, specifier, "node:dgram")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:dgram");
    if (std.mem.eql(u8, specifier, "node:dns")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:dns");
    if (std.mem.eql(u8, specifier, "node:readline")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:readline");
    if (std.mem.eql(u8, specifier, "node:vm")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:vm");
    if (std.mem.eql(u8, specifier, "node:async_hooks")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:async_hooks");
    if (std.mem.eql(u8, specifier, "node:async_context")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:async_context");
    if (std.mem.eql(u8, specifier, "node:perf_hooks")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:perf_hooks");
    if (std.mem.eql(u8, specifier, "node:module")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:module");
    if (std.mem.eql(u8, specifier, "node:diagnostics_channel")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:diagnostics_channel");
    if (std.mem.eql(u8, specifier, "node:report")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:report");
    if (std.mem.eql(u8, specifier, "node:inspector")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:inspector");
    if (std.mem.eql(u8, specifier, "node:tracing")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:tracing");
    if (std.mem.eql(u8, specifier, "node:tty")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:tty");
    if (std.mem.eql(u8, specifier, "node:permissions")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:permissions");
    if (std.mem.eql(u8, specifier, "node:intl")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:intl");
    if (std.mem.eql(u8, specifier, "node:webcrypto")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:webcrypto");
    if (std.mem.eql(u8, specifier, "node:webstreams")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:webstreams");
    if (std.mem.eql(u8, specifier, "node:cluster")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:cluster");
    if (std.mem.eql(u8, specifier, "node:repl")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:repl");
    if (std.mem.eql(u8, specifier, "node:test")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:test");
    if (std.mem.eql(u8, specifier, "node:wasi")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:wasi");
    if (std.mem.eql(u8, specifier, "node:debugger")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:debugger");
    if (std.mem.eql(u8, specifier, "node:v8")) return shu_stub.getExports(ctx, allocator, "v8");
    if (std.mem.eql(u8, specifier, "node:punycode")) return shu_stub.getExports(ctx, allocator, "punycode");
    if (std.mem.eql(u8, specifier, "node:domain")) return shu_stub.getExports(ctx, allocator, "domain");
    if (std.mem.eql(u8, specifier, "node:errors")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:errors");
    if (std.mem.eql(u8, specifier, "node:corepack")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:corepack");
    if (std.mem.eql(u8, specifier, "node:sqlite")) return shu_builtin.getShuBuiltin(ctx, allocator, "shu:sqlite");
    return jsc.JSValueMakeUndefined(ctx);
}

/// 判断是否为已支持的 node: 内置说明符（用于 require/import 分支）；与 NODE_BUILTIN_NAMES 一致
pub fn isSupportedNodeBuiltin(specifier: []const u8) bool {
    for (NODE_BUILTIN_NAMES) |name| {
        if (std.mem.eql(u8, specifier, name)) return true;
    }
    return false;
}
