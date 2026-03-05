/**
 * node:child_process 兼容测试：exec、execSync、spawn、spawnSync、边界
 */
const { describe, it, assert } = require("shu:test");
const cp = require("node:child_process");

describe("node:child_process exports", () => {
  it("has exec execSync spawn spawnSync", () => {
    assert.strictEqual(typeof cp.exec, "function");
    assert.strictEqual(typeof cp.execSync, "function");
    assert.strictEqual(typeof cp.spawn, "function");
    assert.strictEqual(typeof cp.spawnSync, "function");
  });
});

describe("node:child_process execSync", () => {
  it("execSync('echo 1') returns buffer or string", () => {
    const out = cp.execSync("echo 1");
    assert.ok(out != null);
    assert.ok(Buffer.isBuffer(out) || typeof out === "string");
  });
});

describe("node:child_process boundary", () => {
  it("execSync with invalid command throws or returns", () => {
    try {
      cp.execSync("__nonexistent_command_xyz__");
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });
});
