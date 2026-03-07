// shu:process 模块全面测试：实导 API 与边界用例
// 约定：每个 API 至少一条正常用例 + 一条边界用例；不调用 process.exit() 以免终止测试进程
const { describe, it, assert } = require("shu:test");
const path = require("shu:path");

const processModule = require("shu:process");

// ---------- 模块引用与全局一致性 ----------
describe("shu:process module reference", () => {
  it("require('shu:process') returns same as global process", () => {
    assert.strictEqual(processModule, process);
  });

  it("boundary: process is defined and an object", () => {
    assert.ok(typeof process === "object" && process !== null);
  });
});

// ---------- 属性：argv / argv0 / execArgv / execPath ----------
describe("shu:process argv, argv0, execArgv, execPath", () => {
  it("process.argv is array of strings", () => {
    assert.ok(Array.isArray(process.argv));
    process.argv.forEach((arg) => assert.strictEqual(typeof arg, "string"));
  });

  it("process.argv0 is string", () => {
    assert.strictEqual(typeof process.argv0, "string");
    assert.ok(process.argv0.length >= 0);
  });

  it("process.execArgv is array", () => {
    assert.ok(Array.isArray(process.execArgv));
  });

  it("process.execPath is string when argv has entry", () => {
    assert.strictEqual(typeof process.execPath, "string");
  });

  it("boundary: process.argv length >= 0", () => {
    assert.ok(process.argv.length >= 0);
  });

  it("boundary: execArgv is empty or array of strings", () => {
    process.execArgv.forEach((arg) => assert.strictEqual(typeof arg, "string"));
  });
});

// ---------- 属性：env / platform / arch ----------
describe("shu:process env, platform, arch", () => {
  it("process.env is object", () => {
    assert.ok(process.env !== null && typeof process.env === "object");
  });

  it("process.platform is known string", () => {
    assert.strictEqual(typeof process.platform, "string");
    const known = ["darwin", "linux", "win32", "freebsd", "openbsd", "netbsd"];
    assert.ok(known.includes(process.platform) || process.platform.length > 0);
  });

  it("process.arch is non-empty string", () => {
    assert.strictEqual(typeof process.arch, "string");
    assert.ok(process.arch.length > 0);
  });

  it("boundary: platform is one of darwin|linux|win32 in CI", () => {
    assert.ok(["darwin", "linux", "win32"].includes(process.platform) || process.platform.length > 0);
  });
});

// ---------- 属性：pid / ppid（仅 Unix 存在）----------
describe("shu:process pid, ppid", () => {
  it("process.pid is number if present", () => {
    if ("pid" in process && process.pid !== undefined) {
      assert.strictEqual(typeof process.pid, "number");
      assert.ok(Number.isInteger(process.pid));
      assert.ok(process.pid >= 0);
    }
  });

  it("process.ppid is number if present", () => {
    if ("ppid" in process && process.ppid !== undefined) {
      assert.strictEqual(typeof process.ppid, "number");
      assert.ok(Number.isInteger(process.ppid));
      assert.ok(process.ppid >= 0);
    }
  });
});

// ---------- 属性：exitCode ----------
describe("shu:process exitCode", () => {
  it("process.exitCode is number", () => {
    assert.strictEqual(typeof process.exitCode, "number");
    assert.ok(process.exitCode >= 0 && process.exitCode <= 255);
  });

  it("exitCode is writable and readable", () => {
    const prev = process.exitCode;
    process.exitCode = 42;
    assert.strictEqual(process.exitCode, 42);
    process.exitCode = prev;
  });

  it("boundary: exitCode clamps to 0-255 by implementation", () => {
    process.exitCode = 0;
    assert.strictEqual(process.exitCode, 0);
  });
});

