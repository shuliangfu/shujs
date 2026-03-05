/**
 * node:permissions 兼容测试：has、request、边界
 */
const { describe, it, assert } = require("shu:test");
const permissions = require("node:permissions");

describe("node:permissions exports", () => {
  it("has has and request", () => {
    assert.strictEqual(typeof permissions.has, "function");
    assert.strictEqual(typeof permissions.request, "function");
  });
});

describe("node:permissions has", () => {
  it("has(permission) returns boolean or Promise", () => {
    const r = permissions.has("fs.read");
    assert.ok(typeof r === "boolean" || (r != null && typeof r.then === "function"));
  });
});

describe("node:permissions boundary", () => {
  it("request(permission) returns Promise when present", () => {
    const p = permissions.request("fs.read");
    assert.ok(p == null || typeof p.then === "function");
  });
});
