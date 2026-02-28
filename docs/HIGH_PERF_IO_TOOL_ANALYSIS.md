# 高性能 I/O 工具层分析

本文档分析：**能否将三大平台（Linux / macOS / Windows）的高性能 I/O 操作封装成统一工具层，供运行时调用，从而省去重复代码**，同时不违背「每平台内核特化、不做通用实现」的性能规范。

---

## 1. 目标与结论

### 1.1 目标

- 将 io_uring（Linux）、kqueue + fcopyfile（macOS）、IOCP/RIO + TransmitFile（Windows）以及 Buffer 继承、零拷贝文件发送、Thread-per-Core 等能力，**以统一 API 暴露**。
- **调用方**（如 shujs 的 HTTP、net、fs 等）只依赖这一套 API，不手写各平台分支。
- **实现侧**：每个平台仍是**独立、特化的底层驱动**（直接 syscall / 平台 API），无「一份通用代码走天下」的折中实现。

### 1.2 结论

**可以，且建议做。** 做法是：**统一 API + 编译期分派（Comptime Dispatch）**。

- **统一的是「接口」与「调用方式」**：同一套函数名、参数语义、错误约定，文档与版本单一。
- **不统一的是「实现」**：在 Zig 中按 `std.builtin.os.tag` 在**编译期**选择对应平台实现文件，最终二进制里**只包含当前平台代码**，无运行时 `if (linux) ... else if (windows) ...`，无性能损失。
- 因此：**重复消除的是「业务侧重复调用逻辑」和「接口设计/文档的分散」**；**不产生**跨平台的通用慢路径。

---

## 2. 与「不做通用代码」的关系

规范要求：针对每个系统的内核 I/O 模型编写**特化的底层驱动**，不做通用代码。

| 概念 | 说明 |
|------|------|
| **通用代码（规范所禁止）** | 一份实现用运行时分支或抽象层同时服务多平台，导致各平台都走不到最优路径（如用 epoll 抽象同时服务 Linux/Mac，Mac 无法用足 kqueue 特性）。 |
| **工具层（本分析建议）** | 对外是**一套 API**，对内是**多个互不共享的实现**（linux.zig / darwin.zig / windows.zig），编译时只选当前 OS 的那一份。每个平台仍是 100% 特化，只是**入口统一**。 |

因此：工具层是**接口与分派层**，不是「通用实现层」；规范禁止的是通用*实现*，不禁止**接口统一 + 编译期分派**。

---

## 3. 工具层职责与边界

### 3.1 建议由工具层提供的能力（统一 API）

| 能力 | 说明 | Linux | macOS | Windows |
|------|------|-------|-------|---------|
| **网络 I/O 环** | 提交/收割完成项，每核一环 | io_uring | kqueue | IOCP/RIO |
| **Fixed Buffer 读** | 内核直接写入预注册内存 | IORING_OP_READ_FIXED | 无等价，回退预分配 buffer + kqueue 读 | RIO 或 Overlapped + 预分配 |
| **Provide Buffers** | 内核从池中取 buffer 填数据，accept+read 一次完成 | IORING_OP_PROVIDE_BUFFERS | 无，回退 accept + read | 无，回退 AcceptEx + 读 |
| **文件 → 网络零拷贝** | 不经过用户态拷贝 | sendfile / copy_file_range | sendfile / fcopyfile | TransmitFile |
| **Buffer 池（64-byte 对齐）** | 供内核或用户态填数据，再借给 JSC | 与 io_uring 注册一致 | 预分配池 + kqueue | 预分配池 + Overlapped/RIO |
| **mmap 文件 → ArrayBuffer** | 大文件只读映射，包装给 JSC | mmap | mmap | CreateFileMapping + MapViewOfFile |
| **Thread-per-Core 调度** | N 核 N 线程、绑核、每线程独立环 | setaffinity + 每线程 io_uring | setaffinity + 每线程 kqueue | SetThreadAffinityMask + 每线程 IOCP 工作线程 |
| **无锁 Ring Buffer** | 跨线程传递任务/描述符 | 平台无关，可共用实现 | 同上 | 同上 |

上表中「无等价」或「回退」的项，在对应平台实现里用该平台**次优但仍特化**的方式实现（例如 Mac 用预分配 buffer + kqueue，而不是硬塞一个 io_uring 抽象）。

### 3.2 建议不放入工具层的内容

- **协议解析**（HTTP、WebSocket、JSON）：与平台无关，留在上层（如 shujs 的 http/net 模块），只消费工具层提供的「已就绪的 buffer」或「零拷贝发送」。
- **JSC 绑定细节**（如何构造 ArrayBuffer、何时 detach）：可由工具层提供「返回 64-byte 对齐 + 长度」的句柄，由运行时层负责调用 JSC 的 NoCopy API；或工具层在单独模块里依赖 JSC 做薄封装，避免把 JSC 塞进所有平台路径。
- **业务路由、负载均衡**：由运行时在「Thread-per-Core + 无锁 Ring」之上自己实现。

---

## 4. 实现形态：Comptime 分派

### 4.1 目录与编译方式

建议结构（仅示意，不要求立刻落代码）：