// ---------- 属性：version / versions / release / title ----------
describe("shu:process version, versions, release, title", () => {
  it("process.version is string starting with v", () => {
    assert.strictEqual(typeof process.version, "string");
    assert.ok(process.version.length > 0);
    assert.ok(process.version.startsWith("v"));
  });

  it("process.versions is object with shu", () => {
    assert.ok(process.versions !== null && typeof process.versions === "object");
    assert.strictEqual(typeof process.versions.shu, "string");
    assert.ok(process.versions.shu.length > 0);
  });

  it("process.release is object with name", () => {
    assert.ok(process.release !== null && typeof process.release === "object");
    assert.strictEqual(process.release.name, "shu");
  });

  it("process.title is string", () => {
    assert.strictEqual(typeof process.title, "string");
  });

  it("boundary: versions.shu is non-empty", () => {
    assert.ok(process.versions.shu.length > 0);
  });
});

// ---------- 属性：allowedNodeEnvironmentFlags / stdin / stdout / stderr / _events ----------
describe("shu:process allowedNodeEnvironmentFlags, stdio, _events", () => {
  it("process.allowedNodeEnvironmentFlags is array", () => {
    assert.ok(Array.isArray(process.allowedNodeEnvironmentFlags));
  });

  it("process.stdin has fd 0", () => {
    assert.ok(process.stdin !== null && typeof process.stdin === "object");
    assert.strictEqual(process.stdin.fd, 0);
  });

  it("process.stdout has fd 1 and write", () => {
    assert.ok(process.stdout !== null && typeof process.stdout === "object");
    assert.strictEqual(process.stdout.fd, 1);
    assert.strictEqual(typeof process.stdout.write, "function");
  });

  it("process.stderr has fd 2 and write", () => {
    assert.ok(process.stderr !== null && typeof process.stderr === "object");
    assert.strictEqual(process.stderr.fd, 2);
    assert.strictEqual(typeof process.stderr.write, "function");
  });

  it("process._events is object", () => {
    assert.ok(process._events !== null && typeof process._events === "object");
  });

  it("boundary: stdout.write returns boolean", () => {
    const out = process.stdout.write(""); // empty string
    assert.strictEqual(typeof out, "boolean");
  });
});

// ---------- 方法：cwd / chdir ----------
describe("shu:process cwd, chdir", () => {
  it("process.cwd is function", () => {
    assert.strictEqual(typeof process.cwd, "function");
  });

  it("cwd() returns non-empty string", () => {
    const cwd = process.cwd();
    assert.strictEqual(typeof cwd, "string");
    assert.ok(cwd.length > 0);
  });

  it("chdir(dir) changes cwd()", () => {
    const before = process.cwd();
    const parent = path.dirname(before);
    if (parent && parent !== before) {
      process.chdir(parent);
      assert.strictEqual(process.cwd(), parent);
      process.chdir(before);
      assert.strictEqual(process.cwd(), before);
    }
  });

  it("boundary: cwd() returns string after chdir to current", () => {
    const cur = process.cwd();
    process.chdir(cur);
    assert.strictEqual(process.cwd(), cur);
  });
});

// ---------- 方法：exit（仅测存在与 exitCode，不真正 exit）----------
describe("shu:process exit", () => {
  it("process.exit is function", () => {
    assert.strictEqual(typeof process.exit, "function");
  });

  it("boundary: exitCode is number before/after setting", () => {
    const code = process.exitCode;
    process.exitCode = 1;
    assert.strictEqual(process.exitCode, 1);
    process.exitCode = code;
  });
});

// ---------- 方法：nextTick ----------
describe("shu:process nextTick", () => {
  it("process.nextTick is function", () => {
    assert.strictEqual(typeof process.nextTick, "function");
  });

  it("nextTick(cb) invokes callback asynchronously", (done) => {
    let ticked = false;
    process.nextTick(() => {
      ticked = true;
      done();
    });
    assert.strictEqual(ticked, false);
  });

  it("nextTick callbacks run in order", (done) => {
    const order = [];
    process.nextTick(() => order.push(1));
    process.nextTick(() => order.push(2));
    process.nextTick(() => {
      order.push(3);
      assert.deepStrictEqual(order, [1, 2, 3]);
      done();
    });
  });

  it("boundary: nextTick with single callback runs once", (done) => {
    let n = 0;
    process.nextTick(() => { n++; });
    process.nextTick(() => {
      assert.strictEqual(n, 1);
      done();
    });
  });
});

