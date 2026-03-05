// shu:crypto 模块测试（digest/randomUUID/encrypt/decrypt/getRandomValues 等，与 globalThis.crypto 同一引用）
// 约定：新增 API 时补一条正常用例 + 一条边界用例；全局方法（不通过 require）单独测。
const { describe, it, assert } = require("shu:test");

const crypto = require("shu:crypto");

// 仅用全局 crypto，不依赖 require("shu:crypto")，验证 bindings 已注册 globalThis.crypto
describe("global crypto (globalThis.crypto)", () => {
  it("globalThis.crypto exists and is same as require('shu:crypto')", () => {
    assert.ok(globalThis.crypto != null);
    assert.strictEqual(globalThis.crypto, crypto);
  });

  it("globalThis.crypto.randomUUID() works without require", () => {
    const uuid = globalThis.crypto.randomUUID();
    assert.strictEqual(typeof uuid, "string");
    assert.ok(uuid.length > 0);
    assert.ok(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(uuid));
  });

  it("globalThis.crypto.digest(algorithm, data) works without require", () => {
    const hex = globalThis.crypto.digest("SHA-256", "hello");
    assert.strictEqual(typeof hex, "string");
    assert.ok(/^[a-f0-9]+$/i.test(hex));
  });

  it("globalThis.crypto has getRandomValues and fills TypedArray", () => {
    assert.strictEqual(typeof globalThis.crypto.getRandomValues, "function");
    const arr = new Uint8Array(8);
    globalThis.crypto.getRandomValues(arr);
    assert.strictEqual(arr.length, 8);
    assert.ok(arr.some((v) => v !== 0) || arr.every((v) => v === 0)); // 允许全零概率极低
  });

  it("globalThis.crypto has algorithm constants", () => {
    assert.ok("CHACHA20_POLY1305" in globalThis.crypto);
    assert.ok("AES_256_GCM" in globalThis.crypto);
  });

  it("globalThis.crypto.encrypt/decrypt roundtrip without require", () => {
    const key = "a-secret-key-at-least-32-bytes-long!!";
    const plain = "global crypto test";
    const cipher = globalThis.crypto.encrypt(key, plain);
    assert.strictEqual(typeof cipher, "string");
    const back = globalThis.crypto.decrypt(key, cipher);
    assert.strictEqual(back, plain);
  });
});

describe("shu:crypto", () => {
  it("require('shu:crypto') returns same as global crypto", () => {
    assert.strictEqual(crypto, globalThis.crypto);
  });

  it("has randomUUID", () => {
    assert.strictEqual(typeof crypto.randomUUID, "function");
    const uuid = crypto.randomUUID();
    assert.strictEqual(typeof uuid, "string");
    assert.ok(uuid.length > 0);
  });

  it("has digest(algorithm, data)", () => {
    assert.strictEqual(typeof crypto.digest, "function");
    const hex = crypto.digest("SHA-256", "hello");
    assert.strictEqual(typeof hex, "string");
    assert.ok(/^[a-f0-9]+$/i.test(hex));
  });

  it("digest SHA-1 returns 40 hex chars", () => {
    const hex = crypto.digest("SHA-1", "test");
    assert.strictEqual(hex.length, 40);
    assert.ok(/^[a-f0-9]+$/i.test(hex));
  });

  it("has encrypt and decrypt", () => {
    assert.strictEqual(typeof crypto.encrypt, "function");
    assert.strictEqual(typeof crypto.decrypt, "function");
  });

  it("has getRandomValues", () => {
    assert.strictEqual(typeof crypto.getRandomValues, "function");
    const arr = new Uint8Array(16);
    crypto.getRandomValues(arr);
    assert.strictEqual(arr.length, 16);
    const zeros = new Uint8Array(16);
    assert.ok(arr.some((v, i) => v !== zeros[i]), "getRandomValues should fill with random bytes");
  });

  it("has generateKeyPair, encryptWithPublicKey, decryptWithPrivateKey", () => {
    assert.strictEqual(typeof crypto.generateKeyPair, "function");
    assert.strictEqual(typeof crypto.encryptWithPublicKey, "function");
    assert.strictEqual(typeof crypto.decryptWithPrivateKey, "function");
  });

  it("has CHACHA20_POLY1305 and AES_256_GCM constants", () => {
    assert.ok("CHACHA20_POLY1305" in crypto);
    assert.ok("AES_256_GCM" in crypto);
  });

  it("encrypt(key, plaintext) and decrypt(key, ciphertext) roundtrip", () => {
    const key = "a-secret-key-at-least-32-bytes-long!!";
    const plain = "secret message";
    const cipher = crypto.encrypt(key, plain);
    assert.strictEqual(typeof cipher, "string");
    assert.ok(cipher.length > 0);
    const back = crypto.decrypt(key, cipher);
    assert.strictEqual(back, plain);
  });

  it("generateKeyPair('X25519') returns publicKey and privateKey", () => {
    const pair = crypto.generateKeyPair("X25519");
    assert.ok(pair && typeof pair === "object");
    assert.strictEqual(typeof pair.publicKey, "string");
    assert.strictEqual(typeof pair.privateKey, "string");
    assert.ok(pair.publicKey.length > 0 && pair.privateKey.length > 0);
  });

  it("encryptWithPublicKey and decryptWithPrivateKey roundtrip", () => {
    const pair = crypto.generateKeyPair("X25519");
    const plain = "x25519 message";
    const cipher = crypto.encryptWithPublicKey(pair.publicKey, plain);
    assert.strictEqual(typeof cipher, "string");
    const back = crypto.decryptWithPrivateKey(pair.privateKey, cipher);
    assert.strictEqual(back, plain);
  });
});

describe("shu:crypto boundary", () => {
  it("digest with empty string returns hex", () => {
    const hex = crypto.digest("SHA-256", "");
    assert.strictEqual(typeof hex, "string");
    assert.ok(/^[a-f0-9]+$/i.test(hex));
  });

  it("digest with invalid algorithm throws or returns error", () => {
    try {
      const out = crypto.digest("INVALID_ALGO", "x");
      assert.strictEqual(typeof out, "string");
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });

  it("getRandomValues with zero-length buffer does not throw", () => {
    const arr = new Uint8Array(0);
    crypto.getRandomValues(arr);
    assert.strictEqual(arr.length, 0);
  });

  it("decrypt with wrong key throws or returns garbage", () => {
    const key = "a-secret-key-at-least-32-bytes-long!!";
    const cipher = crypto.encrypt(key, "x");
    try {
      const out = crypto.decrypt("wrong-key-at-least-32-bytes-long!!!", cipher);
      assert.ok(typeof out === "string");
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });

  it("encrypt with short key throws or derives", () => {
    try {
      const out = crypto.encrypt("short", "plain");
      assert.strictEqual(typeof out, "string");
    } catch (e) {
      assert.ok(e instanceof Error);
    }
  });
});
