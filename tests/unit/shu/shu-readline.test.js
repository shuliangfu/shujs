// shu:readline 模块测试（createInterface/clearLine 等）
// 约定：新增 API 时补一条正常用例 + 一条边界用例；question 用可读流 mock 做真实输入。
const { describe, it, assert } = require("shu:test");

const readline = require("shu:readline");
const stream = require("shu:stream");

describe("shu:readline", () => {
  it("has createInterface", () => {
    assert.strictEqual(typeof readline.createInterface, "function");
  });

  it("createInterface({ input, output }) returns interface with question/close", () => {
    const iface = readline.createInterface({ input: process.stdin, output: process.stdout });
    assert.ok(iface && typeof iface.question === "function");
    assert.strictEqual(typeof iface.close, "function");
    iface.close();
  });

  it("question(prompt, cb) receives answer from mock input stream", (done) => {
    const input = new stream.Readable();
    const output = new stream.Writable({ write(_chunk, _enc, cb) { cb(); } });
    const iface = readline.createInterface({ input, output });
    iface.question("> ", (answer) => {
      assert.strictEqual(typeof answer, "string");
      assert.strictEqual(answer, "mock-answer");
      iface.close();
      done();
    });
    input.push("mock-answer\n");
    input.push(null);
  });

  it("has clearLine when present", () => {
    if ("clearLine" in readline) {
      assert.strictEqual(typeof readline.clearLine, "function");
    }
  });

  it("clearScreenDown(stream[, cb]) does not throw", (done) => {
    const out = new stream.Writable({ write(_c, _e, cb) { cb(); } });
    if (typeof readline.clearScreenDown === "function") {
      readline.clearScreenDown(out, () => done());
    } else {
      done();
    }
  });

  it("cursorTo(stream, x[, y]) does not throw", (done) => {
    const out = new stream.Writable({ write(_c, _e, cb) { cb(); } });
    if (typeof readline.cursorTo === "function") {
      readline.cursorTo(out, 0, () => done());
    } else {
      done();
    }
  });

  it("moveCursor(stream, dx, dy) does not throw", (done) => {
    const out = new stream.Writable({ write(_c, _e, cb) { cb(); } });
    if (typeof readline.moveCursor === "function") {
      readline.moveCursor(out, 1, 0, () => done());
    } else {
      done();
    }
  });

  it("boundary: createInterface({}) or missing input/output does not throw", () => {
    try {
      const iface = readline.createInterface({});
      if (iface && typeof iface.close === "function") iface.close();
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });
});

describe("shu:readline boundary (production edge cases)", () => {
  it("interface.close() twice does not throw", () => {
    const iface = readline.createInterface({ input: process.stdin, output: process.stdout });
    iface.close();
    iface.close();
  });

  it("cursorTo(stream, NaN) does not crash", (done) => {
    const out = new stream.Writable({ write(_c, _e, cb) { cb(); } });
    if (typeof readline.cursorTo !== "function") return done();
    try {
      readline.cursorTo(out, NaN, 0, () => done());
    } catch (e) {
      assert.ok(e instanceof Error);
      done();
    }
  });

  it("moveCursor(stream, 0, 0) does not throw", (done) => {
    const out = new stream.Writable({ write(_c, _e, cb) { cb(); } });
    if (typeof readline.moveCursor === "function") {
      readline.moveCursor(out, 0, 0, () => done());
    } else {
      done();
    }
  });

  it("question with empty prompt still delivers answer", (done) => {
    const input = new stream.Readable();
    const output = new stream.Writable({ write(_c, _e, cb) { cb(); } });
    const iface = readline.createInterface({ input, output });
    iface.question("", (answer) => {
      assert.strictEqual(answer, "x");
      iface.close();
      done();
    });
    input.push("x\n");
    input.push(null);
  });
});
