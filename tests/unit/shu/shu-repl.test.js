// shu:repl 模块测试（占位：start/ReplServer 抛 not implemented）
const { describe, it, assert } = require("shu:test");

const repl = require("shu:repl");

describe("shu:repl", () => {
  it("has start and ReplServer", () => {
    assert.strictEqual(typeof repl.start, "function");
    assert.ok("ReplServer" in repl);
  });

  it("start() throws not implemented", () => {
    assert.throws(() => repl.start(), /not implemented|repl/i);
  });
});
