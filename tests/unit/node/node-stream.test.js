/**
 * node:stream 兼容测试：Readable/Writable/Duplex/Transform/PassThrough、pipeline、finished、边界
 */
const { describe, it, assert } = require("shu:test");
const stream = require("node:stream");

describe("node:stream exports", () => {
  it("has Readable Writable Duplex Transform PassThrough", () => {
    assert.strictEqual(typeof stream.Readable, "function");
    assert.strictEqual(typeof stream.Writable, "function");
    assert.strictEqual(typeof stream.Duplex, "function");
    assert.strictEqual(typeof stream.Transform, "function");
    assert.strictEqual(typeof stream.PassThrough, "function");
  });
  it("has pipeline and finished", () => {
    assert.strictEqual(typeof stream.pipeline, "function");
    assert.strictEqual(typeof stream.finished, "function");
  });
});

describe("node:stream Readable", () => {
  it("new Readable() has push and read", () => {
    const r = new stream.Readable();
    assert.strictEqual(typeof r.push, "function");
    assert.strictEqual(typeof r.read, "function");
  });
  it("push(chunk) then read() returns chunk", () => {
    const r = new stream.Readable();
    r.push("a");
    r.push(null);
    const out = r.read();
    assert.ok(out === "a" || (out && out.toString && out.toString() === "a"));
  });
});

describe("node:stream Writable", () => {
  it("new Writable() has write and end", () => {
    const w = new stream.Writable();
    assert.strictEqual(typeof w.write, "function");
    assert.strictEqual(typeof w.end, "function");
  });
});

describe("node:stream boundary", () => {
  it("Readable push(null) then read()", () => {
    const r = new stream.Readable();
    r.push(null);
    assert.ok(r.read() === null || r.read() === undefined);
  });
});
