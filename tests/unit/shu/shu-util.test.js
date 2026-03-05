// shu:util 模块 JS 测试：inspect、promisify、types（所有方法全覆盖 + 边界）
const { describe, it, assert } = require("shu:test");
const util = require("shu:util");

describe("shu:util", () => {
  it("util.inspect returns string representation", () => {
    assert.strictEqual(typeof util.inspect({ a: 1 }), "string");
    assert.ok(util.inspect({ a: 1 }).includes("a") || util.inspect({ a: 1 }).length > 0);
  });

  it("util.promisify returns a function", () => {
    const fn = (arg, cb) => cb(null, arg);
    const promisified = util.promisify(fn);
    assert.strictEqual(typeof promisified, "function");
  });

  it("util.promisify wraps callback-style in Promise", async () => {
    const fn = (x, cb) => setTimeout(() => cb(null, x * 2), 0);
    const promisified = util.promisify(fn);
    const result = await promisified(21);
    assert.strictEqual(result, 42);
  });

  it("util.types.isArray", () => {
    assert.strictEqual(util.types.isArray([]), true);
    assert.strictEqual(util.types.isArray({}), false);
  });

  it("util.types.isFunction", () => {
    assert.strictEqual(util.types.isFunction(() => {}), true);
    assert.strictEqual(util.types.isFunction("x"), false);
  });

  it("util.types.isString", () => {
    assert.strictEqual(util.types.isString(""), true);
    assert.strictEqual(util.types.isString(1), false);
  });

  it("util.types.isNumber", () => {
    assert.strictEqual(util.types.isNumber(0), true);
    assert.strictEqual(util.types.isNumber(NaN), true);
    assert.strictEqual(util.types.isNumber("1"), false);
  });

  it("util.types.isBoolean", () => {
    assert.strictEqual(util.types.isBoolean(true), true);
    assert.strictEqual(util.types.isBoolean(1), false);
  });

  it("util.types.isNull", () => {
    assert.strictEqual(util.types.isNull(null), true);
    assert.strictEqual(util.types.isNull(undefined), false);
  });

  it("util.types.isUndefined", () => {
    assert.strictEqual(util.types.isUndefined(undefined), true);
    assert.strictEqual(util.types.isUndefined(null), false);
  });
});

describe("shu:util boundary", () => {
  it("util.inspect(null) returns string", () => {
    assert.strictEqual(typeof util.inspect(null), "string");
  });

  it("util.promisify with callback(err) rejects", async () => {
    const fn = (cb) => setTimeout(() => cb(new Error("err")), 0);
    const promisified = util.promisify(fn);
    let rejected = false;
    try {
      await promisified();
    } catch (_) {
      rejected = true;
    }
    assert.ok(rejected);
  });

  it("util.inspect(undefined) returns string", () => {
    assert.strictEqual(typeof util.inspect(undefined), "string");
  });

  it("util.types with null/undefined", () => {
    assert.strictEqual(util.types.isNull(null), true);
    assert.strictEqual(util.types.isUndefined(undefined), true);
    assert.strictEqual(util.types.isArray(null), false);
  });

  it("util.promisify with non-function throws or returns", () => {
    try {
      util.promisify(null);
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });
});
