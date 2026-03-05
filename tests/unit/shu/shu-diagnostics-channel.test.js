// shu:diagnostics_channel 模块 JS 测试：channel、subscribe、unsubscribe、hasSubscribers
const { describe, it, assert } = require("shu:test");
const dc = require("shu:diagnostics_channel");

describe("shu:diagnostics_channel", () => {
  it("channel(name) returns channel object", () => {
    const ch = dc.channel("test");
    assert.ok(ch && typeof ch === "object");
  });

  it("channel has subscribe and publish", () => {
    const ch = dc.channel("test-sub");
    assert.strictEqual(typeof ch.subscribe, "function");
    assert.strictEqual(typeof ch.publish, "function");
  });

  it("channel(name).subscribe(fn) and channel(name).publish(msg) call subscriber", () => {
    const ch = dc.channel("dc1");
    let received = null;
    ch.subscribe((msg) => {
      received = msg;
    });
    ch.publish({ x: 1 });
    assert.ok(received && received.x === 1);
  });

  it("hasSubscribers(name) returns boolean", () => {
    const name = "dc-has-" + Date.now();
    assert.strictEqual(dc.hasSubscribers(name), false);
    const ch = dc.channel(name);
    ch.subscribe(() => {});
    assert.strictEqual(dc.hasSubscribers(name), true);
  });

  it("channel has unsubscribe", () => {
    const ch = dc.channel("dc-unsub");
    assert.strictEqual(typeof ch.unsubscribe, "function");
  });

  it("unsubscribe removes listener", () => {
    const ch = dc.channel("dc-unsub2");
    let count = 0;
    const fn = () => count++;
    ch.subscribe(fn);
    ch.publish({});
    assert.strictEqual(count, 1);
    ch.unsubscribe(fn);
    ch.publish({});
    assert.strictEqual(count, 1);
  });
});

describe("shu:diagnostics_channel boundary", () => {
  it("publish with no subscribers does not throw", () => {
    const ch = dc.channel("dc-nosub-" + Date.now());
    ch.publish({});
  });
});
