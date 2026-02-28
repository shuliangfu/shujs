# Shu.server 完整参考

本文档合并原 `SHU_SERVER_*` 系列文档，作为 **Shu.server** 的单一参考：概念说明、可配置项、与 Deno/Bun 对比、能力与优化清单、压缩方案、吞吐量分析及常量一览。重复内容已去重。

---

## 一、概念与 API

### 1.1 非阻塞 API 与 stop / reload / restart

- **Shu.server(options)** 为**非阻塞**：调用后立即返回一个 **server 对象**，不占住主线程；接受连接与处理请求由事件循环（setImmediate）驱动。
- 返回对象提供三个方法：
  - **stop()**：请求停止监听，下一轮 tick 关闭 server 并释放资源。
  - **reload(newOptions)**：热重载：用 `newOptions` 更新 handler、config、compression、onError、runLoop、webSocket 等，**不关闭 listener**。
  - **restart()** / **restart(newOptions?)**：下一轮 tick 关闭当前 listen，再用原地址或 `newOptions` 中的地址重新 listen。

```js
const server = Shu.server({ port: 3000, fetch: (req) => new Response("ok") });
server.stop();
server.reload({ fetch: newHandler });
server.restart();
server.restart({ port: 3001, fetch: other });
```

### 1.2 idleTimeout / keepAlive

- **Keep-Alive**：HTTP/1.1 下同一条 TCP 连接可连续处理多个请求；响应头带 `Connection: keep-alive` 和 `Keep-Alive: timeout=N`。
- **options.keepAliveTimeout**（秒，默认 5）控制响应头里的 `Keep-Alive: timeout=N`；设为 **0** 时不写 timeout。服务端尚未按「空闲 N 秒主动断连接」实现，连接会一直保留直到客户端关或出错。

### 1.3 signal 关服（AbortSignal）

- 支持 **options.signal**（AbortSignal）：传入 `AbortController.signal`，当 `abort()` 被调用时，tick 每轮检查 `signal.aborted`，为 true 则停止接受新连接、关闭 server。亦可使用返回的 `server.stop()`。

### 1.4 onError 回调

- **options.onError(err)**：当 handler 抛错或返回非 Response 时调用；若 onError 返回合法 Response 则用其回写，否则回 500。可用于打日志、监控或返回自定义错误页；开发时带堆栈的错误页在 onError 里根据环境返回即可，无需单独 development 选项。

### 1.5 Unix socket

- **options.unix**（字符串路径）：设置后监听该 Unix socket，不再使用 host+port；适合本机 Nginx 反向代理（如 `proxy_pass http://unix:/tmp/app.sock`）。

---

## 二、可配置项（options）


| 选项                           | 类型                                         | 默认/说明                                                                                                                              |
| ---------------------------- | ------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| **port**                     | number                                     | TCP 时必填，1–65535；配 unix 时可省略                                                                                                        |
| **host**                     | string                                     | 可选，默认 `"0.0.0.0"`（仅 TCP 时生效）                                                                                                       |
| **unix**                     | string                                     | 可选，Unix socket 路径；与 host+port 二选一                                                                                                  |
| **handler** / **fetch**      | function                                   | 必填其一，请求处理。返回的 Response 支持 **body**（字符串）或 **filePath**（文件路径，零拷贝 sendfile，不压缩）。                                                      |
| **maxRequestBodySize**       | number                                     | 可选，字节，默认 1MB，不设最高限制；超则 413                                                                                                         |
| **compression**              | boolean                                    | 可选，**默认 true**；按 Accept-Encoding 做 br/gzip/deflate（优先级 br > gzip > deflate），无需用户配置即启用；设 **false** 可关闭。                                                                    |
| **runLoopEveryRequests**     | number                                     | 可选，每 N 个请求跑一次 runLoop，默认 1                                                                                                         |
| **runLoopIntervalMs**        | number                                     | 可选，每 N 毫秒跑一次 runLoop，0 表示不按时间                                                                                                      |
| **reusePort**                | boolean                                    | 可选，API 兼容；listen 已固定 reuse_address（Linux 下含 SO_REUSEPORT）。多进程同端口有两种方式：**手动**起多个进程绑定同 port，或 **options.workers** 内置 cluster 自动 fork |
| **tls**                      | { cert, key }                              | 可选，HTTPS 证书与私钥文件路径                                                                                                                 |
| **onListen**                 | function                                   | 可选，listen 成功后回调                                                                                                                    |
| **onError**                  | function                                   | 可选，handler 抛错或无效返回时调用，可返回自定义 Response                                                                                              |
| **webSocket**                | { onOpen?, onMessage, onClose?, onError?, **maxWritePerTick**?, **readBufferSize**?, **maxPayloadSize**?, **frameBufferSize**? } | 可选，同端口 WebSocket；maxWritePerTick 默认 128KB；readBufferSize 读缓冲默认 128KB；maxPayloadSize ws.send 单次 payload 上限默认 64KB；frameBufferSize handoff 路径帧缓冲默认 64KB |
| **readBufferSize**           | number                                     | 可选，字节，默认 64KB；HTTP 连接读缓冲大小（4KB～256KB）                                                                                               |
| **writeBufInitialCapacity**  | number                                     | 可选，字节，默认 4096；连接 write_buf 初始容量                                                                                                        |
| **headerListInitialCapacity**| number                                     | 可选，字节，默认 4096；连接 header_list 初始容量                                                                                                       |
| **maxAcceptPerTick**         | number                                     | 可选，默认 8；每 tick 最多 accept 的新连接数                                                                                                  |
| **signal**                   | AbortSignal                                | 可选，优雅关机                                                                                                                            |
| **keepAliveTimeout**         | number                                     | 可选，秒，默认 5；写 Keep-Alive: timeout=N，0 不写 timeout                                                                                     |
| **chunkedResponseThreshold** | number                                     | 可选，字节，默认 64KB；响应 body 超过此值才用 chunked                                                                                               |
| **chunkedWriteChunkSize**    | number                                     | 可选，字节，默认 32KB；chunked 每块写出大小                                                                                                       |
| **maxRequestLineLength**     | number                                     | 可选，字节，默认 8192；请求行/单行头长度上限，超则 400                                                                                                   |
| **minBodyToCompress**        | number                                     | 可选，字节，默认 256；仅当 body 超过此值才尝试压缩                                                                                                     |
| **listenBacklog**            | number                                     | 可选，默认 128；listen() 的 kernel backlog                                                                                                |
| **workers**                  | number                                     | 可选，默认 1；>1 时启用内置 cluster：主进程 fork 若干 worker，各 worker 同端口 listen（需 **--allow-exec**）；worker 通过 env SHU_CLUSTER_WORKER 识别            |
| **maxConnections**           | number                                     | 可选，默认 512；明文多路复用**每进程**最大并发连接数（1～5120）；workers>1 时每进程独立受此上限；事件数组堆分配。**reload 不生效**，修改需 **restart**（见下方说明）。                                                                             |
| **maxCompletions**           | number                                     | 可选，默认 256；单次 pollCompletions 最多返回的完成项数量（64～5120）。**reload 不生效**，修改需 **restart**（见下方说明）。                                                                             |


