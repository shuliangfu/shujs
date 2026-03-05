/**
 * node:dgram 兼容测试：createSocket、边界
 */
const { describe, it, assert } = require("shu:test");
const dgram = require("node:dgram");

describe("node:dgram exports", () => {
  it("has createSocket", () => {
    assert.strictEqual(typeof dgram.createSocket, "function");
  });
});

describe("node:dgram createSocket", () => {
  it("createSocket('udp4') returns socket", () => {
    const s = dgram.createSocket("udp4");
    assert.ok(s != null);
    assert.strictEqual(typeof s.close, "function");
    s.close();
  });
});

describe("node:dgram boundary", () => {
  it("createSocket('udp6') when supported", () => {
    try {
      const s = dgram.createSocket("udp6");
      s.close();
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });
});
