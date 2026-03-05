// shu:tls 模块测试（createSecureContext/createServer/connect/getCiphers 等）
// 约定：新增 API 时补一条正常用例 + 一条边界用例。
const { describe, it, assert } = require("shu:test");

const tls = require("shu:tls");

describe("shu:tls", () => {
  it("has createSecureContext, createServer, connect, getCiphers", () => {
    assert.strictEqual(typeof tls.createSecureContext, "function");
    assert.strictEqual(typeof tls.createServer, "function");
    assert.strictEqual(typeof tls.connect, "function");
    assert.strictEqual(typeof tls.getCiphers, "function");
  });

  it("createSecureContext({}) returns object", () => {
    const ctx = tls.createSecureContext({});
    assert.ok(ctx && typeof ctx === "object");
  });

  it("createServer(options, listener) returns object with listen", () => {
    const server = tls.createServer({}, () => {});
    assert.ok(server && typeof server.listen === "function");
  });

  it("getCiphers() returns array of strings when present", () => {
    const ciphers = tls.getCiphers();
    assert.ok(Array.isArray(ciphers));
    if (ciphers.length > 0) assert.strictEqual(typeof ciphers[0], "string");
  });

  it("boundary: createSecureContext() with no options returns object or undefined", () => {
    const ctx = tls.createSecureContext();
    if (ctx !== undefined) assert.ok(typeof ctx === "object");
  });
});
