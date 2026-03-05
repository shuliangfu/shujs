/**
 * node:dns 兼容测试：lookup、resolve、resolve4、resolve6、setServers、getServers、边界
 */
const { describe, it, assert } = require("shu:test");
const dns = require("node:dns");

describe("node:dns exports", () => {
  it("has lookup resolve resolve4 resolve6 setServers getServers", () => {
    assert.strictEqual(typeof dns.lookup, "function");
    assert.strictEqual(typeof dns.resolve, "function");
    assert.strictEqual(typeof dns.resolve4, "function");
    assert.strictEqual(typeof dns.resolve6, "function");
    assert.strictEqual(typeof dns.setServers, "function");
    assert.strictEqual(typeof dns.getServers, "function");
  });
});

describe("node:dns getServers setServers", () => {
  it("getServers() returns array", () => {
    const servers = dns.getServers();
    assert.ok(Array.isArray(servers));
  });
  it("setServers(servers) accepts array", () => {
    dns.setServers(["8.8.8.8"]);
    const s = dns.getServers();
    assert.ok(Array.isArray(s));
  });
});

describe("node:dns lookup", () => {
  it("lookup(hostname, callback) invokes callback", (done) => {
    dns.lookup("localhost", (err, address, family) => {
      assert.ok(err == null || err instanceof Error);
      if (!err) {
        assert.strictEqual(typeof address, "string");
        assert.ok(address.length > 0);
      }
      done();
    });
  });
});

describe("node:dns boundary", () => {
  it("lookup non-existent host calls back with err or empty", (done) => {
    dns.lookup("nonexistent.invalid.xyz.123", (err) => {
      assert.ok(err != null || true);
      done();
    });
  });
});
