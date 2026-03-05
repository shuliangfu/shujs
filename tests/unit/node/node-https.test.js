/**
 * node:https 兼容测试：createServer、边界
 */
const { describe, it, assert } = require("shu:test");
const https = require("node:https");

describe("node:https exports", () => {
  it("has createServer", () => {
    assert.strictEqual(typeof https.createServer, "function");
  });
});

describe("node:https createServer", () => {
  it("createServer() returns server", () => {
    const server = https.createServer();
    assert.ok(server != null);
    assert.strictEqual(typeof server.listen, "function");
    server.close();
  });
});

describe("node:https boundary", () => {
  it("createServer(options) with empty options", () => {
    const server = https.createServer({});
    assert.ok(server != null);
    server.close();
  });
});
