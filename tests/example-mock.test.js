// 演示 shu:test mock 当前能力：仅 mock.fn()，可断言 callCount、calls（无需 run()，加载后自动执行）
const { describe, it, assert, mock } = require("shu:test");

describe("mock.fn()", () => {
  it("records callCount and calls without implementation", () => {
    const fn = mock.fn();
    assert.strictEqual(fn.callCount, 0);
    assert.strictEqual(fn.calls.length, 0);

    fn();
    assert.strictEqual(fn.callCount, 1);
    assert.strictEqual(fn.calls.length, 1);
    assert.strictEqual(fn.calls[0].length, 0);

    fn(1, "a");
    assert.strictEqual(fn.callCount, 2);
    assert.strictEqual(fn.calls[0].length, 0);
    assert.strictEqual(fn.calls[1].length, 2);
    assert.strictEqual(fn.calls[1][0], 1);
    assert.strictEqual(fn.calls[1][1], "a");
  });

  it("with implementation: records and returns impl result", () => {
    const fn = mock.fn((a, b) => a + b);
    const r = fn(2, 3);
    assert.strictEqual(r, 5);
    assert.strictEqual(fn.callCount, 1);
    assert.strictEqual(fn.calls[0][0], 2);
    assert.strictEqual(fn.calls[0][1], 3);
  });

  it("injected as callback: assert after code under test runs", () => {
    const onDone = mock.fn();
    function doSomething(cb) {
      cb("ok");
    }
    doSomething(onDone);
    assert.strictEqual(onDone.callCount, 1);
    assert.strictEqual(onDone.calls[0][0], "ok");
  });
});
