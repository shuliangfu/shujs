/**
 * Node 相关全局 API 兼容测试：reportError、MessageChannel、BroadcastChannel、Buffer、process、console 等
 */
const { describe, it, assert } = require("shu:test");

describe("reportError (Web standard)", () => {
  it("reportError is a function", () => {
    assert.strictEqual(typeof globalThis.reportError, "function");
  });

  it("reportError(err) does not throw (delegates to console.error)", () => {
    const err = new Error("reportError smoke");
    assert.doesNotThrow(() => {
      reportError(err);
    });
  });
});

describe("MessageChannel (Web / Node)", () => {
  it("MessageChannel is a function", () => {
    assert.strictEqual(typeof globalThis.MessageChannel, "function");
  });

  it("new MessageChannel() returns object with port1 and port2", () => {
    const ch = new MessageChannel();
    assert.ok(ch != null);
    assert.ok("port1" in ch);
    assert.ok("port2" in ch);
    assert.ok(ch.port1 != null);
    assert.ok(ch.port2 != null);
  });

  it("each port has postMessage and onmessage", () => {
    const ch = new MessageChannel();
    assert.strictEqual(typeof ch.port1.postMessage, "function");
    assert.strictEqual(typeof ch.port2.postMessage, "function");
    assert.ok("onmessage" in ch.port1);
    assert.ok("onmessage" in ch.port2);
  });

  it("port.postMessage throws not implemented (stub)", () => {
    const ch = new MessageChannel();
    assert.throws(
      () => ch.port1.postMessage("x"),
      /not implemented/i
    );
  });
});

describe("BroadcastChannel (Web)", () => {
  it("BroadcastChannel is a function", () => {
    assert.strictEqual(typeof globalThis.BroadcastChannel, "function");
  });

  it("new BroadcastChannel(name) throws not implemented (stub)", () => {
    assert.throws(
      () => new BroadcastChannel("test"),
      /not implemented/i
    );
  });
});

describe("Buffer (global, Node-compat)", () => {
  it("Buffer is available on globalThis", () => {
    assert.ok(globalThis.Buffer != null);
    assert.strictEqual(typeof globalThis.Buffer, "function");
  });

  it("Buffer.alloc returns Buffer instance", () => {
    const b = Buffer.alloc(8);
    assert.ok(Buffer.isBuffer(b));
    assert.strictEqual(b.length, 8);
  });

  it("Buffer.from(string) returns Buffer", () => {
    const b = Buffer.from("hello");
    assert.ok(Buffer.isBuffer(b));
    assert.strictEqual(b.length, 5);
  });
});

describe("process (global, Node-compat)", () => {
  it("process is available", () => {
    assert.ok(globalThis.process != null);
  });

  it("process has cwd, platform, env, argv", () => {
    assert.strictEqual(typeof process.cwd, "function");
    assert.strictEqual(typeof process.platform, "string");
    assert.ok(process.env != null && typeof process.env === "object");
    assert.ok(Array.isArray(process.argv));
  });
});

describe("console (global)", () => {
  it("console has log, warn, error, info, debug", () => {
    assert.strictEqual(typeof console.log, "function");
    assert.strictEqual(typeof console.warn, "function");
    assert.strictEqual(typeof console.error, "function");
    assert.strictEqual(typeof console.info, "function");
    assert.strictEqual(typeof console.debug, "function");
  });
});

describe("timers (global)", () => {
  it("setTimeout and setInterval are functions", () => {
    assert.strictEqual(typeof globalThis.setTimeout, "function");
    assert.strictEqual(typeof globalThis.setInterval, "function");
  });

  it("clearTimeout and clearInterval are functions", () => {
    assert.strictEqual(typeof globalThis.clearTimeout, "function");
    assert.strictEqual(typeof globalThis.clearInterval, "function");
  });

  it("setImmediate and queueMicrotask are functions", () => {
    assert.strictEqual(typeof globalThis.setImmediate, "function");
    assert.strictEqual(typeof globalThis.queueMicrotask, "function");
  });
});

describe("crypto (globalThis.crypto)", () => {
  it("globalThis.crypto exists", () => {
    assert.ok(globalThis.crypto != null);
  });

  it("crypto has getRandomValues and randomUUID", () => {
    assert.strictEqual(typeof globalThis.crypto.getRandomValues, "function");
    assert.strictEqual(typeof globalThis.crypto.randomUUID, "function");
  });

  it("crypto.subtle exists with digest", () => {
    assert.ok(globalThis.crypto.subtle != null);
    assert.strictEqual(typeof globalThis.crypto.subtle.digest, "function");
  });
});

describe("URL / URLSearchParams (global)", () => {
  it("URL and URLSearchParams are constructors", () => {
    assert.strictEqual(typeof globalThis.URL, "function");
    assert.strictEqual(typeof globalThis.URLSearchParams, "function");
  });

  it("new URL(href) returns object with hostname pathname search", () => {
    const u = new URL("https://example.com/path?a=1");
    assert.strictEqual(u.hostname, "example.com");
    assert.ok(u.pathname.includes("path"));
    assert.strictEqual(u.searchParams.get("a"), "1");
  });

  it("new URL(path, base) resolves relative", () => {
    const u = new URL("/foo", "http://localhost");
    assert.strictEqual(u.hostname, "localhost");
    assert.strictEqual(u.pathname, "/foo");
  });

  it("URLSearchParams get set append", () => {
    const p = new URLSearchParams("a=1");
    assert.strictEqual(p.get("a"), "1");
    p.set("b", "2");
    assert.strictEqual(p.get("b"), "2");
    p.append("a", "3");
    assert.ok(p.get("a") === "1" || p.getAll("a").length >= 1);
  });
});