**reload 与 restart 生效范围**：除 **maxConnections**、**maxCompletions** 外，其余上述选项在 **reload(newOptions)** 时都会生效，不关 listener、不断开已有连接。
**maxConnections** 与 **maxCompletions** 在 listen 时用于创建 io_core（预分配连接槽位与完成队列），reload 不会重建 io_core——若重建会断开当前所有明文连接，故这两项仅在 **restart()** 后生效。

HTTP 连接读缓冲、write_buf/header_list 初始容量及 WebSocket 读缓冲、maxPayload、frame_buf 均可通过上述 options 配置；响应 body 复用 256KB 仍为固定值。

### 2.2 参数与可配置性（写死 vs ServerConfig）

以下为服务端与 WebSocket 相关参数的**写死固定**与**可配置**对照；可配置项均通过 **options** 传入、存入 **ServerConfig**（或 state）。**reload** 时除 maxConnections、maxCompletions 外均会更新；该两项需 **restart** 生效（见上「reload 与 restart 生效范围」）。

| 参数 | 默认/固定值 | 可配置 | 说明 |
|------|-------------|--------|------|
| **Server** | | | |
| 每 tick 最多 accept 数 | 8 | ✅ **maxAcceptPerTick** | 控制单轮 accept 上限，避免 burst 占满；reload 生效 |
| 每进程最大连接数 | 512（1～5120） | ✅ **maxConnections** | 仅 restart 生效 |
| pollCompletions 单次上限 | 256（64～5120） | ✅ **maxCompletions** | 仅 restart 生效 |
| listen backlog | 128 | ✅ **listenBacklog** | 已支持 |
| keepAliveTimeout | 5 秒 | ✅ **keepAliveTimeout** | 已支持 |
| chunked 阈值/块大小 | 64KB / 32KB | ✅ **chunkedResponseThreshold** / **chunkedWriteChunkSize** | 已支持 |
| maxRequestBodySize | 1MB | ✅ **maxRequestBodySize** | 已支持 |
| maxRequestLineLength | 8192 | ✅ **maxRequestLineLength** | 已支持 |
| minBodyToCompress | 256 | ✅ **minBodyToCompress** | 已支持 |
| **WebSocket** | | | |
| 每 tick 每连接最大写出 | 128KB | ✅ **webSocket.maxWritePerTick** | 写队列分段写出，防单连接占满 tick |
| 读缓冲大小（单连接） | 128KB | ✅ **webSocket.readBufferSize** | 按 config 堆分配，范围 4KB～256KB |
| ws.send 单次 payload 上限 | 64KB | ✅ **webSocket.maxPayloadSize** | wsSendCallback 内按 config 校验 |
| handoff 路径 frame_buf | 64KB | ✅ **webSocket.frameBufferSize** | runFrameLoop 按 config 分配 |
| **Server/HTTP** | | | |
| HTTP 连接 read_buf | 64KB | ✅ **readBufferSize** | PlainConnState / TlsConnState，4KB～256KB |
| write_buf / header_list 初始容量 | 4096 | ✅ **writeBufInitialCapacity** / **headerListInitialCapacity** | initCapacity |
| **其它固定** | | | |
| TLS IOCP raw_recv_buf / raw_send_buf | 16KB | ❌ 固定 | TlsPendingEntry |

---

## 三、与 Deno / Bun 对照


