// shu:threads 模块测试（thread.spawn、isMainThread、parentPort、workerData）
// 约定：新增 API 时补一条正常用例 + 一条边界用例。
const { describe, it, assert } = require("shu:test");

const threads = require("shu:threads");

describe("shu:threads", () => {
  it("has thread object with spawn", () => {
    assert.ok(threads.thread && typeof threads.thread === "object");
    assert.strictEqual(typeof threads.thread.spawn, "function");
  });

  it("has isMainThread boolean", () => {
    assert.strictEqual(typeof threads.isMainThread, "boolean");
    assert.strictEqual(threads.isMainThread, true);
  });

  it("has parentPort and workerData (null or object when main)", () => {
    assert.ok("parentPort" in threads);
    assert.ok("workerData" in threads);
  });

  it("boundary: thread.spawn(non-existent path) returns undefined or worker", () => {
    const w = threads.thread.spawn("/nonexistent/shu-threads-test-" + Date.now());
    if (w !== undefined) {
      assert.ok(w && typeof w === "object");
      if (typeof w.join === "function") w.join();
    }
  });
});
