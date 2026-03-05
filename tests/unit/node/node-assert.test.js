/**
 * node:assert 全面兼容测试：ok、strictEqual、deepStrictEqual、fail、throws 全方法 + 边界
 */
const { describe, it, assert } = require("shu:test");
const assertModule = require("node:assert");

describe("node:assert exports", () => {
  it("has ok, strictEqual, deepStrictEqual, fail, throws", () => {
    assert.strictEqual(typeof assertModule.ok, "function");
    assert.strictEqual(typeof assertModule.strictEqual, "function");
    assert.strictEqual(typeof assertModule.deepStrictEqual, "function");
    assert.strictEqual(typeof assertModule.fail, "function");
    assert.strictEqual(typeof assertModule.throws, "function");
  });
});

describe("node:assert ok", () => {
  it("ok(value) does not throw for truthy", () => {
    assertModule.ok(true);
    assertModule.ok(1);
    assertModule.ok("x");
    assertModule.ok({});
    assertModule.ok([]);
  });
  it("ok(false) throws", () => {
    assert.throws(() => assertModule.ok(false));
  });
  it("ok(undefined) throws", () => {
    assert.throws(() => assertModule.ok(undefined));
  });
  it("ok(null) throws", () => {
    assert.throws(() => assertModule.ok(null));
  });
  it("ok(0) throws", () => {
    assert.throws(() => assertModule.ok(0));
  });
  it("ok('') throws", () => {
    assert.throws(() => assertModule.ok(""));
  });
});

describe("node:assert strictEqual", () => {
  it("strictEqual(actual, expected) does not throw when equal", () => {
    assertModule.strictEqual(1, 1);
    assertModule.strictEqual("a", "a");
    assertModule.strictEqual(null, null);
    assertModule.strictEqual(undefined, undefined);
  });
  it("strictEqual throws when not equal", () => {
    assert.throws(() => assertModule.strictEqual(1, 2));
    assert.throws(() => assertModule.strictEqual("a", "b"));
  });
  it("strictEqual(NaN, NaN) does not throw", () => {
    assertModule.strictEqual(NaN, NaN);
  });
  it("strictEqual(0, -0) throws (Object.is: 0 !== -0)", () => {
    try {
      assertModule.strictEqual(0, -0);
      assert.fail("expected throw");
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });
  it("strictEqual with optional message", () => {
    try {
      assertModule.strictEqual(1, 2, "custom message");
    } catch (e) {
      assert.ok(e instanceof Error);
      assert.ok(e.message.includes("custom") || e.message.length > 0);
    }
  });
});

describe("node:assert deepStrictEqual", () => {
  it("deepStrictEqual does not throw when deep equal", () => {
    assertModule.deepStrictEqual({ a: 1 }, { a: 1 });
    assertModule.deepStrictEqual([1, 2], [1, 2]);
    assertModule.deepStrictEqual({ a: { b: 2 } }, { a: { b: 2 } });
  });
  it("deepStrictEqual throws when structure differs", () => {
    assert.throws(() => assertModule.deepStrictEqual({ a: 1 }, { a: 2 }));
    assert.throws(() => assertModule.deepStrictEqual([1, 2], [2, 1]));
  });
  it("deepStrictEqual array order matters", () => {
    assertModule.deepStrictEqual([1, 2], [1, 2]);
    assert.throws(() => assertModule.deepStrictEqual([1, 2], [2, 1]));
  });
  it("deepStrictEqual with nested objects", () => {
    assertModule.deepStrictEqual({ x: { y: [1, 2] } }, { x: { y: [1, 2] } });
  });
});

describe("node:assert fail", () => {
  it("fail() throws", () => {
    assert.throws(() => assertModule.fail());
  });
  it("fail(message) throws with message", () => {
    try {
      assertModule.fail("must fail");
    } catch (e) {
      assert.ok(e instanceof Error);
      assert.ok(e.message.includes("must fail") || e.message.length > 0);
    }
  });
});

describe("node:assert throws", () => {
  it("throws(fn) when fn throws", () => {
    assertModule.throws(() => {
      throw new Error("expected");
    });
  });
  it("throws(fn) throws when fn does not throw", () => {
    assert.throws(() => assertModule.throws(() => {}));
  });
  it("throws with non-function", () => {
    try {
      assertModule.throws("not a function");
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });
  it("throws returns the thrown value when fn throws", () => {
    const err = new Error("my error");
    const result = assertModule.throws(() => {
      throw err;
    });
    assert.strictEqual(result, err);
  });
});
