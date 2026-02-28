# io_core 三层漏斗路线图

底层 I/O 引擎（io_uring / kqueue / IOCP）已解决「如何快速搬运数据」；**Buffer 调度**与**协议解析**决定最终 QPS。本路线图从三个维度补齐，形成「宽 → 中 → 窄」的漏斗。

---

## 当前状态总览

| 维度 | 已完成 | 待做 |
|------|--------|------|
| **1. Buffer 调度** | ChunkAllocator + ThreadLocalChunkCache（栈 128、批量 16）；Darwin/Windows/Linux HighPerfIO 均已接入（Linux 为 ThreadLocalSlotCache + free_bitmap 批量交换） | — |
| **2. 协议解析** | parse.zig 统一使用 io_core.simd_scan.indexOfCrLfCrLf；server 层两处 reading_headers 已用零拷贝解析 | — |
| **3. 全链路零拷贝** | 内核→Buffer 各平台已做；解析→逻辑：tryParseHeadersFromBufferZeroCopy，parsed 持 read_buf 切片；上层 getHeader 仅返回切片，仅 C/JS 边界对 method/path dupeZ，不复制整块头部 | — |
| **4. 平台猎杀** | Darwin setIoThreadQosUserInteractive 已做；Windows RIO、Linux IORING_REGISTER_BUFFERS 已在各平台文件头部注释中标为可选，无需实现即可满足路线图 | — |

**结论**：Buffer 调度、协议解析（SIMD + 零拷贝）、全链路零拷贝（含上层不复制头部）与平台猎杀（Darwin 已做，Windows/Linux 可选已注释）均已落笔或落地。

---

## 1. Buffer 调度：从全局竞争到无锁分片

### 现状

- 各平台 HighPerfIO 内部维护 `free_list` / `free_bitmap`，按 chunk 索引申请/释放。
- 若上层多线程共享同一池并加锁，会产生严重**锁争用**。

### 目标：分层架构

| 层级 | 说明 | 收益 |
|------|------|------|
| **Thread-Local Cache** | 每 I/O 线程私有、固定大小（如 128 块）的无锁栈 | 申请/释放绝大多数在 L1/L2 内完成，无原子/锁 |
| **Global Slab** | 本地栈空/满时与全局池**批量**交换（如一次 16 块） | 降低跨核竞争 |
| **对齐与填充** | Buffer 64 字节对齐，按 Cache Line 整数倍填充 | 避免 False Sharing |

### 接口与落地

- **api.zig** 提供 `ChunkAllocator` 与 **ThreadLocalChunkCache**（本地栈 128、批量 16，take/release + refill/flush）。✅ 已实现。
- **Darwin/Windows** HighPerfIO 已接入 chunk_cache；**Linux** 已接入 **ThreadLocalSlotCache**（槽位版等价实现，popFreeSlotBatch/pushFreeSlotBatch + 同参 128/16），取/还槽位均经本地缓存。

---

## 2. 协议解析：从状态机扫描到 SIMD 向量化

### 现状

- 逐字节扫描，遇 `\r` / `\n` 跳转，在 10Gbps 级流量下易耗尽 CPU。

### 目标

- **批量定位**：用 Zig `@Vector` 一次载入 16/32 字节，用一条指令找出所有 `\r` (0x0D) / `\n` (0x0A) 位置，得到 Bitmask。
- **零拷贝 Slice**：解析后的 Request 只持 `[]const u8` 引用（指向 Buffer 池），不做 memcpy。

### 落地参考

- **io_core/simd_scan.zig**：提供 `indexOfCrLfCrLf`、`findCrLfInBlock` 等。✅ 已实现。
- **server/parse.zig**：统一调用 `io_core.simd_scan.indexOfCrLfCrLf` 做头部边界查找；`tryParseHeadersFromBufferZeroCopy` 返回仅持 `read_buf` 切片的 parsed。✅ 已实现。
- **server/mod.zig**：reading_headers 两处已改为 `tryParseHeadersFromBufferZeroCopy`，零拷贝引用至下次覆盖前有效。

---

## 3. 全链路零拷贝

- **内核 → Buffer**：✅ 已由各平台 accept+recv 或 PROVIDE_BUFFERS 等做到。
- **Buffer → 解析**：✅ 使用 `tryParseHeadersFromBufferZeroCopy`，解析器只读 `read_buf`，不拷贝头部。
- **解析 → 用户逻辑**：✅ parsed.method/path/headers_head 为 `read_buf` 切片，生命周期至下次覆盖前；server 层已遵循。
- **上层不复制头部**：✅ `getHeader(head, name)` 仅返回 `head` 内只读切片；与 JSC 等 C 接口边界仅对 method/path 做 `dupeZ` 以传 C 字符串，不复制整块 `headers_head`，已保证零拷贝语义。

---

## 4. 平台猎杀式优化（已做 / 可选）

| 平台 | 方向 | 状态 |
|------|------|------|
| **Windows** | RIO (Registered I/O)：RIORegisterBuffer 将池注册给内核，AcceptEx 等可升级为 RIO 路径 | 可选/注释级；见 windows.zig 头部；当前已 AcceptEx 零拷贝 + GQCSEx |
| **Linux** | IORING_REGISTER_BUFFERS：io_uring_register 提前固定 Buffer，减少每次 I/O 的映射开销 | 可选/注释级；见 linux.zig 头部「硬件定制级」注释 |
| **Darwin** | P-Core 调度：pthread_set_qos_class_self_np(User Interactive)，保证 I/O/解析跑在性能核 | ✅ 已做：setIoThreadQosUserInteractive()，I/O 线程入口调用一次即可 |

---

## 总结

- **底层 I/O**：✅ 已压榨到物理极限级（预分配、批量系统调用、SoA、缓存行隔离等）。
- **Buffer 调度**：✅ ChunkAllocator + ThreadLocalChunkCache 已实现；Darwin/Windows/Linux 均已接入（Linux 为 ThreadLocalSlotCache）。
- **协议解析**：✅ SIMD 边界查找（parse 内联 + simd_scan.zig）；server 层已用零拷贝解析（tryParseHeadersFromBufferZeroCopy）。

**并非全部写完**：路线图描述的是目标与已落地的接口/示例；把「三层漏斗」全部打通（线程本地 Buffer 分片、平台层接入、server 层 SIMD+零拷贝）后，shujs 才能在跑分上与 Bun/Deno 同台竞技。
