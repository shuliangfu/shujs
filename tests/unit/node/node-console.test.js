/**
 * node:console 全面兼容测试：log、warn、error、info、debug 全方法 + 边界
 */
const { describe, it, assert } = require("shu:test");
const con = require("node:console");

describe("node:console exports", () => {
  it("has log, warn, error, info, debug", () => {
    assert.strictEqual(typeof con.log, "function");
    assert.strictEqual(typeof con.warn, "function");
    assert.strictEqual(typeof con.error, "function");
    assert.strictEqual(typeof con.info, "function");
    assert.strictEqual(typeof con.debug, "function");
  });
});

describe("node:console invocations", () => {
  it("log() no args does not throw", () => {
    assert.doesNotThrow(() => con.log());
  });
  it("log(1, 'a') does not throw", () => {
    assert.doesNotThrow(() => con.log(1, "a"));
  });
  it("warn('msg') does not throw", () => {
    assert.doesNotThrow(() => con.warn("msg"));
  });
  it("error('err') does not throw", () => {
    assert.doesNotThrow(() => con.error("err"));
  });
  it("info('i') does not throw", () => {
    assert.doesNotThrow(() => con.info("i"));
  });
  it("debug('d') does not throw", () => {
    assert.doesNotThrow(() => con.debug("d"));
  });
});

describe("node:console boundary", () => {
  it("log(null), log(undefined)", () => {
    assert.doesNotThrow(() => con.log(null));
    assert.doesNotThrow(() => con.log(undefined));
  });
  it("log many args", () => {
    assert.doesNotThrow(() => con.log(1, 2, 3, {}, [], "x"));
  });
});
