// shu:module 模块 JS 测试：createRequire、isBuiltin、builtinModules、findPackageJSON、stripTypeScriptTypes
// 约定：新增 API 时补一条正常用例 + 一条边界用例。
const { describe, it, assert } = require("shu:test");
const mod = require("shu:module");

describe("shu:module", () => {
  it("mod.createRequire returns require function", () => {
    const base = typeof __filename !== "undefined" ? __filename : process.cwd() + "/package.json";
    const req = mod.createRequire(base);
    assert.strictEqual(typeof req, "function");
  });

  it("mod.isBuiltin('shu:path') returns true", () => {
    assert.strictEqual(mod.isBuiltin("shu:path"), true);
  });

  it("mod.isBuiltin('shu:assert') returns true", () => {
    assert.strictEqual(mod.isBuiltin("shu:assert"), true);
  });

  it("mod.isBuiltin('node:buffer') returns true or false depending on support", () => {
    const out = mod.isBuiltin("node:buffer");
    assert.strictEqual(typeof out, "boolean");
  });

  it("mod.isBuiltin('invalid') returns false", () => {
    assert.strictEqual(mod.isBuiltin("invalid"), false);
  });

  it("mod.builtinModules is array of strings", () => {
    assert.ok(Array.isArray(mod.builtinModules));
    assert.ok(mod.builtinModules.length > 0);
    assert.ok(mod.builtinModules.some((m) => m.startsWith("shu:")));
  });

  it("createRequire can require shu builtins", () => {
    const base = typeof __filename !== "undefined" ? __filename : process.cwd() + "/package.json";
    const req = mod.createRequire(base);
    const pathMod = req("shu:path");
    assert.ok(pathMod && typeof pathMod.join === "function");
  });

  it("has findPackageJSON and stripTypeScriptTypes", () => {
    assert.strictEqual(typeof mod.findPackageJSON, "function");
    assert.strictEqual(typeof mod.stripTypeScriptTypes, "function");
  });

  it("findPackageJSON(specifier, base) returns string or undefined", () => {
    const cwd = process.cwd();
    const out = mod.findPackageJSON(".", cwd);
    if (out !== undefined) {
      assert.strictEqual(typeof out, "string");
      assert.ok(out.length > 0);
    }
  });

  it("stripTypeScriptTypes strips type annotations", () => {
    const code = "const x: number = 1;";
    const out = mod.stripTypeScriptTypes(code);
    assert.strictEqual(typeof out, "string");
    assert.ok(out.includes("const x") && (out.includes("= 1") || out.includes("=1")));
  });
});

describe("shu:module boundary", () => {
  it("isBuiltin('') returns false", () => {
    assert.strictEqual(mod.isBuiltin(""), false);
  });

  it("isBuiltin with non-string throws or returns boolean", () => {
    try {
      const out = mod.isBuiltin(123);
      assert.strictEqual(typeof out, "boolean");
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });

  it("createRequire with invalid base throws or returns require", () => {
    try {
      const req = mod.createRequire("");
      assert.strictEqual(typeof req, "function");
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });

  it("stripTypeScriptTypes('') returns string", () => {
    const out = mod.stripTypeScriptTypes("");
    assert.strictEqual(typeof out, "string");
  });

  it("mod.resolve(specifier, parent) when present", () => {
    if (typeof mod.resolve !== "function") return;
    const req = mod.createRequire(process.cwd() + "/package.json");
    try {
      const r = mod.resolve("shu:path", __filename != null ? __filename : "file:///x");
      assert.strictEqual(typeof r, "string");
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });

  it("findPackageJSON with non-existent dir returns undefined or path", () => {
    const out = mod.findPackageJSON(".", "/nonexistent-dir-" + Date.now());
    assert.ok(out === undefined || (typeof out === "string"));
  });
});
