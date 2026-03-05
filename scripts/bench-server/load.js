// Load client: send N concurrent requests to baseUrl, report throughput and P99 (if timings available)
// Usage: shu|bun|deno run [options] load.js <baseUrl> <totalRequests> [concurrency]
// Example: shu run --allow-net load.js http://127.0.0.1:3333/ 100000 64
// 仅当明确传入三参数时取末尾为 baseUrl/total/concurrency，否则用默认值，避免单独运行无参时 total=NaN 导致立即结束
const argv = process.argv;
const hasThreeArgs = argv.length >= 7; // e.g. shu run --allow-net load.js <url> <total> <concurrency>
const tail = hasThreeArgs ? argv.slice(-3) : [];
const baseUrl = (tail[0] && !tail[0].startsWith("-")) ? tail[0] : "http://127.0.0.1:3333/";
const total = Math.max(0, parseInt(tail[1], 10) || 10000);
const concurrency = Math.max(1, parseInt(tail[2], 10) || 32);

const start = Date.now();
let completed = 0;
const timings = [];

function runOne() {
  if (completed >= total) return;
  const t0 = Date.now();
  fetch(baseUrl)
    .then((r) => r.text())
    .then(() => {
      timings.push(Date.now() - t0);
      completed++;
      runOne();
    })
    .catch(() => {
      completed++;
      runOne();
    });
}

/** Poll until completed >= total, then resolve. */
function wait() {
  if (completed < total) return new Promise((r) => setTimeout(r, 50)).then(wait);
}

(async () => {
  for (let i = 0; i < concurrency; i++) runOne();
  await wait();
  const elapsed = (Date.now() - start) / 1000;
  const rps = total / elapsed;
  timings.sort((a, b) => a - b);
  const p99 = timings[Math.floor(timings.length * 0.99)] ?? 0;
  console.log(JSON.stringify({ total, concurrency, elapsed_sec: elapsed.toFixed(2), req_per_sec: Math.round(rps), p99_ms: p99 }));
  if (typeof process !== "undefined" && process.exit) process.exit(0);
})();
