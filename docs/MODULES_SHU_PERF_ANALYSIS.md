# modules/shu 性能优化分析（对照 00-性能规则）

本文档按 `.cursor/rules/00-性能规则.mdc` 对 `src/runtime/modules/shu` 的优化点做分类整理，并给出建议优先级。

---

## 1. 内存与分配（§1.1 显式 Allocator、§1.2 Arena、§1.3 栈优先）

### 1.1 隐式/全局 Allocator（高优先级）

| 模块 | 问题 | 建议 |
|------|------|------|
| **require/mod.zig** | ~~g_cache_allocator 全局保存 allocator~~ | 已移除全局 g_cache_allocator，allocator 由 initCache 调用方与回调 current_allocator 提供（§1.1） | ✅ 已优化 |
| **perf_hooks/mod.zig** | ~~g_perf_alloc = page_allocator~~ | 已增加 initPerfStore(allocator)，getExports 时注入；ensurePerfStore 回退 current_allocator 或 page_allocator（§1.1） | ✅ 已优化 |
| **readline/mod.zig** | ~~ensureReadlineGlobals 用 page_allocator~~ | 已增加 initReadlineGlobals(allocator)，getExports 时注入；ensureReadlineGlobals 回退 current_allocator 或 page_allocator（§1.1） | ✅ 已优化 |
| **tls/mod.zig, module/mod.zig, http, crond, async_context, text_encoding, system(spawn/run/exec/fork)** | ~~通过 current_allocator 取 allocator~~ | 已收敛：getExports/register 时注入 threadlocal g_*_allocator，回调内优先使用；engine/shu、bindings 传 allocator（§1.1） | ✅ 已优化 |

### 1.2 大栈分配（高优先级，易爆栈）

规范 §1.3：小结构 <8KB 栈优先，**大 buffer 禁止栈上**。

| 文件 | 现状 | 建议 | 状态 |
|------|------|------|------|
| **server/mod.zig** | ~~`read_buf`/`response_body_buf` 栈上~~ | 已改为 allocator.alloc，defer free | ✅ 已优化 |
| **server/connection.zig** | ~~`response_body_buf` 栈上~~ | 已用 RESPONSE_BODY_BUF_SIZE 堆分配，sendH2* 接 []u8 | ✅ 已优化 |
| **server/step_plain.zig / step_tls.zig** | ~~`response_body_buf` 栈上多处~~ | 已每处 alloc + defer free，回调改为 []u8 | ✅ 已优化 |
| **server/response.zig** | ~~回退路径 buf 64KB 栈上~~ | 已改为 sendfileToStream(allocator, …) 内堆分配 | ✅ 已优化 |
| **module/mod.zig** | ~~`code_buf` 256KB 栈上~~ | 已改为 allocator.alloc(MODULE_CODE_BUF_MAX)，defer free | ✅ 已优化 |
| **server/conn_state.zig** | ~~TLS raw_recv_buf/raw_send_buf 栈上~~ | 已改为堆分配（TLS_RAW_BUF_SIZE），TlsPendingEntry/TlsConnState 内 []u8，init/deinit 分配释放 | ✅ 已优化 |
| **websocket_client/mod.zig** | ~~write_buf 64KB 在结构体内~~ | 已改为 init 时 allocator.alloc(WS_CLIENT_WRITE_BUF_SIZE)，deinit 时 free | ✅ 已优化 |

### 1.3 ArrayList / 集合（§1.4 DOD、BoundedArray）