```
runtime/
  high_perf_io/           # 或 io_core / platform_io 等
    mod.zig               # 对外唯一入口：声明 API，按 os.tag 导出对应实现
    api.zig               # 公共类型、错误集、回调类型（平台无关）
    linux.zig             # Linux：io_uring、sendfile、O_DIRECT、affinity
    darwin.zig            # macOS：kqueue、fcopyfile、Mach、affinity
    windows.zig           # Windows：IOCP、RIO、TransmitFile、affinity
    ring_buffer.zig       # 无锁环形队列（平台无关，可被三端共用）
```

- **mod.zig**：根据 `@import("builtin").os.tag` 选择 `linux` / `darwin` / `windows`，并 re-export 该模块的 public 符号；对外只 `@import("high_perf_io")` 即可得到当前平台实现。
- 编译时：若目标为 `linux`，则 **darwin.zig / windows.zig 不会被编译进当前目标**，无额外分支与体积。

### 4.2 API 形态示例（仅说明思路）

以下为**概念级** API，具体签名以实际设计为准：

- `HighPerfIO.init(allocator, options) !HighPerfIO`  
  初始化当前平台的 I/O 子系统（如创建 io_uring 环、或 kqueue、或 IOCP）。
- `HighPerfIO.registerBufferPool(pool) void`  
  向内核注册 buffer 池（Linux: PROVIDE_BUFFERS / Fixed；Mac/Win: 仅内部记录，供后续读用）。
- `HighPerfIO.submitAcceptWithBuffer(fd, user_data) void`  
  提交「接受连接且数据直接入池中 buffer」的请求（Linux: accept + read 合并；Mac/Win: 等价或回退为 accept + 一次 read）。
- `HighPerfIO.pollCompletions(timeout_ns) []Completion`  
  收割已完成项，返回带 user_data、buffer 指针、字节数的完成列表。
- `HighPerfIO.sendFile(out_fd, in_fd, offset, count) !void`  
  文件 → 网络零拷贝（内部：Linux sendfile、Mac fcopyfile/sendfile、Win TransmitFile）。
- `BufferPool.allocAligned(allocator, size_64_align) !*BufferPool`  
  分配 64-byte 对齐池，供注册或直接写；可再提供 `wrapAsJSCArrayBufferNoCopy(ptr, len)` 的**说明**或薄封装（实际 JSC 调用可在运行时层）。
- `ThreadPerCore.run(allocator, num_workers, worker_fn) void`  
  启动 N 个线程、绑核、每线程一个 HighPerfIO 实例（或每线程独立环）。

同一套名字与语义，三份实现；调用方不关心当前是哪个 OS。

---

## 5. 省去的重复与保留的特化

### 5.1 能省去的重复

- **调用点**：HTTP 服务、文件服务、WebSocket 等只写一次「调工具层 sendFile / submitRead / pollCompletions」，不再在每个模块里 `if (linux) { io_uring_xxx } else if (mac) { kqueue_xxx }`。
- **接口约定与文档**：参数含义、错误码、生命周期（如 buffer 何时可回收）集中在一处维护。
- **平台无关的辅助逻辑**：如无锁 Ring Buffer、对齐计算、部分统计逻辑，可放在工具层共用文件中，三端复用同一实现。

### 5.2 必须保留的特化

- **每个平台一个完整实现文件**：linux.zig 只含 Linux syscall/io_uring；darwin.zig 只含 kqueue/Mach/GCD 等；windows.zig 只含 IOCP/RIO/Win32。彼此**不**互相引用实现细节。
- **平台专属调优**：如 Linux 的 O_DIRECT、io_uring 轮询模式；Mac 的 P 核绑定、fcopyfile 使用场景；Windows 的 RIO 与 TransmitFile 的详细参数，都留在各自文件内，不抽象成「通用选项」。

---

## 6. 依赖与实施顺序建议

| 步骤 | 内容 | 说明 |
|------|------|------|
| 1 | 定义 api.zig | 公共类型、错误集、回调形式；不依赖任何平台。 |
| 2 | 先实现单平台（如 Linux）| 在 linux.zig 中实现 io_uring + sendfile + 简单 Buffer 池，mod.zig 仅导出 Linux，验证 API 形状是否适合业务。 |
| 3 | 补 macOS / Windows | 各一份 darwin.zig / windows.zig，实现同一 API；mod.zig 按 os.tag 分派。 |
| 4 | 引入 Thread-per-Core 与 Ring | 在工具层或运行时层提供 ThreadPerCore + 无锁 Ring，与各平台「每线程一环」对接。 |
| 5 | Buffer 继承与 JSC | 在 Buffer 池与 JSC NoCopy ArrayBuffer 之间约定所有权与 detach 时机，可由运行时层或工具层薄封装完成。 |

---

## 7. 小结

- **可以**在 docs 外再实现一个**高性能 I/O 工具层**，供 Linux / macOS / Windows 共用**同一套调用方式**，从而减少重复代码。
- 关键是用 **Zig 的 Comptime 按 OS 分派**：统一的是 **API 与调用方**，不是实现；每个平台仍是**特化底层驱动**，符合「不做通用代码、压榨到物理极限」的目标。
- 建议将**接口与分派**放在工具层，**协议与业务**留在运行时上层；平台专属调优保留在各自实现文件中，不抽象成跨平台通用选项。
- 实施时优先定好 API 与单平台（如 Linux）实现，再补全 Mac/Windows 与 Thread-per-Core、Buffer 继承等，可控制复杂度并持续保证各平台性能。

本文档仅做分析与设计参考，不约束具体代码实现；实际模块名、路径与 API 以代码库为准。
