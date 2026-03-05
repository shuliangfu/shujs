/**
 * node:fs 同步 API 全面兼容测试：readFileSync、writeFileSync、existsSync、readdirSync、statSync 等 + 边界
 */
const { describe, it, assert, beforeAll, afterAll } = require("shu:test");
const fs = require("node:fs");
const path = require("node:path");
const { getTestDataDir, ensureTestDataDir, cleanupTestDataDir } = require("../utils.js");

describe("node:fs exports", () => {
  it("has readFileSync writeFileSync existsSync readdirSync statSync", () => {
    assert.strictEqual(typeof fs.readFileSync, "function");
    assert.strictEqual(typeof fs.writeFileSync, "function");
    assert.strictEqual(typeof fs.existsSync, "function");
    assert.strictEqual(typeof fs.readdirSync, "function");
    assert.strictEqual(typeof fs.statSync, "function");
  });

  it("has mkdirSync unlinkSync", () => {
    assert.strictEqual(typeof fs.mkdirSync, "function");
    assert.strictEqual(typeof fs.unlinkSync, "function");
  });
});

describe("node:fs existsSync", () => {
  it("existsSync(process.cwd()) returns true", () => {
    assert.strictEqual(fs.existsSync(process.cwd()), true);
  });

  it("existsSync on non-existent path returns false", () => {
    const p = path.join(process.cwd(), "__nonexistent_fs_sync_xyz__");
    assert.strictEqual(fs.existsSync(p), false);
  });
});

describe("node:fs writeFileSync and readFileSync roundtrip", () => {
  let testDir;
  let testFile;

  beforeAll(() => {
    ensureTestDataDir("fs-sync");
    testDir = getTestDataDir("fs-sync");
    testFile = path.join(testDir, "node-fs-sync-roundtrip-" + Date.now() + ".txt");
  });

  afterAll(() => {
    if (testFile && fs.existsSync(testFile)) {
      try {
        fs.unlinkSync(testFile);
      } catch (_) {}
    }
    cleanupTestDataDir("fs-sync");
  });

  it("writeFileSync then readFileSync returns same content", () => {
    const content = "hello node:fs sync";
    fs.writeFileSync(testFile, content);
    const read = fs.readFileSync(testFile);
    const str = typeof read === "string" ? read : read.toString();
    assert.strictEqual(str, content);
  });

  it("readFileSync returns string or Buffer", () => {
    const data = fs.readFileSync(testFile);
    assert.ok(typeof data === "string" || (data && typeof data.length === "number"));
  });
});

describe("node:fs readdirSync", () => {
  it("readdirSync(process.cwd()) returns array", () => {
    const names = fs.readdirSync(process.cwd());
    assert.ok(Array.isArray(names));
  });

  it("readdirSync on test data dir returns array of strings", () => {
    ensureTestDataDir("fs-sync");
    const dir = getTestDataDir("fs-sync");
    const names = fs.readdirSync(dir);
    assert.ok(Array.isArray(names));
    names.forEach((n) => assert.strictEqual(typeof n, "string"));
  });
});

describe("node:fs statSync", () => {
  it("statSync(process.cwd()) returns stats object", () => {
    const st = fs.statSync(process.cwd());
    assert.ok(st != null && typeof st === "object");
    assert.strictEqual(typeof st.size, "number");
  });

  it("statSync on file returns size", () => {
    ensureTestDataDir("fs-sync");
    const dir = getTestDataDir("fs-sync");
    const f = path.join(dir, "node-fs-sync-roundtrip-" + Date.now() + ".txt");
    fs.writeFileSync(f, "x");
    const st = fs.statSync(f);
    assert.ok(st.size >= 0);
    fs.unlinkSync(f);
  });
});

describe("node:fs boundary", () => {
  it("readFileSync on non-existent path throws", () => {
    const p = path.join(process.cwd(), "__nonexistent_read_xyz__");
    let err;
    try {
      fs.readFileSync(p);
    } catch (e) {
      err = e;
    }
    assert.ok(err instanceof Error);
  });

  it("existsSync with empty string or relative path", () => {
    const cwdExists = fs.existsSync(".");
    assert.strictEqual(typeof cwdExists, "boolean");
  });
});
