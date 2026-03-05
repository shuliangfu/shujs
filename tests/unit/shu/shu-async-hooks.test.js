// shu:async_hooks 模块测试（executionAsyncId/triggerAsyncId/createHook/AsyncResource）
const { describe, it, assert } = require("shu:test");

const asyncHooks = require("shu:async_hooks");

describe("shu:async_hooks", () => {
  it("has executionAsyncId and triggerAsyncId", () => {
    assert.strictEqual(typeof asyncHooks.executionAsyncId, "function");
    assert.strictEqual(typeof asyncHooks.triggerAsyncId, "function");
  });

  it("executionAsyncId() returns number", () => {
    const id = asyncHooks.executionAsyncId();
    assert.strictEqual(typeof id, "number");
  });

  it("has createHook", () => {
    assert.strictEqual(typeof asyncHooks.createHook, "function");
    const hook = asyncHooks.createHook({});
    assert.ok(hook && typeof hook === "object");
    assert.strictEqual(typeof hook.enable, "function");
    assert.strictEqual(typeof hook.disable, "function");
  });

  it("has AsyncResource", () => {
    assert.ok("AsyncResource" in asyncHooks);
    assert.strictEqual(typeof asyncHooks.AsyncResource, "function");
  });
});
