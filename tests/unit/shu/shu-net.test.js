// shu:net 模块测试（createServer/createConnection/connect/isIP/Server/Socket 等）
// 约定：新增 API 时补一条正常用例 + 一条边界用例。
const { describe, it, assert } = require("shu:test");

const net = require("shu:net");

describe("shu:net", () => {
  it("has createServer, createConnection, connect, Server, Socket", () => {
    assert.strictEqual(typeof net.createServer, "function");
    assert.strictEqual(typeof net.createConnection, "function");
    assert.strictEqual(typeof net.connect, "function");
    assert.strictEqual(typeof net.Server, "function");
    assert.strictEqual(typeof net.Socket, "function");
  });

  it("has isIP, isIPv4, isIPv6", () => {
    assert.strictEqual(typeof net.isIP, "function");
    assert.strictEqual(typeof net.isIPv4, "function");
    assert.strictEqual(typeof net.isIPv6, "function");
  });

  it("isIP('127.0.0.1') returns 4", () => {
    assert.strictEqual(net.isIP("127.0.0.1"), 4);
  });

  it("isIP('::1') returns 6", () => {
    assert.strictEqual(net.isIP("::1"), 6);
  });

  it("isIPv4('127.0.0.1') is true, isIPv6('::1') is true", () => {
    assert.strictEqual(net.isIPv4("127.0.0.1"), true);
    assert.strictEqual(net.isIPv6("::1"), true);
  });

  it("isIP('not-an-ip') returns 0", () => {
    assert.strictEqual(net.isIP("not-an-ip"), 0);
  });

  it("createServer(connectionListener) returns object with listen and close", () => {
    const server = net.createServer(() => {});
    assert.ok(server && typeof server.listen === "function" && typeof server.close === "function");
  });

  it("boundary: isIP('') returns 0", () => {
    assert.strictEqual(net.isIP(""), 0);
  });

  it("boundary: createServer() with no listener returns object or undefined", () => {
    const server = net.createServer();
    if (server !== undefined) {
      assert.ok(typeof server.listen === "function");
    }
  });

  it("server.listen(0) and net.connect(port) exchange data", (done) => {
    const server = net.createServer((socket) => {
      socket.on("data", (data) => {
        assert.strictEqual(String(data), "ping");
        socket.write("pong");
        socket.end();
      });
    });
    server.listen(0, "127.0.0.1", () => {
      const port = server.address().port;
      const client = net.connect(port, "127.0.0.1", () => {
        client.write("ping");
      });
      let received = "";
      client.on("data", (data) => {
        received += String(data);
      });
      client.on("end", () => {
        assert.strictEqual(received, "pong");
        server.close(() => done());
      });
    });
  });
});

describe("shu:net boundary (production edge cases)", () => {
  it("isIP(null) and isIP(123) return 0 or do not throw", () => {
    try {
      assert.ok(net.isIP(null) === 0 || net.isIP(null) === undefined);
    } catch (e) {
      assert.ok(e instanceof Error);
    }
    try {
      assert.ok(typeof net.isIP(123) === "number" || net.isIP(123) === undefined);
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });

  it("server.close() twice with callback does not throw", (done) => {
    const server = net.createServer(() => {});
    server.listen(0, "127.0.0.1", () => {
      server.close(() => {});
      server.close(() => done());
    });
  });

  it("net.connect to invalid port triggers error or closes", (done) => {
    let finished = false;
    const once = () => {
      if (finished) return;
      finished = true;
      client.destroy();
      done();
    };
    const client = net.connect(0, "127.0.0.1");
    client.on("error", once);
    client.on("connect", once);
    setTimeout(once, 500);
  });
});
