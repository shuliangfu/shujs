// 示例测试：shu test 会扫描 tests/*.test.js 并执行。用 assert/expect 写断言，无需 run()，加载后自动执行。
const { describe, it, test, assert, expect, mock, snapshot } = require("shu:test");

describe("example", () => {
  it("passes with assert.ok", () => {
    assert.ok(true);
    assert.ok(1);
  });

  it("passes with assert.strictEqual", () => {
    assert.strictEqual(1, 1);
    assert.strictEqual("a", "a");
  });

  it("passes with assert.deepStrictEqual", () => {
    assert.deepStrictEqual({ a: 1 }, { a: 1 });
    assert.deepStrictEqual([1, 2], [1, 2]);
  });

  it("passes with assert.throws and assert.doesNotThrow", () => {
    assert.throws(() => {
      throw new Error("expected");
    });
    assert.doesNotThrow(() => {});
  });

  it("assert.fail throws", () => {
    assert.throws(() => assert.fail("must throw"));
    assert.throws(() => assert.fail());
  });

  it("t.name is current test name", (t) => {
    assert.strictEqual(t.name, "t.name is current test name");
  });

  it("accepts timeout option", { timeout: 5000 }, () => {
    assert.ok(true);
  });

  it("assert.rejects resolves when promise rejects", async () => {
    const err = new Error("rejected");
    const p = assert.rejects(Promise.reject(err));
    const got = await p;
    assert.strictEqual(got, err);
  });

  it("assert.doesNotReject resolves when promise fulfills", async () => {
    const value = { ok: true };
    const p = assert.doesNotReject(Promise.resolve(value));
    const got = await p;
    assert.strictEqual(got, value);
  });

  it("passes with snapshot", () => {
    snapshot("example-snap", { x: 1 });
    snapshot("example-snap", { x: 1 });
  });

  it("passes with t.done()", (t) => {
    t.done();
  });

  it("can use t.skip() to skip rest", (t) => {
    t.skip();
  });

  it("Deno-style assert.assertEquals and it.ignore", () => {
    assert.assertEquals(1, 1);
    assert.assertStrictEquals("a", "a");
    assert.assertThrows(() => {
      throw new Error("expected");
    });
  });

  it.ignore("skipped via it.ignore (Deno compat)", () => {
    assert.fail("should not run");
  });

  it("passes with mock.method", () => {
    const obj = { add: (a, b) => a + b };
    const mockAdd = mock.method(obj, "add");
    assert.strictEqual(obj.add(2, 3), 5);
    assert.strictEqual(mockAdd.callCount, 1);
    assert.deepStrictEqual(mockAdd.calls[0], [2, 3]);
  });
});

describe("Bun/Deno compat", () => {
  it("expect(value).toBe / toEqual / toBeTruthy / toBeFalsy", () => {
    expect(1).toBe(1);
    expect({ a: 1 }).toEqual({ a: 1 });
    expect(true).toBeTruthy();
    expect(false).toBeFalsy();
  });

  it("expect(fn).toThrow", () => {
    expect(() => {
      throw new Error("expected");
    }).toThrow();
  });

  it("expect(promise).toReject returns thenable", async () => {
    await expect(Promise.reject(new Error("rej"))).toReject();
  });

  it("t.step runs sub-steps (Deno)", async (t) => {
    await t.step("step1", () => {
      assert.strictEqual(1, 1);
    });
    await t.step("step2", async () => {
      await Promise.resolve();
      assert.ok(true);
    });
  });

  test.each([
    [1, 2, 3],
    [2, 3, 5],
  ])((row) => `adds ${row[0]}+${row[1]}=${row[2]}`, (t, a, b, expected) => {
    assert.strictEqual(a + b, expected);
  });
});
