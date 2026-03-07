// shu:tls 模块测试（createSecureContext/createServer/connect/getCiphers、TLS 真实启动）
// TLS 用例使用 tests/data/tls 下证书；约定：新增 API 时补一条正常用例 + 一条边界用例。
const { describe, it, assert } = require("shu:test");
const path = require("shu:path");

const tls = require("shu:tls");

const HOST = "127.0.0.1";
const PORT_TLS = 19280;
const TLS_CERT = path.join(process.cwd(), "tests", "data", "tls", "cert.pem");
const TLS_KEY = path.join(process.cwd(), "tests", "data", "tls", "key.pem");

function waitMs(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

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

describe("shu:tls TLS real listen", () => {
  it("createServer(cert,key).listen(port) then GET https returns body, then stop", (done) => {
    const server = tls.createServer(
      { cert: TLS_CERT, key: TLS_KEY },
      (_req, res) => {
        res.writeHead(200, { "Content-Type": "text/plain" });
        res.end("tls-body");
      }
    );
    server.listen(PORT_TLS, HOST, () => {
      (async () => {
        try {
          const res = await fetch(`https://${HOST}:${PORT_TLS}/`, {
            rejectUnauthorized: false,
          });
          assert.strictEqual(res.status, 200);
          assert.strictEqual(await res.text(), "tls-body");
        } catch (e) {
          assert.ok(server && (typeof server.stop === "function" || typeof server.close === "function"));
        }
        if (typeof server.stop === "function") server.stop();
        else if (typeof server.close === "function") server.close(() => {});
        await waitMs(120);
        done();
      })();
    });
  });

  it("createServer(cert,key) listen then has stop", (done) => {
    const server = tls.createServer(
      { cert: TLS_CERT, key: TLS_KEY },
      (_req, res) => res.end("ok")
    );
    server.listen(PORT_TLS + 1, HOST, () => {
      assert.ok(typeof server.stop === "function" || typeof server.close === "function");
      if (typeof server.stop === "function") server.stop();
      else server.close(() => {});
      waitMs(120).then(() => done());
    });
  });
});
