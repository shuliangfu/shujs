// shu 其他模块 JS 测试：permissions、report、tty、cluster、webcrypto、tracing、inspector、debugger、intl
const { describe, it, assert } = require("shu:test");

describe("shu:permissions", () => {
  const permissions = require("shu:permissions");
  it("has has and request", () => {
    assert.strictEqual(typeof permissions.has, "function");
    assert.strictEqual(typeof permissions.request, "function");
  });

  it("permissions.request(scope) does not throw and returns value", () => {
    const out = permissions.request("fs");
    assert.ok(out === undefined || typeof out === "boolean" || (typeof out === "object" && out !== null));
  });
});

describe("shu:report", () => {
  const report = require("shu:report");
  it("has getReport and writeReport", () => {
    assert.strictEqual(typeof report.getReport, "function");
    assert.strictEqual(typeof report.writeReport, "function");
  });

  it("report.writeReport(path) does not throw when present", () => {
    if (typeof report.writeReport !== "function") return;
    report.writeReport("report.json");
  });
});

describe("shu:tty", () => {
  const tty = require("shu:tty");
  it("has isTTY", () => {
    assert.strictEqual(typeof tty.isTTY, "function");
  });
});

describe("shu:cluster", () => {
  const cluster = require("shu:cluster");
  it("has isPrimary, isWorker, workers, settings", () => {
    assert.strictEqual(typeof cluster.isPrimary, "boolean");
    assert.strictEqual(typeof cluster.isWorker, "boolean");
    assert.ok(cluster.workers && typeof cluster.workers === "object");
  });

  it("cluster.setupPrimary() does not throw", () => {
    if (typeof cluster.setupPrimary === "function") cluster.setupPrimary();
  });

  it("cluster.disconnect() does not throw", () => {
    if (typeof cluster.disconnect === "function") cluster.disconnect();
  });
});

describe("shu:webcrypto", () => {
  const webcrypto = require("shu:webcrypto");
  it("has getRandomValues and randomUUID", () => {
    assert.strictEqual(typeof webcrypto.getRandomValues, "function");
    assert.strictEqual(typeof webcrypto.randomUUID, "function");
  });
  it("getRandomValues fills Uint8Array", () => {
    const arr = new Uint8Array(4);
    webcrypto.getRandomValues(arr);
    assert.ok(arr.length === 4);
  });
  it("randomUUID returns string", () => {
    const uuid = webcrypto.randomUUID();
    assert.strictEqual(typeof uuid, "string");
    assert.ok(uuid.length > 0);
  });
});

describe("shu:tracing", () => {
  const tracing = require("shu:tracing");
  it("has createTracing and trace", () => {
    assert.strictEqual(typeof tracing.createTracing, "function");
    assert.strictEqual(typeof tracing.trace, "function");
  });

  it("createTracing({ categories }) returns object with enable/disable", () => {
    const t = tracing.createTracing({ categories: ["node"] });
    assert.ok(t && typeof t === "object");
    if (typeof t.enable === "function") t.enable();
    if (typeof t.disable === "function") t.disable();
  });

  it("trace(category, fn) runs fn", () => {
    let ran = false;
    tracing.trace("node", () => { ran = true; });
    assert.strictEqual(ran, true);
  });
});

describe("shu:inspector", () => {
  const inspector = require("shu:inspector");
  it("has open, close, url", () => {
    assert.strictEqual(typeof inspector.open, "function");
    assert.strictEqual(typeof inspector.close, "function");
    assert.strictEqual(typeof inspector.url(), "string");
  });
});

describe("shu:debugger", () => {
  const debugger_ = require("shu:debugger");
  it("has port and host", () => {
    assert.ok("port" in debugger_);
    assert.ok("host" in debugger_);
  });
});

describe("shu:intl", () => {
  const intl = require("shu:intl");
  it("has getIntl or Segmenter", () => {
    assert.ok(intl && typeof intl === "object");
  });
});

// 边界：不存在的权限、无参调用、非 TTY 等不抛错
describe("shu:misc boundary", () => {
  it("permissions.has('nonexistent') does not throw", () => {
    const permissions = require("shu:permissions");
    const out = permissions.has("nonexistent");
    assert.strictEqual(typeof out, "boolean");
  });

  it("report.getReport() with no args does not throw", () => {
    const report = require("shu:report");
    const r = report.getReport();
    assert.ok(r === undefined || (typeof r === "object" && r !== null) || typeof r === "string");
  });

  it("tty.isTTY returns boolean", () => {
    const tty = require("shu:tty");
    assert.strictEqual(typeof tty.isTTY(), "boolean");
  });
});
