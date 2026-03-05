/**
 * node:tls 兼容测试：createServer、connect、createSecureContext、边界
 */
const { describe, it, assert } = require("shu:test");
const tls = require("node:tls");

describe("node:tls exports", () => {
  it("has createServer connect createSecureContext", () => {
    assert.strictEqual(typeof tls.createServer, "function");
    assert.strictEqual(typeof tls.connect, "function");
    assert.strictEqual(typeof tls.createSecureContext, "function");
  });
});

describe("node:tls createSecureContext", () => {
  it("createSecureContext() returns context", () => {
    const ctx = tls.createSecureContext();
    assert.ok(ctx != null);
  });
});

describe("node:tls boundary", () => {
  it("createServer() returns server", () => {
    const server = tls.createServer({});
    assert.ok(server != null);
    assert.strictEqual(typeof server.listen, "function");
  });
});
