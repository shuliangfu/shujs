/**
 * node:util 全面兼容测试：inspect、promisify、types 全方法 + 边界
 */
const { describe, it, assert } = require("shu:test");
const util = require("node:util");

describe("node:util exports", () => {
  it("has inspect, promisify, types", () => {
    assert.strictEqual(typeof util.inspect, "function");
    assert.strictEqual(typeof util.promisify, "function");
    assert.ok(util.types != null && typeof util.types === "object");
  });
  it("types has isArray, isFunction, isString, isNumber, isBoolean, isNull, isUndefined", () => {
    assert.strictEqual(typeof util.types.isArray, "function");
    assert.strictEqual(typeof util.types.isFunction, "function");
    assert.strictEqual(typeof util.types.isString, "function");
    assert.strictEqual(typeof util.types.isNumber, "function");
    assert.strictEqual(typeof util.types.isBoolean, "function");
    assert.strictEqual(typeof util.types.isNull, "function");
    assert.strictEqual(typeof util.types.isUndefined, "function");
  });
});

describe("node:util inspect", () => {
  it("inspect(primitive) returns string", () => {
    assert.strictEqual(typeof util.inspect(1), "string");
    assert.strictEqual(typeof util.inspect("hi"), "string");
    assert.strictEqual(typeof util.inspect(true), "string");
    assert.strictEqual(typeof util.inspect(null), "string");
    assert.strictEqual(typeof util.inspect(undefined), "string");
  });
  it("inspect(object) returns string", () => {
    assert.strictEqual(typeof util.inspect({ a: 1 }), "string");
  });
  it("inspect(array) returns string", () => {
    assert.strictEqual(typeof util.inspect([1, 2]), "string");
  });
  it("inspect circular ref does not throw", () => {
    const o = {};
    o.self = o;
    assert.strictEqual(typeof util.inspect(o), "string");
  });
});

describe("node:util promisify", () => {
  it("promisify(fn) returns function", () => {
    const fn = (cb) => { cb(null, "ok"); };
    const promised = util.promisify(fn);
    assert.strictEqual(typeof promised, "function");
  });
  it("promisified function returns Promise", () => {
    const fn = (cb) => { cb(null, "ok"); };
    const promised = util.promisify(fn);
    const p = promised();
    assert.ok(p != null && typeof p.then === "function");
  });
  it("promisified resolve value", async () => {
    const fn = (cb) => { cb(null, 42); };
    const promised = util.promisify(fn);
    const v = await promised();
    assert.strictEqual(v, 42);
  });
  it("promisified reject on callback(err)", async () => {
    const fn = (cb) => { cb(new Error("fail")); };
    const promised = util.promisify(fn);
    let err;
    try {
      await promised();
    } catch (e) {
      err = e;
    }
    assert.ok(err instanceof Error);
    assert.ok(err.message.includes("fail"));
  });
});

describe("node:util types", () => {
  it("types.isArray", () => {
    assert.strictEqual(util.types.isArray([]), true);
    assert.strictEqual(util.types.isArray({}), false);
    assert.strictEqual(util.types.isArray(""), false);
  });
  it("types.isFunction", () => {
    assert.strictEqual(util.types.isFunction(() => {}), true);
    assert.strictEqual(util.types.isFunction(""), false);
  });
  it("types.isString", () => {
    assert.strictEqual(util.types.isString(""), true);
    assert.strictEqual(util.types.isString(1), false);
  });
  it("types.isNumber", () => {
    assert.strictEqual(util.types.isNumber(1), true);
    assert.strictEqual(util.types.isNumber(NaN), true);
    assert.strictEqual(util.types.isNumber("1"), false);
  });
  it("types.isBoolean", () => {
    assert.strictEqual(util.types.isBoolean(true), true);
    assert.strictEqual(util.types.isBoolean(1), false);
  });
  it("types.isNull", () => {
    assert.strictEqual(util.types.isNull(null), true);
    assert.strictEqual(util.types.isNull(undefined), false);
  });
  it("types.isUndefined", () => {
    assert.strictEqual(util.types.isUndefined(undefined), true);
    assert.strictEqual(util.types.isUndefined(null), false);
  });
});

describe("node:util boundary", () => {
  it("inspect(undefined)", () => {
    assert.strictEqual(typeof util.inspect(undefined), "string");
  });
  it("types.isArray(null) false", () => {
    assert.strictEqual(util.types.isArray(null), false);
  });
  it("promisify with non-function throws or no-op", () => {
    try {
      util.promisify(null);
      util.promisify(undefined);
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });
});
