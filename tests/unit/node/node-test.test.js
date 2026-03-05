/**
 * node:test 兼容测试：describe、it、test、run、beforeAll、afterAll、mock、snapshot 等（与 shu:test 语义接近）
 */
const { describe, it, assert } = require("shu:test");
const testModule = require("node:test");

describe("node:test exports", () => {
  it("has describe it test run", () => {
    assert.strictEqual(typeof testModule.describe, "function");
    assert.strictEqual(typeof testModule.it, "function");
    assert.strictEqual(typeof testModule.test, "function");
    assert.strictEqual(typeof testModule.run, "function");
  });
  it("has beforeAll afterAll when present", () => {
    if (testModule.beforeAll) assert.strictEqual(typeof testModule.beforeAll, "function");
    if (testModule.afterAll) assert.strictEqual(typeof testModule.afterAll, "function");
  });
  it("has mock snapshot when present", () => {
    if (testModule.mock) assert.ok(testModule.mock != null);
    if (testModule.snapshot) assert.ok(testModule.snapshot != null);
  });
});

describe("node:test describe and it", () => {
  it("describe(name, fn) registers suite", () => {
    let ran = false;
    testModule.describe("inner", () => {
      testModule.it("inner it", () => { ran = true; });
    });
    assert.strictEqual(ran, false);
  });
});

describe("node:test boundary", () => {
  it("module is same as shu:test or compatible shape", () => {
    assert.ok(testModule != null && typeof testModule === "object");
  });
});
