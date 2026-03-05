/**
 * node:net 兼容测试：createServer、createConnection、connect、Socket、边界
 */
const { describe, it, assert } = require("shu:test");
const net = require("node:net");

describe("node:net exports", () => {
  it("has createServer createConnection connect Socket", () => {
    assert.strictEqual(typeof net.createServer, "function");
    assert.strictEqual(typeof net.createConnection, "function");
    assert.strictEqual(typeof net.connect, "function");
    assert.ok(net.Socket != null && typeof net.Socket === "function");
  });
});

describe("node:net createServer", () => {
  it("createServer() returns server with listen and close", () => {
    const server = net.createServer();
    assert.ok(server != null);
    assert.strictEqual(typeof server.listen, "function");
    assert.strictEqual(typeof server.close, "function");
    server.close();
  });
});

describe("node:net Socket", () => {
  it("new net.Socket() creates socket", () => {
    const s = new net.Socket();
    assert.ok(s != null);
  });
});
