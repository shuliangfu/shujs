# modules/shu 下 shu:xxx 与 io_core 优化关系

本文档列出 `src/runtime/modules/shu` 下所有以 `shu:xxx` 形式暴露的内置模块，并标注哪些**适合或需要使用 io_core** 进行优化。io_core 能力概览见 [IO_CORE_ROADMAP.md](./IO_CORE_ROADMAP.md)。

---

## io_core 可提供的优化能力摘要

| 能力 | 说明 | 适用场景 |
|------|------|----------|
| **HighPerfIO** | accept + 首包 recv、连接 recv/send、pollCompletions 统一收割；Completion.tag=accept\|recv\|send | 高并发 TCP 服务端，I/O 统一走 io_core |
| **sendFile** | 文件→网络零拷贝（Linux sendfile / Darwin sendfile / Windows TransmitFile） | 静态文件响应、大文件发送 |
| **BufferPool / ChunkAllocator** | 预分配池、块级 take/release、线程本地缓存 | 高吞吐 buffer 分配 |
| **simd_scan** | indexOfCrLfCrLf、findCrLfInBlock 等向量化边界查找 | HTTP/协议头部解析 |
| **RingBuffer** | 无锁 SPSC 环形队列 | 生产者-消费者、收发包队列 |
| **mapFileReadOnly / mapFileReadWrite** | 大文件 mmap，零拷贝按需换页 | 大文件只读/读写、大模型等 |

---

## 需要或适合使用 io_core 的模块（xxx 列表）

以下 **xxx** 为**建议接入或已接入 io_core** 的模块名（对应 `shu:xxx`）。

### 1. server（已接入 simd_scan + sendFile + HighPerfIO 全路径；明文与 TLS I/O 均已统一到 io_core）

| 子模块/路径 | 当前状态 | 说明 |
|-------------|----------|------|
| **parse.zig** | ✅ 已用 `io_core.simd_scan.indexOfCrLfCrLf` | 头部边界查找统一走 io_core，无重复实现。 |
| **response.zig** | ✅ 已用 `io_core.sendFile` | `sendfileToStream` 在 stream 为 `*std.net.Stream` 且平台支持时调用 `io_core.sendFile`（含 Windows TransmitFile），否则回退 read+write；**已去掉与 io_core 重复的 sendfile/read+write 自实现**。响应头已做 Date 秒级缓存与 Server 预编码优化。 |
| **mod.zig / accept + 首包** | ✅ 已用 io_core.HighPerfIO | 非 Unix 时创建 HighPerfIO + BufferPool，tick 内先 `pollCompletions` 收新连接（tag=accept、client_stream+首包），再 `submitAcceptWithBuffer` 补足；明文与 TLS 路径均不再走 epoll/kqueue 的 accept 循环或 iocp accept 分支。 |
| **tick.zig / 连接后续 I/O（明文 + TLS）** | ✅ 已用 io_core | 有 server 且启用 io_core 时，tick 内统一 `pollCompletions` 收割 Completion（accept/recv/send）。**明文**：step 内 submitRecv/submitSend/releaseChunk；**TLS**：accept 后握手用 BIO（`TlsPending.startBio` + `feedRead`/`getSend`/`stepBio`），握手完成入 `tls_conns`，recv/send 分支按 fd 分发到 `tls_pending` 或 `tls_conns`，密文 I/O 全部经 io_core（submitRecv/submitSend），TLS 层只做加解密。poll 超时为**自适应**（高负载自动 0，空闲逐步增至 options.pollIdleMs 上限）。 |

- **结论**：**server 明文与 TLS（HTTPS）路径均已统一到 io_core**。已接入：**simd_scan**、**sendFile**、**HighPerfIO（accept + recv + send，含 TLS BIO 握手与已连接 I/O）**；tick 内单一路径 pollCompletions + step 内 submitRecv/submitSend，无重复 epoll/kqueue/iocp 连接 I/O。cluster 模式下 worker 绑核（Linux/Windows 硬绑、macOS 亲和标签 + QoS）与 io_core 无关，见 server 文档。

