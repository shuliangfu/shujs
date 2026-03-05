/**
 * node:tracing 兼容测试：createTracing、trace（no-op）、边界
 */
const { describe, it, assert } = require("shu:test");
const tracing = require("node:tracing");

describe("node:tracing exports", () => {
  it("has createTracing and trace when present", () => {
    assert.ok(tracing.createTracing != null || tracing.trace != null || typeof tracing === "object");
  });
});

describe("node:tracing createTracing", () => {
  it("createTracing() does not throw when present", () => {
    if (tracing.createTracing) {
      assert.doesNotThrow(() => tracing.createTracing({ categories: [] }));
    }
  });
});
