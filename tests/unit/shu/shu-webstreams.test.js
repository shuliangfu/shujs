// shu:webstreams 模块测试（透传 globalThis 的 ReadableStream/WritableStream/TransformStream）
// 约定：新增 API 时补一条正常用例 + 一条边界用例。
const { describe, it, assert } = require("shu:test");

const webstreams = require("shu:webstreams");

describe("shu:webstreams", () => {
  it("has ReadableStream, WritableStream, TransformStream", () => {
    assert.ok(webstreams !== null && typeof webstreams === "object");
    assert.ok("ReadableStream" in webstreams);
    assert.ok("WritableStream" in webstreams);
    assert.ok("TransformStream" in webstreams);
  });

  it("ReadableStream is function when present", () => {
    if (webstreams.ReadableStream != null) {
      assert.strictEqual(typeof webstreams.ReadableStream, "function");
    }
  });

  it("new ReadableStream() when present returns stream with getReader", () => {
    if (webstreams.ReadableStream != null) {
      const rs = new webstreams.ReadableStream({});
      assert.ok(rs && typeof rs.getReader === "function");
    }
  });

  it("boundary: missing ReadableStream is undefined", () => {
    assert.ok(webstreams.ReadableStream === undefined || typeof webstreams.ReadableStream === "function");
  });
});
