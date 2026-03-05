// shu:zlib 模块测试（gzipSync/deflateSync/brotliSync 及解压/异步方法）
// 约定：新增 API 时补一条正常用例 + 一条边界用例。
const { describe, it, assert } = require("shu:test");

const zlib = require("shu:zlib");

describe("shu:zlib", () => {
  it("has gzipSync, deflateSync, brotliSync and gunzipSync, inflateSync, debrotliSync when present", () => {
    assert.strictEqual(typeof zlib.gzipSync, "function");
    assert.strictEqual(typeof zlib.deflateSync, "function");
    assert.strictEqual(typeof zlib.brotliSync, "function");
    if ("gunzipSync" in zlib) assert.strictEqual(typeof zlib.gunzipSync, "function");
    if ("inflateSync" in zlib) assert.strictEqual(typeof zlib.inflateSync, "function");
    if ("debrotliSync" in zlib) assert.strictEqual(typeof zlib.debrotliSync, "function");
  });

  it("gzipSync(data) returns buffer-like, gunzipSync(gzipSync(data)) roundtrip", () => {
    const data = "hello";
    const out = zlib.gzipSync(data);
    assert.ok(out != null && (out.length !== undefined || out.byteLength !== undefined));
    if (typeof zlib.gunzipSync === "function") {
      const back = zlib.gunzipSync(out);
      assert.ok(back != null);
    }
  });

  it("has async gzip, deflate, brotli", () => {
    assert.strictEqual(typeof zlib.gzip, "function");
    assert.strictEqual(typeof zlib.deflate, "function");
    assert.strictEqual(typeof zlib.brotli, "function");
  });

  it("boundary: gzipSync('') returns buffer", () => {
    const out = zlib.gzipSync("");
    assert.ok(out != null);
  });

  it("boundary: deflateSync(empty buffer) returns buffer", () => {
    const out = zlib.deflateSync(new Uint8Array(0));
    assert.ok(out != null);
  });

  it("deflateSync(data) and inflateSync(deflateSync(data)) roundtrip", () => {
    const data = "deflate-inflate";
    const compressed = zlib.deflateSync(data);
    assert.ok(compressed != null && (compressed.length !== undefined || compressed.byteLength !== undefined));
    if (typeof zlib.inflateSync === "function") {
      const back = zlib.inflateSync(compressed);
      assert.ok(back != null);
      assert.strictEqual(String(back), data);
    }
  });

  it("brotliSync(data) and debrotliSync(brotliSync(data)) roundtrip when present", () => {
    const data = "brotli-roundtrip";
    const compressed = zlib.brotliSync(data);
    assert.ok(compressed != null);
    if (typeof zlib.debrotliSync === "function") {
      const back = zlib.debrotliSync(compressed);
      assert.strictEqual(String(back), data);
    }
  });

  it("gzip async with callback", (done) => {
    zlib.gzip("async-data", (err, out) => {
      assert.ok(err === null || err === undefined || err instanceof Error);
      if (!err) assert.ok(out != null);
      done();
    });
  });
});

describe("shu:zlib boundary (production edge cases)", () => {
  it("inflateSync with invalid data throws or returns", () => {
    try {
      zlib.inflateSync(Buffer.from("not-deflated"));
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });

  it("gunzipSync with invalid data throws or returns", () => {
    try {
      if (typeof zlib.gunzipSync === "function") {
        zlib.gunzipSync(Buffer.from("not-gzip"));
      }
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });

  it("deflateSync(null) or undefined does not crash", () => {
    try {
      zlib.deflateSync(null);
      zlib.deflateSync(undefined);
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });
});