| 能力                      | Deno.serve  | Bun.serve     | Shu.server                                 |
| ----------------------- | ----------- | ------------- | ------------------------------------------ |
| port / host(name)       | ✅           | ✅             | ✅                                          |
| handler / fetch         | ✅ handler   | ✅ fetch       | ✅ handler / fetch                          |
| onListen                | ✅           | ❌             | ✅                                          |
| signal（AbortController） | ✅           | ❌             | ✅ options.signal；亦可 server.stop()          |
| server 实例 stop/reload   | ❌           | ✅             | ✅ stop、reload、restart                      |
| maxRequestBodySize      | ❌           | ✅             | ✅                                          |
| idleTimeout / keepAlive | ❌           | ✅ idleTimeout | ✅ keepAliveTimeout                         |
| reusePort               | ❌           | ✅             | ✅ reuse_address                            |
| TLS (cert/key)          | ✅           | ✅             | ✅                                          |
| WebSocket               | 需手写 Upgrade | ✅ websocket   | ✅ webSocket                                |
| compression（br/gzip/deflate） | ✅ br/gzip（自动） | ❌             | ✅ 默认开启，br/gzip/deflate；可设 compression: false 关闭 |
| runLoop 节流              | ❌           | ❌             | ✅ runLoopEveryRequests / runLoopIntervalMs |
| error 回调                | ❌           | ✅ error       | ✅ onError                                  |
| Unix socket             | ✅ path      | ✅ unix        | ✅ unix                                     |


说明：Deno 与 Shu 均默认响应压缩（按 Accept-Encoding 与可压缩类型）；Shu 另支持 deflate，且可用 `compression: false` 关闭。

---

## 四、能力与优化清单

### 4.1 目标与约束

- **吞吐量**：少分配、keep-alive、runLoop 节流、可选 reusePort 多进程。
- **HTTP/1.1**：keep-alive、chunked、正确 Connection/Content-Length。
- **HTTP/2**：TLS ALPN 或 h2c，与 handler 对接。
- **HTTPS**：options.tls { cert, key }。
- **压缩**：Accept-Encoding 做 br/gzip/deflate。
- **WebSocket**：同端口识别 Upgrade，握手后走 WS 帧协议。

**约束**：Shu.server 为主 API；实现以 Zig 为主，JS 侧保持同步 handler。

### 4.2 已实现能力（统一清单）


| 类别                   | 项                                         | 说明                                                                                                                                                                                                                               |
| -------------------- | ----------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **API**              | 非阻塞 + stop/reload/restart                 | 立即返回 server 对象，setImmediate 驱动 tick；每轮最多 accept 8 个连接                                                                                                                                                                            |
| **连接**               | keep-alive                                | 同连接多请求，按 Connection: close 决定关闭；响应头 Keep-Alive: timeout=…                                                                                                                                                                        |
| **分配**               | 减分配 + 复用 buffer                           | 每请求 ArenaAllocator；Response 读出优先用连接内 buffer（Content-Type 1KB、body 256KB）                                                                                                                                                         |
| **Request/Response** | 精简构造                                      | Request headers 用 JSON 一次 parse；Response 只读 status/body/Content-Type                                                                                                                                                             |
| **runLoop**          | 节流                                        | runLoopEveryRequests、runLoopIntervalMs                                                                                                                                                                                           |
| **HTTP/1.1**         | chunked 请求/响应、Connection/CL               | 解析 Transfer-Encoding: chunked；body > 64KB 时 chunked 响应                                                                                                                                                                           |
| **压缩**               | br / gzip / deflate                       | 默认开启（options.compression 默认 true）；优先级 br > gzip > deflate；minBodyToCompress=256，压缩后更短才用；设 compression: false 可关闭                                                                                                                                                        |
| **TLS**              | HTTPS                                     | options.tls: { cert, key }；onListen 含 protocol: 'https'                                                                                                                                                                          |
| **WebSocket**        | 同端口、全非阻塞、写队列+限写                     | Upgrade 识别、握手 101、帧解析/组帧；options.webSocket: { onOpen, onMessage, onClose, onError }；与 HTTP 同多路复用，明文/TLS 均单次 read/write + WouldBlock 处理；send 入队 write_buf，每 tick 每连接最多写 128KB，读缓冲 128KB，可大并发大吞吐。                                                                                                                              |
| **HTTP/2**           | h2 / h2c                                  | TLS ALPN h2；明文 prior knowledge + Upgrade: h2c；HPACK 含 Huffman 解码；响应头 Huffman 编码已实现                                                                                                                                               |
| **I/O 多路复用**         | 明文无 TLS / 有 TLS 时均多路复用                    | **无 TLS**：非 Windows 用 epoll/kqueue/poll；**Windows 默认全 IOCP**（accept + 连接 recv/send 均走完成端口，见 4.6）。**有 TLS**：非 Windows 为 poll + 非阻塞 TLS；**Windows 为全 IOCP**（HTTPS、WSS、h2、chunked 均走完成端口，BIO 模式握手与读写由 WSARecv/WSASend 驱动）。每进程内多连接并发；**WS/WSS、h2c、h2、chunked 请求体均不 handoff**，与 HTTP 同 tick 非阻塞。 |
| **极致优化**             | TCP_NODELAY、8KB 行上限、writev、header 复用、零拷贝等 | 见 4.3                                                                                                                                                                                                                            |


### 4.3 已落地的极致优化


