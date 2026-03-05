// shu:mongo 模块测试（MongoClient 占位：connect/db/close 抛 not implemented）
const { describe, it, assert } = require("shu:test");

const m = require("shu:mongo");

describe("shu:mongo", () => {
  it("exports MongoClient", () => {
    assert.strictEqual(typeof m.MongoClient, "function");
  });

  it("new MongoClient(uri) has connect, db, close", () => {
    const client = new m.MongoClient("mongodb://localhost");
    assert.strictEqual(typeof client.connect, "function");
    assert.strictEqual(typeof client.db, "function");
    assert.strictEqual(typeof client.close, "function");
  });

  it("client.connect() throws not implemented", () => {
    const client = new m.MongoClient("mongodb://localhost");
    assert.throws(() => client.connect(), /shu:mongo not implemented/);
  });
});

describe("bun:mongo maps to shu:mongo", () => {
  const bunMongo = require("bun:mongo");

  it("bun:mongo has same MongoClient as shu:mongo", () => {
    assert.strictEqual(bunMongo.MongoClient, m.MongoClient);
  });
});
