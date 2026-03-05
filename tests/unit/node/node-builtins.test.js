/**
 * Node 内置模块全面兼容测试：所有 node:xxx 与 fs/promises 可 require 且导出预期形状
 * 与 src/runtime/modules/node/builtin.zig NODE_BUILTIN_NAMES 对齐
 */
const { describe, it, assert } = require("shu:test");

/** 需 require 的 node 内置说明符及每个模块至少一个预期导出属性（用于 smoke 检查） */
const NODE_BUILTINS = [
  { specifier: "node:path", expectKeys: ["join", "resolve", "dirname", "basename"] },
  { specifier: "node:fs", expectKeys: ["readFileSync", "writeFileSync", "existsSync", "readdirSync"] },
  { specifier: "node:fs/promises", expectKeys: ["readFile", "writeFile", "readdir", "stat", "mkdir"] },
  { specifier: "fs/promises", expectKeys: ["readFile", "writeFile"] },
  { specifier: "node:zlib", expectKeys: ["gzipSync", "gunzipSync", "deflateSync", "inflateSync"] },
  { specifier: "node:assert", expectKeys: ["ok", "strictEqual", "deepStrictEqual", "throws", "rejects"] },
  { specifier: "node:events", expectKeys: ["EventEmitter"] },
  { specifier: "node:util", expectKeys: ["inspect", "promisify", "types"] },
  { specifier: "node:querystring", expectKeys: ["parse", "stringify"] },
  { specifier: "node:url", expectKeys: ["parse", "format", "URL", "URLSearchParams"] },
  { specifier: "node:string_decoder", expectKeys: ["StringDecoder"] },
  { specifier: "node:crypto", expectKeys: ["randomUUID", "getRandomValues", "digest", "encrypt", "decrypt"] },
  { specifier: "node:os", expectKeys: ["platform", "arch", "homedir", "tmpdir", "cpus", "totalmem", "freemem"] },
  { specifier: "node:process", expectKeys: ["cwd", "platform", "env", "argv", "exit"] },
  { specifier: "node:timers", expectKeys: ["setTimeout", "setInterval", "setImmediate", "clearTimeout", "clearInterval"] },
  { specifier: "node:console", expectKeys: ["log", "warn", "error", "info", "debug"] },
  { specifier: "node:child_process", expectKeys: ["exec", "execSync", "spawn", "spawnSync"] },
  { specifier: "node:worker_threads", expectKeys: ["Worker", "isMainThread", "parentPort", "workerData"] },
  { specifier: "node:buffer", expectKeys: ["Buffer"] },
  { specifier: "node:stream", expectKeys: ["Readable", "Writable", "Duplex", "Transform", "PassThrough", "pipeline"] },
  { specifier: "node:http", expectKeys: ["createServer", "request"] },
  { specifier: "node:https", expectKeys: ["createServer"] },
  { specifier: "node:net", expectKeys: ["createServer", "createConnection", "connect", "Socket"] },
  { specifier: "node:tls", expectKeys: ["createServer", "connect", "createSecureContext"] },
  { specifier: "node:dgram", expectKeys: ["createSocket"] },
  { specifier: "node:dns", expectKeys: ["lookup", "resolve", "resolve4", "resolve6"] },
  { specifier: "node:readline", expectKeys: ["createInterface", "question", "clearLine"] },
  { specifier: "node:vm", expectKeys: ["createContext", "runInContext", "runInNewContext", "Script"] },
  { specifier: "node:async_hooks", expectKeys: ["executionAsyncId", "triggerAsyncId", "createHook", "AsyncResource"] },
  { specifier: "node:async_context", expectKeys: ["AsyncLocalStorage"] },
  { specifier: "node:perf_hooks", expectKeys: ["performance", "PerformanceObserver", "mark", "measure"] },
  { specifier: "node:module", expectKeys: ["createRequire", "isBuiltin", "builtinModules", "findPackageJSON"] },
  { specifier: "node:diagnostics_channel", expectKeys: ["channel", "subscribe", "publish", "hasSubscribers"] },
  { specifier: "node:report", expectKeys: ["getReport", "writeReport"] },
  { specifier: "node:inspector", expectKeys: ["open", "close", "url"] },
  { specifier: "node:tracing", expectKeys: ["createTracing", "trace"] },
  { specifier: "node:tty", expectKeys: ["isTTY", "ReadStream", "WriteStream"] },
  { specifier: "node:permissions", expectKeys: ["has", "request"] },
  { specifier: "node:intl", expectKeys: ["getIntl", "Segmenter"] },
  { specifier: "node:webcrypto", expectKeys: ["crypto", "getRandomValues", "randomUUID"] },
  { specifier: "node:webstreams", expectKeys: ["ReadableStream", "WritableStream", "TransformStream"] },
  { specifier: "node:cluster", expectKeys: ["isPrimary", "isMaster", "workers", "setupPrimary", "disconnect"] },
  { specifier: "node:repl", expectKeys: ["start", "ReplServer"] },
  { specifier: "node:test", expectKeys: ["describe", "it", "test", "beforeAll", "afterAll", "run", "mock"] },
  { specifier: "node:wasi", expectKeys: ["WASI"] },
  { specifier: "node:debugger", expectKeys: ["port", "host"] },
  { specifier: "node:v8", expectKeys: [] },
  { specifier: "node:punycode", expectKeys: [] },
  { specifier: "node:domain", expectKeys: [] },
  { specifier: "node:errors", expectKeys: ["SystemError", "codes"] },
  { specifier: "node:corepack", expectKeys: ["enable", "disable", "run"] },
  { specifier: "node:sqlite", expectKeys: ["DatabaseSync", "Database", "constants", "backup"] },
];

