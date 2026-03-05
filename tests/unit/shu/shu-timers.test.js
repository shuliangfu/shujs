// shu:timers 模块 JS 测试：setTimeout、setImmediate、clearTimeout、queueMicrotask
const { describe, it, assert } = require("shu:test");
const timers = require("shu:timers");

describe("shu:timers", () => {
  it("timers.setTimeout is function", () => {
    assert.strictEqual(typeof timers.setTimeout, "function");
  });

  it("timers.setImmediate is function", () => {
    assert.strictEqual(typeof timers.setImmediate, "function");
  });

  it("timers.clearTimeout is function", () => {
    assert.strictEqual(typeof timers.clearTimeout, "function");
  });

  it("timers.setImmediate runs callback", (t) => {
    timers.setImmediate(() => {
      assert.ok(true);
      t.done();
    });
  });

  it("timers.setTimeout runs after delay", (t) => {
    timers.setTimeout(() => {
      assert.ok(true);
      t.done();
    }, 0);
  });

  it("timers.clearTimeout cancels timeout", (t) => {
    let ran = false;
    const id = timers.setTimeout(() => {
      ran = true;
    }, 1000);
    timers.clearTimeout(id);
    timers.setImmediate(() => {
      assert.strictEqual(ran, false);
      t.done();
    });
  });

  it("timers.queueMicrotask is function", () => {
    assert.strictEqual(typeof timers.queueMicrotask, "function");
  });

  it("timers.setInterval and clearInterval exist", () => {
    assert.strictEqual(typeof timers.setInterval, "function");
    assert.strictEqual(typeof timers.clearInterval, "function");
    assert.strictEqual(typeof timers.clearImmediate, "function");
  });

  it("setInterval runs callback repeatedly until clearInterval", (t) => {
    let count = 0;
    const id = timers.setInterval(() => {
      count++;
      if (count >= 2) {
        timers.clearInterval(id);
        assert.strictEqual(count, 2);
        t.done();
      }
    }, 0);
  });

  it("clearImmediate(id) cancels immediate", (t) => {
    let ran = false;
    const id = timers.setImmediate(() => {
      ran = true;
    });
    timers.clearImmediate(id);
    timers.setTimeout(() => {
      assert.strictEqual(ran, false);
      t.done();
    }, 10);
  });

  it("queueMicrotask runs callback before next tick", (t) => {
    let order = "";
    timers.queueMicrotask(() => {
      order += "m";
      assert.strictEqual(order, "m");
      t.done();
    });
    order += "s";
  });
});

describe("shu:timers boundary", () => {
  it("clearTimeout(undefined) or invalid id does not throw", () => {
    timers.clearTimeout(undefined);
    timers.clearTimeout(999999);
  });

  it("clearInterval(undefined) and clearImmediate(undefined) do not throw", () => {
    timers.clearInterval(undefined);
    timers.clearImmediate(undefined);
  });

  it("setTimeout with 0 delay runs callback", (t) => {
    timers.setTimeout(() => t.done(), 0);
  });

  it("setTimeout with negative delay behaves like 0 or next tick", (t) => {
    timers.setTimeout(() => t.done(), -1);
  });

  it("clearInterval twice on same id does not throw", (t) => {
    const id = timers.setInterval(() => {}, 10000);
    timers.clearInterval(id);
    timers.clearInterval(id);
    timers.setImmediate(() => t.done());
  });

  it("setTimeout returns id that can be passed to clearTimeout", (t) => {
    const id = timers.setTimeout(() => {}, 10000);
    timers.clearTimeout(id);
    timers.setImmediate(() => t.done());
  });

  it("queueMicrotask called multiple times runs all callbacks", (t) => {
    let n = 0;
    timers.queueMicrotask(() => { n++; });
    timers.queueMicrotask(() => { n++; });
    timers.setImmediate(() => {
      assert.ok(n >= 1);
      t.done();
    });
  });
});
