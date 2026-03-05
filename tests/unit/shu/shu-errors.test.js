// node:errors 兼容测试（SystemError、codes 与 Node node:errors 对齐）
const { describe, it, assert } = require("shu:test");

const errors = require("node:errors");

describe("node:errors", () => {
  it("exports SystemError and codes", () => {
    assert.strictEqual(typeof errors.SystemError, "function");
    assert.ok(errors.codes != null && typeof errors.codes === "object");
  });

  it("SystemError instance has name and message", () => {
    const e = new errors.SystemError("test message");
    assert.strictEqual(e.name, "SystemError");
    assert.strictEqual(e.message, "test message");
  });

  it("SystemError accepts options code, errno, syscall, path", () => {
    const e = new errors.SystemError("open failed", {
      code: "ENOENT",
      errno: -2,
      syscall: "open",
      path: "/nonexistent",
    });
    assert.strictEqual(e.code, "ENOENT");
    assert.strictEqual(e.errno, -2);
    assert.strictEqual(e.syscall, "open");
    assert.strictEqual(e.path, "/nonexistent");
  });

  it("codes has common ERR_* and E* keys", () => {
    assert.strictEqual(errors.codes.ERR_INVALID_ARG_TYPE, "ERR_INVALID_ARG_TYPE");
    assert.strictEqual(errors.codes.ERR_OUT_OF_RANGE, "ERR_OUT_OF_RANGE");
    assert.strictEqual(errors.codes.ENOENT, "ENOENT");
    assert.strictEqual(errors.codes.EACCES, "EACCES");
  });
});
