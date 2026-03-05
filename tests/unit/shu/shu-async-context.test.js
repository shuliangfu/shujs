// shu:async_context 模块测试（AsyncLocalStorage）
const { describe, it, assert } = require("shu:test");

const asyncContext = require("shu:async_context");

describe("shu:async_context", () => {
  it("has AsyncLocalStorage", () => {
    assert.ok("AsyncLocalStorage" in asyncContext);
    assert.strictEqual(typeof asyncContext.AsyncLocalStorage, "function");
  });

  it("new AsyncLocalStorage() has run and getStore", () => {
    const als = new asyncContext.AsyncLocalStorage();
    assert.strictEqual(typeof als.run, "function");
    assert.strictEqual(typeof als.getStore, "function");
  });
});

describe("shu:async_context boundary", () => {
  it("getStore() without run returns undefined", () => {
    const asyncContext = require("shu:async_context");
    const als = new asyncContext.AsyncLocalStorage();
    assert.strictEqual(als.getStore(), undefined);
  });
});
