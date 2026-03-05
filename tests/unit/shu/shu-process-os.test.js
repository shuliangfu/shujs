// shu:process 与 shu:os 模块 JS 测试（process 为全局同一引用，os 为 require("shu:os")）
// 约定：新增 API 时补一条正常用例 + 一条边界用例。
const { describe, it, assert } = require("shu:test");
const processModule = require("shu:process");
const os = require("shu:os");

describe("shu:process", () => {
  it("require('shu:process') returns same as global process", () => {
    assert.strictEqual(processModule, process);
  });

  it("process has cwd, platform, env, argv", () => {
    assert.strictEqual(typeof process.cwd, "function");
    const cwd = process.cwd();
    assert.strictEqual(typeof cwd, "string");
    assert.ok(cwd.length > 0);
    assert.ok(process.platform === "darwin" || process.platform === "linux" || process.platform === "win32");
    assert.ok(process.env && typeof process.env === "object");
    assert.ok(Array.isArray(process.argv));
  });

  it("boundary: process.argv length >= 0", () => {
    assert.ok(process.argv.length >= 0);
  });
});

describe("shu:os", () => {
  it("os has platform, arch, homedir, tmpdir, EOL", () => {
    const p = os.platform();
    assert.ok(p === "darwin" || p === "linux" || p === "win32" || p === "freebsd" || p === "openbsd" || p === "netbsd" || p === "unknown");
    const a = os.arch();
    assert.strictEqual(typeof a, "string");
    assert.ok(a.length > 0);
    assert.strictEqual(typeof os.homedir(), "string");
    assert.strictEqual(typeof os.tmpdir(), "string");
    assert.strictEqual(typeof os.EOL, "string");
  });

  it("boundary: os.platform() returns non-empty string", () => {
    assert.ok(os.platform().length > 0);
  });

  it("os.type() returns string", () => {
    const t = os.type();
    assert.strictEqual(typeof t, "string");
    assert.ok(t.length > 0);
  });

  it("os.hostname() returns string", () => {
    const h = os.hostname();
    assert.strictEqual(typeof h, "string");
    assert.ok(h.length > 0);
  });

  it("os.cpus() returns array of objects with model/speed/times", () => {
    const cpus = os.cpus();
    assert.ok(Array.isArray(cpus));
    if (cpus.length > 0) {
      assert.ok(typeof cpus[0] === "object" && cpus[0] !== null);
      assert.ok("model" in cpus[0] || "speed" in cpus[0] || "times" in cpus[0]);
    }
  });

  it("os.loadavg() returns [load1, load5, load15]", () => {
    const load = os.loadavg();
    assert.ok(Array.isArray(load));
    assert.strictEqual(load.length, 3);
    assert.strictEqual(typeof load[0], "number");
    assert.strictEqual(typeof load[1], "number");
    assert.strictEqual(typeof load[2], "number");
  });

  it("os.uptime() returns seconds as number", () => {
    const sec = os.uptime();
    assert.strictEqual(typeof sec, "number");
    assert.ok(sec >= 0);
  });

  it("os.totalmem() returns total memory bytes", () => {
    const total = os.totalmem();
    assert.strictEqual(typeof total, "number");
    assert.ok(total >= 0);
  });

  it("os.freemem() returns free memory bytes", () => {
    const free = os.freemem();
    assert.strictEqual(typeof free, "number");
    assert.ok(free >= 0);
  });

  it("os.cpuUsage() returns number 0..100 or 0 on unsupported", () => {
    const p = os.cpuUsage();
    assert.strictEqual(typeof p, "number");
    assert.ok(p >= 0 && p <= 100);
  });

  it("os.processRssKb() returns number >= 0", () => {
    const kb = os.processRssKb();
    assert.strictEqual(typeof kb, "number");
    assert.ok(kb >= 0);
  });

  it("os.processCpuUsage() returns number >= 0", () => {
    const u = os.processCpuUsage();
    assert.strictEqual(typeof u, "number");
    assert.ok(u >= 0);
  });

  it("os.cpuUsagePerCore() returns array of numbers", () => {
    const arr = os.cpuUsagePerCore();
    assert.ok(Array.isArray(arr));
    arr.forEach((n) => {
      assert.strictEqual(typeof n, "number");
      assert.ok(n >= 0 && n <= 100);
    });
  });

  it("os.swapInfo() returns { totalKb, freeKb }", () => {
    const swap = os.swapInfo();
    assert.ok(swap && typeof swap === "object");
    assert.strictEqual(typeof swap.totalKb, "number");
    assert.strictEqual(typeof swap.freeKb, "number");
    assert.ok(swap.totalKb >= 0 && swap.freeKb >= 0);
  });

  it("os.diskUtilization() returns number 0..100 or 0 on unsupported", () => {
    const d = os.diskUtilization();
    assert.strictEqual(typeof d, "number");
    assert.ok(d >= 0 && d <= 100);
  });

  it("os.isDiskBusy() returns boolean", () => {
    const busy = os.isDiskBusy();
    assert.strictEqual(typeof busy, "boolean");
  });

  it("os.getDiskFreeSpace(path) returns { totalBytes, freeBytes } or undefined", () => {
    const cwd = process.cwd();
    const space = os.getDiskFreeSpace(cwd);
    if (space !== undefined) {
      assert.ok(space && typeof space === "object");
      assert.strictEqual(typeof space.totalBytes, "number");
      assert.strictEqual(typeof space.freeBytes, "number");
      assert.ok(space.totalBytes >= 0 && space.freeBytes >= 0);
    }
  });

  it("boundary: os.getDiskFreeSpace() with no arg returns undefined", () => {
    const space = os.getDiskFreeSpace();
    assert.strictEqual(space, undefined);
  });

  it("os.networkActivityBytesDelta() returns number >= 0", () => {
    const delta = os.networkActivityBytesDelta();
    assert.strictEqual(typeof delta, "number");
    assert.ok(delta >= 0);
  });

  it("os.isNetworkBusy() returns boolean", () => {
    const busy = os.isNetworkBusy();
    assert.strictEqual(typeof busy, "boolean");
  });

  it("os.networkStatsPerInterface() returns array of { name, rxBytes, txBytes }", () => {
    const list = os.networkStatsPerInterface();
    assert.ok(Array.isArray(list));
    list.forEach((iface) => {
      assert.ok(iface && typeof iface === "object");
      assert.strictEqual(typeof iface.name, "string");
      assert.strictEqual(typeof iface.rxBytes, "number");
      assert.strictEqual(typeof iface.txBytes, "number");
      assert.ok(iface.rxBytes >= 0 && iface.txBytes >= 0);
    });
  });

  it("os.tcpConnectionCount() returns number >= 0", () => {
    const count = os.tcpConnectionCount();
    assert.strictEqual(typeof count, "number");
    assert.ok(count >= 0);
  });

  it("os.networkRttMs(host, port) returns number or undefined", () => {
    const rtt = os.networkRttMs("127.0.0.1", 80);
    if (rtt !== undefined) {
      assert.strictEqual(typeof rtt, "number");
      assert.ok(rtt >= 0);
    }
  });

  it("boundary: os.networkRttMs() with no args returns undefined", () => {
    assert.strictEqual(os.networkRttMs(), undefined);
  });
});
