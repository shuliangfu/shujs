/**
 * node:process 全面兼容测试：cwd、platform、env、argv、exit 等 + 边界
 */
const { describe, it, assert } = require("shu:test");
const proc = require("node:process");

describe("node:process exports", () => {
  it("exports same as global process", () => {
    assert.strictEqual(proc, globalThis.process);
  });
});

describe("node:process cwd", () => {
  it("cwd is function", () => {
    assert.strictEqual(typeof proc.cwd, "function");
  });
  it("cwd() returns string", () => {
    const c = proc.cwd();
    assert.strictEqual(typeof c, "string");
    assert.ok(c.length > 0);
  });
});

describe("node:process platform and env", () => {
  it("platform is string", () => {
    assert.strictEqual(typeof proc.platform, "string");
    assert.ok(["darwin", "linux", "win32", "freebsd", "openbsd"].includes(proc.platform) || proc.platform.length > 0);
  });
  it("env is object", () => {
    assert.ok(proc.env != null && typeof proc.env === "object");
  });
  it("argv is array", () => {
    assert.ok(Array.isArray(proc.argv));
  });
});

describe("node:process boundary", () => {
  it("process.version is string if present", () => {
    if ("version" in proc) assert.strictEqual(typeof proc.version, "string");
  });
  it("process.pid is number if present", () => {
    if ("pid" in proc) assert.strictEqual(typeof proc.pid, "number");
  });
});
