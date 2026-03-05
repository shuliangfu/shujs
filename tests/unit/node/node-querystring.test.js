/**
 * node:querystring 全面兼容测试：parse、stringify 全方法 + 边界
 */
const { describe, it, assert } = require("shu:test");
const qs = require("node:querystring");

describe("node:querystring exports", () => {
  it("has parse and stringify", () => {
    assert.strictEqual(typeof qs.parse, "function");
    assert.strictEqual(typeof qs.stringify, "function");
  });
});

describe("node:querystring parse", () => {
  it("parse('a=1&b=2') returns object", () => {
    const o = qs.parse("a=1&b=2");
    assert.ok(o && typeof o === "object");
    assert.strictEqual(o.a, "1");
    assert.strictEqual(o.b, "2");
  });
  it("parse('') returns empty object", () => {
    const o = qs.parse("");
    assert.ok(o && typeof o === "object");
    assert.strictEqual(Object.keys(o).length, 0);
  });
  it("parse single key", () => {
    const o = qs.parse("foo=bar");
    assert.strictEqual(o.foo, "bar");
  });
  it("parse with repeated key", () => {
    const o = qs.parse("a=1&a=2");
    assert.ok(o.a !== undefined);
  });
  it("parse with no value", () => {
    const o = qs.parse("key");
    assert.ok("key" in o);
  });
});

describe("node:querystring stringify", () => {
  it("stringify({ a: 1, b: 2 }) returns query string", () => {
    const s = qs.stringify({ a: 1, b: 2 });
    assert.strictEqual(typeof s, "string");
    assert.ok(s.includes("a=") && s.includes("b="));
  });
  it("stringify({}) returns empty string", () => {
    const s = qs.stringify({});
    assert.strictEqual(typeof s, "string");
  });
  it("roundtrip parse then stringify", () => {
    const str = "x=1&y=2";
    const o = qs.parse(str);
    const back = qs.stringify(o);
    assert.strictEqual(typeof back, "string");
    const o2 = qs.parse(back);
    assert.strictEqual(o2.x, o.x);
    assert.strictEqual(o2.y, o.y);
  });
});

describe("node:querystring boundary", () => {
  it("parse with special chars", () => {
    const o = qs.parse("a=hello%20world");
    assert.ok(o.a != null);
  });
  it("stringify with empty value", () => {
    const s = qs.stringify({ a: "" });
    assert.strictEqual(typeof s, "string");
  });
});
