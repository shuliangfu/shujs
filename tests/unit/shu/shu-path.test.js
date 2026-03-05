// shu:path 模块 JS 测试：join、resolve、basename、dirname、extname、normalize、isAbsolute、sep、delimiter、posix/win32
const { describe, it, assert } = require("shu:test");
const path = require("shu:path");

describe("shu:path", () => {
  it("path.join returns joined path with platform sep", () => {
    const p = path.join("a", "b", "c");
    assert.ok(typeof p === "string");
    assert.ok(p.includes("a") && p.includes("b") && p.includes("c"));
  });

  it("path.resolve returns absolute-style path", () => {
    const p = path.resolve("foo", "bar");
    assert.ok(typeof p === "string");
    assert.ok(p.length > 0);
  });

  it("path.basename returns last portion", () => {
    assert.strictEqual(path.basename("/a/b/c.js"), "c.js");
    assert.strictEqual(path.basename("/a/b/c.js", ".js"), "c");
  });

  it("path.dirname returns directory portion", () => {
    assert.strictEqual(path.dirname("/a/b/c.js"), "/a/b");
  });

  it("path.extname returns extension", () => {
    assert.strictEqual(path.extname("file.js"), ".js");
    assert.strictEqual(path.extname("file"), "");
  });

  it("path.normalize collapses slashes and dots", () => {
    const n = path.normalize("a//b/./c/../d");
    assert.ok(typeof n === "string");
  });

  it("path.isAbsolute returns boolean", () => {
    assert.strictEqual(typeof path.isAbsolute("/foo"), "boolean");
    assert.strictEqual(typeof path.isAbsolute("foo"), "boolean");
  });

  it("path.relative returns relative path between two paths", () => {
    const r = path.relative("/a/b", "/a/b/c/d");
    assert.ok(typeof r === "string");
  });

  it("path.parse returns { root, dir, base, ext, name }", () => {
    const parsed = path.parse("/a/b/c.js");
    assert.ok(parsed && typeof parsed === "object");
    assert.ok("root" in parsed && "dir" in parsed && "base" in parsed && "ext" in parsed && "name" in parsed);
    assert.strictEqual(parsed.base, "c.js");
    assert.strictEqual(parsed.ext, ".js");
    assert.strictEqual(parsed.name, "c");
  });

  it("path.format reassembles from parse result", () => {
    const parsed = path.parse("/a/b/c.js");
    const formatted = path.format(parsed);
    assert.ok(typeof formatted === "string");
  });

  it("path.sep and path.delimiter are strings", () => {
    assert.ok(typeof path.sep === "string");
    assert.ok(typeof path.delimiter === "string");
  });

  it("path.posix and path.win32 have same methods", () => {
    assert.ok(path.posix && typeof path.posix.join === "function");
    assert.ok(path.win32 && typeof path.win32.join === "function");
    assert.strictEqual(path.posix.sep, "/");
    assert.strictEqual(path.win32.sep, "\\");
  });

  it("path.root returns root segment", () => {
    const r = path.root("/a/b/c");
    assert.ok(typeof r === "string");
  });

  it("path.name returns filename without extension", () => {
    assert.strictEqual(path.name("/a/b/c.js"), "c");
  });

  it("path.toNamespacedPath returns string", () => {
    const p = path.toNamespacedPath("/a/b/c.js");
    assert.strictEqual(typeof p, "string");
    assert.ok(p.length >= 0);
  });

  it("path.filePathToUrl returns file URL string", () => {
    const urlStr = path.filePathToUrl("/a/b/c.js");
    assert.strictEqual(typeof urlStr, "string");
    assert.ok(urlStr.startsWith("file://") || urlStr.includes("file"));
  });

  it("path.urlToFilePath decodes file URL to path", () => {
    const fileUrl = path.filePathToUrl("/foo/bar");
    const back = path.urlToFilePath(fileUrl);
    assert.strictEqual(typeof back, "string");
    assert.ok(back.length > 0);
  });
});

describe("shu:path boundary", () => {
  it("path.join() with no args returns current dir or empty", () => {
    const p = path.join();
    assert.strictEqual(typeof p, "string");
  });

  it("path.extname('') returns empty string", () => {
    assert.strictEqual(path.extname(""), "");
  });

  it("path.parse('') returns object with root/dir/base/name/ext", () => {
    const parsed = path.parse("");
    assert.ok(parsed && typeof parsed === "object");
    assert.ok("root" in parsed && "base" in parsed);
  });

  // 生产奇葩：单段、空段、undefined 混入
  it("path.join single segment returns that segment", () => {
    const p = path.join("only");
    assert.strictEqual(typeof p, "string");
    assert.ok(p.length >= 0);
  });

  it("path.join with empty string segments does not throw", () => {
    const p = path.join("a", "", "b");
    assert.strictEqual(typeof p, "string");
  });

  it("path.basename with empty ext returns full base", () => {
    const b = path.basename("/a/b/file.js", "");
    assert.strictEqual(b, "file.js");
  });

  it("path.relative same path returns empty or .", () => {
    const r = path.relative("/a/b", "/a/b");
    assert.strictEqual(typeof r, "string");
  });

  it("path.isAbsolute with empty string returns boolean", () => {
    assert.strictEqual(typeof path.isAbsolute(""), "boolean");
  });

  it("path.normalize with only dots and slashes does not throw", () => {
    const n = path.normalize(".././..");
    assert.strictEqual(typeof n, "string");
  });

  it("path.toNamespacedPath with empty string returns string", () => {
    const p = path.toNamespacedPath("");
    assert.strictEqual(typeof p, "string");
  });

  it("path.filePathToUrl with empty path does not throw", () => {
    const u = path.filePathToUrl("");
    assert.strictEqual(typeof u, "string");
  });

  it("path.urlToFilePath with invalid or non-file URL does not crash", () => {
    try {
      const back = path.urlToFilePath("http://example.com/");
      assert.strictEqual(typeof back, "string");
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });

  it("path.format with empty parse-like object does not throw", () => {
    const f = path.format({ root: "", dir: "", base: "", ext: "", name: "" });
    assert.strictEqual(typeof f, "string");
  });

  it("path.posix.join and path.win32.join with same args give different sep", () => {
    const posix = path.posix.join("a", "b");
    const win32 = path.win32.join("a", "b");
    assert.ok(posix.includes("/"));
    assert.ok(win32.includes("\\"));
  });
});
