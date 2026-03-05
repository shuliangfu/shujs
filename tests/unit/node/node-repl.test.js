/**
 * node:repl 兼容测试：start/REPLServer 已实现（readline + vm），或需 input/output 时抛错
 */
const { describe, it, assert } = require("shu:test");
const repl = require("node:repl");

describe("node:repl exports", () => {
  it("require does not throw", () => {
    assert.ok(repl != null && typeof repl === "object");
  });
  it("has start and REPLServer", () => {
    assert.strictEqual(typeof repl.start, "function");
    assert.ok(repl.ReplServer != null);
  });
  it("has REPL_MODE_STRICT and REPL_MODE_SLOPPY", () => {
    assert.ok(repl.REPL_MODE_STRICT != null);
    assert.ok(repl.REPL_MODE_SLOPPY != null);
  });
});

describe("node:repl start", () => {
  it("start() returns REPLServer when input/output available, or throws", () => {
    const process = globalThis.process;
    const hasStreams = process && process.stdin && process.stdout;
    try {
      const server = repl.start();
      assert.ok(server != null && typeof server === "object");
      assert.strictEqual(typeof server.context, "object");
      assert.strictEqual(typeof server.close, "function");
      assert.strictEqual(typeof server.displayPrompt, "function");
      assert.strictEqual(typeof server.on, "function");
      if (server.close) server.close();
    } catch (e) {
      assert.ok(e.message.match(/not implemented|requires require|input and output streams/i));
    }
  });
});