- **如何确认与调试 io_core 是否生效**
  - **确认**：当前实现下，只要 `Shu.server()` 返回了 server 对象且能正常处理请求，连接 I/O 就一定走 io_core（若 `HighPerfIO`/BufferPool 创建失败则不会返回 server 对象，且没有其他 fallback 路径处理 accept/recv/send）。
  - **调试**：若怀疑 io_core 或 TLS 路径有问题：**(1)** 使用 `Shu.server` 的 **`onError`** 回调，所有服务端错误会在此上报；**(2)** 用 `curl` 或浏览器对 HTTP/HTTPS 各打几次请求（含 keep-alive、立即断开），观察是否崩溃、挂起或触发 onError；**(3)** 需要更细粒度时，可在 Zig 侧临时加日志（如 tick 内 `num_comps`、或按 completion tag 计数），或通过环境变量/options 增加 debug 开关再编译运行。

---

### 2. fs（已接入 mapFileReadOnly；大文件 readSync/copySync 走 io_core）

| 场景 | 当前状态 | 说明 |
|------|----------|------|
| 大文件只读 | ✅ 已用 `io_core.mapFileReadOnly` | `readSync(path, { encoding: null })` 且文件大小 ≥ 256KB 时用 mapFileReadOnly，返回 Buffer 零拷贝、按需换页，避免 readToEndAlloc OOM |
| 大文件复制 | ✅ 已用 `io_core.mapFileReadOnly` | `copySync(src, dest)` 当源文件 ≥ 256KB 时用 mapFileReadOnly 读源 + 整块写目标，减少内存拷贝 |
| 异步 read/write | ✅ 已用 `io_core.AsyncFileIO` | Shu.fs.read / Shu.fs.write 改为 submitReadFile/submitWriteFile → 每轮 tick/runLoop 前 drain 收割完成项并 resolve/reject Promise；>64MB 读或 init 失败时回退 setTimeout+readSync/writeSync |

- **结论**：**fs** 已接入 **mapFileReadOnly**（大文件 readSync、copySync）、**AsyncFileIO**（异步 read/write）；sendFile 由 server 使用，fs 内不直接使用。

**异步 read/write 已接入 io_core（当前实现）**

- **实现**：`Shu.fs.read` / `Shu.fs.write` 使用 **io_core.AsyncFileIO**：首次调用时按需创建 AsyncFileIO 并注册 `drain_async_file_io`；read/write 回调内通过 `Shu.__fsSubmitRead` / `Shu.__fsSubmitWrite` 提交一次异步读/写，将 resolve/reject 放入 pending 表；每轮事件循环（engine 的 runMicrotasks/runLoop 前、server tick 开头）调用 **drain**，即 `AsyncFileIO.pollCompletions(0)`，按 user_data 查表并 resolve/reject 对应 Promise。
- **平台**：Linux 用独立 io_uring 仅做 READ/WRITE；Darwin/Windows 用工作线程 + pread/pwrite 或 ReadFile/WriteFile，完成项入队后由 pollCompletions 取出。
- **回退**：单次读 >64MB 或 AsyncFileIO.init 失败时，read 回退为 `setTimeout(0)` + readSync；write 在 init 失败或脚本拼接失败时回退为 setTimeout + writeSync。

---

### 3. net

| 场景 | 当前实现 | 建议 io_core 用法 |
|------|----------|-------------------|
| 通用 createServer / socket | `std.net.Server` accept + `stream.read` | 若需与 HighPerfIO 同级的 accept+首包入池，可由 **server** 统一走 HighPerfIO；**net** 作为通用 Node 风格 API 可保持现状，或提供“高性能 listen”选项时再对接 io_core |

- **结论**：**net** 为**可选**对接 io_core（HighPerfIO），通常由 **server** 统一做高性能路径即可。

---

### 4. stream