| 文件 | 现状 | 建议 |
|------|------|------|
| **server/conn_state.zig** | ~~headers_list 每次 initCapacity(16) 易扩容~~ | H2 流已用 initCapacity(MAX_H2_HEADERS)+decodeHpackBlockCapped 封顶 64 条，单次分配无扩容（§1.3） | ✅ 已优化 |
| **server/step_plain.zig, step_tls.zig** | ~~同上~~ | 同上，decodeHpackBlockCapped + MAX_H2_HEADERS（§1.3） | ✅ 已优化 |
| **timers/state.zig** | ~~pending_timers/microtask_queue 初始容量 0~~ | 已用 initCapacity(32) 预分配，减少扩容（§1.3） | ✅ 已优化 |
| **perf_hooks/mod.zig** | ~~g_entries initCapacity(0)~~ | 已用 initCapacity(64) 预分配（§1.3） | ✅ 已优化 |
| **esm_loader/mod.zig** | ~~imports/named_exports/body/dep_indices 初始容量小~~ | 已用 ArenaAllocator 跑整图构建与执行、一次释放；parseModule/loadOneModule/topologicalOrder 已 initCapacity(8)（§1.3） | ✅ 已优化 |

---

## 2. Comptime 与 SIMD（§2.1–§2.4）

### 2.1 热路径协议/字符串解析（SIMD 或 comptime）

| 文件 | 现状 | 建议 |
|------|------|------|
| **server/parse.zig** | ~~getHeader 仅 splitScalar 逐行~~ | 已为 connection/upgrade/content-length/accept-encoding/transfer-encoding/sec-websocket-key 增加单次扫描快路径 getHeaderByKnownName（§2.1） | ✅ 已优化 |
| **server/parse.zig** | `indexOfCrLfCrLf` 已用 `io_core.simd_scan.indexOfCrLfCrLf` | ✅ 已优化 |
| **server/parse.zig** | ~~chooseAcceptEncoding/clientWantsClose/transferEncodingChunked 逐字节比较~~ | 已用 comptime 常量 + std.ascii.eqlIgnoreCase | ✅ 已优化 |
| **server/request_js.zig** | ~~逐行 splitScalar + indexOf(": ")~~ | 已改用 parse.iterHeaderLines 统一头部遍历，与 parse 策略一致（§2.1） | ✅ 已优化 |
| **net/mod.zig** | ~~`std.mem.eql(u8, event, "data")` 等~~ | 已用 `socketEventToPropNameZ` 按 event.len switch + eql，并复用减少 JSC 字符串创建 | ✅ 已优化 |
| **permissions/mod.zig** | ~~一连串 eql(scope, "fs.read") 等~~ | 已改为按 scope.len switch + 固定串比较（§2.1） | ✅ 已优化 |
| **dns/mod.zig** | ~~`std.mem.eql(u8, rrtype, "A")`/`"AAAA"`~~ | 已按 rrtype.len switch 再 eql（§2.1） | ✅ 已优化 |
| **crond/mod.zig** | ~~parseField 逐字符 indexOf/迭代~~ | 已用 indexOfScalar 判 '-'，单值无逗号时直接 parseUnsigned 避免 splitScalar（§2.1） | ✅ 已优化 |
| **websocket_client/mod.zig** | ~~两次 indexOf 校验 Sec-WebSocket-Accept~~ | 已用 parse.getHeader(head, "sec-websocket-accept") 单次扫描 + eql（§2.1） | ✅ 已优化 |

### 2.2 运行时 os 判断（改为 comptime）

| 文件 | 现状 | 建议 | 状态 |
|------|------|------|------|
| **server/response.zig** | ~~`if (builtin.os.tag == .linux or ... or .windows)`~~ | 已抽成 `sendfile_platform_ok`、`use_writev_for_body` 顶层常量 | ✅ 已优化 |
| **net/mod.zig** | ~~`if (builtin.os.tag == .windows)`~~ | 已用 `const is_windows` 再使用 | ✅ 已优化 |
| **dgram/mod.zig** | ~~`if (builtin.os.tag == .windows) return` 等~~ | 已用 `const is_windows` 再使用 | ✅ 已优化 |
| **path/mod.zig** | ~~多处 `if (builtin.os.tag == .windows)`~~ | 已用 `is_windows`、`path_sep`、`path_delimiter` 顶层常量 | ✅ 已优化 |
| **server/constants.zig** | `use_io_uring`/`use_epoll`/`use_kqueue` 已为 comptime 常量 | 已符合 §2.2 | ✅ 已符合 §2.2 |

