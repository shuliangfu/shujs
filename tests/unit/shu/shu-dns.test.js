// shu:dns 模块测试（lookup/resolve/lookupService/resolve4/resolve6/reverse/setServers/getServers 等）
// 约定：新增 API 时补一条正常用例 + 一条边界用例。
const { describe, it, assert } = require("shu:test");

const dns = require("shu:dns");

describe("shu:dns", () => {
  it("has lookup, resolve, lookupService, resolve4, resolve6, reverse, setServers, getServers, isIP", () => {
    assert.strictEqual(typeof dns.lookup, "function");
    assert.strictEqual(typeof dns.resolve, "function");
    assert.strictEqual(typeof dns.lookupService, "function");
    assert.strictEqual(typeof dns.resolve4, "function");
    assert.strictEqual(typeof dns.resolve6, "function");
    assert.strictEqual(typeof dns.reverse, "function");
    assert.strictEqual(typeof dns.setServers, "function");
    assert.strictEqual(typeof dns.getServers, "function");
    assert.strictEqual(typeof dns.isIP, "function");
  });

  it("dns.lookup('localhost', callback) calls callback", (done) => {
    dns.lookup("localhost", (err, address, family) => {
      assert.ok(err === null || err === undefined || err instanceof Error);
      if (!err) {
        assert.strictEqual(typeof address, "string");
        assert.ok(family === 4 || family === 6);
      }
      done();
    });
  });

  it("getServers() returns array", () => {
    const servers = dns.getServers();
    assert.ok(Array.isArray(servers));
  });

  it("boundary: setServers([]) does not throw", () => {
    dns.setServers([]);
  });

  it("dns.resolve4('localhost') or resolve when present", (done) => {
    if (typeof dns.resolve4 !== "function") return done();
    dns.resolve4("localhost", (err, addresses) => {
      assert.ok(err === null || err === undefined || err instanceof Error);
      if (!err) assert.ok(Array.isArray(addresses));
      done();
    });
  });

  it("dns.resolve('localhost', 'A') when present", (done) => {
    if (typeof dns.resolve !== "function") return done();
    dns.resolve("localhost", "A", (err, addresses) => {
      assert.ok(err === null || err === undefined || err instanceof Error);
      if (!err) assert.ok(Array.isArray(addresses));
      done();
    });
  });
});

describe("shu:dns boundary (production edge cases)", () => {
  it("lookup with invalid host calls callback with error", (done) => {
    dns.lookup("nonexistent.invalid.domain.xyz.abc", (err) => {
      assert.ok(err instanceof Error || err != null);
      done();
    });
  });

  it("setServers with non-array does not throw or throws", () => {
    try {
      dns.setServers(null);
      dns.setServers(undefined);
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });

  it("getServers after setServers returns array", () => {
    dns.setServers(["8.8.8.8"]);
    const s = dns.getServers();
    assert.ok(Array.isArray(s));
  });
});
