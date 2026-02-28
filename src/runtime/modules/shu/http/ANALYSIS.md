# shu:http / shu:https / shu:tls 与 Shu.server 关系分析

## 结论：**能直接调用 Shu.server**

- **Shu.server(options)** 已由 engine/shu/mod.zig 挂到 `global.Shu.server`，接收 `{ port, host, fetch/handler, tls?, ... }`，返回 `{ stop, reload, restart }`。
- **Bun.serve** 已通过「从 global 取 Shu.server → 构造 options → 调用 Shu.server(options)」实现，说明用同一方式实现 node 风格 API 可行。

## 对应关系

| Node API | 本实现方式 |
|----------|------------|
| `http.createServer([options], requestListener)` | 返回带 `listen(port, [host], [cb])` 的对象；`listen` 内构造 `{ port, host, fetch: requestListener }` 并调用 **Shu.server(opts)**，把返回的 stop/reload/restart 合并到该对象上。 |
| `https.createServer(options, requestListener)` | 同上，options 中若有 `key`/`cert`（文件路径），则构造 `{ ...opts, tls: { cert, key }, fetch: requestListener }` 再调 **Shu.server**。 |
| `tls.createServer(options, secureConnectionListener)` | 与 https 类似，用 **Shu.server** 的 `options.tls` 创建 HTTPS 服务；客户端 `tls.connect` 等可先占位。 |

## 实现要点

1. **shu:http**：`createServer` 返回的 server 对象存 `_requestListener`，`listen(port, host, callback)` 时从 `global.Shu.server` 取函数，用 `{ port, host, fetch: _requestListener }` 调用，得到的结果（含 stop/reload/restart）合并回 server，并调用 callback（若有）。
2. **shu:https**：同 http，但 `createServer(options, requestListener)` 的 options 里取 `key`、`cert` 填到 `Shu.server` 的 `options.tls`。
3. **shu:tls**：`createServer` 与 https 一致（委托 Shu.server + tls）；`connect` 等客户端 API 暂用 stub 或占位。

这样 **不重复实现** HTTP 服务端逻辑，仅做 Node 风格 API 到 Shu.server 的薄封装。