| 场景 | 说明 | 建议 io_core 用法 |
|------|------|-------------------|
| 文件流、管道 | 若包装 fs 读/写或 socket | 涉及“文件→网络”时由底层使用 **sendFile**；若包装大文件读，可考虑 **mapFileReadOnly** 的只读视图（与 fs 大文件策略一致） |

- **结论**：**stream** 适合在涉及**文件流、大文件**时**间接**使用 io_core（sendFile / mmap），由 fs 或 server 层统一封装更合适。

---

### 5. buffer（已接入 ChunkAllocator 池化）

| 场景 | 当前实现 | 说明 |
|------|----------|------|
| Buffer.alloc(64KB) | ✅ 已用 **io_core.BufferPool + ChunkAllocator** | 当 `size == 64*1024` 时从 ChunkAllocator 取块，用 **NoCopy** 交给 JSC TypedArray，GC 时 `poolChunkDeallocator` 归还块；池总大小 4MB、块 64KB，与 server 侧块一致 |
| 其他 size / from / concat | 保持原有 allocator / NoCopy 逻辑 | 未走池 |

- **结论**：**buffer** 已接入 **BufferPool/ChunkAllocator**（64KB 池块、NoCopy 归还），减少高并发下 allocator 压力。

---

### 6. report（已接入 mapFileReadWrite 大报告路径）

| 场景 | 当前实现 | 说明 |
|------|----------|------|
| writeReport(filename) 且报告 ≥ 64KB | ✅ 已用 **io_core.mapFileReadWrite** | 用 cwd 解析 path，创建并扩展文件到 report.len，mapFileReadWrite 后一次性 @memcpy 写入，deinit；避免多次 write 与用户态拷贝 |
| 小报告 / stdout | 保持 createFile + writeAll 或 stdout.writeAll | 不变 |

- **结论**：**report** 已接入 **mapFileReadWrite**（大报告零拷贝写文件）。

---

### 7. dgram（已接入 RingBuffer + recv 缓冲池）

| 场景 | 当前实现 | 说明 |
|------|----------|------|
| UDP recv（message 回调） | ✅ 已用 **io_core.RingBuffer** + 32 槽 recv 池 | 首次有 bound socket 时初始化：32×2048 字节缓冲、free_list/pending 两个 RingBuffer(usize)；recvfrom 入池槽、meta 存 len+addr+socket_id，drain 时用 **NoCopy** Buffer 交付 JS，GC 时归还槽位 |
| 池未就绪 / 回退 | 栈上 2048 缓冲 + makeMessageBufferCopy（拷贝 Buffer） | message 统一为 Buffer（不再为 string） |

- **结论**：**dgram** 已接入 **RingBuffer** 与 recv 缓冲池，零拷贝交付 message Buffer，GC 时归还槽位。

---

## 不需要或仅间接使用 io_core 的模块（xxx 列表）

以下 **xxx** 为**不需要直接使用 io_core**（或仅通过依赖 server/fs 间接受益）的模块，列全以便对照。**“不需要”的含义**：不承担 io_core 所优化的那类 I/O（高并发 accept+recv 入池、文件→网络零拷贝、大文件 mmap、协议边界 SIMD 扫描、块级 buffer 池），因此无需在本模块内引用 io_core；若需优化，应在**实际做这些 I/O 的模块**（server、fs、net）中接入。

### 一、网络相关：http, https, tls, dns 为什么不需要？

