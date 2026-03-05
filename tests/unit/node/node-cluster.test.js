/**
 * node:cluster 兼容测试：isPrimary、workers、setupPrimary、disconnect、边界
 */
const { describe, it, assert } = require("shu:test");
const cluster = require("node:cluster");

describe("node:cluster exports", () => {
  it("has isPrimary or isMaster and workers", () => {
    assert.ok("isPrimary" in cluster || "isMaster" in cluster);
    assert.ok(cluster.workers != null && typeof cluster.workers === "object");
  });
  it("has setupPrimary or setupMaster and disconnect when present", () => {
    if (cluster.setupPrimary) assert.strictEqual(typeof cluster.setupPrimary, "function");
    if (cluster.setupMaster) assert.strictEqual(typeof cluster.setupMaster, "function");
    if (cluster.disconnect) assert.strictEqual(typeof cluster.disconnect, "function");
  });
});

describe("node:cluster isPrimary", () => {
  it("cluster.isPrimary is boolean", () => {
    const v = cluster.isPrimary != null ? cluster.isPrimary : cluster.isMaster;
    assert.strictEqual(typeof v, "boolean");
  });
});

describe("node:cluster boundary", () => {
  it("cluster.workers is object", () => {
    assert.ok(cluster.workers != null && typeof cluster.workers === "object");
  });
});
