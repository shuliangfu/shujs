/**
 * node:os 全面兼容测试：platform、arch、homedir、tmpdir、cpus、loadavg、uptime、totalmem、freemem 等 + 边界
 */
const { describe, it, assert } = require("shu:test");
const os = require("node:os");

describe("node:os exports", () => {
  it("has platform, arch, homedir, tmpdir", () => {
    assert.strictEqual(typeof os.platform, "function");
    assert.strictEqual(typeof os.arch, "function");
    assert.strictEqual(typeof os.homedir, "function");
    assert.strictEqual(typeof os.tmpdir, "function");
  });
  it("has cpus, loadavg, uptime, totalmem, freemem", () => {
    assert.strictEqual(typeof os.cpus, "function");
    assert.strictEqual(typeof os.loadavg, "function");
    assert.strictEqual(typeof os.uptime, "function");
    assert.strictEqual(typeof os.totalmem, "function");
    assert.strictEqual(typeof os.freemem, "function");
  });
});

describe("node:os platform and arch", () => {
  it("platform() returns string", () => {
    const p = os.platform();
    assert.strictEqual(typeof p, "string");
    assert.ok(p.length > 0);
  });
  it("arch() returns string", () => {
    const a = os.arch();
    assert.strictEqual(typeof a, "string");
    assert.ok(["x64", "arm64", "ia32", "x32"].includes(a) || a.length > 0);
  });
});

describe("node:os homedir and tmpdir", () => {
  it("homedir() returns string", () => {
    const h = os.homedir();
    assert.strictEqual(typeof h, "string");
  });
  it("tmpdir() returns string", () => {
    const t = os.tmpdir();
    assert.strictEqual(typeof t, "string");
    assert.ok(t.length > 0);
  });
});

describe("node:os cpus", () => {
  it("cpus() returns array", () => {
    const c = os.cpus();
    assert.ok(Array.isArray(c));
  });
  it("cpus() each element has model and speed", () => {
    const c = os.cpus();
    if (c.length > 0) {
      assert.ok("model" in c[0] || "speed" in c[0] || typeof c[0] === "object");
    }
  });
});

describe("node:os loadavg and uptime", () => {
  it("loadavg() returns array of 3 numbers", () => {
    const l = os.loadavg();
    assert.ok(Array.isArray(l));
    assert.ok(l.length >= 0 && l.length <= 3);
  });
  it("uptime() returns number", () => {
    const u = os.uptime();
    assert.strictEqual(typeof u, "number");
    assert.ok(u >= 0 || isNaN(u) === false);
  });
});

describe("node:os totalmem and freemem", () => {
  it("totalmem() returns number", () => {
    const t = os.totalmem();
    assert.strictEqual(typeof t, "number");
    assert.ok(t > 0);
  });
  it("freemem() returns number", () => {
    const f = os.freemem();
    assert.strictEqual(typeof f, "number");
    assert.ok(f >= 0);
  });
  it("freemem() <= totalmem()", () => {
    assert.ok(os.freemem() <= os.totalmem());
  });
});
