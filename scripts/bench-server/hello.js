// Minimal HTTP server for benchmark: GET / returns "OK"
// Usage: <runtime> run hello.js [shu|deno|bun]  — 传参决定用哪个服务器的 API 启动
// Example: shu run -A hello.js shu  |  bun run hello.js bun  |  deno run -A hello.js deno
const host = '0.0.0.0'
const port = Number((typeof process !== 'undefined' && process.env && process.env.PORT) || '3333')

// 第一个命令行参数：process.argv[2]（shu/bun/deno 风格）或 Deno.args[0]
const arg =
  (typeof process !== 'undefined' && process.argv && process.argv[2]) ||
  (typeof Deno !== 'undefined' && Deno.args && Deno.args[0])
const runtime = String(arg || 'shu').toLowerCase()

if (runtime === 'bun' && typeof Bun !== 'undefined') {
  Bun.serve({ port, hostname: host, fetch: () => new Response('OK', { headers: { 'Content-Type': 'text/plain' } }) })
  console.log('bun.serve....')
} else if (runtime === 'deno' && typeof Deno !== 'undefined') {
  Deno.serve({ port, hostname: host }, () => new Response('OK', { headers: { 'Content-Type': 'text/plain' } }))
  console.log('deno.serve....')
} else {
  // 默认或显式 shu，或当前环境无 Bun/Deno 时用 Shu
  Shu.server({ port, host, fetch: () => new Response('OK', { headers: { 'Content-Type': 'text/plain' } }) })
  console.log('shu.server....')
}
console.error('Server listening on', host + ':' + port)