| xxx | 不需要的直接理由 |
|-----|------------------|
| **http** | **不持有 listen/accept/recv/sendfile**。shu:http 的 `createServer(requestListener)` 只构造带 `listen(port, host, callback)` 的 JS 对象；`listen` 内部是**调用 `globalThis.Shu.server({ port, host, fetch })`**，真正执行 listen、accept、读请求、写响应、sendfile 的是 **shu:server**。io_core 的 HighPerfIO、sendFile、simd_scan 都应在 **server** 里用；**http 只是 Node 风格 API 外壳，不直接做任何块 I/O**，因此不需要也不应在本模块引用 io_core。 |
| **https** | **与 http 相同，再包一层 TLS**。shu:https 复用 shu:http 的 createServer/listen，只是把 `Shu.server` 的选项加上 TLS。底层仍是 **server** 在 listen/accept/recv/sendfile；TLS 在 server 或 net 提供的 stream 上做加解密。io_core 优化仍在 **server**（及可选 net）层；**https 不持有 socket、不读不写字节流**，因此不需要直接使用 io_core。 |
| **tls** | **只做“在已有 stream 上包装 TLS”**。shu:tls 从 shu:net 拿 `stream`（`getStreamById`），在其上做握手、加解密；**真正的 socket read/write 在 net（或由 server 交给 net 的 connection）里完成**。io_core 优化的是“谁拿 fd/stream、谁做 accept/recv/sendfile”——那是 **net** 或 **server**，不是 tls。**tls 不拥有传输层，不直接做块 I/O**，因此不需要直接使用 io_core。 |
| **dns** | **做的是名字解析，不是高并发 TCP 或文件→网络 I/O**。shu:dns 提供 lookup、resolve*、reverse 等，底层用系统 getaddrinfo/getnameinfo 或自定义解析器，在**工作线程里跑**，结果通过 setImmediate 回主线程。**没有**：accept 池、首包 recv 入池、sendfile、HTTP 头部 SIMD 扫描、大块 buffer 池。io_core 针对的是“高并发 TCP 服务端 + 文件零拷贝 + 协议解析”；**dns 是低频解析/查询，流量形态与 io_core 完全不符**，因此不需要使用 io_core。 |

**小结**：http/https/tls 的“不需要” = **I/O 发生在 server/net，它们只是 API 或加密层**；dns 的“不需要” = **业务形态是解析查询，不是 io_core 所优化的高吞吐 I/O**。

### 二、其余“不需要”模块的理由（逐条）

| xxx | 不需要的直接理由 |
|-----|------------------|
| **path** | 纯路径字符串处理（join、resolve、dirname、basename 等），无任何块 I/O、无 socket、无文件描述符。 |
| **process** | 进程信息、env、argv、stdin/stdout/stderr 句柄、exit 等；不实现高并发 accept/recv 或文件→网络零拷贝。 |
| **timers** | setTimeout/setInterval/setImmediate，定时回调调度，无块 I/O。 |
| **console** | log/error/warn 等写 stdout/stderr，不涉及 io_core 所优化的块 I/O（accept 池、sendfile、mmap）。 |
| **system** | 子进程 spawn/exec，启动外部进程、管道；不负责“本进程内”的 listen/accept/sendfile 或大文件 mmap。 |
| **zlib** | 压缩/解压（gzip、deflate 等），在内存里做变换，无 socket、无文件→网络零拷贝、无 accept 池。 |
| **crypto** | 加密/哈希（randomBytes、createHash、scrypt 等），CPU 与算法为主，无块 I/O 优化点。 |
| **assert** | 断言（ok、equal、throws 等），测试用，无 I/O。 |
| **os** | 系统信息（platform、cpus、freemem、tmpdir 等），无块 I/O。 |
| **events** | EventEmitter（on/emit/once），事件订阅与触发，无块 I/O。 |
| **util** | 工具函数（inspect、format、types 等），无块 I/O。 |
| **querystring** | 查询串 parse/stringify，纯内存解析，无 socket/文件 I/O。 |
| **url** | URL 解析与构造，纯内存，无块 I/O。 |
| **string_decoder** | 字节→字符串解码（UTF-8 等），无高吞吐 socket/文件路径。 |
| **threads** | Worker 线程（Worker、parentPort）；线程本身不持有 io_core 的 HighPerfIO/sendFile；若 Worker 内跑 server，应在 server 侧接 io_core，而非在 threads 模块接。 |
| **readline** | 行读取（通常配合 stdin 或小 buffer），非高并发、非大文件 mmap、非 accept 池场景。 |
| **vm** | 脚本执行（runInContext 等），无块 I/O。 |
| **async_hooks** | 异步上下文/生命周期钩子，无块 I/O。 |
| **async_context** | 同上，异步上下文，无块 I/O。 |
| **perf_hooks** | 性能计时 API，无块 I/O。 |
| **module** | 模块解析/加载（require/import 解析），无高并发 socket 或 sendfile。 |
| **repl** | 占位实现，无 I/O。 |
| **test** | 占位实现，无 I/O。 |
| **inspector** | 占位实现，无 I/O。 |
| **wasi** | 占位实现，无 I/O。 |
| **diagnostics_channel** | 通道发布/订阅，无块 I/O。 |
| **tracing** | 追踪 API，无块 I/O。 |
| **tty** | isTTY、ReadStream/WriteStream 占位，无 io_core 所针对的块 I/O。 |
| **permissions** | 权限查询（has/request），无块 I/O。 |
| **intl** | 国际化（getIntl、Segmenter），无块 I/O。 |
| **webcrypto** | 透传 globalThis.crypto，无块 I/O。 |
| **webstreams** | 透传 ReadableStream/WritableStream 等，无直接块 I/O；若底层是 fs/net，优化在 fs/net/server。 |
| **cluster** | 单进程占位（fork 未实现），无块 I/O。 |
| **debugger** | 占位实现，无块 I/O。 |

