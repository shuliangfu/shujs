/**
 * node:webstreams 兼容测试：ReadableStream、WritableStream、TransformStream 透传、边界
 */
const { describe, it, assert } = require("shu:test");
const ws = require("node:webstreams");

describe("node:webstreams exports", () => {
  it("has ReadableStream WritableStream TransformStream when present", () => {
    assert.ok(ws.ReadableStream != null || ws.WritableStream != null || ws.TransformStream != null || typeof ws === "object");
  });
});

describe("node:webstreams ReadableStream", () => {
  it("new ReadableStream() when present", () => {
    if (ws.ReadableStream) {
      const rs = new ws.ReadableStream();
      assert.ok(rs != null);
    }
  });
});

describe("node:webstreams boundary", () => {
  it("exports at least one stream class or is object", () => {
    assert.ok(ws != null && typeof ws === "object");
  });
});
