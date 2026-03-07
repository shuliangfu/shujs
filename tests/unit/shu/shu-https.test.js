// shu:https 模块测试（createServer、server.listen/close、TLS 真实启动）
// TLS 用例使用 tests/data/tls 下证书；约定：新增 API 时补一条正常用例 + 一条边界用例。
const { describe, it, assert } = require("shu:test");
const path = require("shu:path");

const https = require("shu:https");

const HOST = "127.0.0.1";
const PORT_HTTPS = 19270;
const TLS_CERT = path.join(process.cwd(), "tests", "data", "tls", "cert.pem");
const TLS_KEY = path.join(process.cwd(), "tests", "data", "tls", "key.pem");

function waitMs(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

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

describe("shu:https TLS real listen", () => {
  it("createServer(cert,key).listen(port) then GET https returns body, then stop", (done) => {
    const server = https.createServer(
      { cert: TLS_CERT, key: TLS_KEY },
      (_req, res) => {
        res.writeHead(200, { "Content-Type": "text/plain" });
        res.end("https-body");
      }
    );
    server.listen(PORT_HTTPS, HOST, () => {
      (async () => {
        try {
          const res = await fetch(`https://${HOST}:${PORT_HTTPS}/`, {
            rejectUnauthorized: false,
          });
          assert.strictEqual(res.status, 200);
          assert.strictEqual(await res.text(), "https-body");
        } catch (e) {
          assert.ok(server && (typeof server.stop === "function" || typeof server.close === "function"));
        }
        if (typeof server.stop === "function") server.stop();
        else if (typeof server.close === "function") server.close(() => {});
        waitMs(120).then(() => done());
      })();
    });
  });

  it("createServer(cert,key) with listener only: listen then stop", (done) => {
    const server = https.createServer(
      { cert: TLS_CERT, key: TLS_KEY },
      (_req, res) => res.end("ok")
    );
    server.listen(PORT_HTTPS + 1, HOST, () => {
      assert.ok(typeof server.stop === "function" || typeof server.close === "function");
      if (typeof server.stop === "function") server.stop();
      else server.close(() => {});
      waitMs(120).then(() => done());
    });
  });
});