## 汇总：建议使用 io_core 的 xxx 列表

| 优先级 | xxx | io_core 能力 | 说明 |
|--------|-----|--------------|------|
| **已用** | **server** | simd_scan | parse 已用 indexOfCrLfCrLf |
| **已用** | **server** | sendFile | response.sendfileToStream 已改为 io_core.sendFile，三端零拷贝（含 Windows TransmitFile） |
| **已用** | **server** | HighPerfIO | 明文与 TLS 路径：accept + 首包 recv + 连接 recv/send 已统一走 pollCompletions + submitRecv/submitSend（Linux/Darwin/Windows）；TLS 为 BIO 模式，底层 I/O 全经 io_core。 |
| **已用** | **fs** | mapFileReadOnly + AsyncFileIO | 大文件 readSync/copySync 走 mapFileReadOnly；异步 read/write 走 AsyncFileIO（submit → drain 收割并 resolve/reject） |
| **可选** | **net** | HighPerfIO | 高性能 listen 时与 server 统一对接 |
| **可选** | **stream** | sendFile / mapFileReadOnly | 文件流、大文件由 fs/server 封装 |
| **已用** | **buffer** | BufferPool / ChunkAllocator | Buffer.alloc(64KB) 走池、NoCopy 归还 |
| **已用** | **report** | mapFileReadWrite | 大报告（≥64KB）写文件走 mapFileReadWrite |
| **已用** | **dgram** | RingBuffer + recv 池 | free_list/pending 双 RingBuffer、32 槽缓冲池、message NoCopy 归还 |

**需要或适合接入 io_core 的 xxx（已实现/建议实现）：**  
**server**（simd_scan、sendFile、HighPerfIO 已全部接入）、**fs**（mapFileReadOnly 已接入）、**buffer**（ChunkAllocator 池化 64KB）、**report**（大报告 mapFileReadWrite）、**dgram**（RingBuffer + recv 池）。

**可选接入的 xxx：**  
net、stream。

**不需要直接使用 io_core 的 xxx：**  
path, process, timers, console, system, zlib, crypto, assert, os, events, util, querystring, url, string_decoder, threads, http, https, tls, dns, readline, vm, async_hooks, async_context, perf_hooks, module, repl, test, inspector, wasi, diagnostics_channel, tracing, tty, permissions, intl, webcrypto, webstreams, cluster, debugger。

---

*文档与 `builtin.zig` 中 `SUPPORTED` 的 shu:xxx 列表一致；若新增内置模块，可按上表规则判断是否接入 io_core。*
