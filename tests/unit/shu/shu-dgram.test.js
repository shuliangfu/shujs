// shu:dgram 模块测试：createSocket、socket 方法（bind/send/close/address/ref/unref/on）全覆盖 + 边界
const { describe, it, assert } = require("shu:test");

const dgram = require("shu:dgram");

describe("shu:dgram", () => {
  it("has createSocket", () => {
    assert.strictEqual(typeof dgram.createSocket, "function");
  });

  it("createSocket('udp4') returns socket with bind, send, close, address, ref, unref, on", () => {
    const socket = dgram.createSocket("udp4");
    assert.ok(socket && typeof socket === "object");
    assert.strictEqual(typeof socket.bind, "function");
    assert.strictEqual(typeof socket.send, "function");
    assert.strictEqual(typeof socket.close, "function");
    assert.strictEqual(typeof socket.address, "function");
    assert.strictEqual(typeof socket.ref, "function");
    assert.strictEqual(typeof socket.unref, "function");
    assert.strictEqual(typeof socket.on, "function");
    assert.strictEqual(typeof socket.setBroadcast, "function");
    assert.strictEqual(typeof socket.setMulticastTTL, "function");
  });

  it("createSocket('udp6') returns socket", () => {
    const socket = dgram.createSocket("udp6");
    assert.ok(socket && typeof socket === "object");
    if (typeof socket.close === "function") socket.close();
  });

  it("socket.on('message', fn) and socket.close() do not throw", () => {
    const socket = dgram.createSocket("udp4");
    socket.on("message", () => {});
    socket.close();
  });

  it("bind(0) then send to self and receive message", (done) => {
    const server = dgram.createSocket("udp4");
    const payload = Buffer.from("dgram-ping");
    server.on("message", (msg) => {
      assert.ok(Buffer.isBuffer(msg) || msg instanceof Uint8Array);
      assert.strictEqual(String(msg), "dgram-ping");
      server.close(() => done());
    });
    server.on("error", (err) => {
      server.close();
      done(err);
    });
    server.bind(0, "127.0.0.1", () => {
      const addr = server.address();
      assert.ok(addr && addr.port > 0);
      const client = dgram.createSocket("udp4");
      client.send(payload, addr.port, "127.0.0.1", (err) => {
        if (err) return done(err);
        client.close();
      });
    });
  });

  it("socket.setBroadcast(flag) does not throw", () => {
    const socket = dgram.createSocket("udp4");
    socket.setBroadcast(false);
    socket.setBroadcast(true);
    socket.close();
  });

  it("socket.setMulticastTTL(ttl) does not throw", () => {
    const socket = dgram.createSocket("udp4");
    socket.setMulticastTTL(1);
    socket.close();
  });
});

describe("shu:dgram boundary", () => {
  it("createSocket() with no args returns undefined", () => {
    const socket = dgram.createSocket();
    assert.strictEqual(socket, undefined);
  });

  it("socket.close() twice with callback does not throw", (done) => {
    const socket = dgram.createSocket("udp4");
    socket.close(() => {});
    socket.close(() => done());
  });

  it("socket.address() before bind returns undefined or empty", () => {
    const socket = dgram.createSocket("udp4");
    const addr = socket.address();
    socket.close();
    assert.ok(addr === undefined || (typeof addr === "object" && (addr.port === undefined || addr.port === 0)));
  });

  it("socket.ref() and unref() before bind do not throw", () => {
    const socket = dgram.createSocket("udp4");
    socket.ref();
    socket.unref();
    socket.close();
  });

  it("setBroadcast and setMulticastTTL after close do not crash", () => {
    const socket = dgram.createSocket("udp4");
    socket.close();
    try {
      socket.setBroadcast(true);
      socket.setMulticastTTL(2);
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });

  it("createSocket with unknown type returns undefined or throws", () => {
    try {
      const s = dgram.createSocket("udp99");
      assert.ok(s === undefined || (s && typeof s.close === "function"));
      if (s && typeof s.close === "function") s.close();
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });
});
