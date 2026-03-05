// 其他全局注册 API 测试：AbortController、atob、btoa（由 bindings 注册到 globalThis）
// 不依赖 --allow-net
const { describe, it, assert } = require("shu:test");

describe("global AbortController", () => {
  it("AbortController is a constructor", () => {
    assert.strictEqual(typeof globalThis.AbortController, "function");
  });

  it("new AbortController() has signal and abort()", () => {
    const c = new AbortController();
    assert.ok(c != null);
    assert.ok("signal" in c);
    assert.ok("abort" in c);
    assert.strictEqual(typeof c.abort, "function");
    assert.strictEqual(c.signal.aborted, false);
  });

  it("controller.abort() sets signal.aborted to true", () => {
    const c = new AbortController();
    c.abort();
    assert.strictEqual(c.signal.aborted, true);
  });

  it("controller.abort(reason) sets signal.reason", () => {
    const c = new AbortController();
    const reason = new Error("cancel");
    c.abort(reason);
    assert.strictEqual(c.signal.aborted, true);
    assert.ok(c.signal.reason === reason || c.signal.reason != null);
  });
});

describe("global atob / btoa (encoding)", () => {
  it("atob and btoa are functions", () => {
    assert.strictEqual(typeof globalThis.atob, "function");
    assert.strictEqual(typeof globalThis.btoa, "function");
  });

  it("btoa encodes binary string to base64", () => {
    assert.strictEqual(btoa("hello"), "aGVsbG8=");
  });

  it("atob decodes base64 to binary string", () => {
    assert.strictEqual(atob("aGVsbG8="), "hello");
  });

  it("atob(btoa(x)) round-trip", () => {
    const x = "foo bar";
    assert.strictEqual(atob(btoa(x)), x);
  });

  it("atob invalid base64 throws", () => {
    let threw = false;
    try {
      atob("!!!");
    } catch (_) {
      threw = true;
    }
    assert.ok(threw);
  });

  it("atob empty string returns empty string", () => {
    assert.strictEqual(atob(""), "");
  });

  it("btoa empty string returns empty string", () => {
    assert.strictEqual(btoa(""), "");
  });

  it("btoa with character out of range (code point > 255) throws", () => {
    let threw = false;
    try {
      btoa("\u0100"); // U+0100 > 255
    } catch (_) {
      threw = true;
    }
    assert.ok(threw);
  });
});
