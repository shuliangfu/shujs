/**
 * node:wasi 兼容测试：WASI 类可构造，getImportObject 可用，start() 暂抛 not implemented
 */
const { describe, it, assert } = require("shu:test");
const wasi = require("node:wasi");

describe("node:wasi exports", () => {
  it("require does not throw", () => {
    assert.ok(wasi != null && typeof wasi === "object");
  });
  it("has WASI constructor", () => {
    assert.strictEqual(typeof wasi.WASI, "function");
  });
});

describe("node:wasi WASI instance", () => {
  it("new WASI() returns instance with start and getImportObject", () => {
    const w = new wasi.WASI({});
    assert.ok(w != null && typeof w === "object");
    assert.strictEqual(typeof w.start, "function");
    assert.strictEqual(typeof w.getImportObject, "function");
  });
  it("getImportObject() returns object with wasi_snapshot_preview1", () => {
    const w = new wasi.WASI({});
    const imp = w.getImportObject();
    assert.ok(imp != null && typeof imp === "object");
    assert.ok("wasi_snapshot_preview1" in imp);
  });
  it("start() throws not implemented", () => {
    const w = new wasi.WASI({});
    try {
      w.start({});
      assert.fail("expected throw");
    } catch (e) {
      assert.ok(e.message.match(/not implemented/i));
    }
  });
});
