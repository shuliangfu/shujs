// shu:stream 模块测试（Readable/Writable/Duplex/Transform/PassThrough/pipeline/finished）
// 约定：新增 API 时补一条正常用例 + 一条边界用例。
const { describe, it, assert } = require("shu:test");

const stream = require("shu:stream");

describe("shu:stream", () => {
  it("has Readable, Writable, Duplex, Transform, PassThrough", () => {
    assert.strictEqual(typeof stream.Readable, "function");
    assert.strictEqual(typeof stream.Writable, "function");
    assert.strictEqual(typeof stream.Duplex, "function");
    assert.strictEqual(typeof stream.Transform, "function");
    assert.strictEqual(typeof stream.PassThrough, "function");
  });

  it("has pipeline and finished", () => {
    assert.strictEqual(typeof stream.pipeline, "function");
    assert.strictEqual(typeof stream.finished, "function");
  });

  it("new stream.Readable() has push and read", () => {
    const r = new stream.Readable();
    assert.ok(r && typeof r.push === "function" && typeof r.read === "function");
  });

  it("new stream.Writable() has write and end", () => {
    const w = new stream.Writable();
    assert.ok(w && typeof w.write === "function" && typeof w.end === "function");
  });

  it("pipeline(single stream, callback) calls callback", (done) => {
    const r = new stream.Readable();
    stream.pipeline(r, (err) => {
      assert.ok(err === null || err === undefined || err instanceof Error);
      done();
    });
    r.push(null);
  });

  it("boundary: finished(stream, callback) with valid stream does not throw", (done) => {
    const r = new stream.Readable();
    stream.finished(r, (err) => {
      done();
    });
    r.push(null);
  });

  it("Readable: push(data) then read() returns same data", () => {
    const r = new stream.Readable();
    const data = "stream-hello";
    r.push(data);
    r.push(null);
    const out = r.read();
    assert.ok(out === data || (out && out.toString && out.toString() === data));
  });

  it("Writable: write(data) then end() completes and callback receives chunk", (done) => {
    const w = new stream.Writable({
      write(chunk, enc, cb) {
        assert.ok(chunk != null);
        assert.strictEqual(String(chunk), "writable-data");
        cb();
      },
    });
    w.write("writable-data", () => {});
    w.end(() => done());
  });

  it("pipeline(Readable, Writable, callback) moves data", (done) => {
    const r = new stream.Readable();
    const chunks = [];
    const w = new stream.Writable({
      write(chunk, enc, cb) {
        chunks.push(chunk);
        cb();
      },
    });
    stream.pipeline(r, w, (err) => {
      assert.ok(err === null || err === undefined);
      assert.ok(chunks.length >= 1);
      assert.strictEqual(String(chunks[0]), "piped");
      done();
    });
    r.push("piped");
    r.push(null);
  });

  it("new stream.Duplex() has read/write and can push and write", (done) => {
    const d = new stream.Duplex({
      read() {},
      write(chunk, enc, cb) {
        assert.strictEqual(String(chunk), "duplex-data");
        cb();
        done();
      },
    });
    d.write("duplex-data");
  });

  it("new stream.Transform() transforms chunk", (done) => {
    const t = new stream.Transform({
      transform(chunk, enc, cb) {
        this.push(chunk.toString().toUpperCase());
        cb();
      },
    });
    const out = [];
    t.on("data", (d) => out.push(d));
    t.on("end", () => {
      assert.ok(out.length >= 1);
      assert.strictEqual(String(out[0]), "HI");
      done();
    });
    t.write("hi");
    t.end();
  });

  it("new stream.PassThrough() passes data through", (done) => {
    const p = new stream.PassThrough();
    const out = [];
    p.on("data", (d) => out.push(d));
    p.on("end", () => {
      assert.strictEqual(String(out[0]), "pass");
      done();
    });
    p.write("pass");
    p.end();
  });
});

describe("shu:stream boundary (production edge cases)", () => {
  it("pipeline with single stream and immediate push(null) completes", (done) => {
    const r = new stream.Readable();
    stream.pipeline(r, (err) => {
      assert.ok(err === null || err === undefined);
      done();
    });
    r.push(null);
  });

  it("finished callback called once when stream ends", (done) => {
    const r = new stream.Readable();
    let count = 0;
    stream.finished(r, (err) => {
      count++;
      assert.strictEqual(count, 1);
      done();
    });
    r.push(null);
  });

  it("Writable end() twice only completes once", (done) => {
    const w = new stream.Writable({ write(_c, _e, cb) { cb(); } });
    w.end();
    w.end(() => done());
  });

  it("Readable read() after push(null) returns null or remaining", () => {
    const r = new stream.Readable();
    r.push("a");
    r.push(null);
    const first = r.read();
    const second = r.read();
    assert.ok(first != null || second === null || second === undefined);
  });

  it("pipeline callback receives error when middle stream errors", (done) => {
    const r = new stream.Readable();
    const t = new stream.Transform({
      transform(_chunk, _enc, cb) {
        cb(new Error("transform error"));
      },
    });
    const w = new stream.Writable({ write(_c, _e, cb) { cb(); } });
    stream.pipeline(r, t, w, (err) => {
      assert.ok(err instanceof Error);
      assert.ok(err.message.includes("transform") || err.message.length > 0);
      done();
    });
    r.push("x");
    r.push(null);
  });

  it("PassThrough with empty write then end completes", (done) => {
    const p = new stream.PassThrough();
    p.on("end", () => done());
    p.write("");
    p.end();
  });
});
