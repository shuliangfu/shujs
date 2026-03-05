/**
 * node:tty 兼容测试：isTTY、ReadStream、WriteStream、边界
 */
const { describe, it, assert } = require("shu:test");
const tty = require("node:tty");

describe("node:tty exports", () => {
  it("has isTTY", () => {
    assert.strictEqual(typeof tty.isTTY, "function");
  });
  it("has ReadStream and WriteStream when present", () => {
    if (tty.ReadStream) assert.strictEqual(typeof tty.ReadStream, "function");
    if (tty.WriteStream) assert.strictEqual(typeof tty.WriteStream, "function");
  });
});

describe("node:tty isTTY", () => {
  it("isTTY(fd) returns boolean", () => {
    const v = tty.isTTY(1);
    assert.strictEqual(typeof v, "boolean");
  });
});

describe("node:tty boundary", () => {
  it("isTTY(0) and isTTY(2) return boolean", () => {
    assert.strictEqual(typeof tty.isTTY(0), "boolean");
    assert.strictEqual(typeof tty.isTTY(2), "boolean");
  });
});
