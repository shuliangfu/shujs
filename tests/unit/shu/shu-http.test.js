// shu:http 模块测试（createServer、server.listen、close）
// 约定：新增 API 时补一条正常用例 + 一条边界用例。
const { describe, it, assert } = require("shu:test");

const http = require("shu:http");

describe("shu:http", () => {
  it("has createServer", () => {
    assert.strictEqual(typeof http.createServer, "function");
  });

  it("createServer(requestListener) returns object with listen and close", () => {
    const server = http.createServer(() => {});
    assert.ok(server && typeof server === "object");
    assert.strictEqual(typeof server.listen, "function");
    assert.strictEqual(typeof server.close, "function");
  });

  it("server.listen(0) then server.close() does not throw", (done) => {
    const server = http.createServer((req, res) => res.end("ok"));
    server.listen(0, "127.0.0.1", () => {
      server.close(() => done());
    });
  });

  it("real request: createServer res.end(body), listen(0), fetch, assert body", (done) => {
    const server = http.createServer((_req, res) => {
      res.writeHead(200, { "Content-Type": "text/plain" });
      res.end("http-body");
    });
    server.listen(0, "127.0.0.1", () => {
      const port = server.address().port;
      const url = "http://127.0.0.1:" + port + "/";
      (async () => {
        try {
          const res = await fetch(url);
          const text = await res.text();
          assert.strictEqual(res.status, 200);
          assert.strictEqual(text, "http-body");
        } finally {
          server.close(() => done());
        }
      })();
    });
  });

  it("boundary: createServer() with no args returns undefined", () => {
    const server = http.createServer();
    assert.strictEqual(server, undefined);
  });

  it("boundary: createServer(non-function) returns undefined", () => {
    assert.strictEqual(http.createServer(null), undefined);
    assert.strictEqual(http.createServer(1), undefined);
  });
});
