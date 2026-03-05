#!/usr/bin/env bash
# Unified server benchmark: shu vs Bun vs Deno (hello-world)
# Usage: ./run-bench.sh [port]
# Requires: zig build (shu); optionally bun and deno in PATH
# Load client: per-runtime (shu/bun/deno run load.js) so event loop runs until result is printed.

set -e
PORT="${1:-3333}"
BASE="http://127.0.0.1:${PORT}"
TOTAL=50000
CONCURRENCY=64

# run_one name start_cmd load_cmd
# load_cmd is run with args: baseUrl total concurrency; must print one JSON line to stdout.
# Use timeout when available (Linux) so load client does not hang indefinitely; macOS has no timeout by default.
run_one() {
  local name="$1"
  local start_cmd="$2"
  local load_cmd="$3"
  PORT="$PORT" $start_cmd &
  local pid=$!
  sleep 2
  local out
  if command -v timeout >/dev/null 2>&1; then
    out=$(timeout 120 $load_cmd "$BASE" "$TOTAL" "$CONCURRENCY" 2>/dev/null) || true
  else
    out=$($load_cmd "$BASE" "$TOTAL" "$CONCURRENCY" 2>/dev/null) || true
  fi
  kill $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true
  [[ -z "$out" ]] && out="{}"
  echo "{\"runtime\":\"$name\",\"result\":$out}"
}

echo "Benchmark: $TOTAL requests, concurrency $CONCURRENCY, port $PORT"

# hello.js 接收第一个参数为 runtime（shu|deno|bun），据此启动对应服务器
command -v shu >/dev/null 2>&1 && run_one "shu" "shu run -A scripts/bench-server/hello.js shu" "shu run -A scripts/bench-server/load.js" || echo "{\"runtime\":\"shu\",\"skip\":\"not in PATH\"}"

command -v bun >/dev/null 2>&1 && run_one "bun" "bun run scripts/bench-server/hello.js bun" "bun run scripts/bench-server/load.js" || echo "{\"runtime\":\"bun\",\"skip\":\"not in PATH\"}"
command -v deno >/dev/null 2>&1 && run_one "deno" "deno run -A scripts/bench-server/hello.js deno" "deno run -A scripts/bench-server/load.js" || echo "{\"runtime\":\"deno\",\"skip\":\"not in PATH\"}"

echo "Done. Parse JSON for req_per_sec and p99_ms."
