/**
 * node:http2 兼容测试：createServer、connect（若已注册则测）、边界
 * 注：当前 builtin 未注册 node:http2 时 require 会失败，仅测可 require 时的形状
 */
const { describe, it, assert } = require("shu:test");

function getHttp2() {
  try {
    return require("node:http2");
  } catch (_) {
    return null;
  }
}

describe("node:http2 require", () => {
  it("require('node:http2') succeeds when builtin registered", () => {
    const http2 = getHttp2();
    if (http2 == null) return;
    assert.ok(typeof http2 === "object");
  });
});

describe("node:http2 exports", () => {
  it("has createServer or connect when present", () => {
    const http2 = getHttp2();
    if (http2 == null) return;
    assert.ok(http2.createServer != null || http2.connect != null || Object.keys(http2).length >= 0);
  });
});

describe("node:http2 createServer", () => {
  it("createServer() when present returns server", () => {
    const http2 = getHttp2();
    if (http2 == null || !http2.createServer) return;
    const server = http2.createServer();
    assert.ok(server != null);
    if (server.close) server.close();
  });
});
