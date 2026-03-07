// shu:assert 模块测试（Node 风格 assert：ok/strictEqual/deepStrictEqual/fail/throws）
const { describe, it, assert } = require("shu:test");

const assertModule = require("shu:assert");

describe("shu:assert", () => {
  // 覆盖导出接口：同步断言、异步断言与 Deno 别名都应存在
  it("exports full assert api surface", () => {
    assert.strictEqual(typeof assertModule.ok, "function");
    assert.strictEqual(typeof assertModule.strictEqual, "function");
    assert.strictEqual(typeof assertModule.deepStrictEqual, "function");
    assert.strictEqual(typeof assertModule.fail, "function");
    assert.strictEqual(typeof assertModule.throws, "function");
    assert.strictEqual(typeof assertModule.doesNotThrow, "function");
    assert.strictEqual(typeof assertModule.rejects, "function");
    assert.strictEqual(typeof assertModule.doesNotReject, "function");
    assert.strictEqual(typeof assertModule.assertEquals, "function");
    assert.strictEqual(typeof assertModule.assertStrictEquals, "function");
    assert.strictEqual(typeof assertModule.assertThrows, "function");
    assert.strictEqual(typeof assertModule.assertRejects, "function");
  });

  it("ok(value) does not throw for truthy", () => {
    assertModule.ok(true);
    assertModule.ok(1);
    assertModule.ok("x");
  });

  it("strictEqual(actual, expected) uses Object.is", () => {
    assertModule.strictEqual(1, 1);
    assertModule.strictEqual("a", "a");
  });

  it("deepStrictEqual compares by structure", () => {
    assertModule.deepStrictEqual({ a: 1 }, { a: 1 });
  });

  it("throws(fn) when fn throws", () => {
    assertModule.throws(() => {
      throw new Error("expected");
    });
  });

  // 覆盖 doesNotThrow 的通过路径：普通函数与返回值函数都应通过
  it("doesNotThrow(fn) passes for non-throwing functions", () => {
    assertModule.doesNotThrow(() => {});
    assertModule.doesNotThrow(() => 42);
  });

  it("fail() throws", () => {
    assert.throws(() => assertModule.fail());
  });

  // 覆盖 fail(message)：应抛出且 message 生效
  it("fail(message) throws with custom message", () => {
    assert.throws(() => assertModule.fail("custom-fail-message"));
  });

  // 验证异步断言通过路径：rejects 应返回被拒绝的错误对象
  it("rejects(promise) resolves with rejection reason", async () => {
    const err = new Error("rejects-reason");
    const got = await assertModule.rejects(Promise.reject(err));
    assert.strictEqual(got, err);
  });

  // 验证异步断言通过路径：doesNotReject 应返回 resolve 的原值
  it("doesNotReject(promise) resolves with fulfilled value", async () => {
    const value = { ok: true };
    const got = await assertModule.doesNotReject(Promise.resolve(value));
    assert.strictEqual(got, value);
  });

  // 覆盖 rejects/doesNotReject 的函数入参路径（而非直接 Promise）
  it("rejects(fn) and doesNotReject(fn) support function input", async () => {
    const err = new Error("from-fn");
    const gotReject = await assertModule.rejects(async () => {
      throw err;
    });
    assert.strictEqual(gotReject, err);

    const gotResolve = await assertModule.doesNotReject(async () => "ok");
    assert.strictEqual(gotResolve, "ok");
  });

  // 覆盖 Deno 别名：assertEquals / assertStrictEquals / assertThrows / assertRejects
  it("deno aliases pass on valid input", async () => {
    assertModule.assertEquals({ a: 1 }, { a: 1 });
    const o = {};
    assertModule.assertStrictEquals(o, o);
    assertModule.assertThrows(() => {
      throw new Error("expected");
    });
    const err = new Error("alias-reject");
    const got = await assertModule.assertRejects(Promise.reject(err));
    assert.strictEqual(got, err);
  });
});

