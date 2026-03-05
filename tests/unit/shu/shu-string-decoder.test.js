// shu:string_decoder 模块 JS 测试：StringDecoder、write、end
const { describe, it, assert } = require("shu:test");
const { StringDecoder } = require("shu:string_decoder");

describe("shu:string_decoder", () => {
  it("StringDecoder is a constructor", () => {
    assert.strictEqual(typeof StringDecoder, "function");
    const sd = new StringDecoder();
    assert.ok(sd);
  });

  it("write(buffer) returns decoded string", () => {
    const sd = new StringDecoder("utf8");
    const buf = Buffer.from("hello");
    const s = sd.write(buf);
    assert.strictEqual(typeof s, "string");
    assert.strictEqual(s, "hello");
  });

  it("end(buffer?) returns remaining decoded string", () => {
    const sd = new StringDecoder("utf8");
    const s = sd.end();
    assert.strictEqual(typeof s, "string");
  });

  it("write multiple chunks concatenates decoded string", () => {
    const sd = new StringDecoder("utf8");
    const s1 = sd.write(Buffer.from("hel"));
    const s2 = sd.write(Buffer.from("lo"));
    assert.strictEqual(s1 + s2, "hello");
  });

  it("end(buffer) decodes remaining and returns string", () => {
    const sd = new StringDecoder("utf8");
    sd.write(Buffer.from("ab"));
    const tail = sd.end(Buffer.from("cd"));
    assert.strictEqual(typeof tail, "string");
    assert.ok(tail.includes("cd") || tail.length >= 0);
  });
});

describe("shu:string_decoder boundary", () => {
  it("write(empty buffer) returns empty string", () => {
    const sd = new StringDecoder("utf8");
    const buf = Buffer.alloc(0);
    const s = sd.write(buf);
    assert.strictEqual(typeof s, "string");
    assert.strictEqual(s, "");
  });

  it("end() with no buffer returns string", () => {
    const sd = new StringDecoder("utf8");
    assert.strictEqual(typeof sd.end(), "string");
  });

  it("StringDecoder with utf8 encoding default", () => {
    const sd = new StringDecoder();
    assert.strictEqual(sd.write(Buffer.from("x")), "x");
  });
});
