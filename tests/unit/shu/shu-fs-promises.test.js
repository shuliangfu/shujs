// node:fs/promises 与 fs/promises 解析及 Promise 形态 API 测试
// 约定：使用 tests/unit/utils 提供的测试数据目录，用例结束后清理
const { describe, it, assert, beforeAll, afterAll } = require("shu:test");
const path = require("shu:path");
const { getTestDataDir, ensureTestDataDir, cleanupTestDataDir } = require("../utils.js");

describe("node:fs/promises", () => {
  beforeAll(() => {
    ensureTestDataDir("fs");
  });

  afterAll(() => {
    cleanupTestDataDir("fs");
  });

  it("require('node:fs/promises') returns object with Promise-based methods", () => {
    const fsp = require("node:fs/promises");
    assert.ok(fsp != null && typeof fsp === "object");
    assert.strictEqual(typeof fsp.readFile, "function");
    assert.strictEqual(typeof fsp.writeFile, "function");
    assert.strictEqual(typeof fsp.readdir, "function");
    assert.strictEqual(typeof fsp.stat, "function");
    assert.strictEqual(typeof fsp.mkdir, "function");
    assert.strictEqual(typeof fsp.unlink, "function");
    assert.strictEqual(typeof fsp.copyFile, "function");
    assert.strictEqual(typeof fsp.appendFile, "function");
  });

  it("require('fs/promises') returns same-shaped API as node:fs/promises", () => {
    const fsp = require("fs/promises");
    assert.ok(fsp != null && typeof fsp === "object");
    assert.strictEqual(typeof fsp.readFile, "function");
    assert.strictEqual(typeof fsp.writeFile, "function");
  });

  it("readFile returns a Promise", () => {
    const fsp = require("node:fs/promises");
    const p = fsp.readFile(process.cwd() + "/nonexistent-xxx-no-create");
    assert.ok(p != null && typeof p.then === "function");
  });

  it("writeFile then readFile roundtrip (Promise API)", async () => {
    const fsp = require("node:fs/promises");
    const dir = getTestDataDir("fs");
    const file = path.join(dir, "fs-promises-roundtrip-" + Date.now() + ".txt");
    const content = "hello fs/promises";
    await fsp.writeFile(file, content);
    const read = await fsp.readFile(file);
    assert.strictEqual(typeof read, "string");
    assert.strictEqual(read, content);
    await fsp.unlink(file);
  });

  it("readdir returns Promise resolving to array", async () => {
    const fsp = require("node:fs/promises");
    const dir = getTestDataDir("fs");
    const names = await fsp.readdir(dir);
    assert.ok(Array.isArray(names));
  });

  it("stat returns Promise resolving to stats object", async () => {
    const fsp = require("node:fs/promises");
    const st = await fsp.stat(process.cwd());
    assert.ok(st != null && typeof st.size === "number");
  });

  it("exists returns Promise resolving to boolean", async () => {
    const fsp = require("node:fs/promises");
    const ok = await fsp.exists(process.cwd());
    assert.strictEqual(ok, true);
  });
});
