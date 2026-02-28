# server/mod.zig 按功能模块拆分方案

当前 `mod.zig` 约 4500 行，建议按功能拆成多个子模块，单文件目标约 800～1200 行，便于维护与协作。

---

## 一、当前结构概览（行号与职责）

| 行号区间       | 大致行数 | 职责 |
|----------------|----------|------|
| 1–445          | ~445     | 入口（getExports/register）、serverCallback（解析 options、listen、创建 state、setImmediate 驱动） |
| 447–591        | ~145     | updateStateFromOptions、serverStateCleanup、doListen |
| 593–1877       | **~1285**| **serverTickCallback**：stop/restart/signal、cluster、**明文 io_core tick**、**TLS io_core tick**、**poll/iocp fallback**、runLoop 节流、setImmediate 续驱 |
| 1878–1944      | ~67      | serverStopCallback、serverReloadCallback、serverRestartCallback |
| 1945–2072      | ~128     | makeListenInfoObject、WebSocket JS 回调（wsOnMessage/wsOnError/wsSend）、makeWebSocketObject、setTcpNoDelay |
| 2073–2120      | ~48      | DEFAULT_* 常量 |
| 2120–2340      | ~220     | ServerState、PlainMuxState、H2StreamEntry、PlainConnState |
| 2341–2535      | ~195     | TlsConnState |
| 2536–2725      | ~190     | setNonBlocking、muxPollerCreate/Add/UpdateWrite/Remove、muxIoUringWait、muxPollerWait、MuxStepResult、IocpStepOpts |
| 2726–3282      | **~557** | **stepPlainConn**（明文连接状态机一步） |
| 3283–3832      | **~550** | **stepTlsConn**（TLS 连接状态机一步） |
| 3833–3873      | ~41      | PreReadReader、PreReadTlsStream |
| 3874–4036      | ~163     | handleConnectionPlain |
| 4038–4194      | ~157     | handleConnection（通用阻塞处理）、isH2cUpgrade |
| 4196–4335      | ~140     | handleH2Connection |
| 4337–4496      | ~160     | sendH2Response、sendH2Error、sendH2ResponseToBuffer |

结论：单文件膨胀主要来自三块——**tick 循环**（~1285 行）、**stepPlainConn**（~557 行）、**stepTlsConn**（~550 行），其余为状态定义、mux 工具、handoff 处理等。

---

## 二、拆分目标与依赖关系

- 单文件目标：**约 800～1200 行**，便于阅读和 review。
- Zig 不允许循环 import，需保持 **DAG**：下层不依赖上层，上层可依赖下层。
- 已有子模块：`types`、`parse`、`response`、`request_js`、`options`、`http2`、`websocket`、`iocp` 等，拆分时尽量只从 `mod.zig` 抽离，少动现有模块。

建议的 **层级**（下层 → 上层）：

```
第 0 层（无 server 内部依赖）
  types.zig, parse.zig, response.zig, options.zig, request_js.zig, http2.zig, websocket.zig, iocp.zig, io_core

第 1 层（仅依赖第 0 层 + 少量 build_options）
  constants.zig      — DEFAULT_* 等常量
  conn_state.zig     — 连接/多路复用相关状态与枚举（见下）

第 2 层（依赖第 0、1 层）
  state.zig          — ServerState、PlainMuxState（若不再放 mod 则放这里）
  mux.zig            — muxPoller*、muxIoUringWait、muxPollerWait、setNonBlocking、setTcpNoDelay
  ws_glue.zig        — WebSocket 与 JS 的胶水（wsWriteNet/Tls、wsReadNet/Tls、wsOnMessage/wsOnError/wsSend、makeWebSocketObject 等）

第 3 层（依赖第 0–2 层）
  step_plain.zig     — MuxStepResult、IocpStepOpts、stepPlainConn
  step_tls.zig       — stepTlsConn
  connection.zig     — PreReadReader、PreReadTlsStream、handleConnectionPlain、handleConnection、isH2cUpgrade、handleH2Connection、sendH2* 等

第 4 层（依赖第 0–3 层）
  tick.zig           — serverTickCallback 的完整实现（io_core 明文/TLS、poll/iocp fallback、runLoop、setImmediate）

第 5 层（入口，依赖上述全部）
  mod.zig            — getExports、register、serverCallback、updateStateFromOptions、serverStateCleanup、doListen、stop/reload/restart、makeListenInfoObject；tick 只负责调用 tick.run(state)
```

---

## 三、建议拆成的文件与预估行数

