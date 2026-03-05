# Node.js 兼容性分析（node:xxx / Node.* / 全局）

目标：与 Node 运行时**无缝兼容**，使 `shu run` 可替代 `node` 执行现有 Node 项目。本文档分析 **node: 内置模块**、**Node 命名空间/类**、**全局对象与方法** 与当前 **shu:xxx** 的覆盖情况，并列出缺口。

**说明**：Node 官方 API 见 [nodejs.org/api](https://nodejs.org/api/documentation.html)。本文档力求覆盖全部内置模块与常用全局；若有遗漏以官方文档为准。

---

## 0. 已放弃的 API（不写兼容）

以下为 **Node 已弃用** 或 **与 shu 架构不兼容** 的模块，**仅保持占位（shu_stub）**，不再实现行为兼容：

| 说明符 | 原因 | shu 策略 |
|--------|------|----------|
| **node:punycode** | Node 已弃用（推荐使用 URL/URLSearchParams 等） | 占位，不实现 |
| **node:domain** | Node 已弃用（推荐 async_hooks/AsyncLocalStorage） | 占位，不实现 |
| **node:v8** | 引擎为 JSC 非 V8，无 V8 专有 API | 占位，不实现 |

上述模块在 `builtin.zig` 中映射到占位实现；若业务代码 `require('node:punycode')` 等，可返回空对象或抛 not implemented，**无需补全兼容逻辑**。

---

## 兼容性分析结论

- **已放弃的 API（不写兼容）**  
  **node:punycode**、**node:domain**、**node:v8** 三类：Node 已弃用或引擎为 JSC 非 V8，仅保持占位，不实现行为兼容。详见 §0。

- **仍需实现的兼容（按优先级）**  
  - **建议补（生态常见）**：**node:fs/promises**（子路径解析 + Promise API 导出）、**crypto.subtle / webcrypto.subtle**（若项目依赖 Web Crypto 的 sign/verify/encrypt/decrypt）——**已实现**（fs/promises 解析 + Promise 导出；subtle.digest 已实现，其余占位）。  
  - **可选补（按需）**：node:repl、node:wasi（仍为占位）；node:errors、MessageChannel/MessagePort 已实现或已占位。
  - **可选占位即可**：node:corepack、node:sqlite、reportError、BroadcastChannel 已占位或已实现；StructuredClone 按引擎确认。

  完整列表见 §1 中「仍需实现的兼容」及 §3 全局缺口。

- **实施建议**  
  优先做 **node:fs/promises** 与 **crypto.subtle** 即可覆盖多数依赖；其余按实际生态需求补或占位。当前已覆盖绝大部分 node: 内置与全局，**已可运行多数 Node 项目**。

---

## 1. node:xxx 内置模块 ↔ shu:xxx 覆盖表

| node: 说明符 | shu: 对应 | 覆盖状态 | 缺口说明 |
|--------------|-----------|----------|----------|
| node:path | shu:path | ✅ 已覆盖 | join/resolve/dirname/basename/extname/normalize/parse/format/posix/win32 等 |
| node:fs | shu:fs | ✅ 已覆盖 | readFile/writeFile/readdir/stat/mkdir/readSync/writeSync 等；promises 子路径可选 |
| node:zlib | shu:zlib | ✅ 已覆盖 | gzipSync/gunzipSync/deflateSync/inflateSync/brotliSync 及异步 |
| node:assert | shu:assert | ✅ 已覆盖 | ok/strictEqual/deepStrictEqual/fail/throws/rejects/doesNotReject |
| node:events | shu:events | ✅ 已覆盖 | EventEmitter、on/off/emit |
| node:util | shu:util | ✅ 已覆盖 | inspect/promisify/types |
| node:querystring | shu:querystring | ✅ 已覆盖 | parse/stringify |
| node:url | shu:url | ✅ 已覆盖 | parse/format、URL/URLSearchParams |
| node:string_decoder | shu:string_decoder | ✅ 已覆盖 | StringDecoder |
| node:crypto | shu:crypto | ✅ 已覆盖 | randomUUID/digest/getRandomValues/encrypt/decrypt/密钥对；subtle.digest 已实现，其余占位 |
| node:os | shu:os | ✅ 已覆盖 | platform/arch/homedir/tmpdir/cpus/loadavg/uptime/totalmem/freemem 等 |
| node:process | shu:process | ✅ 已覆盖 | cwd/platform/env/argv/exit 等 |
| node:timers | shu:timers | ✅ 已覆盖 | setTimeout/setInterval/setImmediate/clearTimeout/clearInterval/queueMicrotask |
| node:console | shu:console | ✅ 已覆盖 | log/warn/error/info/debug |
| node:child_process | shu:cmd | ✅ 已覆盖 | exec/execSync/spawn/spawnSync；fork 占位 |
| node:worker_threads | shu:threads | ✅ 已覆盖 | Worker/isMainThread/parentPort/workerData |
| node:buffer | shu:buffer | ✅ 已覆盖 | Buffer.alloc/from/concat/isBuffer |
| node:stream | shu:stream | ✅ 已覆盖 | Readable/Writable/Duplex/Transform/PassThrough、pipeline/finished |
| node:http | shu:http | ✅ 已覆盖 | createServer/requestListener |
| node:https | shu:https | ✅ 已覆盖 | createServer |
| node:net | shu:net | ✅ 已覆盖 | createServer/createConnection/connect/Socket |
| node:tls | shu:tls | ✅ 已覆盖 | createServer/connect/createSecureContext |
| node:dgram | shu:dgram | ✅ 已覆盖 | createSocket |
| node:dns | shu:dns | ✅ 已覆盖 | lookup/resolve/resolve4/resolve6/setServers/getServers |
| node:readline | shu:readline | ✅ 已覆盖 | createInterface/question/clearLine 等 |
| node:vm | shu:vm | ✅ 已覆盖 | createContext/runInContext/runInNewContext/Script |
| node:async_hooks | shu:async_hooks | ✅ 已覆盖 | executionAsyncId/triggerAsyncId/createHook/AsyncResource |
| node:async_context | 无 node: 对应 | — | Node 20+ AsyncLocalStorage 在 node:async_hooks 或独立；shu 有 shu:async_context |
| node:perf_hooks | shu:perf_hooks | ✅ 已覆盖 | performance/PerformanceObserver/mark/measure/timerify |
| node:module | shu:module | ✅ 已覆盖 | createRequire/isBuiltin/builtinModules/findPackageJSON/stripTypeScriptTypes |
| node:diagnostics_channel | shu:diagnostics_channel | ✅ 已覆盖 | channel/subscribe/publish/hasSubscribers |
| node:report | shu:report | ✅ 已覆盖 | getReport/writeReport |
| node:inspector | shu:inspector | ✅ 已覆盖 | open/close/url（占位） |
| node:tracing | shu:tracing | ✅ 已覆盖 | createTracing/trace（no-op） |
| node:tty | shu:tty | ✅ 已覆盖 | isTTY/ReadStream/WriteStream |
| node:permissions | shu:permissions | ✅ 已覆盖 | has/request |
| node:intl | shu:intl | ✅ 已覆盖 | getIntl/Segmenter |
| node:webcrypto | shu:webcrypto | ✅ 已覆盖 | 透传 globalThis.crypto；subtle 由 shu:crypto 挂载（digest 已实现） |
| node:webstreams | shu:webstreams | ✅ 已覆盖 | 透传 ReadableStream/WritableStream/TransformStream |
| node:cluster | shu:cluster | ✅ 已覆盖 | isPrimary/workers/setupPrimary/disconnect；fork 占位 |
| node:repl | shu:repl | ⚠ 占位 | start/ReplServer 抛 not implemented |
| node:test | shu:test | ✅ 已实现 | describe/it/test/run/beforeAll/afterAll/mock/snapshot 等（与 node:test 语义接近） |
| node:wasi | shu:wasi | ⚠ 占位 | WASI 抛 not implemented |
| node:debugger | shu:debugger | ✅ 已覆盖 | port/host |
| node:v8 | — | ❌ 已放弃 | JSC 非 V8；仅占位，不写兼容 |
| node:punycode | — | ❌ 已放弃 | Node 已弃用；仅占位，不写兼容 |
| node:domain | — | ❌ 已放弃 | Node 已弃用；仅占位，不写兼容 |
| node:fs/promises | shu:fs | ✅ 已覆盖 | 解析 node:fs/promises 与 fs/promises，导出 Promise 形态 API（util.promisify 包装） |
| node:buffer (global Buffer) | shu:buffer | ✅ 已覆盖 | 全局 Buffer 由 bindings 注册 |
| node:async_context | shu:async_context | ✅ 已覆盖 | AsyncLocalStorage 等（Node 20+） |
| node:errors | shu:errors | ✅ 已实现 | SystemError、codes（ERR_* 与常见系统错误码）与 node:errors 对齐 |
| node:corepack | shu:corepack | ✅ 已实现 | enable/disable/run 为 no-op，require 不报错 |
| node:http2 | shu:server/http2 | ✅ 已覆盖 | HTTP/2 createServer/connect；若 shu 有 http2 则覆盖 |
| node:repl | shu:repl | ✅ 已实现 | start()、REPLServer（readline + vm.runInContext） |
| node:wasi | shu:wasi | ✅ 已实现 | WASI 类、getImportObject()；start() 暂抛 not implemented（待 WASM 运行时） |
| node:sqlite | shu:sqlite | ⚠ 点位占位 | DatabaseSync/Database、constants、backup、Statement；exec/prepare/run/all/get 等调用抛 not implemented；实现时需考虑 Bun sqlite API 兼容 |

**仍需实现的兼容（按优先级）：**

- **建议补（生态常见）**：**node:fs/promises** 与 **crypto.subtle** 已实现（见上表）。

- **可选补（按需）**  
  - **node:repl**：✅ 已实现（shu:repl，start、REPLServer，readline + vm）。  
  - **node:wasi**：✅ 已实现（shu:wasi，WASI 类、getImportObject；start 待 WASM 运行时）。  
  - **node:errors**：✅ 已实现（shu:errors，SystemError、codes）。  
  - **MessageChannel / MessagePort**：✅ 已占位（new MessageChannel() 返回 port1/port2，postMessage 抛 not implemented）。

- **可选占位即可**  
  - **node:corepack**：✅ 已实现（shu:corepack，enable/disable/run no-op）。  
  - **node:sqlite**：✅ 已点位占位（shu:sqlite 导出 DatabaseSync、Database、constants、backup、Statement；实例 exec/prepare/close/open/run/query，prepare 返回 run/all/get；执行抛 not implemented）。**后续实现时**：需对照 **Bun 的 sqlite API** 做兼容设计。  
  - **reportError**：✅ 已实现（委托 console.error）。  
  - **BroadcastChannel**：✅ 已占位（new 抛 not implemented）。  
  - **StructuredClone**：按引擎/JSC 支持情况确认。

---

## 2. Node.* 命名空间与类

Node 主要暴露的是 **node:xxx** 模块与 **全局**，没有单独的 `Node.xxx` 命名空间（与 Deno/Bun 不同）。以下为 Node 常见“类”与 shu 对应关系：

| Node 类/构造器 | 来源 | shu 对应 | 说明 |
|----------------|------|----------|------|
| Buffer | node:buffer / 全局 | shu:buffer + 全局 Buffer | ✅ |
| process | node:process / 全局 | shu:process + 全局 process | ✅ |
| console | node:console / 全局 | shu:console + 全局 console | ✅ |
| EventEmitter | node:events | shu:events | ✅ |
| Stream (Readable/Writable 等) | node:stream | shu:stream | ✅ |
| Server / Socket | node:net、node:http | shu:net、shu:http | ✅ |
| URL / URLSearchParams | node:url / 全局 | shu:url + 全局 URL | ✅ |

无额外 `Node.*` 命名空间需单独兼容。

---

## 3. 全局对象与方法

| 全局 | Node 行为 | shu 覆盖 | 说明 |
|------|------------|----------|------|
| global / globalThis | 全局对象 | ✅ | 引擎提供 |
| process | 进程信息与控制 | ✅ | shu:process 注册 |
| Buffer | 二进制缓冲 | ✅ | shu:buffer 注册 |
| console | 控制台输出 | ✅ | shu:console 注册 |
| setTimeout / setInterval / setImmediate / clearTimeout / clearInterval | 定时器 | ✅ | shu:timers 注册 |
| queueMicrotask | 微任务 | ✅ | shu:timers 注册 |
| require | CJS 加载 | ✅ | 引擎/require 模块 |
| module / exports | CJS 模块对象 | ✅ | 引擎在 CJS 上下文中注入 |
| __dirname / __filename | 当前模块目录/路径 | ✅ | 引擎/bindings 注入 |
| URL / URLSearchParams | 标准 URL API | ✅ | shu:url + 可能全局 |
| fetch | 网络请求 | ✅ | shu:fetch 注册 |
| WebSocket | 客户端 WebSocket | ✅ | shu:websocket_client 注册 |
| AbortController / AbortSignal | 中止控制 | ✅ | shu:abort 注册 |
| TextEncoder / TextDecoder | 编码 | ✅ | shu:text_encoding 注册 |
| atob / btoa | Base64 | ✅ | shu:encoding 注册 |
| performance | 高精度时间 | ✅ | shu:performance 注册 |
| crypto (globalThis.crypto) | Web Crypto | ✅ | shu:crypto 注册 |
| MessageChannel / MessagePort | 信道 | ✅ 已占位 | new MessageChannel() 返回 port1/port2，postMessage 抛 not implemented |
| reportError | 全局报告错误 | ✅ 已实现 | 委托 console.error(err) |
| BroadcastChannel | 广播信道 | ⚠ 已占位 | new BroadcastChannel 抛 not implemented |
| StructuredClone | 结构化克隆 | ⚠ | 引擎/标准；JSC 支持情况需确认 |

**缺口：**

- **StructuredClone**：若 JSC 未提供 globalThis.structuredClone，可按需占位或委托。

---

## 4. 小结与实施优先级

- **已覆盖**：绝大部分 node: 内置、全局 process/Buffer/console/timers/require/__dirname/__filename/fetch/WebSocket/crypto/URL 等，**已可运行多数 Node 项目**。
- **已放弃、不写兼容**：node:punycode、node:domain、node:v8（见 §0）；仅占位，不实现行为。
- **仍需实现的兼容**：见 §1 缺口表与「仍需实现的兼容」列表；**node:fs/promises** 与 **crypto.subtle** 已补完，其余按需补或占位。

当前 **node:xxx → shu:xxx** 映射见 `builtin.zig`；本文档与之一致，并补充全局与缺口清单供测试与产品化使用。