describe("node builtins (require)", () => {
  for (const { specifier, expectKeys } of NODE_BUILTINS) {
    it(`${specifier} resolves and has expected exports`, () => {
      const mod = require(specifier);
      assert.ok(mod != null && typeof mod === "object", `${specifier} should be an object`);
      for (const key of expectKeys) {
        assert.ok(key in mod, `${specifier} should have '${key}'`);
      }
    });
  }
});

describe("node builtins (stub shape)", () => {
  it("node:v8 returns stub object", () => {
    const mod = require("node:v8");
    assert.ok(mod != null && typeof mod === "object");
    assert.ok(mod.__stub === true);
  });

  it("node:punycode returns stub object", () => {
    const mod = require("node:punycode");
    assert.ok(mod != null && typeof mod === "object");
    assert.ok(mod.__stub === true);
  });

  it("node:domain returns stub object", () => {
    const mod = require("node:domain");
    assert.ok(mod != null && typeof mod === "object");
    assert.ok(mod.__stub === true);
  });

  it("node:corepack returns object with enable, disable, run", () => {
    const mod = require("node:corepack");
    assert.ok(mod != null && typeof mod === "object");
    assert.strictEqual(typeof mod.enable, "function");
    assert.strictEqual(typeof mod.disable, "function");
    assert.strictEqual(typeof mod.run, "function");
  });

  it("node:sqlite returns object with DatabaseSync, Database, constants, backup", () => {
    const mod = require("node:sqlite");
    assert.ok(mod != null && typeof mod === "object");
    assert.strictEqual(typeof mod.DatabaseSync, "function");
    assert.strictEqual(typeof mod.Database, "function");
    assert.ok(mod.constants != null && typeof mod.constants === "object");
    assert.strictEqual(typeof mod.backup, "function");
    const db = new mod.DatabaseSync(":memory:");
    assert.strictEqual(typeof db.exec, "function");
    assert.strictEqual(typeof db.prepare, "function");
    const stmt = db.prepare("SELECT 1");
    assert.strictEqual(typeof stmt.run, "function");
    assert.strictEqual(typeof stmt.all, "function");
    assert.strictEqual(typeof stmt.get, "function");
  });
});
