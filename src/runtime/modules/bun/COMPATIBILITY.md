# Bun 兼容性分析（Bun.* / bun:xxx / 全局）

目标：与 Bun 运行时**无缝兼容**，使 Bun 风格脚本（`Bun.*`、`bun:xxx`、Shell `$` 等）可在 shu 上运行。本文档分析 **Bun 全局命名空间 Bun.xxx**、**bun: 内置说明符**、**全局对象与方法** 与当前 **shu:xxx** 的覆盖情况，并列出缺口。

**说明**：Bun 完整文档见 [bun.sh/docs](https://bun.sh/docs)、[bun.com/docs/runtime/bun-apis](https://bun.com/docs/runtime/bun-apis.md)；全局列表见 [bun.sh/docs/api/globals](https://bun.sh/docs/api/globals)。下表覆盖主要 Bun.* 与 bun:；CLI（bun install、bun run 等）与构建器能力不在此列。

---

## 1. Bun.* 命名空间 API ↔ shu 覆盖表

Bun 将大部分能力放在 **Bun** 全局对象下；内置说明符 **bun:xxx** 仅用于少数原生模块（ffi、sqlite、test、jsc）。下表按 builtin.zig 分类列出 Bun.* 与 shu 的对应关系。

### 1.1 HTTP 与网络

| Bun API | 说明 | shu 覆盖 | 对应实现/缺口 |
|---------|------|----------|----------------|
| Bun.serve(options) | HTTP/WebSocket 服务 | ✅ | engine/bun/mod.zig → Shu.server（shu:server） |
| Bun.listen(options) | TCP 监听 | ✅ | shu:net createServer + listen |
| Bun.connect(options) | TCP 连接 | ✅ | shu:net connect |
| Bun.udpSocket(options?) | UDP Socket | ✅ | shu:dgram |
| WebSocket (client) | 客户端 WebSocket | ✅ | shu:websocket_client |
| WebSocket (server) | 在 Bun.serve fetch 中 upgrade | ✅ | shu:server WebSocket |

### 1.2 文件 I/O

| Bun API | 说明 | shu 覆盖 | 对应实现/缺口 |
|---------|------|----------|----------------|
| Bun.file(path) | 返回带 .text()/.json()/.arrayBuffer() 等句柄 | ✅ | engine/bun/mod.zig → Shu.fs.readSync |
| Bun.write(dest, content) | 同步写文件/Response/Blob 等 | ✅ | engine/bun/mod.zig → Shu.fs.writeSync |
| Bun.stdin / Bun.stdout / Bun.stderr | 标准流 | ⚠ | 可封装 shu 层 stdio 或占位 |

### 1.3 子进程与 Shell

| Bun API | 说明 | shu 覆盖 | 对应实现/缺口 |
|---------|------|----------|----------------|
| Bun.spawn(options) | 异步 spawn | ✅ | shu:cmd spawn |
| Bun.spawnSync(options) | 同步 spawn | ✅ | shu:cmd spawnSync |
| $ \`cmd\` / $.shell() | Shell 模板与执行 | ⚠ | 需在 shu 层封装 cmd 或单独实现 $ |

### 1.4 打包与转译

| Bun API | 说明 | shu 覆盖 | 对应实现/缺口 |
|---------|------|----------|----------------|
| Bun.build(options) | 打包/打包为 bundle | ❌ | 构建时能力；shu build 可另实现 |
| Bun.Transpiler | TS/JSX 转译 | ⚠ | strip 等可部分覆盖；完整 Transpiler 可选 |

### 1.5 哈希、密码与压缩

| Bun API | 说明 | shu 覆盖 | 对应实现/缺口 |
|---------|------|----------|----------------|
| Bun.hash(input, algorithm?) | 哈希 | ✅ | shu:crypto hash / createHash |
| Bun.password.hash/verify | 密码哈希 (bcrypt/argon2) | ⚠ | 需 shu:crypto 扩展或占位 |
| Bun.CryptoHasher / Bun.sha | 流式哈希 / sha256 等 | ✅ | shu:crypto |
| Bun.gzipSync / Bun.gunzipSync | gzip 压缩/解压 | ✅ | shu:zlib |
| Bun.deflateSync / Bun.inflateSync | deflate | ✅ | shu:zlib |
| Bun.zstd* | Zstd | ⚠ | 若 shu:zlib 支持则覆盖；否则占位 |

### 1.6 DNS、SQL、Redis

| Bun API | 说明 | shu 覆盖 | 对应实现/缺口 |
|---------|------|----------|----------------|
| Bun.dns.lookup / prefetch / getCacheStats | DNS 解析与缓存 | ✅ | shu:dns resolve*；prefetch/cacheStats 可扩展或占位 |
| Bun.SQL / Bun.sql | PostgreSQL/MySQL/SQLite 驱动 | ❌ | 无对应；可占位或后续实现 |
| Bun.RedisClient / Bun.redis | Redis 客户端 | ❌ | 无对应；可占位 |

### 1.7 测试、Worker、插件

| Bun API | 说明 | shu 覆盖 | 对应实现/缺口 |
|---------|------|----------|----------------|
| describe / test / it / expect | 测试框架 | ✅ | shu:test（describe/it/expect、mock、it.each 等） |
| new Worker(url) | 工作线程 | ✅ | shu:threads Worker |
| Bun.plugin(plugin) | 插件注册 | ❌ | 构建/加载时能力；可占位 |

### 1.8 工具与系统

| Bun API | 说明 | shu 覆盖 | 对应实现/缺口 |
|---------|------|----------|----------------|
| Bun.version / Bun.revision | 版本信息 | ⚠ | 可暴露 shu 版本 |
| Bun.env | 环境变量 | ✅ | process.env → shu:process |
| Bun.main | 主入口路径 | ⚠ | 可对应 process 或入口 URL |
| Bun.sleep(ms) / Bun.sleepSync(ms) | 睡眠 | ⚠ | 可用 timers/sync 睡眠封装或占位 |
| Bun.nanoseconds() | 高精度时间 | ✅ | shu:perf_hooks / performance.now 可组合 |
| Bun.which(bin) | 查找可执行文件 | ⚠ | 需 shu 层实现或占位 |
| Bun.fileURLToPath / Bun.pathToFileURL | URL↔路径 | ✅ | shu:path 或 url.pathToFileURL 等 |

### 1.9 Cookie、Glob、路由

| Bun API | 说明 | shu 覆盖 | 对应实现/缺口 |
|---------|------|----------|----------------|
| Bun.Cookie / Bun.CookieMap | Cookie 解析与管理 | ⚠ | 可基于 shu:server 请求头解析实现或占位 |
| Bun.Glob | 文件 glob | ⚠ | 需 shu 层或 fs 扩展 |
| Bun.FileSystemRouter | 文件系统路由 | ❌ | 可选实现 |

### 1.10 流、内存、解析

| Bun API | 说明 | shu 覆盖 | 对应实现/缺口 |
|---------|------|----------|----------------|
| Bun.readableStreamTo* (Bytes/Blob/FormData/JSON/Array) | ReadableStream 转换 | ⚠ | 可基于 fetch/stream 实现或占位 |
| Bun.ArrayBufferSink / Bun.allocUnsafe / Bun.concatArrayBuffers | 缓冲与内存 | ⚠ | Buffer/ArrayBuffer 可部分覆盖；Sink 可占位 |
| Bun.resolveSync(specifier, from?) | 模块解析 | ⚠ | 与 require/loader 配合可部分实现 |
| Bun.semver / Bun.TOML.parse / Bun.markdown / Bun.color | 解析与格式化 | ❌ | 可选或占位 |
| Bun.peek / Bun.deepEquals / Bun.deepMatch / Bun.inspect | 比较与调试 | ⚠ | 部分可用 util 或占位 |
| Bun.escapeHTML / Bun.stringWidth / Bun.indexOfLine | 字符串工具 | ⚠ | 可占位或小实现 |
| Bun.randomUUIDv7 | UUID v7 | ⚠ | crypto.randomUUID 可替代或扩展 |
| Bun.mmap / Bun.gc / Bun.generateHeapSnapshot | 底层/调试 | ❌ | 可选或占位 |
| HTMLRewriter | HTML 流式重写 | ❌ | 可选 |

### 1.11 Bun.* 补充（来自官方文档，未在上表逐条列出）

| Bun API / 能力 | 说明 | shu 覆盖建议 |
|----------------|------|--------------|
| Bun.Archive | tar 归档创建/解压 | ⚠ 可对应 shu:archive/tar 或占位 |
| Bun.S3 / S3 客户端 | S3 兼容对象存储 | ❌ 可占位 |
| Bun.Secrets | 运行时密钥存储 | ❌ 可占位 |
| Bun C 编译器 | 从 JS 编译/运行 C | ❌ 可占位 |
| Bun.write 追加 / Bun.file 流式读 | 写追加、流式读文件 | ⚠ 若 shu:fs 支持则覆盖 |
| import.meta.dir / .file / .path | 当前模块目录/文件名/路径 | ⚠ 引擎或 shu:module 可提供 |
| BuildMessage / ResolveMessage | 构建/解析消息（内部） | 可选占位 |

---

## 2. bun: 内置说明符 ↔ shu 覆盖表

| bun: 说明符 | 说明 | shu 覆盖 | 对应实现/缺口 |
|-------------|------|----------|----------------|
| bun:ffi | 外部函数接口，调用 C/C++ 动态库 | ❌ | 无对应；可占位 |
| bun:sqlite | SQLite 绑定 | ❌ | 无对应；可占位 |
| bun:test | 内置测试 describe/test/expect | ✅ | 使用 shu:test，bun:test 可映射到 shu:test |
| bun:jsc | JSC 底层 API | ❌ | 内部用；可不暴露或占位 |

当前 **BUN_BUILTIN_NAMES** 为空，**getBunBuiltin** 返回 undefined；若需 `import x from "bun:test"`，可在解析层将 bun:test 映射到 shu:test 并实现 getBunBuiltin("bun:test", …)。

---

## 3. 全局对象与方法（Bun 环境）

Bun 继承 Node 与 Web 全局，并增加 **Bun**、**$**（Shell）等。

| 全局 | Bun 行为 | shu 覆盖 | 说明 |
|------|----------|----------|------|
| Bun | 命名空间对象 | ✅ 部分 | engine/bun 已实现 file/write/serve；其余见 §1 |
| $ | Shell 模板与执行 | ⚠ | 需实现 $ \`cmd\` 与 $.shell() |
| fetch / Request / Response | 标准 | ✅ | shu:fetch |
| console | 标准 | ✅ | shu:console |
| process | Node 兼容 | ✅ | shu:process |
| Buffer | Node 兼容 | ✅ | shu:buffer |
| require / module / __dirname / __filename | Node 兼容 | ✅ | 引擎 + shu:module |
| setTimeout / setInterval / queueMicrotask | 标准 | ✅ | shu:timers |
| URL / URLSearchParams | 标准 | ✅ | shu:url |
| TextEncoder / TextDecoder | 标准 | ✅ | shu:encoding |
| crypto / performance / AbortController | 标准 | ✅ | shu:crypto、shu:perf_hooks、shu:abort |
| WebSocket | 标准 | ✅ | shu:websocket_client |
| describe / it / test / expect | 测试 | ✅ | shu:test |
| alert / confirm / prompt | Web（CLI 场景） | ⚠ | 可占位或委托 readline |
| BuildMessage / ResolveMessage | Bun 内部 | ⚠ | 可选占位 |
| reportError | Web 标准 | ⚠ | 可占位或委托 console |
| ShadowRealm | 标准提案 | ⚠ | 引擎支持则已有 |
| DOMException / SubtleCrypto | Web | ✅ | 与 crypto/异常对齐 |
| ReadableStream / WritableStream / TransformStream 等 | Web Streams | ✅ | shu:webstreams / 标准 |

**缺口：** 全局 **$**、部分 **Bun.***（见 §1 中 ❌/⚠ 项）。

---

## 4. 小结与实施优先级

- **已可由 shu 覆盖的 Bun 能力**：Bun.serve、Bun.file、Bun.write、Bun.spawn/Bun.spawnSync、Bun.listen/Bun.connect、Bun.udpSocket、Bun.hash/Bun.sha、Bun.gzipSync/Bun.gunzipSync 等、Bun.dns、Bun.env、Bun.fileURLToPath/Bun.pathToFileURL、describe/it/expect、Worker、fetch、WebSocket、process、Buffer、require。
- **优先实现**：  
  1. 保持 **Bun.serve / Bun.file / Bun.write** 与 engine/bun 的现有实现。  
  2. 补 **Bun.version / Bun.revision / Bun.main**、**Bun.sleep/Bun.sleepSync**（可选）、**Bun.which**（可选）。  
  3. 若需 Shell 兼容：实现 **$** 与 **$.shell()**（委托 shu:cmd）。  
  4. **bun:test**：在 getBunBuiltin 中映射到 shu:test 的 exports。
- **可选/后续**：Bun.build、Bun.SQL/Bun.redis、Bun.plugin、Bun.Glob、Bun.Cookie、Bun.password、Bun.Transpiler、readableStreamTo*、Bun.ArrayBufferSink、bun:ffi、bun:sqlite。

本文档与 `modules/bun/builtin.zig`、`engine/bun/mod.zig`、`compat/bun/mod.zig` 一致，供 Bun 兼容层开发与测试使用。
