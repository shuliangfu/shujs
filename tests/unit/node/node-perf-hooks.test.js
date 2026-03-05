/**
 * node:perf_hooks 兼容测试：performance、PerformanceObserver、mark、measure、timerify、边界
 */
const { describe, it, assert } = require("shu:test");
const perf = require("node:perf_hooks");

describe("node:perf_hooks exports", () => {
  it("has performance and PerformanceObserver", () => {
    assert.ok(perf.performance != null);
    assert.strictEqual(typeof perf.PerformanceObserver, "function");
  });
  it("has mark measure timerify when present", () => {
    if (perf.performance.mark) assert.strictEqual(typeof perf.performance.mark, "function");
    if (perf.performance.measure) assert.strictEqual(typeof perf.performance.measure, "function");
    if (perf.performance.now) assert.strictEqual(typeof perf.performance.now, "function");
  });
});

describe("node:perf_hooks performance", () => {
  it("performance.now() returns number", () => {
    const t = perf.performance.now();
    assert.strictEqual(typeof t, "number");
    assert.ok(t >= 0);
  });
});

describe("node:perf_hooks boundary", () => {
  it("performance.timeOrigin or now is number", () => {
    const n = perf.performance.now();
    assert.ok(typeof n === "number");
  });
});