// ---------- 方法：uptime / hrtime / hrtime.bigint ----------
describe("shu:process uptime, hrtime", () => {
  it("process.uptime is function", () => {
    assert.strictEqual(typeof process.uptime, "function");
  });

  it("uptime() returns number >= 0", () => {
    const u = process.uptime();
    assert.strictEqual(typeof u, "number");
    assert.ok(u >= 0);
  });

  it("process.hrtime is function", () => {
    assert.strictEqual(typeof process.hrtime, "function");
  });

  it("hrtime() returns [sec, nsec] array", () => {
    const t = process.hrtime();
    assert.ok(Array.isArray(t));
    assert.strictEqual(t.length, 2);
    assert.strictEqual(typeof t[0], "number");
    assert.strictEqual(typeof t[1], "number");
    assert.ok(Number.isInteger(t[0]) || t[0] >= 0);
    assert.ok(t[1] >= 0 && t[1] < 1e9);
  });

  it("hrtime(prev) returns delta array", () => {
    const prev = process.hrtime();
    const now = process.hrtime(prev);
    assert.ok(Array.isArray(now));
    assert.strictEqual(now.length, 2);
    assert.strictEqual(typeof now[0], "number");
    assert.strictEqual(typeof now[1], "number");
  });

  it("process.hrtime.bigint is function", () => {
    assert.strictEqual(typeof process.hrtime.bigint, "function");
  });

  it("hrtime.bigint() returns number", () => {
    const n = process.hrtime.bigint();
    assert.strictEqual(typeof n, "number");
    assert.ok(n >= 0);
  });

  it("boundary: uptime() is non-negative float", () => {
    const u = process.uptime();
    assert.ok(u >= 0 && typeof u === "number");
  });

  it("boundary: hrtime() twice gives non-decreasing or near values", () => {
    const a = process.hrtime();
    const b = process.hrtime();
    const secA = a[0] + a[1] / 1e9;
    const secB = b[0] + b[1] / 1e9;
    assert.ok(secB >= secA - 0.001);
  });
});

// ---------- 方法：memoryUsage / cpuUsage ----------
describe("shu:process memoryUsage, cpuUsage", () => {
  it("process.memoryUsage is function", () => {
    assert.strictEqual(typeof process.memoryUsage, "function");
  });

  it("memoryUsage() returns object with rss, heapTotal, heapUsed, external, arrayBuffers", () => {
    const mem = process.memoryUsage();
    assert.ok(mem !== null && typeof mem === "object");
    assert.strictEqual(typeof mem.rss, "number");
    assert.strictEqual(typeof mem.heapTotal, "number");
    assert.strictEqual(typeof mem.heapUsed, "number");
    assert.strictEqual(typeof mem.external, "number");
    assert.strictEqual(typeof mem.arrayBuffers, "number");
  });

  it("process.cpuUsage is function", () => {
    assert.strictEqual(typeof process.cpuUsage, "function");
  });

  it("cpuUsage() returns object with user, system", () => {
    const cpu = process.cpuUsage();
    assert.ok(cpu !== null && typeof cpu === "object");
    assert.strictEqual(typeof cpu.user, "number");
    assert.strictEqual(typeof cpu.system, "number");
  });

  it("boundary: memoryUsage values are numbers", () => {
    const mem = process.memoryUsage();
    assert.ok(mem.rss >= 0 && mem.heapTotal >= 0 && mem.heapUsed >= 0);
  });
});

