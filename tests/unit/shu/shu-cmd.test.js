// shu:cmd 模块测试（exec/run/spawn 等，对应 node:child_process）
// 真实执行用例需 --allow-run；无权限时 execSync/spawnSync 抛错，用例 catch 后跳过断言。
const { describe, it, assert } = require("shu:test");

const cmd = require("shu:cmd");

describe("shu:cmd", () => {
  it("has exec, execSync, run, runSync, spawn, spawnSync", () => {
    assert.strictEqual(typeof cmd.exec, "function");
    assert.strictEqual(typeof cmd.execSync, "function");
    assert.strictEqual(typeof cmd.run, "function");
    assert.strictEqual(typeof cmd.runSync, "function");
    assert.strictEqual(typeof cmd.spawn, "function");
    assert.strictEqual(typeof cmd.spawnSync, "function");
  });

  it("fork exists (may throw when called)", () => {
    assert.ok("fork" in cmd);
    assert.strictEqual(typeof cmd.fork, "function");
  });

  it("execSync(cmd) runs command and returns { stdout, stderr, code } when allowed", () => {
    const cmdStr = process.platform === "win32" ? "echo 1" : "echo 1";
    try {
      const r = cmd.execSync(cmdStr);
      assert.ok(r && typeof r === "object");
      assert.ok("stdout" in r && "stderr" in r && "code" in r);
      assert.strictEqual(typeof r.code, "number");
      assert.ok(String(r.stdout).includes("1") || r.stdout.trim() === "1");
    } catch (e) {
      assert.ok(e instanceof Error);
      if (e.message && e.message.includes("allow-run")) return;
      throw e;
    }
  });

  it("spawnSync(options) runs subprocess and returns { status, stdout, stderr } when allowed", () => {
    const argv = process.platform === "win32" ? ["cmd", "/c", "echo", "2"] : ["echo", "2"];
    try {
      const r = cmd.spawnSync({ cmd: argv });
      assert.ok(r && typeof r === "object");
      assert.ok("status" in r);
      assert.ok("stdout" in r || "status" in r);
      if (r.stdout != null) assert.ok(String(r.stdout).includes("2"));
    } catch (e) {
      assert.ok(e instanceof Error);
      if (e.message && e.message.includes("allow-run")) return;
      throw e;
    }
  });
});
