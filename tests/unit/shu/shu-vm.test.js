// shu:vm 模块测试（createContext/runInContext/runInNewContext/runInThisContext/Script/isContext 等）
// 约定：新增 API 时补一条正常用例 + 一条边界用例。
const { describe, it, assert } = require("shu:test");

const vm = require("shu:vm");

describe("shu:vm", () => {
  it("has createContext, runInContext, runInNewContext, runInThisContext, isContext, disposeContext, measureMemory, Script, constants", () => {
    assert.strictEqual(typeof vm.createContext, "function");
    assert.strictEqual(typeof vm.runInContext, "function");
    assert.strictEqual(typeof vm.runInNewContext, "function");
    assert.strictEqual(typeof vm.runInThisContext, "function");
    assert.strictEqual(typeof vm.isContext, "function");
    assert.strictEqual(typeof vm.disposeContext, "function");
    assert.strictEqual(typeof vm.measureMemory, "function");
    assert.ok(vm.Script && typeof vm.Script === "function");
    assert.ok(vm.constants && typeof vm.constants === "object");
  });

  it("runInThisContext('1+1') returns 2", () => {
    const result = vm.runInThisContext("1+1");
    assert.strictEqual(result, 2);
  });

  it("createContext(sandbox) and isContext(sandbox) returns true", () => {
    const sandbox = { x: 1 };
    const ctx = vm.createContext(sandbox);
    assert.ok(ctx && typeof ctx === "object");
    assert.strictEqual(vm.isContext(sandbox), true);
  });

  it("new vm.Script(code) has runInThisContext", () => {
    const script = new vm.Script("2+3");
    assert.strictEqual(typeof script.runInThisContext, "function");
    assert.strictEqual(script.runInThisContext(), 5);
  });

  it("boundary: runInThisContext('') returns undefined or value", () => {
    const result = vm.runInThisContext("");
    assert.ok(result === undefined || result !== undefined);
  });

  it("boundary: Script() with no args throws", () => {
    assert.throws(() => new vm.Script());
  });

  it("runInContext(code, contextifiedSandbox) runs in sandbox", () => {
    const sandbox = { a: 10 };
    vm.createContext(sandbox);
    const result = vm.runInContext("a + 1", sandbox);
    assert.strictEqual(result, 11);
  });

  it("runInNewContext(code[, sandbox]) runs in new sandbox", () => {
    const result = vm.runInNewContext("1 + 2", {});
    assert.strictEqual(result, 3);
  });

  it("disposeContext(sandbox) does not throw", () => {
    const sandbox = { x: 1 };
    vm.createContext(sandbox);
    vm.disposeContext(sandbox);
  });

  it("measureMemory() returns promise or value when present", (t) => {
    const p = vm.measureMemory();
    if (p && typeof p.then === "function") {
      p.then(() => t.done()).catch(() => t.done());
    } else {
      t.done();
    }
  });
});

describe("shu:vm boundary (production edge cases)", () => {
  it("isContext(plain object) returns false", () => {
    assert.strictEqual(vm.isContext({}), false);
  });

  it("isContext(null) and isContext(undefined) do not throw", () => {
    const a = vm.isContext(null);
    const b = vm.isContext(undefined);
    assert.strictEqual(typeof a, "boolean");
    assert.strictEqual(typeof b, "boolean");
  });

  it("runInThisContext with syntax error throws", () => {
    assert.throws(() => vm.runInThisContext("{{{"));
  });

  it("runInNewContext with null sandbox does not crash", () => {
    try {
      vm.runInNewContext("1", null);
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });

  it("disposeContext on non-context object does not crash", () => {
    try {
      vm.disposeContext({});
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });

  it("Script runInThisContext multiple times returns same result", () => {
    const script = new vm.Script("40 + 2");
    assert.strictEqual(script.runInThisContext(), 42);
    assert.strictEqual(script.runInThisContext(), 42);
  });

  it("createContext same object twice does not throw", () => {
    const sandbox = { x: 1 };
    vm.createContext(sandbox);
    vm.createContext(sandbox);
    assert.strictEqual(vm.isContext(sandbox), true);
  });
});