| 项                               | 说明                                                                                                                                                                                                                                                                            | 效果                                             |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------- |
| **I/O 多路复用（epoll/kqueue/poll / Windows IOCP）** | **无 TLS**：非 Windows 时 accept 后 setNonBlocking，Linux 用 epoll、macOS·BSD 用 kqueue、其他 POSIX 用 poll；**Windows 默认全 IOCP**（accept + 连接 recv/send 均走完成端口，不 poll）。**有 TLS**：非 Windows 为 poll + 非阻塞 TLS；**Windows 为全 IOCP**（HTTPS、WSS、h2、chunked 均走完成端口，BIO 模式）。每进程连接上限由 options.maxConnections 配置（默认 512）；**WS/WSS、h2c、h2（TLS）、chunked 请求体均不 handoff**。workers>1 时多进程同端口。 | 每进程内多连接并发，可多进程扩多核；WS/WSS、H2、chunked 与 HTTP 同事件循环 |
| TCP_NODELAY                     | accept 后对 TCP stream 设 TCP_NODELAY（POSIX）                                                                                                                                                                                                                                     | 降低首包与小响应延迟                                     |
| 请求行/头行长度上限                      | 超过 8KB 即 400                                                                                                                                                                                                                                                                  | 安全与资源边界                                        |
| chunked 写块 32K                  | writeChunkedBody 块大小                                                                                                                                                                                                                                                          | 减少 write 次数                                    |
| runLoopIntervalMs               | 按时间间隔跑 runLoop                                                                                                                                                                                                                                                                | 长连接上也能定期跑事件循环                                  |
| 每轮多 accept                      | 每轮最多 accept 8 个连接（多路复用路径同理）                                                                                                                                                                                                                                                   | 更快消化 listen 队列                                 |
| deflate 支持                      | Accept-Encoding deflate，raw deflate                                                                                                                                                                                                                                           | 多一种压缩选项                                        |
| HTTP/2 响应头 Huffman 编码           | 字面量值经 HPACK Huffman 编码，更短时使用                                                                                                                                                                                                                                                  | 减 H2 带宽                                        |
| writev 合并写                      | 非 chunked 且 POSIX 下一次写「响应头+body」                                                                                                                                                                                                                                              | 减少 syscall                                     |
| 连接级响应头 buffer 复用                | keep-alive 上复用 header_list                                                                                                                                                                                                                                                    | 少分配、少 GC 压力                                    |
| 请求头解析零拷贝                        | headers_head + getHeader，不建 HashMap；makeRequestObject 逐行拼 JSON                                                                                                                                                                                                                | 少建表、少拷贝                                        |


**关于「转交」**：

- **chunked 请求体**：已改为**非阻塞多路复用**。检测到 `Transfer-Encoding: chunked` 后不 handoff，进入 phase `reading_chunked_body`，每 tick 非阻塞读入、用 `parseChunkedIncremental` 增量解析，body 收齐后切 `responding`，与 Content-Length 路径一致。
- **h2c / h2**：已改为**非阻塞多路复用**。明文 prior knowledge 或 TLS 首包 24 字节 CLIENT_PREFACE 识别为 HTTP/2 后，不 handoff，走 h2_send_preface → h2_frames。
当前仅 **Upgrade: h2c**（非 prior knowledge 的 HTTP/1.1 升级）仍会转交 `handleConnectionPlain`；其余均在多路复用内非阻塞。

### 4.4 本轮已完成的优化（已落地）


| 项                         | 说明                                                                                                                                                                                                                    | 状态      |
| ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- |
| **epoll/kqueue 替代 poll**  | 明文多路复用：Linux 使用 epoll，macOS·BSD 使用 kqueue，其他 POSIX 回退 poll；poller 创建/注册/注销/等待已实现，可扩展更多连接。                                                                                                                             | ✅ 已优化完成 |
| **多进程同端口（reusePort）基础**   | listen 已固定 reuse_address；Zig 在 Linux 下会同时设置 SO_REUSEPORT。多进程同端口有两种方式：**手动**—直接启动多个 Shu 进程绑定同一 host:port，由内核分发；**自动**—使用 options.workers + --allow-exec 内置 cluster，主进程自动 fork 多 worker 同端口。options.reusePort 为 API 兼容。 | ✅ 已优化完成 |
| **内置 cluster 模式**         | options.workers > 1 且 **--allow-exec** 时：主进程 fork 若干 worker（同命令行 + env SHU_CLUSTER_WORKER=i），各 worker 同端口 listen；主进程不 listen，仅维持事件循环，stop() 时向所有 worker 发 SIGTERM。                                                    | ✅ 已优化完成 |
| **worker 存活监控与自动重启**      | 主进程每轮 tick 用 kill(pid,0) 检测 worker 是否存活；若某 worker 已退出则按同 argv 与 SHU_CLUSTER_WORKER 自动重新 spawn 该槽位。                                                                                                                    | ✅ 已优化完成 |
| **单进程连接上限（向 Bun 靠拢）**     | options.maxConnections 可配置 1～2048（默认 512）；事件数组堆分配，与 Bun 量级对齐。                                                                                                                                                         | ✅ 已优化完成 |
| **SIMD 头块查找**             | 头块中查找 `\r\n\r\n` 使用 @Vector(4,u8) 比较、16 字节步进扫描，减少标量循环。                                                                                                                                                                | ✅ 已优化完成 |
| **零拷贝 body/文件（sendfile）** | 响应设置 **filePath** 时：POSIX 下用 sendfile() 从文件直送 socket，不经过用户态 body 缓冲；支持绝对/相对路径；非 POSIX 或非明文流时回退为分块 read+write。                                                                                                         | ✅ 已优化完成 |
| **Linux io_uring（就绪检测）**  | Linux 下固定用 io_uring 做就绪检测：每 tick 对 server + 所有 client fd 提交 poll_add，submit_and_wait(1) 取 CQE，与 epoll 路径共用 accept/step；读写仍为 read/write。**后续可选**：shu:fs 异步 read/write、连接 recv/send 改用 io_uring 提交与 CQE 完成（Zig 标准库支持），可进一步超越 Node。 | ✅ 已优化完成 |
| **Windows 非阻塞+多路复用**      | **无 TLS 时** Windows 默认**全 IOCP**（AcceptEx + WSARecv/WSASend，accept 与连接读写均走完成端口，每 tick 仅 drain GetQueuedCompletionStatus，不做 poll）；可 `-Duse_iocp=false` 回退为 poll。**有 TLS 时**（`use_iocp_full_tls`）**TLS 也全 IOCP**：BIO 模式握手与连接读写均由 WSARecv/WSASend 完成项驱动，不 poll（见 4.5）。                                                                                         | ✅ 明文与 TLS 全 IOCP 已落地 |
| **TLS 非阻塞握手**             | 有 TLS 时 accept 后 fd 设 non-blocking，握手中连接纳入 poll(server + 握手中 fd)，可读/可写时推进 SSL_accept，握手完成再进 tls_conns；主循环不阻塞，Windows 与 POSIX 统一。                                                                                      | ✅ 已优化完成 |
| **TLS 读写非阻塞**             | 握手完成后连接进入 tls_conns，与 tls_pending 共用同一 poll；SSL_read/SSL_write 返回 WANT_READ/WANT_WRITE 时由 poll 再驱动，读头/读 body/写响应全程非阻塞，与明文多路复用一致。                                                                                      | ✅ 已优化完成 |
| **HTTP/2 非阻塞多路复用**        | 明文 h2c（prior knowledge）与 TLS h2（ALPN）均不 handoff：检测到 24 字节 CLIENT_PREFACE 后写 SETTINGS、phase 切 h2_send_preface → h2_frames，每 tick 非阻塞 parseOneFrameFromBuffer + 写帧，与 HTTP/WS 同事件循环。                    | ✅ 已优化完成 |
| **chunked 请求体非阻塞**         | `Transfer-Encoding: chunked` 不再 handoff：phase 切 `reading_chunked_body`，每 tick 非阻塞读 + `parseChunkedIncremental` 增量解析，body 收齐后切 `responding`，明文与 TLS 路径一致。 | ✅ 已优化完成 |