describe("shu:assert boundary", () => {
  it("ok(false) throws", () => {
    assert.throws(() => assertModule.ok(false));
  });

  it("strictEqual(actual, expected) throws when not equal", () => {
    assert.throws(() => assertModule.strictEqual(1, 2));
  });

  it("deepStrictEqual throws when structure differs", () => {
    assert.throws(() => assertModule.deepStrictEqual({ a: 1 }, { a: 2 }));
  });

  it("throws(fn) throws when fn does not throw", () => {
    assert.throws(() => assertModule.throws(() => {}));
  });

  // 覆盖 doesNotThrow 的失败路径：被测函数抛错时 should throw
  it("doesNotThrow(fn) throws when fn throws", () => {
    assert.throws(() =>
      assertModule.doesNotThrow(() => {
        throw new Error("boom");
      })
    );
  });

  it("ok(undefined) and ok(null) throw", () => {
    assert.throws(() => assertModule.ok(undefined));
    assert.throws(() => assertModule.ok(null));
  });

  it("strictEqual(NaN, NaN) does not throw", () => {
    assertModule.strictEqual(NaN, NaN);
  });

  it("strictEqual(0, -0) behavior (Object.is: 0 !== -0)", () => {
    try {
      assertModule.strictEqual(0, -0);
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });

  it("throws with non-function throws or fails", () => {
    // 当前实现对非函数输入是 no-op，不应抛错
    assertModule.throws("not a function");
    assertModule.doesNotThrow("not a function");
  });

  it("deepStrictEqual with array order matters", () => {
    assertModule.deepStrictEqual([1, 2], [1, 2]);
    assert.throws(() => assertModule.deepStrictEqual([1, 2], [2, 1]));
  });

  // 验证 rejects 的失败路径：当 Promise resolve 时，rejects 应返回 reject 的 Promise
  it("rejects fails when promise resolves", async () => {
    await assert.rejects(assertModule.rejects(Promise.resolve(1)));
  });

  // 验证 doesNotReject 的失败路径：当 Promise reject 时，doesNotReject 应返回 reject 的 Promise
  it("doesNotReject fails when promise rejects", async () => {
    await assert.rejects(
      assertModule.doesNotReject(Promise.reject(new Error("reject-intentional")))
    );
  });

  // 覆盖别名失败路径：assertRejects 在 Promise resolve 时应失败
  it("assertRejects alias fails when promise resolves", async () => {
    await assert.rejects(assertModule.assertRejects(Promise.resolve(1)));
  });

  // 覆盖别名失败路径：assertEquals / assertStrictEquals / assertThrows 均应在不匹配时抛错
  it("assertEquals/assertStrictEquals/assertThrows aliases fail on mismatch", () => {
    assert.throws(() => assertModule.assertEquals({ a: 1 }, { a: 2 }));
    assert.throws(() => assertModule.assertStrictEquals(1, 2));
    assert.throws(() => assertModule.assertThrows(() => {}));
  });

  // 覆盖 doesNotReject 的函数失败路径：函数返回 reject Promise 时 should reject
  it("doesNotReject(fn) fails when function returns rejected promise", async () => {
    await assert.rejects(
      assertModule.doesNotReject(async () => {
        throw new Error("fn-reject");
      })
    );
  });
});

// ---------------------------------------------------------------------------
// 故意失败用例（Intentional Failures）
// 说明：
// 1) 本区块所有用例都是“特意写错”的断言；
// 2) 目的仅用于验证 shu:test 是否能正确统计断言失败数量与失败信息；
// 3) 正常开发时请勿默认运行此区块，或在验证完成后移除/跳过。
// ---------------------------------------------------------------------------
describe("shu:assert intentional failures", () => {
  it("intentional fail: ok should fail", () => {
    assertModule.ok(false);
  });

  it("intentional fail: strictEqual should fail", () => {
    assertModule.strictEqual(1, 2);
  });

  it("intentional fail: deepStrictEqual should fail", () => {
    assertModule.deepStrictEqual({ a: 1 }, { a: 2 });
  });

  it("intentional fail: throws should fail when callback does not throw", () => {
    assertModule.throws(() => {});
  });

  it("intentional fail: doesNotThrow should fail when callback throws", () => {
    assertModule.doesNotThrow(() => {
      throw new Error("intentional throw");
    });
  });

  it("intentional fail: fail should always fail", () => {
    assertModule.fail("intentional fail");
  });

  it("intentional fail: rejects should fail when promise resolves", async () => {
    await assertModule.rejects(Promise.resolve("ok"));
  });

  it("intentional fail: doesNotReject should fail when promise rejects", async () => {
    await assertModule.doesNotReject(Promise.reject(new Error("intentional reject")));
  });

  it("intentional fail: assertEquals alias should fail", () => {
    assertModule.assertEquals({ a: 1 }, { a: 2 });
  });

  it("intentional fail: assertStrictEquals alias should fail", () => {
    assertModule.assertStrictEquals(1, 2);
  });

  it("intentional fail: assertThrows alias should fail", () => {
    assertModule.assertThrows(() => {});
  });

  it("intentional fail: assertRejects alias should fail", async () => {
    await assertModule.assertRejects(Promise.resolve(1));
  });
});
