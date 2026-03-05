/**
 * node:timers 全面兼容测试：setTimeout、setInterval、setImmediate、clearTimeout、clearInterval、queueMicrotask 全方法 + 边界
 */
const { describe, it, assert } = require("shu:test");
const timers = require("node:timers");

describe("node:timers exports", () => {
  it("has setTimeout, setInterval, setImmediate, clearTimeout, clearInterval, queueMicrotask", () => {
    assert.strictEqual(typeof timers.setTimeout, "function");
    assert.strictEqual(typeof timers.setInterval, "function");
    assert.strictEqual(typeof timers.setImmediate, "function");
    assert.strictEqual(typeof timers.clearTimeout, "function");
    assert.strictEqual(typeof timers.clearInterval, "function");
    assert.strictEqual(typeof timers.queueMicrotask, "function");
  });
});

describe("node:timers setTimeout", () => {
  it("setTimeout(fn, 0) runs callback", (done) => {
    timers.setTimeout(() => { done(); }, 0);
  });
  it("setTimeout returns id (number or object)", () => {
    const id = timers.setTimeout(() => {}, 1);
    assert.ok(id != null);
  });
  it("clearTimeout(id) cancels", (done) => {
    const id = timers.setTimeout(() => { done(new Error("should not run")); }, 1000);
    timers.clearTimeout(id);
    timers.setTimeout(() => { done(); }, 10);
  });
});

describe("node:timers setInterval", () => {
  it("setInterval returns id", () => {
    const id = timers.setInterval(() => {}, 100);
    assert.ok(id != null);
    timers.clearInterval(id);
  });
  it("clearInterval stops repeat", (done) => {
    let count = 0;
    const id = timers.setInterval(() => {
      count++;
      if (count >= 2) {
        timers.clearInterval(id);
        done();
      }
    }, 5);
  });
});

describe("node:timers setImmediate", () => {
  it("setImmediate(fn) runs callback", (done) => {
    timers.setImmediate(() => { done(); });
  });
  it("setImmediate returns id", () => {
    const id = timers.setImmediate(() => {});
    assert.ok(id != null);
  });
});

describe("node:timers queueMicrotask", () => {
  it("queueMicrotask(fn) runs callback", (done) => {
    timers.queueMicrotask(() => { done(); });
  });
  it("queueMicrotask runs before setTimeout(0)", (done) => {
    const order = [];
    timers.setTimeout(() => {
      order.push("timeout");
      assert.deepStrictEqual(order, ["micro", "timeout"]);
      done();
    }, 0);
    timers.queueMicrotask(() => { order.push("micro"); });
  });
});

describe("node:timers boundary", () => {
  it("setTimeout(fn, 0) with clearTimeout immediately", () => {
    const id = timers.setTimeout(() => {}, 0);
    timers.clearTimeout(id);
  });
  it("clearTimeout(undefined) does not throw", () => {
    timers.clearTimeout(undefined);
  });
  it("clearInterval(undefined) does not throw", () => {
    timers.clearInterval(undefined);
  });
});