### 4.5 可进一步推进的方向

**Windows TLS 全 IOCP**

- **目标**：HTTPS、WSS、h2、chunked over TLS 在 Windows 下全部走 IOCP（含握手与连接读写），与明文一致。
- **现状**：**已实现**。有 TLS 且 Windows + use_iocp 时（`use_iocp_full_tls`）：
  - **Accept**：AcceptEx 完成项 → 新连接用 **BIO 模式**（`tls.TlsPending.startBio`）创建握手中状态，socket 关联完成端口并立即 postRecv。
  - **握手中**：WSARecv 完成 → `feedRead` 喂入加密数据 → `stepBio`；若需发送则 `getSend` → postSend；握手完成则移入 `tls_conns` 并 postRecv。
  - **已握手连接**：WSARecv 完成 → `feedRead` → `stepTlsConn`（内部 `readAfterFeed`/`writeApp`）；需写则 `getSend` → postSend，否则 postRecv。WSASend 完成 → `stepTlsConn` → `getSend` → postSend 或 postRecv。
  - 每 tick 仅 drain GetQueuedCompletionStatus，**不再 poll** TLS 的 fd；与明文全 IOCP 一致。

### 4.6 向 Bun 性能靠拢（极致性能路线图）

目标：在 I/O 模型、零拷贝、SIMD、单进程并发上限、TLS/Windows 等维度向 Bun 的「高 QPS、低延迟」靠拢。


| 方向                  | 说明                                                                                                                                                            | 难度/收益 | 状态                              |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- | ------------------------------- |
| **单进程连接上限**         | 当前 128 → 可配置 512～2048（options.maxConnections），与 Bun 量级对齐；事件数组堆分配避免栈溢出。                                                                                        | 中/高   | 见 4.4 已落地                       |
| **SIMD 头解析**        | 用 SIMD 在头块中快速查找 `\r\n\r\n` 及头名比较，减少标量扫描。                                                                                                                      | 中/中   | 见 4.4 已落地                       |
| **Linux io_uring**  | Linux 下固定用 io_uring 做就绪检测（poll_add + submit_and_wait，读写仍为 read/write）。每 tick 对 server + 所有 client fd 提交 poll_add，一次 wait 取 CQE，与 epoll 路径共用同一 accept/step 逻辑。 | 高/高   | ✅ 已实现（poll 就绪路径）                |
| **零拷贝 body/文件**     | 响应 **filePath** 时使用 sendfile()（见 4.4 已落地）；body 路径已 writev 合并写。                                                                                                | —     | ✅ 已落地                           |
| **TLS/Windows 高并发** | Windows 下 HTTPS、WSS、h2、chunked over TLS **全部走 IOCP**（BIO 模式：握手与读写均由 WSARecv/WSASend 完成项驱动）。可用 **-Duse_iocp=false** 回退。                                    | 高/中   | ✅ 明文与 TLS 全 IOCP 已实现 |


已落地项在 4.4 表中补充。**Windows**：**无 TLS** 时默认**全 IOCP**（CreateIoCompletionPort + AcceptEx + WSARecv/WSASend），accept 与连接读写均走完成端口，每 tick 仅 drain GetQueuedCompletionStatus，不做 poll；可用 `-Duse_iocp=false` 回退为纯 poll。**有 TLS** 时（`use_iocp_full_tls`）**TLS 也全 IOCP**：新连接用 BIO 模式握手（startBio），握手中与已握手连接的读写均由 overlapped WSARecv/WSASend 完成项驱动（feedRead/stepBio、feedRead/stepTlsConn、getSend/postSend）。**Linux io_uring**：已用 io_uring 做就绪检测。recv/send 批量化等为后续可选优化。

