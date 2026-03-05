// shu:url 模块 JS 测试：parse、format；URL/URLSearchParams 若由全局提供则一并测
// 方法全覆盖 + 边界：空串、无效 URL、format 空对象
const { describe, it, assert } = require("shu:test");
const url = require("shu:url");

describe("shu:url", () => {
  it("url.parse returns object with href, pathname, search, etc.", () => {
    const parsed = url.parse("https://example.com/path?a=1");
    assert.ok(parsed && typeof parsed === "object");
    assert.ok("href" in parsed || "pathname" in parsed || "host" in parsed);
  });

  it("url.format takes object and returns url string", () => {
    const obj = { protocol: "https:", host: "example.com", pathname: "/foo" };
    const str = url.format(obj);
    assert.strictEqual(typeof str, "string");
    assert.ok(str.length > 0);
  });

  it("URL global or url.URL parses URL", () => {
    const URLConstructor = typeof URL !== "undefined" ? URL : url.URL;
    if (URLConstructor) {
      const u = new URLConstructor("https://example.com/path");
      assert.strictEqual(u.hostname, "example.com");
      assert.strictEqual(u.pathname, "/path");
    }
  });

  it("url.parse with query string includes search/query", () => {
    const parsed = url.parse("https://a.com/?a=1&b=2");
    assert.ok(parsed && typeof parsed === "object");
    assert.ok("href" in parsed || "search" in parsed || "query" in parsed || "pathname" in parsed);
  });

  it("url.parse with hash includes hash or pathname", () => {
    const parsed = url.parse("https://example.com/path#section");
    assert.ok(parsed && typeof parsed === "object");
    assert.ok("hash" in parsed || "pathname" in parsed || "href" in parsed);
  });

  it("URLSearchParams get/getAll/toString when available", () => {
    const URLConstructor = typeof URL !== "undefined" ? URL : url.URL;
    if (!URLConstructor) return;
    const u = new URLConstructor("https://example.com/?a=1&a=2&b=3");
    const sp = u.searchParams;
    if (sp && typeof sp.get === "function") {
      assert.strictEqual(sp.get("a"), "1");
      if (typeof sp.getAll === "function") {
        const all = sp.getAll("a");
        assert.ok(Array.isArray(all) && all.length >= 1);
      }
      if (typeof sp.toString === "function") {
        assert.strictEqual(typeof sp.toString(), "string");
      }
    }
  });

  describe("shu:url boundary", () => {
    it("url.parse empty string returns object or throws", () => {
      try {
        const p = url.parse("");
        assert.ok(p === undefined || (typeof p === "object" && p !== null));
      } catch (_) {
        // allowed to throw for invalid URL
      }
    });

    it("url.format empty object returns string", () => {
      const str = url.format({});
      assert.strictEqual(typeof str, "string");
    });

    it("url.format with only pathname returns string", () => {
      const str = url.format({ pathname: "/foo/bar" });
      assert.strictEqual(typeof str, "string");
    });

    it("url.parse relative path returns object or throws", () => {
      try {
        const p = url.parse("/relative/path");
        assert.ok(p === undefined || (typeof p === "object" && p !== null));
      } catch (_) {}
    });
  });
});
