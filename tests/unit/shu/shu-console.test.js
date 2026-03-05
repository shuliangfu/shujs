// shu:console 模块测试（require 返回与 globalThis.console 一致）
const { describe, it, assert } = require("shu:test");

const consoleModule = require("shu:console");

describe("shu:console", () => {
  it("require('shu:console') returns same as global console", () => {
    assert.strictEqual(consoleModule, globalThis.console);
  });

  it("has log, warn, error, info, debug", () => {
    assert.strictEqual(typeof consoleModule.log, "function");
    assert.strictEqual(typeof consoleModule.warn, "function");
    assert.strictEqual(typeof consoleModule.error, "function");
    assert.strictEqual(typeof consoleModule.info, "function");
    assert.strictEqual(typeof consoleModule.debug, "function");
  });

  it("warn(...) does not throw", () => {
    consoleModule.warn("warn-msg");
    consoleModule.warn("a", 1);
  });

  it("error(...) does not throw", () => {
    consoleModule.error("error-msg");
  });

  it("info(...) does not throw", () => {
    consoleModule.info("info-msg");
  });

  it("debug(...) does not throw", () => {
    consoleModule.debug("debug-msg");
  });
});

describe("shu:console boundary", () => {
  it("log() with no args does not throw", () => {
    consoleModule.log();
  });

  it("log with multiple args does not throw", () => {
    consoleModule.log("a", 1, null, {});
  });

  it("log(null) and log(undefined) do not throw", () => {
    consoleModule.log(null);
    consoleModule.log(undefined);
  });

  it("error with Error object does not throw", () => {
    consoleModule.error(new Error("test error"));
  });

  it("info with long string does not throw", () => {
    consoleModule.info("a".repeat(10000));
  });
});
