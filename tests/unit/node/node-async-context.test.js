/**
 * node:async_context (shu:async_context) 兼容测试：AsyncLocalStorage、边界
 */
const { describe, it, assert } = require("shu:test");

describe("node:async_context require", () => {
  it("require('node:async_context') or async_hooks has AsyncLocalStorage when present", () => {
    let AsyncLocalStorage;
    try {
      const ctx = require("node:async_context");
      AsyncLocalStorage = ctx.AsyncLocalStorage;
    } catch (_) {
      try {
        const ah = require("node:async_hooks");
        AsyncLocalStorage = ah.AsyncLocalStorage;
      } catch (__) {}
    }
    if (AsyncLocalStorage) {
      assert.strictEqual(typeof AsyncLocalStorage, "function");
    } else {
      assert.ok(true, "AsyncLocalStorage not exposed in this runtime");
    }
  });
});

describe("node:async_context AsyncLocalStorage when present", () => {
  it("new AsyncLocalStorage() run() getStore()", () => {
    let AsyncLocalStorage;
    try {
      AsyncLocalStorage = require("node:async_context").AsyncLocalStorage;
    } catch (_) {
      return;
    }
    const storage = new AsyncLocalStorage();
    storage.run(42, () => {
      assert.strictEqual(storage.getStore(), 42);
    });
  });
});
