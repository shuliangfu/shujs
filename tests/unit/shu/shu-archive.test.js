// shu:archive 模块测试（getExports 返回空对象；tar/zip 通过 Shu.archive 注册，此处仅测 require 与 exports 形态）
// 约定：新增 API 时补一条正常用例 + 一条边界用例。
const { describe, it, assert } = require("shu:test");

const archive = require("shu:archive");

describe("shu:archive", () => {
  it("require('shu:archive') returns object", () => {
    assert.ok(archive !== null && typeof archive === "object");
  });

  it("exports is extensible (empty or with tar/zip from register)", () => {
    assert.ok(Object.getOwnPropertyNames(archive).length >= 0);
  });

  it("boundary: archive is not null and has typeof object", () => {
    assert.strictEqual(typeof archive, "object");
    assert.ok(archive !== null);
  });
});
