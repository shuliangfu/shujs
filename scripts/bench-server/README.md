# Server benchmark (shu vs Bun vs Deno)

Unified benchmark for hello-world HTTP throughput and P99 latency.

## Usage

1. Build shu: `zig build -Doptimize=ReleaseFast`
2. Run: `./scripts/bench-server/run-bench.sh [port]`
   - Uses `./zig-out/bin/shu` by default; set `SHU_BIN` to override.
   - Runs shu, then Bun and Deno if in PATH.
3. Each runtime: start server → run load client with the **same** runtime (e.g. `bun run load.js` when benchmarking Bun) so the event loop runs until the result is printed → report `req_per_sec` and `p99_ms`.

## CI

Add a job that runs after build, e.g.:

```yaml
- run: zig build -Doptimize=ReleaseFast
- run: chmod +x scripts/bench-server/run-bench.sh && ./scripts/bench-server/run-bench.sh 3333
```

Parse JSON lines for `req_per_sec` / `p99_ms` to track regressions or compare with Bun/Deno.

## Scenarios

- **hello.js**: GET / returns "OK" (current).
- **Static file / WebSocket**: add further scripts and extend run-bench.sh.
