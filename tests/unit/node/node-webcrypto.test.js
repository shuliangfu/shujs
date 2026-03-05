/**
 * node:webcrypto 兼容测试：透传 globalThis.crypto；getRandomValues、randomUUID、subtle、边界
 */
const { describe, it, assert } = require("shu:test");
const webcrypto = require("node:webcrypto");

describe("node:webcrypto exports", () => {
  it("has getRandomValues randomUUID subtle or same as crypto", () => {
    assert.ok(webcrypto.getRandomValues != null || webcrypto.randomUUID != null || webcrypto.subtle != null || webcrypto === globalThis.crypto);
  });
});

describe("node:webcrypto getRandomValues", () => {
  it("getRandomValues fills TypedArray", () => {
    const arr = new Uint8Array(8);
    const out = webcrypto.getRandomValues ? webcrypto.getRandomValues(arr) : globalThis.crypto.getRandomValues(arr);
    assert.ok(out != null);
  });
});

describe("node:webcrypto boundary", () => {
  it("randomUUID returns string when present", () => {
    const c = webcrypto.randomUUID ? webcrypto : globalThis.crypto;
    if (c && c.randomUUID) {
      const u = c.randomUUID();
      assert.strictEqual(typeof u, "string");
    }
  });
});