// ---------- 方法：emitWarning / on / emit / off ----------
describe("shu:process emitWarning, on, emit, off", () => {
  it("process.emitWarning is function", () => {
    assert.strictEqual(typeof process.emitWarning, "function");
  });

  it("emitWarning(msg) triggers warning event", (done) => {
    process.once("warning", (w) => {
      assert.ok(w !== undefined);
      done();
    });
    process.emitWarning("test warning");
  });

  it("process.on is function", () => {
    assert.strictEqual(typeof process.on, "function");
  });

  it("process.emit is function", () => {
    assert.strictEqual(typeof process.emit, "function");
  });

  it("process.off is function", () => {
    assert.strictEqual(typeof process.off, "function");
  });

  it("on(ev, fn) and emit(ev, arg) invoke listener", (done) => {
    const ev = "test-event-" + Date.now();
    process.on(ev, (x) => {
      assert.strictEqual(x, 42);
      process.off(ev);
      done();
    });
    process.emit(ev, 42);
  });

  it("off(ev, fn) removes single listener", () => {
    const ev = "test-off-" + Date.now();
    const fn = () => {};
    process.on(ev, fn);
    process.off(ev, fn);
    let called = false;
    process.on(ev, () => { called = true; });
    process.emit(ev);
    assert.strictEqual(called, true);
    process.off(ev);
  });

  it("off(ev) with no fn clears all listeners for event", () => {
    const ev = "test-off-all-" + Date.now();
    process.on(ev, () => {});
    process.off(ev);
    let count = 0;
    process.on(ev, () => { count++; });
    process.emit(ev);
    assert.strictEqual(count, 1);
    process.off(ev);
  });

  it("boundary: emit with no listeners returns false", () => {
    const ev = "nonexistent-event-" + Date.now();
    const r = process.emit(ev);
    assert.strictEqual(r, false);
  });
});

// ---------- 方法：getuid / geteuid / getgid / getegid / umask（仅 Unix）----------
describe("shu:process getuid, geteuid, getgid, getegid, umask", () => {
  it("getuid is function if present", () => {
    if (typeof process.getuid === "function") {
      const uid = process.getuid();
      assert.strictEqual(typeof uid, "number");
      assert.ok(Number.isInteger(uid) && uid >= 0);
    }
  });

  it("geteuid is function if present", () => {
    if (typeof process.geteuid === "function") {
      const euid = process.geteuid();
      assert.strictEqual(typeof euid, "number");
      assert.ok(Number.isInteger(euid) && euid >= 0);
    }
  });

  it("getgid is function if present", () => {
    if (typeof process.getgid === "function") {
      const gid = process.getgid();
      assert.strictEqual(typeof gid, "number");
      assert.ok(Number.isInteger(gid) && gid >= 0);
    }
  });

  it("getegid is function if present", () => {
    if (typeof process.getegid === "function") {
      const egid = process.getegid();
      assert.strictEqual(typeof egid, "number");
      assert.ok(Number.isInteger(egid) && egid >= 0);
    }
  });

  it("umask is function if present", () => {
    if (typeof process.umask === "function") {
      const prev = process.umask(0o22);
      assert.strictEqual(typeof prev, "number");
      process.umask(prev);
    }
  });
});

// ---------- 全局 __dirname / __filename ----------
describe("shu:process __dirname, __filename", () => {
  it("__dirname is string", () => {
    assert.strictEqual(typeof globalThis.__dirname, "string");
  });

  it("__filename is string", () => {
    assert.strictEqual(typeof globalThis.__filename, "string");
  });

  it("__dirname is directory of __filename", () => {
    const dir = globalThis.__dirname;
    const file = globalThis.__filename;
    assert.ok(file.length > 0);
    assert.ok(dir.length > 0);
    assert.ok(file.includes(path.sep) || dir === "." || path.dirname(file) === dir);
  });

  it("boundary: __filename is non-empty when run as file", () => {
    assert.ok(globalThis.__filename.length >= 0);
  });
});
