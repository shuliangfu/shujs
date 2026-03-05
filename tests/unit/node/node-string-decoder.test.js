/**
 * node:string_decoder 兼容测试：StringDecoder 及 write/end、边界
 */
const { describe, it, assert } = require("shu:test");
const { StringDecoder } = require("node:string_decoder");

describe("node:string_decoder exports", () => {
  it("exports StringDecoder", () => {
    assert.strictEqual(typeof StringDecoder, "function");
  });
});

describe("node:string_decoder instance", () => {
  it("new StringDecoder() creates instance", () => {
    const sd = new StringDecoder();
    assert.ok(sd != null);
    assert.strictEqual(typeof sd.write, "function");
    assert.strictEqual(typeof sd.end, "function");
  });
  it("write(Buffer) returns string", () => {
    const sd = new StringDecoder();
    const s = sd.write(Buffer.from("hello"));
    assert.strictEqual(typeof s, "string");
    assert.strictEqual(s, "hello");
  });
  it("end() returns string", () => {
    const sd = new StringDecoder();
    const s = sd.end();
    assert.strictEqual(typeof s, "string");
  });
});

describe("node:string_decoder boundary", () => {
  it("write(empty Buffer)", () => {
    const sd = new StringDecoder();
    assert.strictEqual(sd.write(Buffer.alloc(0)), "");
  });
});