---

## 3. 零拷贝与 I/O（§1.6 Buffer 继承、§3.4 零拷贝）

### 3.1 拷贝可消除处

| 文件 | 现状 | 建议 |
|------|------|------|
| **buffer/mod.zig** | ~~`Buffer.from(TypedArray)` 用 dupe 再 NoCopy~~ | 已支持 `Buffer.from(ta, { copy: false })` 零拷贝引用原 backing store；约定使用期间须保持原 TypedArray 引用（§3.1） | ✅ 已优化 |
| **buffer/mod.zig** | ~~类数组逐元素读再 alloc~~ | 已对 len≤256 用栈缓冲逐元素读再 dupe 交 JSC（§3.1） | ✅ 已优化 |
| **server/parse.zig** | ~~tryParseHeadersFromBuffer 里 dupe(head_only)~~ | **parseHttpRequest 已改为内部调用 tryParseHeadersFromBufferZeroCopy**，头部零拷贝，仅 body 用 allocator | ✅ 已优化 |
| **dgram/mod.zig** | ~~池 32 槽易满走 makeMessageBufferCopy~~ | 已扩大 DGRAM_RECV_POOL_SIZE 至 64，减少拷贝路径（§3.1） | ✅ 已优化 |
| **fs/mod.zig** | 大文件 readSync 已用 `mapFileReadOnly` + NoCopy；小文件/非 Buffer 路径仍有 dupe | copySync 小文件已改为 **std.fs.copyFileAbsolute**，由内核 copy_file_range/sendfile 等实现（§3.1/§5） | ✅ 已优化 |

### 3.2 已符合零拷贝的设计

| 模块 | 说明 |
|------|------|
| **server/response.zig** | 已用 `io_core.sendFile`（含 Windows TransmitFile）；非支持平台 64KB read+write 回退 |
| **fs/mod.zig** | 大文件 readSync/copySync 已 mmap；异步 read/write 已 AsyncFileIO |
| **dgram/mod.zig** | 已用 RingBuffer + recv 池、NoCopy 交付 message Buffer |

---

## 4. 锁与共享状态（§3.5、§3.6）

| 文件 | 现状 | 建议 |
|------|------|------|
| **readline/mod.zig** | ~~每 chunk 持锁期间 clone 整表~~ | 已缩短持锁：≤32 个 interface 时栈拷贝后立即 unlock，>32 才锁内 clone（§4） | ✅ 已优化 |
| **net/mod.zig** | ~~drain 持锁期间执行全部回调~~ | 已缩短持锁：drainPendingConnects 仅锁内移入 taken，回调在锁外执行（§4） | ✅ 已优化 |
| **dns/mod.zig** | ~~drain 持锁期间执行全部回调~~ | 已缩短持锁：drainPendingDns 仅锁内移入 taken，回调在锁外执行（§4） | ✅ 已优化 |
| **require/mod.zig** | 模块缓存 `g_cache` 单次 run 串行使用 | 若未来多线程 run 需考虑锁或 per-context cache |

---

## 5. I/O 与平台（§3.1、§4）

| 项目 | 现状 | 建议 |
|------|------|------|
| **server** | 已按平台用 io_uring/epoll/kqueue/IOCP（constants + state） | ✅ 已平台特化 |
| **server/response.zig** | 非 chunked 且非 Windows 时 writev 合并头+体（L309–324） | ✅ 已优化；Windows 未用 TransmitFile 时仍两次 write，可确认 io_core 对「头+文件体」是否有合并封装 |
| **fs copySync 小文件** | ~~readToEndAlloc + writeAll~~ | 已用 std.fs.copyFileAbsolute，内核零拷贝（§3.1/§5） | ✅ 已优化 |
| **server/parse.zig** | ~~`parseHttpRequest` 内多次 reader.read~~ | 已新增 `parseHttpRequestFromSlice(allocator, data, config)`，供上层已提供整块请求数据时零拷贝解析；chunked 仍用 parseHttpRequest（§5） | ✅ 已优化 |

