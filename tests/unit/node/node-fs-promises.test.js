/**
 * node:fs/promises 与 fs/promises 全面兼容测试：Promise 形态 API 与 Node 对齐
 */
const { describe, it, assert, beforeAll, afterAll } = require("shu:test");
const path = require("node:path");
const { getTestDataDir, ensureTestDataDir, cleanupTestDataDir } = require("../utils.js");

describe("node:fs/promises require", () => {
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
});

describe("node:fs/promises API returns Promises", () => {
  it("readFile returns a Promise", () => {
    const fsp = require("node:fs/promises");
    const p = fsp.readFile(process.cwd() + "/nonexistent-xxx-no-create");
    assert.ok(p != null && typeof p.then === "function");
  });

  it("writeFile returns a Promise", () => {
    const fsp = require("node:fs/promises");
    const p = fsp.writeFile("/tmp/shu-fs-promises-touch", "x");
    assert.ok(p != null && typeof p.then === "function");
  });
});

describe("node:fs/promises roundtrip and readdir/stat/exists", () => {
  beforeAll(() => {
    ensureTestDataDir("fs");
  });

  afterAll(() => {
    cleanupTestDataDir("fs");
  });

  it("writeFile then readFile roundtrip (Promise API)", async () => {
    const fsp = require("node:fs/promises");
    const dir = getTestDataDir("fs");
    const file = path.join(dir, "node-fs-promises-roundtrip-" + Date.now() + ".txt");
    const content = "hello node:fs/promises";
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

describe("node:fs/promises boundary", () => {
  it("readFile on non-existent path rejects", async () => {
    const fsp = require("node:fs/promises");
    const badPath = process.cwd() + "/__nonexistent_file_xyz_12345__";
    let err;
    try {
      await fsp.readFile(badPath);
    } catch (e) {
      err = e;
    }
    assert.ok(err instanceof Error);
  });

  it("exists returns false for non-existent path", async () => {
    const fsp = require("node:fs/promises");
    const ok = await fsp.exists(process.cwd() + "/__nonexistent_xyz_999__");
    assert.strictEqual(ok, false);
  });

  it("stat on directory returns stats with isDirectory-like or size", async () => {
    const fsp = require("node:fs/promises");
    const st = await fsp.stat(process.cwd());
    assert.ok(st != null);
    assert.strictEqual(typeof st.size, "number");
  });
});
