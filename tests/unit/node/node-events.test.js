/**
 * node:events (EventEmitter) 全面兼容测试：on、off、emit 全方法 + 边界
 */
const { describe, it, assert } = require("shu:test");
const { EventEmitter } = require("node:events");

describe("node:events exports", () => {
  it("exports EventEmitter constructor", () => {
    assert.strictEqual(typeof EventEmitter, "function");
  });
});

describe("node:events EventEmitter on and emit", () => {
  it("new EventEmitter() creates instance", () => {
    const ee = new EventEmitter();
    assert.ok(ee != null);
    assert.strictEqual(typeof ee.on, "function");
    assert.strictEqual(typeof ee.emit, "function");
    assert.strictEqual(typeof ee.off, "function");
  });
  it("on(name, fn) then emit(name) calls listener", () => {
    const ee = new EventEmitter();
    let called = false;
    ee.on("test", () => { called = true; });
    ee.emit("test");
    assert.strictEqual(called, true);
  });
  it("on multiple listeners all get called", () => {
    const ee = new EventEmitter();
    let count = 0;
    ee.on("x", () => { count++; });
    ee.on("x", () => { count++; });
    ee.emit("x");
    assert.strictEqual(count, 2);
  });
  it("emit passes arguments to listener", () => {
    const ee = new EventEmitter();
    let received = null;
    ee.on("data", (a, b) => { received = [a, b]; });
    ee.emit("data", 1, 2);
    assert.deepStrictEqual(received, [1, 2]);
  });
  it("emit with no listeners returns false or does not throw", () => {
    const ee = new EventEmitter();
    const result = ee.emit("nonexistent");
    assert.strictEqual(typeof result, "boolean");
  });
});

describe("node:events off", () => {
  it("off(name, fn) removes listener", () => {
    const ee = new EventEmitter();
    let count = 0;
    const fn = () => { count++; };
    ee.on("y", fn);
    ee.off("y", fn);
    ee.emit("y");
    assert.strictEqual(count, 0);
  });
  it("off after emit still works for next emit", () => {
    const ee = new EventEmitter();
    let count = 0;
    const fn = () => { count++; };
    ee.on("z", fn);
    ee.emit("z");
    assert.strictEqual(count, 1);
    ee.off("z", fn);
    ee.emit("z");
    assert.strictEqual(count, 1);
  });
});

describe("node:events boundary", () => {
  it("on with empty name does not throw", () => {
    const ee = new EventEmitter();
    ee.on("", () => {});
    ee.emit("");
  });
  it("on with one arg (no fn) does not crash", () => {
    const ee = new EventEmitter();
    ee.on("a"); // may no-op
    ee.emit("a");
  });
  it("emit with many args", () => {
    const ee = new EventEmitter();
    let args = null;
    ee.on("m", (...a) => { args = a; });
    ee.emit("m", 1, 2, 3, 4, 5);
    assert.strictEqual(args.length, 5);
  });
});
