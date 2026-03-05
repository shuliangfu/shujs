/**
 * node:crypto 全面兼容测试：randomUUID、getRandomValues、digest、crypto.subtle + 边界
 */
const { describe, it, assert } = require("shu:test");
const crypto = require("node:crypto");

describe("node:crypto exports", () => {
  it("has getRandomValues and randomUUID", () => {
    assert.strictEqual(typeof crypto.getRandomValues, "function");
    assert.strictEqual(typeof crypto.randomUUID, "function");
  });
  it("subtl or subtle exists", () => {
    assert.ok(crypto.subtle != null || crypto.subtl != null);
  });
});

describe("node:crypto randomUUID", () => {
  it("randomUUID() returns string", () => {
    const u = crypto.randomUUID();
    assert.strictEqual(typeof u, "string");
    assert.ok(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(u));
  });
});

describe("node:crypto getRandomValues", () => {
  it("getRandomValues(Uint8Array) fills buffer", () => {
    const arr = new Uint8Array(16);
    crypto.getRandomValues(arr);
    let same = true;
    for (let i = 1; i < arr.length; i++) if (arr[i] !== arr[0]) { same = false; break; }
    assert.ok(!same || arr.length <= 1);
  });
});

describe("node:crypto subtle digest", () => {
  const subtle = crypto.subtle || crypto.subtl;
  if (subtle && typeof subtle.digest === "function") {
    it("subtle.digest('SHA-256', buffer) returns Promise", async () => {
      const buf = new Uint8Array([1, 2, 3]);
      const p = subtle.digest("SHA-256", buf);
      assert.ok(p != null && typeof p.then === "function");
      const result = await p;
      assert.ok(result instanceof ArrayBuffer);
    });
  }
});

describe("node:crypto boundary", () => {
  it("getRandomValues with zero-length TypedArray", () => {
    const arr = new Uint8Array(0);
    crypto.getRandomValues(arr);
  });
  it("randomUUID twice differ", () => {
    const a = crypto.randomUUID();
    const b = crypto.randomUUID();
    assert.notStrictEqual(a, b);
  });
});
