// shu:sql 模块测试（Bun 风格 sql/SQL 占位：tagged template 抛 not implemented）
const { describe, it, assert } = require("shu:test");

const s = require("shu:sql");

describe("shu:sql", () => {
  it("exports sql and SQL", () => {
    assert.strictEqual(typeof s.sql, "function");
    assert.strictEqual(typeof s.SQL, "function");
  });

  it("sql tagged template throws not implemented", () => {
    assert.throws(() => s.sql`SELECT 1`, /shu:sql not implemented/);
  });

  it("new SQL(uri) returns callable instance", () => {
    const db = new s.SQL("postgresql://localhost");
    assert.strictEqual(typeof db, "function");
    assert.throws(() => db`SELECT 1`, /shu:sql not implemented/);
  });

  it("SQL instance has begin method", () => {
    const db = new s.SQL("sqlite:///tmp/x.db");
    assert.strictEqual(typeof db.begin, "function");
    assert.throws(() => db.begin(), /shu:sql not implemented/);
  });
});

describe("bun:sql maps to shu:sql", () => {
  const bunSql = require("bun:sql");

  it("bun:sql has same sql and SQL as shu:sql", () => {
    assert.strictEqual(bunSql.sql, s.sql);
    assert.strictEqual(bunSql.SQL, s.SQL);
  });
});
