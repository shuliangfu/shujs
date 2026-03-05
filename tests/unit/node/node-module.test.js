/**
 * node:module 兼容测试：createRequire、isBuiltin、builtinModules、findPackageJSON、stripTypeScriptTypes、边界
 */
const { describe, it, assert } = require("shu:test");
const mod = require("node:module");

describe("node:module exports", () => {
  it("has createRequire isBuiltin findPackageJSON stripTypeScriptTypes", () => {
    assert.strictEqual(typeof mod.createRequire, "function");
    assert.strictEqual(typeof mod.isBuiltin, "function");
    assert.strictEqual(typeof mod.findPackageJSON, "function");
    assert.strictEqual(typeof mod.stripTypeScriptTypes, "function");
  });
  it("has builtinModules array", () => {
    assert.ok(Array.isArray(mod.builtinModules));
    assert.ok(mod.builtinModules.length > 0);
  });
});

describe("node:module isBuiltin", () => {
  it("isBuiltin('node:path') returns true", () => {
    assert.strictEqual(mod.isBuiltin("node:path"), true);
  });
  it("isBuiltin('node:fs') returns true", () => {
    assert.strictEqual(mod.isBuiltin("node:fs"), true);
  });
  it("isBuiltin('non-existent') returns false", () => {
    assert.strictEqual(mod.isBuiltin("non-existent-module-xyz"), false);
  });
});

describe("node:module createRequire", () => {
  it("createRequire(path) returns require function", () => {
    const req = mod.createRequire(process.cwd() + "/package.json");
    assert.strictEqual(typeof req, "function");
    assert.strictEqual(typeof req.resolve, "function");
  });
  it("createRequire(path)() can require node:path", () => {
    const req = mod.createRequire(process.cwd() + "/package.json");
    const pathMod = req("node:path");
    assert.ok(pathMod && typeof pathMod.join === "function");
  });
});

describe("node:module boundary", () => {
  it("builtinModules includes node:path", () => {
    assert.ok(mod.builtinModules.includes("node:path"));
  });
});
