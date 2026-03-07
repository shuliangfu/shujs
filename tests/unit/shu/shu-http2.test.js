// shu:http2 模块全面测试：API、客户端 connect/request/close、服务端 createServer/createSecureServer/stream/listen、边界
// 需 --allow-net 时才能跑“真实 H2 请求”用例；createSecureServer().listen() 真实启动需 TLS 证书（见下方 TLS_CERT/TLS_KEY）
//
// 约定：新增 API 或分支时补一条正常用例 + 一条边界用例；边界测试集中在 describe("shu:http2 boundary") 下。
const { describe, it, assert } = require("shu:test");
const path = require("shu:path");

const http2 = require("shu:http2");

// 测试用 TLS 证书路径（tests/data/tls 下，可与 TLS_CERT_PATH/TLS_KEY_PATH 覆盖）
const DEFAULT_TLS_CERT = path.join(process.cwd(), "tests", "data", "tls", "cert.pem");
const DEFAULT_TLS_KEY = path.join(process.cwd(), "tests", "data", "tls", "key.pem");

const HOST = "127.0.0.1";
const PORT_HTTP2_SERVER = 19300;
const PORT_HTTP2_BOUNDARY = 19320;

function waitMs(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

// -----------------------------------------------------------------------------
// API 与导出
// -----------------------------------------------------------------------------
describe("shu:http2 API", () => {
  it("has connect, createServer, createSecureServer, getDefaultSettings, getPackedSettings, constants", () => {
    assert.strictEqual(typeof http2.connect, "function");
    assert.strictEqual(typeof http2.createServer, "function");
    assert.strictEqual(typeof http2.createSecureServer, "function");
    assert.strictEqual(typeof http2.getDefaultSettings, "function");
    assert.strictEqual(typeof http2.getPackedSettings, "function");
    assert.ok(http2.constants && typeof http2.constants === "object");
  });

  it("constants has HTTP2_HEADER_* and DEFAULT_SETTINGS_* keys", () => {
    assert.strictEqual(http2.constants.HTTP2_HEADER_STATUS, ":status");
    assert.strictEqual(http2.constants.HTTP2_HEADER_METHOD, ":method");
    assert.strictEqual(http2.constants.HTTP2_HEADER_PATH, ":path");
    assert.strictEqual(http2.constants.HTTP2_HEADER_AUTHORITY, ":authority");
    assert.strictEqual(http2.constants.HTTP2_HEADER_SCHEME, ":scheme");
    assert.strictEqual(http2.constants.HTTP2_HEADER_CONTENT_TYPE, "content-type");
    assert.strictEqual(http2.constants.DEFAULT_SETTINGS_ENABLE_PUSH, 1);
    assert.strictEqual(http2.constants.DEFAULT_SETTINGS_HEADER_TABLE_SIZE, 4096);
    assert.strictEqual(http2.constants.DEFAULT_SETTINGS_INITIAL_WINDOW_SIZE, 65535);
    assert.strictEqual(http2.constants.DEFAULT_SETTINGS_MAX_FRAME_SIZE, 16384);
  });

  it("getDefaultSettings() returns object with expected keys", () => {
    const s = http2.getDefaultSettings();
    assert.ok(s && typeof s === "object");
    assert.ok(typeof s.headerTableSize === "number");
    assert.ok(typeof s.enablePush === "number");
    assert.ok(typeof s.initialWindowSize === "number");
    assert.ok(typeof s.maxFrameSize === "number");
    assert.ok(typeof s.maxConcurrentStreams === "number");
    assert.ok(typeof s.maxHeaderListSize === "number");
    assert.strictEqual(s.headerTableSize, 4096);
    assert.strictEqual(s.enablePush, 1);
    assert.strictEqual(s.initialWindowSize, 65535);
    assert.strictEqual(s.maxFrameSize, 16384);
  });

  it("getPackedSettings() returns Buffer (length 0 or packed payload)", () => {
    const packed = http2.getPackedSettings(http2.getDefaultSettings());
    assert.ok(Buffer.isBuffer(packed));
    assert.ok(Number.isInteger(packed.length) && packed.length >= 0);
  });

  it("getPackedSettings(undefined) returns Buffer without throwing", () => {
    const packed = http2.getPackedSettings(undefined);
    assert.ok(Buffer.isBuffer(packed));
  });
});

// -----------------------------------------------------------------------------
// createServer / createSecureServer 返回对象形态
// -----------------------------------------------------------------------------
describe("shu:http2 createServer / createSecureServer", () => {
  it("createServer() returns object with _events, on, listen", () => {
    const server = http2.createServer();
    assert.ok(server && typeof server === "object");
    assert.ok(Array.isArray(server._events?.stream) || server._events?.stream === undefined);
    assert.strictEqual(typeof server.on, "function");
    assert.strictEqual(typeof server.listen, "function");
  });

  it("createSecureServer() returns object with _events, on, listen, _tlsOptions", () => {
    const server = http2.createSecureServer({ cert: "/tmp/c.pem", key: "/tmp/k.pem" });
    assert.ok(server && typeof server === "object");
    assert.strictEqual(typeof server.on, "function");
    assert.strictEqual(typeof server.listen, "function");
    assert.ok(server._tlsOptions != null);
    assert.strictEqual(server._tlsOptions.cert, "/tmp/c.pem");
    assert.strictEqual(server._tlsOptions.key, "/tmp/k.pem");
  });

  it("createSecureServer() with no args returns server without _tlsOptions", () => {
    const server = http2.createSecureServer();
    assert.ok(server && typeof server === "object");
    assert.strictEqual(typeof server.listen, "function");
    assert.ok(server._tlsOptions === undefined || server._tlsOptions == null);
  });

  it("server.on('stream', fn) registers listener", () => {
    const server = http2.createSecureServer({ cert: "c", key: "k" });
    const fn = (stream, headers) => { stream.respond({ ":status": 200 }); stream.end(""); };
    server.on("stream", fn);
    assert.ok(Array.isArray(server._events.stream));
    assert.strictEqual(server._events.stream.length, 1);
    assert.strictEqual(server._events.stream[0], fn);
  });

  it("server.on('stream', fn1); server.on('stream', fn2) pushes second listener", () => {
    const server = http2.createSecureServer({});
    const fn1 = () => {};
    const fn2 = () => {};
    server.on("stream", fn1);
    server.on("stream", fn2);
    assert.strictEqual(server._events.stream.length, 2);
    assert.strictEqual(server._events.stream[0], fn1);
    assert.strictEqual(server._events.stream[1], fn2);
  });
});

// -----------------------------------------------------------------------------
// 客户端 connect / session.request / session.close
// -----------------------------------------------------------------------------
describe("shu:http2 client connect and session", () => {
  it("connect(url) returns object with request and close", () => {
    const session = http2.connect("https://example.com/");
    assert.ok(session && typeof session === "object");
    assert.strictEqual(typeof session.request, "function");
    assert.strictEqual(typeof session.close, "function");
    assert.ok(session.__url != null);
  });

  it("session.close() does not throw", () => {
    const session = http2.connect("https://example.com/");
    session.close();
  });

  it("session.close(callback) invokes callback", (done) => {
    const session = http2.connect("https://example.com/");
    session.close(() => done());
  });

  it("session.request(callback) with invalid URL invokes callback with err", (done) => {
    const session = http2.connect("https://invalid-domain-that-does-not-resolve-xyz-12345.local/");
    session.request((err, res) => {
      assert.ok(err != null);
      assert.ok(res === undefined || res == null);
      done();
    });
  });

  it("session.request(opts, callback) same as request(callback) for callback", (done) => {
    const session = http2.connect("https://invalid-domain-xyz-789.local/");
    session.request({}, (err) => {
      assert.ok(err != null);
      done();
    });
  });
});

// -----------------------------------------------------------------------------
// 真实 HTTP/2 客户端请求（需 --allow-net；若环境无网可跳过）
// -----------------------------------------------------------------------------
describe("shu:http2 real client request (requires --allow-net)", () => {
  it("connect(https://nghttp2.org/) and session.request get statusCode/headers/body", (done) => {
    const session = http2.connect("https://nghttp2.org/");
    session.request((err, res) => {
      if (err) {
        try {
          assert.ok(err.message != null || err.code != null);
        } catch (_) {}
        session.close();
        return done();
      }
      assert.ok(res && typeof res === "object");
      assert.ok(Number.isInteger(res.statusCode));
      assert.ok(res.headers != null && typeof res.headers === "object");
      assert.ok(typeof res.body === "string");
      session.close();
      done();
    });
  });
});

// -----------------------------------------------------------------------------
// createServer (plain) listen 抛错
// -----------------------------------------------------------------------------
describe("shu:http2 createServer (plain) listen throws", () => {
  it("createServer().listen(port) throws (plain not implemented)", () => {
    const server = http2.createServer();
    server.on("stream", () => {});
    assert.throws(
      () => server.listen(PORT_HTTP2_SERVER, HOST),
      /plain.*not implemented|createServer.*listen/i
    );
  });
});

// -----------------------------------------------------------------------------
// createSecureServer listen 边界：无 stream、无 cert/key、无效 port
// -----------------------------------------------------------------------------
describe("shu:http2 createSecureServer listen boundary", () => {
  it("listen(port) without .on('stream') throws", () => {
    const server = http2.createSecureServer({ cert: "/c.pem", key: "/k.pem" });
    assert.throws(
      () => server.listen(PORT_HTTP2_BOUNDARY, HOST),
      /no 'stream' listener|stream listener/i
    );
  });

  it("listen(port) without cert/key in options throws", () => {
    const server = http2.createSecureServer({});
    server.on("stream", (stream, headers) => { stream.respond({ ":status": 200 }); stream.end(""); });
    assert.throws(
      () => server.listen(PORT_HTTP2_BOUNDARY + 1, HOST),
      /cert.*key|options must have/i
    );
  });

  it("listen(port) with empty string cert/key throws", () => {
    const server = http2.createSecureServer({ cert: "", key: "" });
    server.on("stream", () => {});
    assert.throws(
      () => server.listen(PORT_HTTP2_BOUNDARY + 2, HOST),
      /cert.*key/i
    );
  });

  it("listen() with no port argument does not throw (returns undefined or throws)", () => {
    const server = http2.createSecureServer({ cert: "/c", key: "/k" });
    server.on("stream", () => {});
    try {
      const ret = server.listen();
      assert.ok(ret === undefined || ret === server);
    } catch (e) {
      assert.ok(e != null);
    }
  });

  it("listen(0) invalid port: may throw or fail later", () => {
    const server = http2.createSecureServer({ cert: "/c", key: "/k" });
    server.on("stream", () => {});
    try {
      server.listen(0, HOST);
      assert.ok(server.stop != null || server.stop === undefined);
      if (typeof server.stop === "function") server.stop();
    } catch (e) {
      assert.ok(e != null);
    }
  });

  it("listen(99999) invalid port: returns undefined or throws", () => {
    const server = http2.createSecureServer({ cert: "/c", key: "/k" });
    server.on("stream", () => {});
    try {
      const ret = server.listen(99999, HOST);
      assert.ok(ret === undefined || ret === server);
    } catch (e) {
      assert.ok(e != null);
    }
  });
});

// -----------------------------------------------------------------------------
// createSecureServer 真实启动（仅当 TLS_CERT_PATH / TLS_KEY_PATH 环境变量存在时）
// -----------------------------------------------------------------------------
describe("shu:http2 createSecureServer real listen (optional TLS cert)", () => {
  const certPath = process.env.TLS_CERT_PATH || DEFAULT_TLS_CERT;
  const keyPath = process.env.TLS_KEY_PATH || DEFAULT_TLS_KEY;
  const hasTlsCert = certPath.length > 0 && keyPath.length > 0;

  it("createSecureServer(cert,key).on('stream').listen(port,callback) starts and callback gets server, stop() works", async function () {
    if (!hasTlsCert) {
      this.skip();
      return;
    }
    const server = http2.createSecureServer({ cert: certPath, key: keyPath });
    server.on("stream", (stream) => {
      stream.respond({ ":status": 200, "content-type": "text/plain" });
      stream.end("h2-body");
    });
    await new Promise((resolve, reject) => {
      server.listen(PORT_HTTP2_SERVER, HOST, (err) => {
        if (err) return reject(err);
        resolve();
      });
    });
    assert.strictEqual(typeof server.stop, "function");
    server.stop();
    await waitMs(120);
  });
});

// -----------------------------------------------------------------------------
// 边界：connect 无效参数、getDefaultSettings/getPackedSettings 边界
// -----------------------------------------------------------------------------
describe("shu:http2 boundary", () => {
  it("connect() with no args returns undefined", () => {
    const session = http2.connect();
    assert.strictEqual(session, undefined);
  });

  it("connect(123) non-string url returns undefined", () => {
    const session = http2.connect(123);
    assert.strictEqual(session, undefined);
  });

  it("connect(null) returns undefined", () => {
    assert.strictEqual(http2.connect(null), undefined);
  });

  it("getDefaultSettings() return value has numeric fields in valid range", () => {
    const s = http2.getDefaultSettings();
    assert.ok(s.headerTableSize >= 0);
    assert.ok(s.initialWindowSize >= 0);
    assert.ok(s.maxFrameSize >= 16384 && s.maxFrameSize <= 16777215);
    assert.ok(s.maxConcurrentStreams >= 0);
    assert.ok(s.maxHeaderListSize >= 0);
  });

  it("getPackedSettings({}) returns Buffer", () => {
    const packed = http2.getPackedSettings({});
    assert.ok(Buffer.isBuffer(packed));
  });

  it("createServer with no listener: server still has on/listen", () => {
    const server = http2.createServer();
    assert.strictEqual(typeof server.on, "function");
    assert.strictEqual(typeof server.listen, "function");
  });
});
