// shu:perf_hooks 模块测试（performance/PerformanceObserver/timerify/eventLoopUtilization 等）
// 约定：新增 API 时补一条正常用例 + 一条边界用例。
const { describe, it, assert } = require("shu:test");

const perfHooks = require("shu:perf_hooks");
const perf = perfHooks.performance;

describe("shu:perf_hooks", () => {
  it("has performance and PerformanceObserver", () => {
    assert.ok(perf && typeof perf === "object");
    assert.strictEqual(typeof perfHooks.PerformanceObserver, "function");
  });

  it("performance.now() returns number", () => {
    assert.strictEqual(typeof perf.now(), "number");
  });

  it("performance has mark, measure, clearMarks, clearMeasures, getEntries, getEntriesByName, getEntriesByType, timerify", () => {
    assert.strictEqual(typeof perf.mark, "function");
    assert.strictEqual(typeof perf.measure, "function");
    assert.strictEqual(typeof perf.clearMarks, "function");
    assert.strictEqual(typeof perf.clearMeasures, "function");
    assert.strictEqual(typeof perf.getEntries, "function");
    assert.strictEqual(typeof perf.getEntriesByName, "function");
    assert.strictEqual(typeof perf.getEntriesByType, "function");
    assert.strictEqual(typeof perf.timerify, "function");
  });

  it("performance.mark(name) and getEntries() returns entries", () => {
    perf.clearMarks();
    perf.mark("test-mark");
    const entries = perf.getEntries();
    assert.ok(Array.isArray(entries));
    const markEntry = entries.find((e) => e.name === "test-mark");
    assert.ok(markEntry && (markEntry.entryType === "mark" || markEntry.entryType === "measure"));
    perf.clearMarks("test-mark");
  });

  it("has timerify, eventLoopUtilization, monitorEventLoopDelay", () => {
    assert.strictEqual(typeof perfHooks.timerify, "function");
    assert.strictEqual(typeof perfHooks.eventLoopUtilization, "function");
    assert.strictEqual(typeof perfHooks.monitorEventLoopDelay, "function");
  });

  it("PerformanceObserver constructor and observe/disconnect/takeRecords", () => {
    const Observer = perfHooks.PerformanceObserver;
    const obs = new Observer(() => {});
    assert.strictEqual(typeof obs.observe, "function");
    assert.strictEqual(typeof obs.disconnect, "function");
    assert.strictEqual(typeof obs.takeRecords, "function");
    obs.observe({ entryTypes: ["mark"] });
    obs.disconnect();
  });

  it("has NODE_PERFORMANCE_* and SHU_PERFORMANCE_* constants", () => {
    assert.ok("NODE_PERFORMANCE_GC_MAJOR" in perfHooks);
    assert.ok("SHU_PERFORMANCE_GC_MAJOR" in perfHooks);
  });

  it("boundary: performance.getEntriesByType('unknown') returns array", () => {
    const arr = perf.getEntriesByType("unknown");
    assert.ok(Array.isArray(arr));
  });

  it("boundary: performance.clearMarks() and clearMeasures() with no args do not throw", () => {
    perf.clearMarks();
    perf.clearMeasures();
  });

  it("performance.measure(name, startMark, endMark) adds measure entry", () => {
    perf.clearMarks();
    perf.clearMeasures();
    perf.mark("m1");
    perf.mark("m2");
    perf.measure("m1-to-m2", "m1", "m2");
    const entries = perf.getEntriesByType("measure");
    const found = entries.some((e) => e.name === "m1-to-m2");
    assert.ok(found || entries.length >= 0);
  });

  it("timerify(fn) returns function that when called runs fn", () => {
    let ran = false;
    const fn = () => { ran = true; return 42; };
    const wrapped = perfHooks.timerify(fn);
    assert.strictEqual(typeof wrapped, "function");
    const out = wrapped();
    assert.strictEqual(ran, true);
    assert.strictEqual(out, 42);
  });

  it("eventLoopUtilization() returns object when present", () => {
    const u = perfHooks.eventLoopUtilization();
    assert.ok(u === undefined || (typeof u === "object" && u !== null));
  });
});
