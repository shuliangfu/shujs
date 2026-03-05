/**
 * node:errors 全面兼容测试：SystemError、codes 与 Node node:errors API 对齐
 */
const { describe, it, assert } = require("shu:test");

const errors = require("node:errors");

describe("node:errors exports", () => {
  it("exports SystemError and codes", () => {
    assert.strictEqual(typeof errors.SystemError, "function");
    assert.ok(errors.codes != null && typeof errors.codes === "object");
  });
});

describe("node:errors SystemError", () => {
  it("SystemError instance has name and message", () => {
    const e = new errors.SystemError("test message");
    assert.strictEqual(e.name, "SystemError");
    assert.strictEqual(e.message, "test message");
  });

  it("SystemError accepts options code, errno, syscall, path, dest", () => {
    const e = new errors.SystemError("open failed", {
      code: "ENOENT",
      errno: -2,
      syscall: "open",
      path: "/nonexistent",
      dest: "/dest",
    });
    assert.strictEqual(e.code, "ENOENT");
    assert.strictEqual(e.errno, -2);
    assert.strictEqual(e.syscall, "open");
    assert.strictEqual(e.path, "/nonexistent");
    assert.strictEqual(e.dest, "/dest");
  });

  it("SystemError without options still has name SystemError", () => {
    const e = new errors.SystemError("msg");
    assert.strictEqual(e.name, "SystemError");
    assert.strictEqual(e.message, "msg");
  });

  it("SystemError is instanceof Error", () => {
    const e = new errors.SystemError("err");
    assert.ok(e instanceof Error);
  });
});

describe("node:errors codes", () => {
  it("codes has common ERR_* keys", () => {
    assert.strictEqual(errors.codes.ERR_INVALID_ARG_TYPE, "ERR_INVALID_ARG_TYPE");
    assert.strictEqual(errors.codes.ERR_OUT_OF_RANGE, "ERR_OUT_OF_RANGE");
    assert.strictEqual(errors.codes.ERR_STREAM_WRITE_AFTER_END, "ERR_STREAM_WRITE_AFTER_END");
    assert.strictEqual(errors.codes.ERR_METHOD_NOT_IMPLEMENTED, "ERR_METHOD_NOT_IMPLEMENTED");
  });

  it("codes has common E* system codes", () => {
    assert.strictEqual(errors.codes.ENOENT, "ENOENT");
    assert.strictEqual(errors.codes.EACCES, "EACCES");
    assert.strictEqual(errors.codes.EEXIST, "EEXIST");
    assert.strictEqual(errors.codes.ETIMEDOUT, "ETIMEDOUT");
  });
});

describe("node:errors boundary", () => {
  it("SystemError with empty message", () => {
    const e = new errors.SystemError("");
    assert.strictEqual(e.name, "SystemError");
    assert.strictEqual(e.message, "");
    assert.ok(e instanceof Error);
  });

  it("SystemError with only code in options", () => {
    const e = new errors.SystemError("msg", { code: "EINVAL" });
    assert.strictEqual(e.code, "EINVAL");
  });

  it("SystemError with path only in options", () => {
    const e = new errors.SystemError("msg", { path: "/tmp/foo" });
    assert.strictEqual(e.path, "/tmp/foo");
  });

  it("codes access non-existent key returns undefined or string", () => {
    const v = errors.codes.NON_EXISTENT_CODE_KEY;
    assert.ok(v === undefined || typeof v === "string");
  });
});
