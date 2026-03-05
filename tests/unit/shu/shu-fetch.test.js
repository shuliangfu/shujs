// 全局 fetch 模块测试：globalThis.fetch 由 shu fetch 模块注册，需 --allow-net
// 通过本地 server 发真实请求，校验 Response 的 ok/status/statusText/body、.text()、.json()
// 含边界测试：无参、非 2xx、.json() 非 JSON  body、不可达地址
const { describe, it, assert } = require("shu:test");
const serverModule = require("shu:server");

const PORT_FETCH = 19270;
const HOST = "127.0.0.1";

function waitMs(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

describe("shu fetch (global fetch)", () => {
  it("global fetch is a function", () => {
    assert.strictEqual(typeof globalThis.fetch, "function");
  });

  it("fetch(url) returns Promise resolving to Response-like object", async () => {
    const server = serverModule.server({
      port: PORT_FETCH,
      host: HOST,
      fetch: () => new Response("hello", { headers: { "Content-Type": "text/plain" } }),
    });
    await waitMs(80);
    const res = await fetch(`http://${HOST}:${PORT_FETCH}/`);
    assert.ok(res != null);
    assert.strictEqual(typeof res.status, "number");
    assert.strictEqual(res.status, 200);
    assert.strictEqual(res.ok, true);
    assert.ok("statusText" in res);
    assert.ok("body" in res);
    server.stop();
    await waitMs(120);
  });

  it("response.text() returns Promise resolving to body string", async () => {
    const server = serverModule.server({
      port: PORT_FETCH + 1,
      host: HOST,
      fetch: () => new Response("world", { headers: { "Content-Type": "text/plain" } }),
    });
    await waitMs(80);
    const res = await fetch(`http://${HOST}:${PORT_FETCH + 1}/`);
    const text = await res.text();
    assert.strictEqual(text, "world");
    server.stop();
    await waitMs(120);
  });

  it("response.json() returns Promise resolving to parsed JSON", async () => {
    const server = serverModule.server({
      port: PORT_FETCH + 2,
      host: HOST,
      fetch: () => new Response('{"a":1,"b":"x"}', { headers: { "Content-Type": "application/json" } }),
    });
    await waitMs(80);
    const res = await fetch(`http://${HOST}:${PORT_FETCH + 2}/`);
    const data = await res.json();
    assert.strictEqual(data.a, 1);
    assert.strictEqual(data.b, "x");
    server.stop();
    await waitMs(120);
  });

  it("fetch to unreachable host rejects", async () => {
    // 使用未监听的端口，请求应失败并 reject
    let rejected = false;
    let errMsg = "";
    try {
      await fetch(`http://${HOST}:${PORT_FETCH + 9}/`);
    } catch (e) {
      rejected = true;
      errMsg = e != null ? String(e) : "";
    }
    assert.ok(rejected, "fetch to unreachable port should reject");
    assert.ok(errMsg.length >= 0);
  });
});

describe("shu fetch boundary", () => {
  it("fetch() with no arguments returns undefined or non-thenable", () => {
    const ret = fetch();
    // 实现：无参时返回 undefined，故无 then
    assert.ok(ret === undefined || typeof ret?.then !== "function");
  });

  it("non-2xx response: res.ok false and res.status set", async () => {
    const server = serverModule.server({
      port: PORT_FETCH + 3,
      host: HOST,
      fetch: () => new Response("not found", { status: 404 }),
    });
    await waitMs(80);
    const res = await fetch(`http://${HOST}:${PORT_FETCH + 3}/`);
    assert.strictEqual(res.status, 404);
    assert.strictEqual(res.ok, false);
    assert.strictEqual(await res.text(), "not found");
    server.stop();
    await waitMs(120);
  });

  it("response.json() on non-JSON body rejects", async () => {
    const server = serverModule.server({
      port: PORT_FETCH + 4,
      host: HOST,
      fetch: () => new Response("not json", { headers: { "Content-Type": "text/plain" } }),
    });
    await waitMs(80);
    const res = await fetch(`http://${HOST}:${PORT_FETCH + 4}/`);
    let rejected = false;
    try {
      await res.json();
    } catch (_) {
      rejected = true;
    }
    assert.ok(rejected, "response.json() on non-JSON body should reject");
    server.stop();
    await waitMs(120);
  });
});
