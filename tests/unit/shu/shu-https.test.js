// shu:https 模块测试（createServer、server.listen/close）
// 约定：新增 API 时补一条正常用例 + 一条边界用例。
const { describe, it, assert } = require("shu:test");

const https = require("shu:https");

describe("shu:https", () => {
  it("has createServer", () => {
    assert.strictEqual(typeof https.createServer, "function");
  });

  it("createServer(options, listener) returns object with listen and close", () => {
    const server = https.createServer({}, () => {});
    assert.ok(server && typeof server === "object");
    assert.strictEqual(typeof server.listen, "function");
    assert.strictEqual(typeof server.close, "function");
  });

  it("boundary: createServer() with no args returns undefined", () => {
    const server = https.createServer();
    assert.strictEqual(server, undefined);
  });

  it("boundary: createServer(options, non-function) returns undefined", () => {
    assert.strictEqual(https.createServer({}, null), undefined);
    assert.strictEqual(https.createServer({}, 1), undefined);
  });
});
