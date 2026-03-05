/**
 * node:http 兼容测试：createServer、requestListener、边界
 */
const { describe, it, assert } = require("shu:test");
const http = require("node:http");

describe("node:http exports", () => {
  it("has createServer", () => {
    assert.strictEqual(typeof http.createServer, "function");
  });
});

describe("node:http createServer", () => {
  it("createServer() returns server with listen close", () => {
    const server = http.createServer();
    assert.ok(server != null);
    assert.strictEqual(typeof server.listen, "function");
    assert.strictEqual(typeof server.close, "function");
  });
  it("createServer(requestListener) accepts request and response", () => {
    const server = http.createServer((req, res) => {
      assert.ok(req != null);
      assert.ok(res != null);
      assert.strictEqual(typeof res.end, "function");
    });
    assert.ok(server != null);
    server.close();
  });
});

describe("node:http boundary", () => {
  it("createServer() then close() does not throw", () => {
    const server = http.createServer();
    server.close();
  });
});
