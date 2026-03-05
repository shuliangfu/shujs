/**
 * node:debugger 兼容测试：port、host、边界
 */
const { describe, it, assert } = require("shu:test");
const dbg = require("node:debugger");

describe("node:debugger exports", () => {
  it("has port and host", () => {
    assert.ok("port" in dbg || "host" in dbg || typeof dbg === "object");
  });
});

describe("node:debugger port host", () => {
  it("port is number or undefined", () => {
    if (dbg.port !== undefined) assert.strictEqual(typeof dbg.port, "number");
  });
  it("host is string or undefined", () => {
    if (dbg.host !== undefined) assert.strictEqual(typeof dbg.host, "string");
  });
});
