/**
 * node:diagnostics_channel 兼容测试：channel、subscribe、publish、hasSubscribers、边界
 */
const { describe, it, assert } = require("shu:test");
const dc = require("node:diagnostics_channel");

describe("node:diagnostics_channel exports", () => {
  it("has channel subscribe publish hasSubscribers", () => {
    assert.strictEqual(typeof dc.channel, "function");
    assert.strictEqual(typeof dc.subscribe, "function");
    assert.strictEqual(typeof dc.publish, "function");
    assert.strictEqual(typeof dc.hasSubscribers, "function");
  });
});

describe("node:diagnostics_channel channel", () => {
  it("channel(name) returns channel object", () => {
    const ch = dc.channel("test-channel");
    assert.ok(ch != null);
    assert.strictEqual(typeof ch.subscribe, "function");
    assert.strictEqual(typeof ch.publish, "function");
  });
  it("channel subscribe and publish", () => {
    const ch = dc.channel("test-pub-" + Date.now());
    let received = null;
    ch.subscribe((msg) => { received = msg; });
    ch.publish("hello");
    assert.strictEqual(received, "hello");
  });
});

describe("node:diagnostics_channel boundary", () => {
  it("channel('') returns channel", () => {
    const ch = dc.channel("");
    assert.ok(ch != null);
  });
});
