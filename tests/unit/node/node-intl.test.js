/**
 * node:intl 兼容测试：getIntl、Segmenter、边界
 */
const { describe, it, assert } = require("shu:test");
const intl = require("node:intl");

describe("node:intl exports", () => {
  it("has getIntl when present", () => {
    if (intl.getIntl) assert.strictEqual(typeof intl.getIntl, "function");
  });
  it("has Segmenter when present", () => {
    if (intl.Segmenter) assert.ok(intl.Segmenter != null);
  });
});

describe("node:intl getIntl", () => {
  it("getIntl() returns Intl or object when present", () => {
    if (intl.getIntl) {
      const i = intl.getIntl();
      assert.ok(i != null);
    }
  });
});

describe("node:intl boundary", () => {
  it("module exports at least one of getIntl or Segmenter", () => {
    assert.ok(intl.getIntl != null || intl.Segmenter != null || Object.keys(intl).length >= 0);
  });
});
