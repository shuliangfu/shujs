/**
 * node:report 兼容测试：getReport、writeReport、边界
 */
const { describe, it, assert } = require("shu:test");
const report = require("node:report");

describe("node:report exports", () => {
  it("has getReport and writeReport", () => {
    assert.strictEqual(typeof report.getReport, "function");
    assert.strictEqual(typeof report.writeReport, "function");
  });
});

describe("node:report getReport", () => {
  it("getReport() returns report object with header", () => {
    const r = report.getReport();
    assert.ok(r != null);
    assert.strictEqual(typeof r, "object");
    assert.ok(r.header && typeof r.header === "object");
    assert.ok(typeof r.header.event === "string");
    assert.strictEqual(r.header.cwd, ".");
    assert.ok(typeof r.header.entryPoint === "string");
    assert.strictEqual(r.header.entryPoint.startsWith("/"), false);
  });
});

describe("node:report boundary", () => {
  it("writeReport() does not throw when present", () => {
    if (report.writeReport) {
      assert.doesNotThrow(() => report.writeReport());
    }
  });
});
