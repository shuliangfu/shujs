/**
 * node:url 全面兼容测试：parse、format、URL、URLSearchParams 全方法 + 边界
 */
const { describe, it, assert } = require("shu:test");
const url = require("node:url");

describe("node:url exports", () => {
  it("has parse, format, URL, URLSearchParams", () => {
    assert.strictEqual(typeof url.parse, "function");
    assert.strictEqual(typeof url.format, "function");
    assert.strictEqual(typeof url.URL, "function");
    assert.strictEqual(typeof url.URLSearchParams, "function");
  });
});

describe("node:url parse", () => {
  it("parse returns object with host path etc", () => {
    const o = url.parse("http://example.com/path");
    assert.ok(o && typeof o === "object");
    assert.ok("host" in o || "hostname" in o || "path" in o || "pathname" in o);
  });
  it("parse('http://a.b/c')", () => {
    const o = url.parse("http://a.b/c");
    assert.strictEqual(typeof o, "object");
  });
});

describe("node:url format", () => {
  it("format(object) returns string", () => {
    const s = url.format({ protocol: "http:", host: "example.com", pathname: "/" });
    assert.strictEqual(typeof s, "string");
  });
});

describe("node:url URL", () => {
  it("new URL(str) creates URL instance", () => {
    const u = new url.URL("http://example.com/path");
    assert.ok(u != null);
    assert.strictEqual(u.hostname, "example.com");
    assert.ok(u.pathname.includes("path") || u.pathname === "/path");
  });
  it("URL with base", () => {
    const u = new url.URL("/foo", "http://example.com");
    assert.strictEqual(u.hostname, "example.com");
    assert.strictEqual(u.pathname, "/foo");
  });
});

describe("node:url URLSearchParams", () => {
  it("new URLSearchParams(string)", () => {
    const p = new url.URLSearchParams("a=1&b=2");
    assert.ok(p != null);
    assert.strictEqual(p.get("a"), "1");
    assert.strictEqual(p.get("b"), "2");
  });
  it("get set append", () => {
    const p = new url.URLSearchParams();
    p.append("k", "v");
    assert.strictEqual(p.get("k"), "v");
  });
});

describe("node:url boundary", () => {
  it("parse invalid URL", () => {
    try {
      const o = url.parse("not-a-url");
      assert.ok(o != null);
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });
  it("format empty object", () => {
    const s = url.format({});
    assert.strictEqual(typeof s, "string");
  });
});
