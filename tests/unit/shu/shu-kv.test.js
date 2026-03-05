// shu:kv 模块测试（Deno KV 风格占位：openKv 返回 Promise<Kv>，Kv 方法抛 not implemented）
const { describe, it, assert } = require("shu:test");

const kvModule = require("shu:kv");

describe("shu:kv", () => {
  it("exports openKv", () => {
    assert.strictEqual(typeof kvModule.openKv, "function");
  });

  it("openKv() returns Promise that resolves to Kv-shaped object", async () => {
    const kv = await kvModule.openKv();
    assert.ok(kv !== null && typeof kv === "object");
    assert.strictEqual(typeof kv.get, "function");
    assert.strictEqual(typeof kv.set, "function");
    assert.strictEqual(typeof kv.delete, "function");
    assert.strictEqual(typeof kv.list, "function");
    assert.strictEqual(typeof kv.getMany, "function");
    assert.strictEqual(typeof kv.atomic, "function");
    assert.strictEqual(typeof kv.close, "function");
    assert.strictEqual(typeof kv.enqueue, "function");
    assert.strictEqual(typeof kv.listenQueue, "function");
    assert.strictEqual(typeof kv.watch, "function");
  });

  it("kv.get() throws not implemented", async () => {
    const kv = await kvModule.openKv();
    assert.throws(() => kv.get(["foo"]), /shu:kv not implemented/);
  });

  it("kv.set() throws not implemented", async () => {
    const kv = await kvModule.openKv();
    assert.throws(() => kv.set(["foo"], "bar"), /shu:kv not implemented/);
  });
});