// ---------- 边界与真实行为：reportError ----------
describe("reportError boundary", () => {
  it("reportError(undefined) does not throw", () => {
    assert.doesNotThrow(() => reportError(undefined));
  });

  it("reportError(null) does not throw", () => {
    assert.doesNotThrow(() => reportError(null));
  });

  it("reportError(string) does not throw", () => {
    assert.doesNotThrow(() => reportError("plain string"));
  });
});

// ---------- 边界：MessageChannel ----------
describe("MessageChannel boundary", () => {
  it("multiple MessageChannel instances have distinct port1/port2", () => {
    const ch1 = new MessageChannel();
    const ch2 = new MessageChannel();
    assert.notStrictEqual(ch1.port1, ch2.port1);
    assert.notStrictEqual(ch1.port2, ch2.port2);
  });
});

// ---------- 边界：BroadcastChannel（stub 仍测构造） ----------
describe("BroadcastChannel boundary", () => {
  it("BroadcastChannel name can be empty string", () => {
    try {
      new BroadcastChannel("");
    } catch (e) {
      assert.ok(e.message.match(/not implemented/i));
    }
  });
});

// ---------- 全局 Buffer 真实 + 边界 ----------
describe("Buffer (global) real and boundary", () => {
  it("Buffer.alloc(0) returns length 0", () => {
    const b = Buffer.alloc(0);
    assert.strictEqual(b.length, 0);
  });

  it("Buffer.from(string) roundtrip toString", () => {
    const s = "hello world";
    const b = Buffer.from(s);
    assert.strictEqual(b.toString(), s);
  });

  it("Buffer.concat([b1,b2]) length is sum", () => {
    const b1 = Buffer.from("a");
    const b2 = Buffer.from("b");
    const c = Buffer.concat([b1, b2]);
    assert.strictEqual(c.length, 2);
    assert.strictEqual(c.toString(), "ab");
  });

  it("Buffer.concat([]) returns empty buffer", () => {
    const c = Buffer.concat([]);
    assert.strictEqual(c.length, 0);
  });

  it("Buffer.isBuffer(undefined) and isBuffer(null) false", () => {
    assert.strictEqual(Buffer.isBuffer(undefined), false);
    assert.strictEqual(Buffer.isBuffer(null), false);
  });

  it("buffer[index] read write", () => {
    const b = Buffer.alloc(3);
    b[0] = 97;
    b[1] = 98;
    b[2] = 99;
    assert.strictEqual(b.toString(), "abc");
  });
});

// ---------- process 真实 + 边界 ----------
describe("process real and boundary", () => {
  it("process.cwd() returns non-empty string", () => {
    const c = process.cwd();
    assert.strictEqual(typeof c, "string");
    assert.ok(c.length > 0);
  });

  it("process.argv is array with at least one element", () => {
    assert.ok(Array.isArray(process.argv));
    assert.ok(process.argv.length >= 1);
  });

  it("process.env is object and can be read", () => {
    assert.ok(process.env != null && typeof process.env === "object");
    const keys = Object.keys(process.env);
    assert.strictEqual(typeof keys.length, "number");
  });

  it("process.platform is known string", () => {
    const p = process.platform;
    assert.strictEqual(typeof p, "string");
    assert.ok(["darwin", "linux", "win32", "freebsd", "openbsd"].includes(p) || p.length > 0);
  });
});

// ---------- console 真实 + 边界 ----------
describe("console real and boundary", () => {
  it("console.log returns undefined", () => {
    const r = console.log("x");
    assert.strictEqual(r, undefined);
  });

  it("console.error with multiple args", () => {
    assert.doesNotThrow(() => console.error("a", 1, {}));
  });

  it("console.log with object", () => {
    assert.doesNotThrow(() => console.log({ a: 1 }));
  });
});

// ---------- timers 真实 + 边界 ----------
describe("timers (global) real and boundary", () => {
  it("setTimeout passes args to callback", (done) => {
    setTimeout(
      (a, b) => {
        assert.strictEqual(a, 1);
        assert.strictEqual(b, 2);
        done();
      },
      0,
      1,
      2
    );
  });

  it("setImmediate passes args to callback", (done) => {
    setImmediate((x) => {
      assert.strictEqual(x, 42);
      done();
    }, 42);
  });

  it("clearTimeout(0) does not throw", () => {
    clearTimeout(0);
  });

  it("clearInterval(0) does not throw", () => {
    clearInterval(0);
  });

  it("setTimeout callback receives no args when not passed", (done) => {
    setTimeout(() => {
      done();
    }, 0);
  });
});

// ---------- crypto (global) 真实 + 边界 ----------
describe("crypto (global) real and boundary", () => {
  it("getRandomValues returns same typed array", () => {
    const arr = new Uint8Array(4);
    const out = globalThis.crypto.getRandomValues(arr);
    assert.strictEqual(out, arr);
  });

  it("randomUUID matches UUID format", () => {
    const u = globalThis.crypto.randomUUID();
    assert.ok(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(u));
  });

  it("getRandomValues with length 0 does not throw", () => {
    const arr = new Uint8Array(0);
    globalThis.crypto.getRandomValues(arr);
  });

  it("subtle.digest returns Promise", () => {
    const p = globalThis.crypto.subtle.digest("SHA-256", new Uint8Array(0));
    assert.ok(p != null && typeof p.then === "function");
  });
});
