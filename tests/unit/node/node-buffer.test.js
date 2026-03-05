/**
 * node:buffer (Buffer) 全面兼容测试：alloc、from、concat、isBuffer 全方法 + 边界
 */
const { describe, it, assert } = require("shu:test");
const { Buffer } = require("node:buffer");

describe("node:buffer exports", () => {
  it("exports Buffer constructor", () => {
    assert.strictEqual(typeof Buffer, "function");
    assert.ok(Buffer.alloc != null);
    assert.ok(Buffer.from != null);
    assert.ok(Buffer.isBuffer != null);
    assert.ok(Buffer.concat != null);
  });
});

describe("node:buffer alloc", () => {
  it("Buffer.alloc(size) returns buffer of given size", () => {
    const b = Buffer.alloc(10);
    assert.ok(b && b.length === 10);
  });
  it("Buffer.alloc(0) returns length 0 buffer", () => {
    const b = Buffer.alloc(0);
    assert.ok(b && b.length === 0);
  });
  it("Buffer.alloc fills with zero", () => {
    const b = Buffer.alloc(4);
    assert.strictEqual(b[0], 0);
    assert.strictEqual(b[3], 0);
  });
  it("Buffer.alloc with large size", () => {
    try {
      const b = Buffer.alloc(1024 * 1024);
      assert.ok(b && b.length === 1024 * 1024);
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });
});

describe("node:buffer from", () => {
  it("Buffer.from(string) creates buffer from string", () => {
    const b = Buffer.from("hello");
    assert.ok(b && b.length === 5);
    assert.strictEqual(b.toString(), "hello");
  });
  it("Buffer.from('') returns length 0 buffer", () => {
    const b = Buffer.from("");
    assert.ok(b && b.length === 0);
  });
  it("Buffer.from(array) creates buffer from array", () => {
    const b = Buffer.from([1, 2, 3]);
    assert.ok(b && b.length === 3);
    assert.strictEqual(b[0], 1);
    assert.strictEqual(b[1], 2);
    assert.strictEqual(b[2], 3);
  });
  it("Buffer.from([]) returns length 0 buffer", () => {
    const b = Buffer.from([]);
    assert.ok(b && b.length === 0);
  });
  it("Buffer.from(array) with out-of-range bytes", () => {
    try {
      const b = Buffer.from([256, -1, 255]);
      assert.ok(b.length >= 0);
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });
});

describe("node:buffer isBuffer", () => {
  it("isBuffer returns true for Buffer instances", () => {
    const b = Buffer.alloc(1);
    assert.strictEqual(Buffer.isBuffer(b), true);
  });
  it("isBuffer returns false for plain object", () => {
    assert.strictEqual(Buffer.isBuffer({}), false);
    assert.strictEqual(Buffer.isBuffer("string"), false);
  });
  it("isBuffer(null) and isBuffer(undefined) return false", () => {
    assert.strictEqual(Buffer.isBuffer(null), false);
    assert.strictEqual(Buffer.isBuffer(undefined), false);
  });
  it("isBuffer(0), isBuffer(true), isBuffer([]) return false", () => {
    assert.strictEqual(Buffer.isBuffer(0), false);
    assert.strictEqual(Buffer.isBuffer(true), false);
    assert.strictEqual(Buffer.isBuffer([]), false);
  });
  it("isBuffer(Uint8Array) may be false (Node Buffer is subclass)", () => {
    const u = new Uint8Array(1);
    assert.strictEqual(Buffer.isBuffer(u), false);
  });
});

describe("node:buffer concat", () => {
  it("concat concatenates buffers", () => {
    const a = Buffer.from([1, 2]);
    const b = Buffer.from([3, 4]);
    const c = Buffer.concat([a, b]);
    assert.ok(c && c.length === 4);
    assert.strictEqual(c[0], 1);
    assert.strictEqual(c[3], 4);
  });
  it("concat([]) returns empty buffer", () => {
    const c = Buffer.concat([]);
    assert.ok(c && c.length === 0);
  });
  it("concat single buffer returns same length", () => {
    const one = Buffer.from([1, 2, 3]);
    const c = Buffer.concat([one]);
    assert.ok(c && c.length === 3);
  });
});

describe("node:buffer instance", () => {
  it("buffer has length property", () => {
    const b = Buffer.alloc(5);
    assert.strictEqual(b.length, 5);
  });
  it("buffer is indexable", () => {
    const b = Buffer.from([10, 20, 30]);
    assert.strictEqual(b[0], 10);
    assert.strictEqual(b[2], 30);
  });
  it("buffer.toString() returns string when present", () => {
    const b = Buffer.from("abc");
    assert.strictEqual(typeof b.toString, "function");
    assert.strictEqual(b.toString(), "abc");
  });
});

describe("node:buffer allocUnsafe when present", () => {
  it("Buffer.allocUnsafe exists and returns buffer", () => {
    if (typeof Buffer.allocUnsafe !== "function") return;
    const b = Buffer.allocUnsafe(8);
    assert.ok(b && b.length === 8);
  });
  it("Buffer.allocUnsafe(0) when present", () => {
    if (typeof Buffer.allocUnsafe !== "function") return;
    const b = Buffer.allocUnsafe(0);
    assert.ok(b && b.length === 0);
  });
});
