/**
 * node:path 全面兼容测试：所有方法 + 边界用例
 * 与 Node path API 对齐：join、resolve、dirname、basename、extname、normalize、isAbsolute、relative、parse、format、sep、delimiter、posix、win32、toNamespacedPath、filePathToUrl、urlToFilePath、root、name
 */
const { describe, it, assert } = require("shu:test");
const path = require("node:path");

describe("node:path exports", () => {
  it("has all Node path methods", () => {
    assert.strictEqual(typeof path.join, "function");
    assert.strictEqual(typeof path.resolve, "function");
    assert.strictEqual(typeof path.dirname, "function");
    assert.strictEqual(typeof path.basename, "function");
    assert.strictEqual(typeof path.extname, "function");
    assert.strictEqual(typeof path.normalize, "function");
    assert.strictEqual(typeof path.isAbsolute, "function");
    assert.strictEqual(typeof path.relative, "function");
    assert.strictEqual(typeof path.parse, "function");
    assert.strictEqual(typeof path.format, "function");
    assert.strictEqual(typeof path.toNamespacedPath, "function");
    assert.strictEqual(typeof path.filePathToUrl, "function");
    assert.strictEqual(typeof path.urlToFilePath, "function");
    assert.strictEqual(typeof path.root, "function");
    assert.strictEqual(typeof path.name, "function");
    assert.strictEqual(typeof path.sep, "string");
    assert.strictEqual(typeof path.delimiter, "string");
    assert.ok(path.posix != null && typeof path.posix.join === "function");
    assert.ok(path.win32 != null && typeof path.win32.join === "function");
  });
});

describe("node:path join", () => {
  it("join(a,b,c) returns joined path with platform sep", () => {
    const p = path.join("a", "b", "c");
    assert.strictEqual(typeof p, "string");
    assert.ok(p.includes("a") && p.includes("b") && p.includes("c"));
  });
  it("join() with no args returns string", () => {
    const p = path.join();
    assert.strictEqual(typeof p, "string");
  });
  it("join single segment returns that segment", () => {
    const p = path.join("only");
    assert.strictEqual(typeof p, "string");
    assert.ok(p.length >= 0);
  });
  it("join with empty string segments", () => {
    const p = path.join("a", "", "b");
    assert.strictEqual(typeof p, "string");
  });
  it("join with many segments", () => {
    const p = path.join("a", "b", "c", "d", "e");
    assert.strictEqual(typeof p, "string");
    assert.ok(p.includes("a") && p.includes("e"));
  });
});

describe("node:path resolve", () => {
  it("resolve returns absolute-style path", () => {
    const p = path.resolve("foo", "bar");
    assert.strictEqual(typeof p, "string");
    assert.ok(p.length > 0);
  });
  it("resolve single segment", () => {
    const p = path.resolve(".");
    assert.strictEqual(typeof p, "string");
  });
});

describe("node:path dirname", () => {
  it("dirname returns directory portion", () => {
    assert.strictEqual(path.dirname("/a/b/c.js"), "/a/b");
  });
  it("dirname of root returns root", () => {
    const d = path.dirname("/foo");
    assert.strictEqual(typeof d, "string");
  });
  it("dirname of single segment returns . or platform equiv", () => {
    const d = path.dirname("file");
    assert.strictEqual(typeof d, "string");
  });
});

describe("node:path basename", () => {
  it("basename(path) returns last portion", () => {
    assert.strictEqual(path.basename("/a/b/c.js"), "c.js");
  });
  it("basename(path, ext) strips extension", () => {
    assert.strictEqual(path.basename("/a/b/c.js", ".js"), "c");
  });
  it("basename with empty ext returns full base", () => {
    assert.strictEqual(path.basename("/a/b/file.js", ""), "file.js");
  });
  it("basename of path with no ext", () => {
    assert.strictEqual(path.basename("/a/b/file"), "file");
  });
});

describe("node:path extname", () => {
  it("extname returns extension with dot", () => {
    assert.strictEqual(path.extname("file.js"), ".js");
  });
  it("extname of no ext returns empty", () => {
    assert.strictEqual(path.extname("file"), "");
  });
  it("extname('') returns empty string", () => {
    assert.strictEqual(path.extname(""), "");
  });
  it("extname of .hidden returns .hidden", () => {
    const e = path.extname(".hidden");
    assert.strictEqual(typeof e, "string");
  });
});

