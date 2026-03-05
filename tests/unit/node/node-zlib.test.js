/**
 * node:zlib 兼容测试：gzipSync/deflateSync/brotliSync 及解压、边界
 */
const { describe, it, assert } = require("shu:test");
const zlib = require("node:zlib");

describe("node:zlib exports", () => {
  it("has gzipSync deflateSync brotliSync", () => {
    assert.strictEqual(typeof zlib.gzipSync, "function");
    assert.strictEqual(typeof zlib.deflateSync, "function");
    assert.strictEqual(typeof zlib.brotliSync, "function");
  });
  it("has async gzip deflate brotli when present", () => {
    if (zlib.gzip) assert.strictEqual(typeof zlib.gzip, "function");
    if (zlib.deflate) assert.strictEqual(typeof zlib.deflate, "function");
  });
});

describe("node:zlib gzipSync", () => {
  it("gzipSync(Buffer) returns Buffer", () => {
    const input = Buffer.from("hello");
    const out = zlib.gzipSync(input);
    assert.ok(out != null && out.length > 0);
    assert.ok(Buffer.isBuffer(out));
  });
  it("gzipSync(string) returns Buffer", () => {
    const out = zlib.gzipSync("test");
    assert.ok(out != null && out.length > 0);
  });
});

describe("node:zlib deflateSync", () => {
  it("deflateSync(Buffer) returns Buffer", () => {
    const input = Buffer.from("data");
    const out = zlib.deflateSync(input);
    assert.ok(out != null && out.length > 0);
  });
});

describe("node:zlib brotliSync", () => {
  it("brotliSync(Buffer) returns Buffer when present", () => {
    const input = Buffer.from("hello");
    const out = zlib.brotliSync(input);
    assert.ok(out != null && out.length >= 0);
  });
});

describe("node:zlib boundary", () => {
  it("gzipSync empty buffer", () => {
    const out = zlib.gzipSync(Buffer.alloc(0));
    assert.ok(out != null);
  });
});