---

## 五、压缩方案（gzip / Comprezz）


| 方案           | 说明                                                                     |
| ------------ | ---------------------------------------------------------------------- |
| **Comprezz** | Zig 纯实现，当前用于 gzip/deflate；无 C 依赖，与 Brotli（C）并列。                        |
| **C zlib**   | 可选：链接 libz，用 deflateInit2_(..., windowBits+16, ...) 做 gzip，与 Bun 方式一致。 |


压缩优先级：br > gzip > deflate；仅当 body 超过 minBodyToCompress 且压缩后更短才使用。

---

## 六、吞吐量分析

### 6.1 当前架构要点

- **单线程**：accept / 处理请求 / runMicrotasks / runLoop 均在 setImmediate 驱动的 tick 内完成。
- **明文无 TLS 时**：均启用 **I/O 多路复用**：Linux 用 epoll、macOS·BSD 用 kqueue、其它 POSIX 用 poll；**Windows 默认全 IOCP**（accept + 连接 recv/send 均走完成端口，不 poll，可 `-Duse_iocp=false` 回退为 poll）。**每进程**内多连接并发；**WS**、**h2c** 不 handoff，与 HTTP 同 tick 非阻塞。
- **有 TLS 时**：非 Windows 为 poll + 非阻塞 TLS；**Windows 为全 IOCP**（HTTPS、WSS、h2、chunked 均走完成端口，BIO 模式握手与读写由 WSARecv/WSASend 驱动，不 poll）；**WSS**、**h2** 不 handoff，与 HTTPS 同事件循环。
- **keep-alive**：同连接可处理多请求，摊薄建连/关连成本；多路复用路径下 keep-alive 连接在写完响应后复位到 reading_headers 继续读下一请求。

### 6.2 主要瓶颈（定性）

1. **串行模型**：吞吐上界受单请求耗时限制；多核未利用。
2. **JSC 跨界与分配**：Request/Response 构造与读取依赖大量 JSC API 与 Zig 侧分配；已通过 arena、复用 buffer、零拷贝等缓解。
3. **runLoop 节流**：可通过 runLoopEveryRequests / runLoopIntervalMs 降低频率。

### 6.3 压测建议

- 简单 handler 返回小 body，用 **wrk** / **hey** / **ab** 打 127.0.0.1，看 Requests/sec 与延迟分布。
- 示例：`wrk -t2 -c10 -d10s http://127.0.0.1:3000/`

### 6.4 Shu 与 Bun / Deno 对比（简要）

本小节从**架构与性能设计**角度做定性对比，不给出具体 QPS 数字（实际吞吐取决于 handler 复杂度、压测工具、环境，建议用 wrk/hey 自测）。

| 维度 | Bun | Deno | Shu.server |
|------|-----|------|------------|
| **JS 引擎** | JSC | V8 | JSC（与 Bun 一致） |
| **服务端实现** | Zig | Rust | Zig |
| **事件循环** | 单线程 + setImmediate 式 tick | 多线程 tokio + 单线程 V8 执行 | 单线程 + setImmediate 驱动 tick |
| **I/O 模型** | epoll/kqueue/IOCP，非阻塞多路复用 | tokio 异步 I/O | epoll/kqueue/poll，Windows 默认全 IOCP；TLS 在 Windows 下也全 IOCP（BIO 模式） |
| **keep-alive** | 支持 | 支持 | 支持，同连接多请求摊薄建连成本 |
| **连接内优化** | 少分配、writev、零拷贝等 | 各自实现 | arena、连接级 buffer 复用、writev、sendfile、请求头零拷贝、SIMD 头块查找等（见 4.2、4.3） |
| **WS/H2/chunked** | 多路复用内不阻塞 | 异步任务 | 均不 handoff，与 HTTP 同 tick 非阻塞 |
| **多核** | workers / 多进程 | 多线程 runtime | options.workers 内置 cluster + reusePort |
| **吞吐瓶颈** | 单请求耗时、单线程上界 | 任务调度、V8 执行 | 同 6.2：串行模型、JSC 跨界与分配、runLoop 节流 |

- **Shu vs Bun**：技术栈与 I/O 路线与 Bun 对齐（JSC + Zig、单线程多路复用、epoll/kqueue/IOCP、keep-alive、减分配、writev、workers）。设计目标是在相同维度上达到同量级性能；实际 Requests/sec 需在同一 handler、同一压测条件下对比。
- **Shu vs Deno**：Deno 使用 V8 + Rust 与 tokio 多线程 I/O，模型不同。Shu 单线程多路复用、JSC 在冷启动与内存上通常更省，峰值 JS 执行则取决于具体 workload；二者是不同取舍，而非同一实现的两版。
- **建议**：用简单 handler（如返回固定小 body）在 127.0.0.1 上跑 `wrk -t2 -c10 -d10s` 或 hey，对比同机上的 Bun/Deno/Shu，得到本机可复现的吞吐与延迟分布后再做结论。

---

## 七、适用场景

本节从**使用场景**角度说明 Shu.server 适合做什么、与 Bun/Deno 的取舍，便于选型。

### 7.1 Shu.server 适合的场景

