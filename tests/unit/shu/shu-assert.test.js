// shu:assert 模块测试（Node 风格 assert：ok/strictEqual/deepStrictEqual/fail/throws）
const { describe, it, assert } = require("shu:test");

const assertModule = require("shu:assert");

describe("shu:assert", () => {
  it("exports ok, strictEqual, deepStrictEqual, fail, throws", () => {
    assert.strictEqual(typeof assertModule.ok, "function");
    assert.strictEqual(typeof assertModule.strictEqual, "function");
    assert.strictEqual(typeof assertModule.deepStrictEqual, "function");
    assert.strictEqual(typeof assertModule.fail, "function");
    assert.strictEqual(typeof assertModule.throws, "function");
  });

  it("ok(value) does not throw for truthy", () => {
    assertModule.ok(true);
    assertModule.ok(1);
    assertModule.ok("x");
  });

  it("strictEqual(actual, expected) uses Object.is", () => {
    assertModule.strictEqual(1, 1);
    assertModule.strictEqual("a", "a");
  });

  it("deepStrictEqual compares by structure", () => {
    assertModule.deepStrictEqual({ a: 1 }, { a: 1 });
  });

  it("throws(fn) when fn throws", () => {
    assertModule.throws(() => {
      throw new Error("expected");
    });
  });

  it("fail() throws", () => {
    assert.throws(() => assertModule.fail());
  });
});

describe("shu:assert boundary", () => {
  it("ok(false) throws", () => {
    assert.throws(() => assertModule.ok(false));
  });

  it("strictEqual(actual, expected) throws when not equal", () => {
    assert.throws(() => assertModule.strictEqual(1, 2));
  });

  it("deepStrictEqual throws when structure differs", () => {
    assert.throws(() => assertModule.deepStrictEqual({ a: 1 }, { a: 2 }));
  });

  it("throws(fn) throws when fn does not throw", () => {
    assert.throws(() => assertModule.throws(() => {}));
  });

  it("ok(undefined) and ok(null) throw", () => {
    assert.throws(() => assertModule.ok(undefined));
    assert.throws(() => assertModule.ok(null));
  });

  it("strictEqual(NaN, NaN) does not throw", () => {
    assertModule.strictEqual(NaN, NaN);
  });

  it("strictEqual(0, -0) behavior (Object.is: 0 !== -0)", () => {
    try {
      assertModule.strictEqual(0, -0);
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });

  it("throws with non-function throws or fails", () => {
    try {
      assertModule.throws("not a function");
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });

  it("deepStrictEqual with array order matters", () => {
    assertModule.deepStrictEqual([1, 2], [1, 2]);
    assert.throws(() => assertModule.deepStrictEqual([1, 2], [2, 1]));
  });
});
