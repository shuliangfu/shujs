/**
 * node:inspector 兼容测试：open、close、url（占位）、边界
 */
const { describe, it, assert } = require("shu:test");
const inspector = require("node:inspector");

describe("node:inspector exports", () => {
  it("has open close url", () => {
    assert.strictEqual(typeof inspector.open, "function");
    assert.strictEqual(typeof inspector.close, "function");
    assert.strictEqual(typeof inspector.url, "function");
  });
});

describe("node:inspector open close url", () => {
  it("open() and close() do not throw", () => {
    assert.doesNotThrow(() => inspector.open());
    assert.doesNotThrow(() => inspector.close());
  });
  it("url() returns string or undefined", () => {
    const u = inspector.url();
    assert.ok(u === undefined || typeof u === "string");
  });
});
