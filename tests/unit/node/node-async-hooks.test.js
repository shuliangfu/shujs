/**
 * node:async_hooks 兼容测试：executionAsyncId、triggerAsyncId、createHook、AsyncResource、边界
 */
const { describe, it, assert } = require("shu:test");
const async_hooks = require("node:async_hooks");

describe("node:async_hooks exports", () => {
  it("has executionAsyncId triggerAsyncId createHook AsyncResource", () => {
    assert.strictEqual(typeof async_hooks.executionAsyncId, "function");
    assert.strictEqual(typeof async_hooks.triggerAsyncId, "function");
    assert.strictEqual(typeof async_hooks.createHook, "function");
    assert.strictEqual(typeof async_hooks.AsyncResource, "function");
  });
});

describe("node:async_hooks executionAsyncId triggerAsyncId", () => {
  it("executionAsyncId() returns number", () => {
    const id = async_hooks.executionAsyncId();
    assert.strictEqual(typeof id, "number");
  });
  it("triggerAsyncId() returns number", () => {
    const id = async_hooks.triggerAsyncId();
    assert.strictEqual(typeof id, "number");
  });
});

describe("node:async_hooks createHook", () => {
  it("createHook({}) returns hook with enable disable", () => {
    const hook = async_hooks.createHook({});
    assert.ok(hook != null);
    assert.strictEqual(typeof hook.enable, "function");
    assert.strictEqual(typeof hook.disable, "function");
  });
});

describe("node:async_hooks AsyncResource", () => {
  it("new AsyncResource(type) creates resource", () => {
    const r = new async_hooks.AsyncResource("test");
    assert.ok(r != null);
  });
});

describe("node:async_hooks boundary", () => {
  it("executionAsyncId in setTimeout callback", (done) => {
    setTimeout(() => {
      const id = async_hooks.executionAsyncId();
      assert.strictEqual(typeof id, "number");
      done();
    }, 0);
  });
});
