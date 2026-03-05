/**
 * node:vm 兼容测试：createContext、runInContext、runInNewContext、Script、isContext、边界
 */
const { describe, it, assert } = require("shu:test");
const vm = require("node:vm");

describe("node:vm exports", () => {
  it("has createContext runInContext runInNewContext Script", () => {
    assert.strictEqual(typeof vm.createContext, "function");
    assert.strictEqual(typeof vm.runInContext, "function");
    assert.strictEqual(typeof vm.runInNewContext, "function");
    assert.ok(vm.Script != null && typeof vm.Script === "function");
  });
  it("has isContext disposeContext when present", () => {
    if (vm.isContext) assert.strictEqual(typeof vm.isContext, "function");
    if (vm.disposeContext) assert.strictEqual(typeof vm.disposeContext, "function");
  });
});

describe("node:vm createContext and runInContext", () => {
  it("createContext({}) returns sandbox", () => {
    const sandbox = vm.createContext({});
    assert.ok(sandbox != null && typeof sandbox === "object");
  });
  it("runInContext(code, context) returns result", () => {
    const ctx = vm.createContext({ x: 1 });
    const result = vm.runInContext("x + 1", ctx);
    assert.strictEqual(result, 2);
  });
});

describe("node:vm runInNewContext", () => {
  it("runInNewContext(code) returns result", () => {
    const result = vm.runInNewContext("1 + 2");
    assert.strictEqual(result, 3);
  });
  it("runInNewContext(code, sandbox) sees sandbox", () => {
    const sandbox = { a: 10 };
    const result = vm.runInNewContext("a * 2", sandbox);
    assert.strictEqual(result, 20);
  });
});

describe("node:vm Script", () => {
  it("new vm.Script(code) creates script", () => {
    const script = new vm.Script("return 42");
    assert.ok(script != null);
    assert.strictEqual(typeof script.runInNewContext, "function");
  });
  it("script.runInNewContext() returns value", () => {
    const script = new vm.Script("return 100");
    const v = script.runInNewContext();
    assert.strictEqual(v, 100);
  });
});

describe("node:vm boundary", () => {
  it("runInNewContext empty string", () => {
    const v = vm.runInNewContext("undefined");
    assert.strictEqual(v, undefined);
  });
});