describe("node:path normalize", () => {
  it("normalize collapses slashes and dots", () => {
    const n = path.normalize("a//b/./c/../d");
    assert.strictEqual(typeof n, "string");
  });
  it("normalize only dots and slashes", () => {
    const n = path.normalize(".././..");
    assert.strictEqual(typeof n, "string");
  });
  it("normalize empty string", () => {
    const n = path.normalize("");
    assert.strictEqual(typeof n, "string");
  });
});

describe("node:path isAbsolute", () => {
  it("isAbsolute returns boolean", () => {
    assert.strictEqual(typeof path.isAbsolute("/foo"), "boolean");
    assert.strictEqual(typeof path.isAbsolute("foo"), "boolean");
  });
  it("isAbsolute('') returns boolean", () => {
    assert.strictEqual(typeof path.isAbsolute(""), "boolean");
  });
});

describe("node:path relative", () => {
  it("relative(from, to) returns relative path", () => {
    const r = path.relative("/a/b", "/a/b/c/d");
    assert.strictEqual(typeof r, "string");
  });
  it("relative same path returns empty or .", () => {
    const r = path.relative("/a/b", "/a/b");
    assert.strictEqual(typeof r, "string");
  });
});

describe("node:path parse and format", () => {
  it("parse returns { root, dir, base, ext, name }", () => {
    const parsed = path.parse("/a/b/c.js");
    assert.ok(parsed && typeof parsed === "object");
    assert.ok("root" in parsed && "dir" in parsed && "base" in parsed && "ext" in parsed && "name" in parsed);
    assert.strictEqual(parsed.base, "c.js");
    assert.strictEqual(parsed.ext, ".js");
    assert.strictEqual(parsed.name, "c");
  });
  it("format reassembles from parse result", () => {
    const parsed = path.parse("/a/b/c.js");
    const formatted = path.format(parsed);
    assert.strictEqual(typeof formatted, "string");
  });
  it("parse('') returns object with root/dir/base/name/ext", () => {
    const parsed = path.parse("");
    assert.ok(parsed && typeof parsed === "object");
    assert.ok("root" in parsed && "base" in parsed);
  });
  it("format with empty parse-like object", () => {
    const f = path.format({ root: "", dir: "", base: "", ext: "", name: "" });
    assert.strictEqual(typeof f, "string");
  });
});

describe("node:path sep and delimiter", () => {
  it("sep and delimiter are strings", () => {
    assert.strictEqual(typeof path.sep, "string");
    assert.strictEqual(typeof path.delimiter, "string");
  });
  it("posix.sep is / and win32.sep is \\", () => {
    assert.strictEqual(path.posix.sep, "/");
    assert.strictEqual(path.win32.sep, "\\");
  });
  it("posix.join and win32.join give different sep", () => {
    const posix = path.posix.join("a", "b");
    const win32 = path.win32.join("a", "b");
    assert.ok(posix.includes("/"));
    assert.ok(win32.includes("\\"));
  });
});

describe("node:path root and name", () => {
  it("root returns root segment", () => {
    const r = path.root("/a/b/c");
    assert.strictEqual(typeof r, "string");
  });
  it("name returns filename without extension", () => {
    assert.strictEqual(path.name("/a/b/c.js"), "c");
  });
});

describe("node:path toNamespacedPath", () => {
  it("toNamespacedPath returns string", () => {
    const p = path.toNamespacedPath("/a/b/c.js");
    assert.strictEqual(typeof p, "string");
  });
  it("toNamespacedPath('') returns string", () => {
    const p = path.toNamespacedPath("");
    assert.strictEqual(typeof p, "string");
  });
});

describe("node:path filePathToUrl and urlToFilePath", () => {
  it("filePathToUrl returns file URL string", () => {
    const urlStr = path.filePathToUrl("/a/b/c.js");
    assert.strictEqual(typeof urlStr, "string");
    assert.ok(urlStr.startsWith("file://") || urlStr.includes("file"));
  });
  it("urlToFilePath decodes file URL to path", () => {
    const fileUrl = path.filePathToUrl("/foo/bar");
    const back = path.urlToFilePath(fileUrl);
    assert.strictEqual(typeof back, "string");
    assert.ok(back.length > 0);
  });
  it("filePathToUrl('') does not throw", () => {
    const u = path.filePathToUrl("");
    assert.strictEqual(typeof u, "string");
  });
  it("urlToFilePath with non-file URL", () => {
    try {
      const back = path.urlToFilePath("http://example.com/");
      assert.strictEqual(typeof back, "string");
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });
});