- **同端口多协议**：需要在一套 listen 上同时提供 HTTP/1.1、WebSocket、HTTP/2（h2/h2c）、HTTPS/WSS，且希望 WS/H2/chunked 不阻塞主循环、与 HTTP 共享多路复用。
- **Bun 风格 API 但希望可控**：习惯 `fetch` + `Response`、`webSocket` 配置，需要 **stop / reload / restart** 热重载或优雅重启，且希望缓冲与连接数等参数可配置（见第二节）。
- **多进程同端口**：内网或边缘部署时希望多进程绑同端口、内核负载均衡，可用 **options.workers** 内置 cluster 或手动起多进程 + **reusePort**。
- **Windows 上 HTTPS/WSS 高并发**：Windows 下 TLS 全 IOCP（BIO 模式），HTTPS、WSS、h2、chunked 均走完成端口，与明文路径一致，适合需要在本机或 Windows 服务器上跑 TLS 的场景。
- **资源与冷启动敏感**：JSC + Zig 单线程多路复用，冷启动与内存占用通常较省；适合边缘、轻量网关、本地开发/调试等对进程体积与启动时间有要求的场景。
- **压缩与零拷贝**：需要按 Accept-Encoding 做 br/gzip/deflate，或响应 **filePath** 时用 sendfile 零拷贝，无需自建反向代理即可减轻带宽与 CPU。

### 7.2 与 Bun / Deno 的适用场景对比

| 场景/需求 | Bun | Deno | Shu.server |
|-----------|-----|------|------------|
| 与现有 Bun 项目 API 兼容、追求生态与成熟度 | ✅ 首选 | 需迁移 | 兼容 fetch/webSocket，API 对齐；生态与工具链不如 Bun 成熟 |
| 需要默认权限模型、安全优先（如 Deno 风格） | 无 | ✅ 首选 | 当前无内置权限模型，适合可信环境或配合反向代理 |
| 需要热重载/优雅重启（不关 listen 更新 handler） | ✅ | 需自行实现 | ✅ reload/restart，不关 listener |
| 同端口 HTTP + WS + H2 + TLS，且希望实现可控 | ✅ | 支持 | ✅ 同端口、多路复用内全非阻塞，实现透明、可配置 |
| Windows 上 HTTPS/WSS 高并发、少阻塞 | 各平台优化 | 依赖 tokio | ✅ 全 IOCP（含 TLS），与 Linux/Mac 行为一致 |
| 多进程同端口、内核负载均衡 | 支持 | 支持 | ✅ workers 或手动多进程 + reusePort |
| 冷启动/内存敏感（边缘、Serverless、本地工具） | 已优化 | V8 相对吃内存 | JSC + Zig，目标同量级；具体需压测 |
| 需要完整 Node 兼容层、npm 生态 | ✅ | 部分 | 视 Shu 运行时整体进度，非仅 server 维度 |

- **选 Shu 的典型情况**：要 Bun 风格的 HTTP/WS/H2 API 与性能路线，同时希望热重载、可配置缓冲与连接数、Windows TLS 与多进程行为清晰、实现可读可维护时，Shu.server 是一个可选方案。
- **选 Bun**：优先考虑生态、包管理、测试与打包一体化、生产验证程度时，Bun 更合适。
- **选 Deno**：优先考虑默认安全、权限模型、TypeScript 与标准库体验时，Deno 更合适。

---

## 八、小结对照表


| 概念                        | Shu 现状                                         |
| ------------------------- | ---------------------------------------------- |
| 非阻塞 + stop/reload/restart | ✅ 已实现，setImmediate 驱动 tick                     |
| 无 TLS 时 Mac/Linux/Windows | ✅ 同一套非阻塞多路复用（epoll/kqueue/IOCP 或 poll），行为一致   |
| keepAliveTimeout          | ✅ 可配置，仅影响响应头 Keep-Alive: timeout=N；尚未做服务端空闲断连接 |
| signal 关服                 | ✅ options.signal 或 server.stop()               |
| onError 回调                | ✅ 抛错/无效返回时调用，可返回自定义 Response                   |
| Unix socket               | ✅ options.unix（与 host+port 二选一）                |

---

## 九、阻塞点检查（Linux / Mac / Windows）

以下为对主事件循环与多路复用路径的阻塞点审计结论；**handoff 路径**（单连接交给 handleConnection / handleH2Connection 跑完）为**设计上的阻塞**，不列入“需修复”项。

### 9.1 主循环与多路复用（非阻塞）

| 平台 | 路径 | 说明 |
|------|------|------|
| **Linux** | 明文 | epoll / io_uring 就绪后 accept；连接 setNonBlocking；stepPlainConn 单次 read/write，IOCP 时用完成项注入字节，不阻塞。 |
| **Linux** | TLS | poll(0) 或 epoll 就绪后 accept；TLS 非阻塞 step + readNonblock/writeNonblock。 |
| **Mac/BSD** | 明文 | kqueue 就绪后 accept；连接 setNonBlocking；stepPlainConn 同上。 |
| **Mac/BSD** | TLS | 同 Linux TLS。 |
| **Windows** | 明文 | 全 IOCP：getCompletion(0)，AcceptEx + WSARecv/WSASend，无 poll；stepPlainConn 仅用完成项数据。 |
| **Windows** | TLS | 全 IOCP 时 getCompletion(0) + BIO 握手/读写；非全 IOCP 时 poll(0) + 非阻塞 TLS。 |

