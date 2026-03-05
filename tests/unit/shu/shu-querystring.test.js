// shu:querystring 模块 JS 测试：parse、stringify
const { describe, it, assert } = require("shu:test");
const qs = require("shu:querystring");

describe("shu:querystring", () => {
  it("parse returns object from query string", () => {
    const out = qs.parse("a=1&b=2");
    assert.ok(out && typeof out === "object");
    assert.strictEqual(out.a, "1");
    assert.strictEqual(out.b, "2");
  });

  it("parse handles leading ?", () => {
    const out = qs.parse("?x=3");
    assert.ok(out && typeof out === "object");
    assert.strictEqual(out.x, "3");
  });

  it("stringify returns query string from object", () => {
    const str = qs.stringify({ a: 1, b: "hello" });
    assert.strictEqual(typeof str, "string");
    assert.ok(str.includes("a=") && str.includes("b="));
  });
});

describe("shu:querystring boundary", () => {
  it("parse('') returns empty object", () => {
    const out = qs.parse("");
    assert.ok(out && typeof out === "object");
    assert.strictEqual(Object.keys(out).length, 0);
  });

  it("stringify({}) returns empty string", () => {
    const str = qs.stringify({});
    assert.strictEqual(typeof str, "string");
    assert.strictEqual(str, "");
  });

  it("parse('a') returns key with empty value", () => {
    const out = qs.parse("a");
    assert.ok(out && out.a !== undefined);
  });

  it("parse('a=1&b=2&c=3') multiple pairs", () => {
    const out = qs.parse("a=1&b=2&c=3");
    assert.strictEqual(out.a, "1");
    assert.strictEqual(out.b, "2");
    assert.strictEqual(out.c, "3");
  });

  it("stringify with empty value", () => {
    const str = qs.stringify({ a: "", b: "v" });
    assert.strictEqual(typeof str, "string");
    assert.ok(str.includes("b="));
  });

  it("parse then stringify roundtrip", () => {
    const orig = "x=1&y=2";
    const parsed = qs.parse(orig);
    const back = qs.stringify(parsed);
    assert.ok(back.length >= 0);
    const p2 = qs.parse(back);
    assert.strictEqual(p2.x, "1");
    assert.strictEqual(p2.y, "2");
  });

  it("parse('&') edge", () => {
    const out = qs.parse("&");
    assert.ok(out && typeof out === "object");
  });

  it("stringify with null/undefined value", () => {
    const str = qs.stringify({ a: null, b: undefined });
    assert.strictEqual(typeof str, "string");
  });
});
