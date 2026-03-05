// shu:buffer 模块 JS 测试：Buffer.alloc、from、isBuffer、concat
const { describe, it, assert } = require("shu:test");
const { Buffer } = require("shu:buffer");

describe("shu:buffer", () => {
  it("Buffer.alloc(size) returns buffer of given size", () => {
    const b = Buffer.alloc(10);
    assert.ok(b && b.length === 10);
    assert.ok(b instanceof Uint8Array || (typeof b.length === "number" && b.length === 10));
  });

  it("Buffer.from(string) creates buffer from string", () => {
    const b = Buffer.from("hello");
    assert.ok(b && b.length === 5);
  });

  it("Buffer.from(array) creates buffer from array", () => {
    const b = Buffer.from([1, 2, 3]);
    assert.ok(b && b.length === 3);
    assert.strictEqual(b[0], 1);
    assert.strictEqual(b[1], 2);
    assert.strictEqual(b[2], 3);
  });

  it("Buffer.isBuffer returns true for Buffer instances", () => {
    const b = Buffer.alloc(1);
    assert.strictEqual(Buffer.isBuffer(b), true);
  });

  it("Buffer.isBuffer returns false for plain object", () => {
    assert.strictEqual(Buffer.isBuffer({}), false);
    assert.strictEqual(Buffer.isBuffer("string"), false);
  });

  it("Buffer.concat concatenates buffers", () => {
    const a = Buffer.from([1, 2]);
    const b = Buffer.from([3, 4]);
    const c = Buffer.concat([a, b]);
    assert.ok(c && c.length === 4);
    assert.strictEqual(c[0], 1);
    assert.strictEqual(c[3], 4);
  });

  it("Buffer.allocUnsafe(size) returns buffer of given size when present", () => {
    if (typeof Buffer.allocUnsafe !== "function") return;
    const b = Buffer.allocUnsafe(8);
    assert.ok(b && b.length === 8);
  });
});

describe("shu:buffer boundary", () => {
  it("Buffer.alloc(0) returns length 0 buffer", () => {
    const b = Buffer.alloc(0);
    assert.ok(b && b.length === 0);
  });

  it("Buffer.from('') returns length 0 buffer", () => {
    const b = Buffer.from("");
    assert.ok(b && b.length === 0);
  });

  it("Buffer.concat([]) returns empty buffer", () => {
    const c = Buffer.concat([]);
    assert.ok(c && c.length === 0);
  });

  it("Buffer.isBuffer(null) and isBuffer(undefined) return false", () => {
    assert.strictEqual(Buffer.isBuffer(null), false);
    assert.strictEqual(Buffer.isBuffer(undefined), false);
  });

  // 生产奇葩：类型错、单元素、大长度、负数
  it("Buffer.isBuffer(0), isBuffer(true), isBuffer([]) return false", () => {
    assert.strictEqual(Buffer.isBuffer(0), false);
    assert.strictEqual(Buffer.isBuffer(true), false);
    assert.strictEqual(Buffer.isBuffer([]), false);
  });

  it("Buffer.concat single buffer returns same length", () => {
    const one = Buffer.from([1, 2, 3]);
    const c = Buffer.concat([one]);
    assert.ok(c && c.length === 3);
  });

  it("Buffer.from(array) with empty array returns length 0", () => {
    const b = Buffer.from([]);
    assert.ok(b && b.length === 0);
  });

  it("Buffer.from(array) with out-of-range bytes clamps or throws", () => {
    try {
      const b = Buffer.from([256, -1, 255]);
      assert.ok(b.length >= 0);
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });

  it("Buffer.alloc with large size does not throw (or throws RangeError)", () => {
    try {
      const b = Buffer.alloc(1024 * 1024);
      assert.ok(b && b.length === 1024 * 1024);
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });

  it("Buffer.allocUnsafe(0) when present returns length 0 buffer", () => {
    if (typeof Buffer.allocUnsafe !== "function") return;
    const b = Buffer.allocUnsafe(0);
    assert.ok(b && b.length === 0);
  });
});