---

## 6. 优先级与实施顺序（对齐规范「压榨指南」）

| 优先级 | 类别 | 内容 | 说明 |
|--------|------|------|------|
| **P0** | 内存 | **大栈 256KB/64KB 改为池或堆** | ✅ 已优化：module、server/mod、connection、step_plain/step_tls、response 回退 buf 均已堆分配 |
| **P0** | 内存 | **显式 allocator** | ✅ perf_hooks 已 initPerfStore(allocator)；require/readline 及 current_allocator 收敛可继续 |
| **P1** | 零拷贝 | **热路径用 tryParseHeadersFromBufferZeroCopy** | ✅ 已优化：parseHttpRequest 内部已用 ZeroCopy，阻塞路径也零拷贝 |
| **P1** | SIMD/comptime | **parse getHeader / accept-encoding / connection / chunked** | ✅ 已做：getHeader 常用头名单次扫描快路径；permissions/parse 常量、net/dns 已优化 |
| **P2** | 集合 | **conn_state / step 的 Header 列表** | ✅ H2 已用 MAX_H2_HEADERS 封顶 + decodeHpackBlockCapped，单次分配无扩容 |
| **P2** | 锁 | **readline、net、dns 的全局 Mutex** | ✅ readline 栈拷贝+早解锁；net/dns drain 锁内仅移出、回调锁外 |
| **P3** | 零拷贝 | **Buffer.from(TypedArray) 直接 NoCopy** | ✅ 已支持 copy: false 可选零拷贝 |
| **P3** | I/O | **fs copySync 小文件** | ✅ 已用 std.fs.copyFileAbsolute（内核 copy_file_range/sendfile） |

---

## 7. 小结

- **已做得较好的**：io_core 平台分派、simd_scan 头部边界、sendFile/TransmitFile、fs 大文件 mmap、AsyncFileIO、dgram RingBuffer+池、server constants 的 comptime。
- **优先改的**：大栈 buffer 改为池/堆（防爆栈）、显式 allocator 收敛、热路径零拷贝解析、热路径字符串/comptime 与 SIMD。
- **中期**：ArrayList/SoA/BoundedArray、锁与 per-thread 结构。
- **后期**：Buffer.from 零拷贝（小文件 copySync 已用 copyFileAbsolute）。

---

## 8. 剩余项：可优化性与性能收益

| 项 | 能优化吗 | 性能提升 | 说明 |
|----|----------|----------|------|
| **§1.1 显式 allocator（tls/module/http/crond/async/text_encoding/spawn/run）** | ~~能~~ | **很小** | ✅ 已优化：tls/module/http/crond/async_context/text_encoding 与 system(spawn/run/exec/fork) 均已 getExports/register 注入 allocator，回调内优先使用；engine/shu、bindings 传 allocator。 |
| **§1.3 esm_loader Arena + 固定容量** | ~~能~~ | **有** | ✅ 已优化：runAsEsmModule 用 ArenaAllocator 构建与执行整图，initCapacity(8) 用于 imports/named_exports/dep_indices/modules/order。 |
| **§3.1 Buffer.from(TypedArray) 直接 NoCopy** | ~~能（需约定）~~ | **有** | ✅ 已优化：支持 `Buffer.from(ta, { copy: false })`，约定使用期间保持原 TypedArray 引用。 |
| **§5 parseHttpRequest 多次 reader.read** | ~~依赖上层~~ | 有（若上层改） | ✅ 已优化：新增 `parseHttpRequestFromSlice`，上层已提供整块数据时可零拷贝解析（chunked 仍用流式 parseHttpRequest）。 |

以上均按「全路径以性能优先、无例外」的规范做排查与建议；具体改动需结合测试与 profiling 验证。