| 文件 | 内容摘要 | 预估行数 |
|------|----------|----------|
| **constants.zig** | DEFAULT_*、WS_READ_BUF_SIZE、use_iocp_full、use_iocp_full_tls、IocpOpCtx 等 | ~80 |
| **conn_state.zig** | MuxConnPhase、H2StreamEntry、PlainConnState、TlsPendingEntry、TlsConnState、MuxStepResult、IocpStepOpts | ~450 |
| **state.zig** | ServerState、PlainMuxState（及二者 init/deinit 若可独立） | ~220 |
| **mux.zig** | setNonBlocking、setTcpNoDelay、muxPollerCreate/Add/UpdateWrite/Remove、muxIoUringWait、muxPollerWait | ~200 |
| **ws_glue.zig** | wsWriteNet/Tls、wsReadNet/Tls、WsMessageCbContext、WsErrorCbContext、wsOnMessageCallback、wsOnErrorCallback、wsSendCallback、makeWebSocketObject | ~220 |
| **step_plain.zig** | stepPlainConn 全文 | ~560 |
| **step_tls.zig** | stepTlsConn 全文 | ~550 |
| **connection.zig** | PreReadReader、PreReadTlsStream、handleConnectionPlain、handleConnection、isH2cUpgrade、handleH2Connection、sendH2Response、sendH2Error、sendH2ResponseToBuffer | ~750 |
| **tick.zig** | serverTickCallback 整段（stop/restart/signal、cluster、io_core 明文、io_core TLS、poll/iocp fallback、runLoop、setImmediate） | ~1290 |
| **mod.zig** | 入口与生命周期：getExports、register、serverCallback、updateStateFromOptions、serverStateCleanup、doListen、serverStop/Reload/RestartCallback、makeListenInfoObject；g_ws_send_registry、g_server_state；调用 tick.run(state) | ~550 |

合计约 4870 行（含少量重复的 import/注释），单文件均落在 80～1290 行；若希望 tick 也控制在 ~1000 行内，可再拆：

- **tick.zig**：总控（stop/restart/signal、cluster、runLoop、setImmediate）+ 调用下层。
- **tick_io_core.zig**：明文 io_core 分支 + TLS io_core 分支（约 500+ 行）。
- **tick_fallback.zig**：poll/iocp fallback 分支（约 400 行）。

---

## 四、实施顺序建议（降低风险）

1. **constants.zig**：抽出常量与 IocpOpCtx，mod 与 tick 等改为从 constants 引用。无行为变化，易回滚。
2. **mux.zig**：抽出 mux 与 setNonBlocking/setTcpNoDelay，mod 中 `const mux = @import("mux.zig");`，tick 里改称 `mux.muxPollerWait` 等。
3. **conn_state.zig**：抽出 PlainConnState、TlsConnState、TlsPendingEntry、H2StreamEntry、MuxStepResult、IocpStepOpts、MuxConnPhase。step_plain/step_tls 和 tick 都依赖这些类型，因此先抽状态最稳。
4. **state.zig**（可选）：若希望 mod 更薄，再把 ServerState、PlainMuxState 迁到 state.zig；state 依赖 conn_state、constants。
5. **step_plain.zig** / **step_tls.zig**：整块搬出 stepPlainConn / stepTlsConn，依赖 conn_state、state、types、parse、response、http2、ws、request_js 等。
6. **connection.zig**：抽出 PreRead*、handleConnection*、handleH2Connection、sendH2*、isH2cUpgrade。
7. **ws_glue.zig**：抽出 WebSocket JS 胶水，注意 g_ws_send_registry 的可见性（可保留在 mod 中由 ws_glue 通过参数或 small 接口使用）。
8. **tick.zig**：把 serverTickCallback 实现迁出，mod 仅保留「取 state → 调 tick.run(state)」；若单文件仍超 1000 行，再拆 tick_io_core / tick_fallback。

每步完成后跑测试与手动回归（明文/TLS、io_core/poll/iocp、reload/restart、WebSocket、h2c）。

---

## 五、注意事项

- **全局与回调**：`g_server_state`、`g_ws_send_registry`、`g_next_ws_id` 建议仍放在 mod.zig，通过参数传入 tick/ws_glue，或提供 `server/set_globals.zig` 式的小接口，避免子模块直接握有全局。
- **build_options / builtin**：conn_state、mux、tick 等会用到 `use_iocp_full`、`use_iocp_full_tls`、`use_io_uring` 等，这些可放在 constants.zig，由各子模块 import。
- **TlsConnState / TlsPendingEntry**：仅在 `build_options.have_tls` 时存在字段差异，拆到 conn_state.zig 时保留现有 `if (build_options.have_tls)` 条件编译即可。
- **step 与 handoff**：stepPlainConn/stepTlsConn 返回 MuxStepResult，tick 根据结果调 handleConnectionPlain、handleConnection、handleH2Connection；connection.zig 提供这些 handoff 入口，tick 只做分支与调用，不内联大段逻辑。

按上述顺序拆分后，**mod.zig 可收敛到约 550 行**，其余分布在 8～10 个文件中，单文件约 **80～1200 行**，tick 若再拆则最大约 **1000 行**，便于后续维护与「按功能模块」阅读。
