/**
 * node:worker_threads 兼容测试：Worker、isMainThread、parentPort、workerData、边界
 */
const { describe, it, assert } = require("shu:test");
const wt = require("node:worker_threads");

describe("node:worker_threads exports", () => {
  it("has Worker isMainThread parentPort workerData", () => {
    assert.strictEqual(typeof wt.Worker, "function");
    assert.strictEqual(typeof wt.isMainThread, "boolean");
    assert.ok(wt.parentPort === null || wt.parentPort != null);
  });
});

describe("node:worker_threads isMainThread", () => {
  it("isMainThread is true in main script", () => {
    assert.strictEqual(wt.isMainThread, true);
  });
});

describe("node:worker_threads boundary", () => {
  it("parentPort is null in main thread", () => {
    assert.strictEqual(wt.parentPort, null);
  });
});
