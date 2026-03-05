// shu:events 模块 JS 测试：EventEmitter、on、emit、off
const { describe, it, assert } = require("shu:test");
const { EventEmitter } = require("shu:events");

describe("shu:events", () => {
  it("EventEmitter is a constructor", () => {
    assert.strictEqual(typeof EventEmitter, "function");
    const ee = new EventEmitter();
    assert.ok(ee instanceof EventEmitter);
  });

  it("on(name, fn) and emit(name, ...args) call listeners", () => {
    const ee = new EventEmitter();
    let called = 0;
    let received = null;
    ee.on("foo", (x) => {
      called++;
      received = x;
    });
    ee.emit("foo", 42);
    assert.strictEqual(called, 1);
    assert.strictEqual(received, 42);
  });

  it("emit returns true when there are listeners", () => {
    const ee = new EventEmitter();
    ee.on("a", () => {});
    assert.strictEqual(ee.emit("a"), true);
  });

  it("emit returns false when no listeners", () => {
    const ee = new EventEmitter();
    assert.strictEqual(ee.emit("none"), false);
  });

  it("off(name, fn) removes listener", () => {
    const ee = new EventEmitter();
    const fn = () => {};
    ee.on("x", fn);
    ee.off("x", fn);
    let count = 0;
    ee.on("x", () => count++);
    ee.emit("x");
    assert.strictEqual(count, 1);
  });

  it("multiple listeners for same event all run", () => {
    const ee = new EventEmitter();
    let a = 0;
    let b = 0;
    ee.on("t", () => a++);
    ee.on("t", () => b++);
    ee.emit("t");
    assert.strictEqual(a, 1);
    assert.strictEqual(b, 1);
  });

  it("emit with no args invokes listener with no args", () => {
    const ee = new EventEmitter();
    let argc = -1;
    ee.on("n", function () { argc = arguments.length; });
    ee.emit("n");
    assert.strictEqual(argc, 0);
  });

  it("emit with multiple args passes all to listener", () => {
    const ee = new EventEmitter();
    let received = [];
    ee.on("m", (a, b, c) => { received = [a, b, c]; });
    ee.emit("m", 1, "two", true);
    assert.strictEqual(received[0], 1);
    assert.strictEqual(received[1], "two");
    assert.strictEqual(received[2], true);
  });
});

describe("shu:events boundary", () => {
  it("off(name, otherFn) does not remove different listener", () => {
    const ee = new EventEmitter();
    let count = 0;
    const fn = () => count++;
    ee.on("e", fn);
    ee.off("e", () => {});
    ee.emit("e");
    assert.strictEqual(count, 1);
  });

  it("emit with no listeners returns false", () => {
    const ee = new EventEmitter();
    assert.strictEqual(ee.emit("none"), false);
  });

  it("same listener added twice is called twice unless off once", () => {
    const ee = new EventEmitter();
    let n = 0;
    const fn = () => n++;
    ee.on("d", fn);
    ee.on("d", fn);
    ee.emit("d");
    assert.strictEqual(n, 2);
    ee.off("d", fn);
    ee.emit("d");
    assert.strictEqual(n, 2);
  });
});
