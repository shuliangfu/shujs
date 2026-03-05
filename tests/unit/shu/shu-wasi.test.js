// shu:wasi 模块测试（占位：WASI 类抛 not implemented）
const { describe, it, assert } = require("shu:test");

const wasi = require("shu:wasi");

describe("shu:wasi", () => {
  it("exports object with WASI or methods", () => {
    assert.ok(wasi !== null && typeof wasi === "object");
  });

  it("WASI or constructor throws when used", () => {
    if (typeof wasi.WASI === "function") {
      assert.throws(() => new wasi.WASI({}), /not implemented|wasi/i);
    }
  });
});