- **无 TLS（state.tls_ctx == null）**：Mac / Linux / Windows 均走**同一套**非阻塞多路复用（plain_mux）：Linux 用 epoll/io_uring，Mac 用 kqueue，Windows 用 IOCP（或 poll）；accept 仅在就绪事件/IOCP 完成项之后调用，行为一致、单 tick 不阻塞。
- **poll / epoll_wait / kqueue / GetQueuedCompletionStatus**：均使用 **timeout = 0**（非阻塞）。
- **accept()**：仅在“有就绪事件”或“IOCP 完成项”之后调用；兼容路径（见 9.2）也统一先 **poll(0)** 再 accept，避免无事件时 accept 阻塞。

### 9.2 已修复的阻塞风险

1. **stepPlainConn reading_preface（明文 h2c 检测）**
   原为 `while (conn.read_len < 24) { conn.stream.read(...) }`，在非阻塞 fd 上可能自旋或误关连接。
   已改为：**单次 read**，若 `WouldBlock` 返回 `.continue_`，若 `n == 0` 返回 `.remove_and_close`，未满 24 字节也返回 `.continue_`，由下次就绪再读。

2. **兼容路径（原“无 TLS 回退”）accept 阻塞**
   原在“无 TLS 或 TLS 结构未就绪”的 else 分支中，Windows 上曾直接 `should_accept = true`，导致无连接时 **accept() 阻塞**。
   已改为：**Linux/Mac/Windows 统一**先 `poll(server_fd, 0)`，仅当 `POLL.IN` 时再 accept；且若有 `tls_pending`，则**延迟分配** `tls_poll_fds`/`tls_poll_client_fds`，accept 时将新连接入 `tls_pending`（setNonBlocking），下一 tick 走 TLS 非阻塞 poll 路径，避免整连接阻塞。

3. **TLS 兼容路径整连接阻塞**
   当 TLS 已配置但 poll 数组未就绪时，原为 accept 后对单连接做阻塞式 `TlsStream.accept` + handle。
   已改为：先尝试**延迟分配** poll 数组；accept 时若有 `tls_pending` 则将连接加入握手中队列（非阻塞），下一 tick 由 TLS poll 路径处理。仅当 `tls_pending` 为 null 时才退化为单连接阻塞处理——正常 listen 成功时 `tls_pending` 已在 init 中分配，该分支仅作防御性兜底。

**兼容路径进入条件**：`state.tls_ctx != null` 且未进入主 TLS poll 分支（例如 `tls_poll_fds`/`tls_poll_client_fds` 为 null）。正常 listen 成功时通常不进入；若进入，首 tick 会尝试延迟分配，之后与主 TLS 路径行为一致。

4. **WebSocket 明文路径 read/write 阻塞**
   明文多路复用下 `stepPlainConn` 的 `ws_handshake_writing` / `ws_frames` 曾用 `stream.read()` / `stream.write()`，在非阻塞 fd 上产生 `WouldBlock` 时被当作错误并关闭连接。
   已改为：read/write **catch `error.WouldBlock` 时返回 `.continue_`**，与 TLS 路径的 `readNonblock`/`writeNonblock` 行为一致，**WebSocket 明文与 TLS 均为全非阻塞**，可支撑大并发 WS/WSS 连接。

### 9.3 复杂请求已改为非阻塞（无 handoff）

- **h2c upgrade（Upgrade: h2c）**：不再 handoff。检测到 isH2cUpgrade 后留在多路复用内：写 101（phase `h2c_writing_101`）→ 等 24 字节 preface（`h2c_wait_preface`）→ 发 SETTINGS（`h2_send_preface`）→ `h2_frames`，与 prior knowledge h2 一致，全程非阻塞。
- **TLS ALPN h2**：不再 handoff。握手完成后若 ALPN 为 `h2`，将连接放入 `tls_conns` 且 phase 设为 `h2_send_preface`（write_buf 已带 SETTINGS），由 stepTlsConn 非阻塞走 h2_send_preface → h2_frames。
- **handleConnectionPlain / handleConnection / handleH2Connection**：仅在**兼容路径且 tls_pending 为 null** 时会对单连接整连接阻塞；正常多路复用及“兼容路径 + 延迟分配 + tls_pending”下已无 h2c/h2 的 handoff，行为与非 TLS 一致（Mac/Linux/Windows 均非阻塞）。

**WebSocket**：不 handoff，留在多路复用内。握手阶段 `ws_handshake_writing` 写 101 响应；帧阶段 `ws_frames` 单次 read → stepFrames 解析完整帧、回调 onMessage、ping 回 pong、close 回 close，再单次 write；明文路径与 TLS 路径均对 WouldBlock/WantRead/WantWrite 返回 `.continue_`，**全非阻塞**。**写队列与每 tick 限写**：`ws.send(data)` 入队到连接 `write_buf`，每 tick 每连接最多写出 **128KB**（`WS_MAX_WRITE_PER_TICK`），避免单连接写量过大占满事件循环；IOCP 路径下 postSend 同样按 128KB 分段。**读缓冲 128KB**（`WS_READ_BUF_SIZE`），单次可收更多帧，提高吞吐。与 HTTP 共享同一 epoll/kqueue/IOCP/poll，可支撑大吞吐与高并发 WS 连接。

### 9.4 可选加固（未改）

- **listen 句柄设为非阻塞**：当前未对 `state.server.?.stream.handle` 调用 setNonBlocking。在“先 poll 再 accept”的前提下，accept 仅在就绪后调用，一般不会阻塞；若需进一步避免极端竞态（poll 与 accept 之间连接被重置），可对 listen 句柄 setNonBlocking，并在所有 accept 的 catch 中把 `error.WouldBlock` 当作“本 tick 无连接”处理（break/continue）。
