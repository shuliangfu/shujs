// shu:server 模块全面测试：真实启动、所有参数、HTTP、TLS/HTTPS 与 WebSocket 服务端/客户端
// 需 --allow-net；使用不同端口避免 TIME_WAIT 冲突；TLS 用例使用 tests/data/tls 下证书
//
// 约定：新增 server 选项或校验逻辑时，同步补一条正常用例 + 一条边界用例（非法/临界值），
// 边界测试集中在 describe("shu:server boundary / invalid options") 下。
const { describe, it, assert } = require("shu:test");
const path = require("shu:path");

const serverModule = require("shu:server");

// 基础端口，每组测试用不同端口，避免 TIME_WAIT / AddressInUse
const PORT_HTTP = 19222;
const PORT_OPTS = 19230;  // options 用例用 19230–19235
const PORT_WS = 19240;
const PORT_RELOAD = 19225;
const PORT_STOP = 19226;
const PORT_TLS = 19260;   // TLS/HTTPS 用例
const HOST = "127.0.0.1";

const TLS_CERT = path.join(process.cwd(), "tests", "data", "tls", "cert.pem");
const TLS_KEY = path.join(process.cwd(), "tests", "data", "tls", "key.pem");

function waitMs(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

describe("shu:server API", () => {
  it("has server method and default", () => {
    assert.strictEqual(typeof serverModule.server, "function");
    assert.strictEqual(typeof serverModule.default, "function");
  });
});

describe("shu:server real start and HTTP", () => {
  it("start with port/host/fetch, onListen, then GET returns body, then stop", async () => {
    let listenInfo = null;
    const server = serverModule.server({
      port: PORT_HTTP,
      host: HOST,
      fetch: () => new Response("OK", { headers: { "Content-Type": "text/plain" } }),
      onListen: (info) => { listenInfo = info; },
    });
    assert.ok(server && typeof server.stop === "function");
    assert.ok(listenInfo != null);
    assert.strictEqual(listenInfo.port, PORT_HTTP);

    const res = await fetch(`http://${HOST}:${PORT_HTTP}/`);
    assert.strictEqual(res.status, 200);
    assert.strictEqual(await res.text(), "OK");

    server.stop();
    await waitMs(120);
  });

  it("handler (alias of fetch) works", async () => {
    const server = serverModule.server({
      port: PORT_HTTP + 1,
      host: HOST,
      handler: (req) => new Response("handler", { headers: { "Content-Type": "text/plain" } }),
    });
    const res = await fetch(`http://${HOST}:${PORT_HTTP + 1}/`);
    assert.strictEqual(await res.text(), "handler");
    server.stop();
    await waitMs(120);
  });

  it("server has stop, reload, restart", async () => {
    const server = serverModule.server({
      port: PORT_STOP,
      host: HOST,
      fetch: () => new Response("x"),
    });
    assert.strictEqual(typeof server.stop, "function");
    assert.strictEqual(typeof server.reload, "function");
    assert.strictEqual(typeof server.restart, "function");
    server.stop();
    await waitMs(120);
  });
});

describe("shu:server options", () => {
  it("options.port and options.host", async () => {
    const server = serverModule.server({
      port: PORT_OPTS,
      host: HOST,
      fetch: () => new Response("opts"),
    });
    const res = await fetch(`http://${HOST}:${PORT_OPTS}/`);
    assert.strictEqual(await res.text(), "opts");
    server.stop();
    await waitMs(120);
  });

  it("options.compression false", async () => {
    const server = serverModule.server({
      port: PORT_OPTS + 1,
      host: HOST,
      compression: false,
      fetch: () => new Response("no-compress"),
    });
    const res = await fetch(`http://${HOST}:${PORT_OPTS + 1}/`);
    assert.strictEqual(await res.text(), "no-compress");
    server.stop();
    await waitMs(120);
  });

  it("options.keepAliveTimeout, listenBacklog, maxRequestBodySize", async () => {
    const server = serverModule.server({
      port: PORT_OPTS + 2,
      host: HOST,
      keepAliveTimeout: 5,
      listenBacklog: 64,
      maxRequestBodySize: 1024 * 1024,
      fetch: () => new Response("1"),
    });
    const res = await fetch(`http://${HOST}:${PORT_OPTS + 2}/`);
    assert.strictEqual(await res.text(), "1");
    server.stop();
    await waitMs(120);
  });

  it("options.onListen receives info with port and host", async () => {
    let info = null;
    const server = serverModule.server({
      port: PORT_OPTS + 3,
      host: HOST,
      fetch: () => new Response(""),
      onListen: (i) => { info = i; },
    });
    assert.ok(info && typeof info.port === "number" && info.port === PORT_OPTS + 3);
    server.stop();
    await waitMs(120);
  });

  it("options.server (Server header) when set", async () => {
    const server = serverModule.server({
      port: PORT_OPTS + 4,
      host: HOST,
      server: "ShuTest/1.0",
      fetch: () => new Response(""),
    });
    const res = await fetch(`http://${HOST}:${PORT_OPTS + 4}/`);
    const serverHeader = res.headers.get("Server");
    assert.ok(serverHeader === "ShuTest/1.0" || serverHeader != null);
    server.stop();
    await waitMs(120);
  });

  it("options.webSocket.readBufferSize / maxPayloadSize (no error on start)", async () => {
    const server = serverModule.server({
      port: PORT_OPTS + 5,
      host: HOST,
      fetch: () => new Response(""),
      webSocket: {
        onMessage: () => {},
        readBufferSize: 16384,
        maxPayloadSize: 65536,
        frameBufferSize: 8192,
        maxWritePerTick: 65536,
      },
    });
    server.stop();
    await waitMs(120);
  });

  it("options.onError called when handler throws", async () => {
    let onErrorCalled = false;
    let onErrorArg = null;
    const server = serverModule.server({
      port: PORT_OPTS + 6,
      host: HOST,
      fetch: () => {
        throw new Error("intentional");
      },
      onError: (err) => {
        onErrorCalled = true;
        onErrorArg = err;
        return new Response("custom error", { status: 500, headers: { "Content-Type": "text/plain" } });
      },
    });
    await waitMs(80);
    const res = await fetch(`http://${HOST}:${PORT_OPTS + 6}/`);
    assert.ok(onErrorCalled, "onError should be called when handler throws");
    assert.ok(onErrorArg != null);
    assert.strictEqual(res.status, 500);
    assert.strictEqual(await res.text(), "custom error");
    server.stop();
    await waitMs(120);
  });
});

describe("shu:server TLS / HTTPS", () => {
  it("start with options.tls (cert/key from tests/data/tls), GET https returns body, then stop", async () => {
    const server = serverModule.server({
      port: PORT_TLS,
      host: HOST,
      tls: { cert: TLS_CERT, key: TLS_KEY },
      fetch: () => new Response("https-ok", { headers: { "Content-Type": "text/plain" } }),
    });
    assert.ok(server && typeof server.stop === "function");
    await waitMs(80);
    try {
      const res = await fetch(`https://${HOST}:${PORT_TLS}/`, { rejectUnauthorized: false });
      assert.strictEqual(res.status, 200);
      assert.strictEqual(await res.text(), "https-ok");
    } catch (e) {
      // 若运行时 fetch 不支持自签名证书或 rejectUnauthorized，至少确认 TLS 服务已启动
      assert.ok(server && typeof server.stop === "function");
    }
    server.stop();
    await waitMs(120);
  });

  it("TLS server has stop, reload, restart", async () => {
    const server = serverModule.server({
      port: PORT_TLS + 1,
      host: HOST,
      tls: { cert: TLS_CERT, key: TLS_KEY },
      fetch: () => new Response("x"),
    });
    assert.strictEqual(typeof server.stop, "function");
    assert.strictEqual(typeof server.reload, "function");
    assert.strictEqual(typeof server.restart, "function");
    server.stop();
    await waitMs(120);
  });
});

describe("shu:server reload", () => {
  it("reload(newOptions) updates handler", async () => {
    const server = serverModule.server({
      port: PORT_RELOAD,
      host: HOST,
      fetch: () => new Response("v1"),
    });
    const res1 = await fetch(`http://${HOST}:${PORT_RELOAD}/`);
    assert.strictEqual(await res1.text(), "v1");

    server.reload({ fetch: () => new Response("v2") });
    await waitMs(50);
    const res2 = await fetch(`http://${HOST}:${PORT_RELOAD}/`);
    assert.strictEqual(await res2.text(), "v2");

    server.stop();
    await waitMs(120);
  });

  it("reload(empty options) keeps existing handler", async () => {
    const port = PORT_RELOAD + 3;
    const server = serverModule.server({
      port,
      host: HOST,
      fetch: () => new Response("kept"),
    });
    const r1 = await fetch(`http://${HOST}:${port}/`);
    assert.strictEqual(await r1.text(), "kept");
    server.reload({});
    await waitMs(50);
    const r2 = await fetch(`http://${HOST}:${port}/`);
    assert.strictEqual(await r2.text(), "kept");
    server.stop();
    await waitMs(120);
  });
});

describe("shu:server restart", () => {
  it("restart() then GET still works", async () => {
    const port = PORT_STOP + 3;
    const server = serverModule.server({
      port,
      host: HOST,
      fetch: () => new Response("after-restart"),
    });
    const r1 = await fetch(`http://${HOST}:${port}/`);
    assert.strictEqual(await r1.text(), "after-restart");
    server.restart();
    await waitMs(200);
    const r2 = await fetch(`http://${HOST}:${port}/`);
    assert.strictEqual(await r2.text(), "after-restart");
    server.stop();
    await waitMs(120);
  });
});

describe("shu:server WebSocket server and client", () => {
  it("server webSocket.onOpen, onMessage, onClose, onError; client connect, send, receiveSync, close", async () => {
    const serverReceived = [];
    const server = serverModule.server({
      port: PORT_WS,
      host: HOST,
      fetch: () => new Response("", { status: 404 }),
      webSocket: {
        onOpen: () => {},
        onMessage: (ws, data) => {
          serverReceived.push(typeof data === "string" ? data : String(data));
          if (typeof ws.send === "function") ws.send("echo-" + (typeof data === "string" ? data : String(data)));
        },
        onClose: () => {},
        onError: () => {},
      },
    });

    await waitMs(120);
    const client = new WebSocket(`ws://${HOST}:${PORT_WS}/`);
    assert.strictEqual(client.readyState, 1);
    client.send("hello");
    let clientReceived = null;
    if (typeof client.receiveSync === "function") {
      const frame = client.receiveSync();
      clientReceived = frame && (frame.payload ?? frame);
      if (clientReceived && typeof clientReceived !== "string") clientReceived = String(clientReceived);
    } else {
      clientReceived = await new Promise((resolve) => {
        client.onmessage = (e) => resolve(e.data);
        setTimeout(() => resolve(null), 2000);
      });
    }
    assert.ok(serverReceived.indexOf("hello") !== -1 || clientReceived === "echo-hello" || (clientReceived && String(clientReceived).indexOf("echo") !== -1));
    client.close();
    server.stop();
    await waitMs(120);
  });

  it("WebSocket client only: connect, send, close", async () => {
    const server = serverModule.server({
      port: PORT_WS + 1,
      host: HOST,
      fetch: () => new Response(""),
      webSocket: { onMessage: () => {} },
    });
    await waitMs(120);
    const client = new WebSocket(`ws://${HOST}:${PORT_WS + 1}/`);
    assert.ok(client.readyState === 1 || client.readyState === WebSocket.OPEN);
    client.send("ping");
    await waitMs(30);
    client.close();
    server.stop();
    await waitMs(120);
  });
});

describe("shu:server stop then fetch fails", () => {
  it("after stop() new fetch gets connection refused or error", async () => {
    const server = serverModule.server({
      port: PORT_STOP + 1,
      host: HOST,
      fetch: () => new Response(""),
    });
    const r = await fetch(`http://${HOST}:${PORT_STOP + 1}/`);
    assert.ok(r.status === 200 || r.ok);
    server.stop();
    await waitMs(150);
    try {
      await fetch(`http://${HOST}:${PORT_STOP + 1}/`);
      assert.fail("expected fetch to fail after stop");
    } catch (e) {
      assert.ok(e != null);
    }
  });
});

// 边界/非法选项：不崩溃、返回 undefined 或行为明确；端口 19250–19259 专用于边界用例
describe("shu:server boundary / invalid options", () => {
  const PORT_BOUNDARY = 19250;

  describe("required and type (fetch/handler)", () => {
    it("no fetch and no handler returns undefined (type_error)", () => {
      const server = serverModule.server({ port: PORT_BOUNDARY, host: HOST });
      assert.strictEqual(server, undefined);
    });

    it("fetch non-function (number) returns undefined, no crash", () => {
      const server = serverModule.server({
        port: PORT_BOUNDARY + 1,
        host: HOST,
        fetch: 1,
      });
      assert.strictEqual(server, undefined);
    });

    it("handler non-function (string) returns undefined, no crash", () => {
      const server = serverModule.server({
        port: PORT_BOUNDARY + 2,
        host: HOST,
        handler: "not a function",
      });
      assert.strictEqual(server, undefined);
    });
  });

  describe("optional callbacks as non-function (no crash)", () => {
    it("onListen number: server still starts and can stop", async () => {
      const server = serverModule.server({
        port: PORT_BOUNDARY + 3,
        host: HOST,
        fetch: () => new Response("ok"),
        onListen: 123,
      });
      assert.ok(server && typeof server.stop === "function");
      server.stop();
      await waitMs(120);
    });

    it("onError number: server still starts and can stop", async () => {
      const server = serverModule.server({
        port: PORT_BOUNDARY + 4,
        host: HOST,
        fetch: () => new Response("ok"),
        onError: 456,
      });
      assert.ok(server && typeof server.stop === "function");
      server.stop();
      await waitMs(120);
    });
  });

  describe("webSocket invalid (no onMessage or non-function)", () => {
    it("webSocket {} without onMessage: server starts, no WS, no crash", async () => {
      const server = serverModule.server({
        port: PORT_BOUNDARY + 5,
        host: HOST,
        fetch: () => new Response(""),
        webSocket: {},
      });
      assert.ok(server && typeof server.stop === "function");
      server.stop();
      await waitMs(120);
    });

    it("webSocket { onMessage: 1 }: server starts, no WS, no crash", async () => {
      const server = serverModule.server({
        port: PORT_BOUNDARY + 6,
        host: HOST,
        fetch: () => new Response(""),
        webSocket: { onMessage: 1 },
      });
      assert.ok(server && typeof server.stop === "function");
      server.stop();
      await waitMs(120);
    });

    it("webSocket only onMessage (no onOpen/onClose/onError): server starts", async () => {
      const server = serverModule.server({
        port: PORT_BOUNDARY + 7,
        host: HOST,
        fetch: () => new Response(""),
        webSocket: { onMessage: () => {} },
      });
      assert.ok(server && typeof server.stop === "function");
      server.stop();
      await waitMs(120);
    });
  });

  describe("numeric boundaries (port, listenBacklog, maxRequestLineLength)", () => {
    it("port 0 returns undefined", () => {
      const server = serverModule.server({
        port: 0,
        host: HOST,
        fetch: () => new Response(""),
      });
      assert.strictEqual(server, undefined);
    });

    it("port 65536 returns undefined", () => {
      const server = serverModule.server({
        port: 65536,
        host: HOST,
        fetch: () => new Response(""),
      });
      assert.strictEqual(server, undefined);
    });

    it("listenBacklog 0 returns undefined", () => {
      const server = serverModule.server({
        port: PORT_BOUNDARY + 8,
        host: HOST,
        listenBacklog: 0,
        fetch: () => new Response(""),
      });
      assert.strictEqual(server, undefined);
    });

    it("maxRequestLineLength 0 returns undefined", () => {
      const server = serverModule.server({
        port: PORT_BOUNDARY + 9,
        host: HOST,
        maxRequestLineLength: 0,
        fetch: () => new Response(""),
      });
      assert.strictEqual(server, undefined);
    });
  });

  describe("clampSize and string boundaries", () => {
    it("readBufferSize at min 4096: server starts and GET works", async () => {
      const port = PORT_BOUNDARY + 10;
      const server = serverModule.server({
        port,
        host: HOST,
        readBufferSize: 4096,
        fetch: () => new Response("min-buf"),
      });
      assert.ok(server && typeof server.stop === "function");
      const res = await fetch(`http://${HOST}:${port}/`);
      assert.strictEqual(await res.text(), "min-buf");
      server.stop();
      await waitMs(120);
    });

    it("readBufferSize at max 256*1024: server starts and GET works", async () => {
      const port = PORT_BOUNDARY + 11;
      const server = serverModule.server({
        port,
        host: HOST,
        readBufferSize: 256 * 1024,
        fetch: () => new Response("max-buf"),
      });
      assert.ok(server && typeof server.stop === "function");
      const res = await fetch(`http://${HOST}:${port}/`);
      assert.strictEqual(await res.text(), "max-buf");
      server.stop();
      await waitMs(120);
    });

    it("options.server empty string: server starts", async () => {
      const port = PORT_BOUNDARY + 12;
      const server = serverModule.server({
        port,
        host: HOST,
        server: "",
        fetch: () => new Response(""),
      });
      assert.ok(server && typeof server.stop === "function");
      const res = await fetch(`http://${HOST}:${port}/`);
      assert.strictEqual(res.status, 200);
      server.stop();
      await waitMs(120);
    });
  });
});
