/**
 * node:readline 兼容测试：createInterface、question、clearLine、边界
 */
const { describe, it, assert } = require("shu:test");
const readline = require("node:readline");

describe("node:readline exports", () => {
  it("has createInterface", () => {
    assert.strictEqual(typeof readline.createInterface, "function");
  });
});

describe("node:readline createInterface", () => {
  it("createInterface({ input, output }) returns interface", () => {
    const mockStream = { on: () => {}, write: () => {}, read: () => null };
    const rl = readline.createInterface({ input: mockStream, output: mockStream });
    assert.ok(rl != null);
    assert.strictEqual(typeof rl.question, "function");
    assert.strictEqual(typeof rl.close, "function");
  });
  it("interface has on and close", () => {
    const mockStream = { on: () => {}, write: () => {}, read: () => null };
    const rl = readline.createInterface({ input: mockStream, output: mockStream });
    assert.strictEqual(typeof rl.on, "function");
    rl.close();
  });
});

describe("node:readline boundary", () => {
  it("createInterface with empty input/output options", () => {
    try {
      readline.createInterface({});
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });
});
