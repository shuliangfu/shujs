# Deno 兼容性分析（Deno.\* / deno:xxx / 全局）

目标：与 Deno 运行时**无缝兼容**，使 Deno 风格脚本（`Deno.*`、node: 与标准 Web API）可在 shu 上运行。本文档分析 **Deno 全局命名空间 Deno.xxx**、**deno: 说明符**（若有）、**全局对象与方法** 与当前 **shu:xxx** 的覆盖情况，并列出缺口。

**说明**：Deno 完整符号表见 [docs.deno.com/api/deno/all_symbols](https://docs.deno.com/api/deno/all_symbols)。下表按类别列出主要 API；类型与选项接口（如 Deno.ConnectTlsOptions）未逐条列出，实现时需对照官方文档。

---

## 1. Deno.\* 命名空间 API ↔ shu 覆盖表

Deno 将非标准 API 全部放在 **Deno** 全局对象下，无独立 `deno:xxx` 内置模块（标准库通过 JSR @std 发布）。下表按类别列出 Deno.\* 与 shu 的对应关系。

### 1.1 系统与环境

| Deno API         | 说明                            | shu 覆盖 | 对应实现/缺口                                        |
| ---------------- | ------------------------------- | -------- | ---------------------------------------------------- |
| Deno.args        | 脚本参数                        | ✅       | process.argv → shu:process                           |
| Deno.build       | 运行时构建信息 (os/arch/target) | ⚠ 部分   | process.platform/arch 可映射；需提供 Deno.build 对象 |
| Deno.cwd()       | 当前工作目录                    | ✅       | process.cwd() → shu:process                          |
| Deno.chdir(path) | 切换工作目录                    | ⚠        | 需 shu 提供 chdir 或通过 process 扩展                |
| Deno.env         | 环境变量 get/set/toObject       | ✅       | process.env → shu:process                            |
| Deno.execPath()  | 可执行文件路径                  | ⚠        | process.execPath 若有则覆盖；否则需补                |
| Deno.exit(code?) | 退出进程                        | ✅       | process.exit → shu:process                           |
| Deno.mainModule  | 主模块 URL                      | ⚠        | 需从入口 URL 暴露或占位                              |
| Deno.noColor     | 是否禁用颜色                    | ⚠        | 可占位或从 env NO_COLOR 读                           |
| Deno.version     | 运行时版本                      | ⚠        | 可暴露 shu 版本号                                    |

### 1.2 文件系统

| Deno API                               | 说明                | shu 覆盖 | 对应实现/缺口                                           |
| -------------------------------------- | ------------------- | -------- | ------------------------------------------------------- |
| Deno.readFile(path)                    | 读文件为 Uint8Array | ✅       | shu:fs readFileSync/readFile，需返回 Uint8Array 或适配  |
| Deno.readTextFile(path)                | 读文件为字符串      | ✅       | shu:fs readFileSync(encoding) / readFile                |
| Deno.writeFile(path, data)             | 写文件              | ✅       | shu:fs writeFileSync/writeFile                          |
| Deno.writeTextFile(path, data)         | 写文本文件          | ✅       | shu:fs                                                  |
| Deno.open(path, options?)              | 打开文件得 FsFile   | ⚠        | shu:fs 有 open/readSync/writeSync，需封装为 FsFile 接口 |
| Deno.close(rid)                        | 关闭资源 id         | ⚠        | 需与 open 配套的 rid 管理                               |
| Deno.ftruncate(rid, len?)              | 截断                | ⚠        | 若暴露 FsFile 需实现                                    |
| Deno.fstat(rid) / Deno.stat(path)      | 文件元信息          | ✅       | shu:fs statSync                                         |
| Deno.lstat(path)                       | 符号链接本身 stat   | ✅       | shu:fs lstatSync                                        |
| Deno.mkdir(path, options?)             | 创建目录            | ✅       | shu:fs mkdirSync/mkdir                                  |
| Deno.remove(path, options?)            | 删除文件/目录       | ✅       | shu:fs unlinkSync/rmdirSync                             |
| Deno.rename(old, new)                  | 重命名              | ✅       | shu:fs renameSync                                       |
| Deno.readDir(path)                     | 迭代目录项          | ✅       | shu:fs readdirSync/readdirWithStatsSync                 |
| Deno.chmod(path, mode) / chmodSync     | 修改权限            | ⚠        | 需 shu:fs 扩展 chmod                                    |
| Deno.chown(path, uid, gid) / chownSync | 修改属主            | ⚠        | 需 shu:fs 扩展 chown（Windows 无）                      |
| Deno.copyFile(src, dest)               | 复制文件            | ✅       | shu:fs copySync/copyFileSync                            |
| Deno.symlink(old, new, type?)          | 创建符号链接        | ✅       | shu:fs symlinkSync                                      |
| Deno.readLink(path)                    | 读符号链接目标      | ✅       | shu:fs readlinkSync                                     |
| Deno.realPath(path)                    | 解析真实路径        | ✅       | shu:fs realpathSync                                     |
| Deno.truncate(path, len?)              | 截断文件            | ✅       | shu:fs truncateSync                                     |

### 1.3 网络与 HTTP

| Deno API                   | 说明               | shu 覆盖  | 对应实现/缺口                              |
| -------------------------- | ------------------ | --------- | ------------------------------------------ | ------------------------------------------------ |
| Deno.listen(options)       | 监听 TCP           | ✅        | shu:net createServer + listen              |
| Deno.listenTls(options)    | 监听 TLS           | ✅        | shu:tls createServer                       |
| Deno.connect(options)      | TCP 连接           | ✅        | shu:net connect/createConnection           |
| Deno.connectTls(options)   | TLS 连接           | ✅        | shu:tls connect                            |
| Deno.serve(handler         | options)           | HTTP 服务 | ✅                                         | shu:server / Shu.server 或 shu:http createServer |
| Deno.serveHttp(conn)       | 底层 HTTP 连接处理 | ⚠         | 可与 shu:server 请求回调适配或占位         |
| fetch / Request / Response | 标准 fetch         | ✅        | shu:fetch + 全局 fetch                     |
| WebSocket                  | 客户端/服务端      | ✅        | shu:websocket_client、shu:server WebSocket |

### 1.4 子进程

| Deno API                             | 说明                   | shu 覆盖 | 对应实现/缺口                                          |
| ------------------------------------ | ---------------------- | -------- | ------------------------------------------------------ |
| Deno.Command                         | 创建子进程命令         | ✅       | shu:cmd exec/execSync/spawn/spawnSync 可封装为 Command |
| Deno.Command.spawn()                 | 异步 spawn             | ✅       | shu:cmd spawn                                          |
| Deno.Command.output() / outputSync() | 执行并取 stdout/stderr | ✅       | shu:cmd execSync/spawnSync                             |
| Deno.ChildProcess                    | 子进程句柄             | ✅       | 与 shu:cmd 返回对象对齐                                |

### 1.5 权限

| Deno API                        | 说明     | shu 覆盖 | 对应实现/缺口              |
| ------------------------------- | -------- | -------- | -------------------------- |
| Deno.permissions.query(opts)    | 查询权限 | ✅       | shu:permissions.has        |
| Deno.permissions.request(opts)  | 请求权限 | ✅       | shu:permissions.request    |
| Deno.permissions.revoke(opts)   | 撤销权限 | ⚠        | 若 shu 支持可扩展          |
| Deno.permissions.request() 无参 | 请求全部 | ⚠        | 与 request(scope) 对齐即可 |

### 1.6 测试与基准

| Deno API                 | 说明       | shu 覆盖 | 对应实现/缺口   |
| ------------------------ | ---------- | -------- | --------------- | ---------------------------- |
| Deno.test(name, fn       | options)   | 注册测试 | ✅              | shu:test describe/it/test    |
| Deno.test.step(name, fn) | 子步骤     | ✅       | shu:test t.step |
| Deno.bench(name, fn      | options)   | 注册基准 | ⚠               | 需 shu:test 或单独 bench API |
| Deno.BenchContext        | 基准上下文 | ⚠        | 同上            |

### 1.7 其他 Deno.\* API

| Deno API                                | 说明           | shu 覆盖 | 对应实现/缺口                                   |
| --------------------------------------- | -------------- | -------- | ----------------------------------------------- |
| Deno.resolveDns(host, type?)            | DNS 解析       | ✅       | shu:dns resolve/resolve4/resolve6               |
| Deno.addSignalListener(sig, handler)    | 信号监听       | ⚠        | 需 shu 层实现或占位                             |
| Deno.removeSignalListener(sig, handler) | 移除信号监听   | ⚠        | 同上                                            |
| Deno.kv.open(path)                      | KV 存储        | ❌       | 无对应；可占位或后续实现                        |
| Deno.Kv / Deno.AtomicOperation          | KV 原子操作    | ❌       | 同上                                            |
| Deno.bundle(entrypoints, options?)      | 打包           | ❌       | 属构建时；shu build 可另实现                    |
| Deno.CompileStream / 编译 API           | 编译 TS 等     | ⚠        | strip 已有；完整编译可选                        |
| Deno.errors.\*                          | 错误类         | ⚠        | 可提供 Deno.errors.NotFound 等与 Node/Deno 对齐 |
| Deno.stdin / stdout / stderr            | 标准流         | ⚠        | 可封装为 Reader/Writer；Bun 风格有 Bun.stdin 等 |
| Deno.readAll(reader) / readAllSync      | 读尽 Reader    | ⚠        | 若暴露 Reader 需实现                            |
| Deno.writeAll(writer, data)             | 写尽 Writer    | ⚠        | 同上                                            |
| Deno.upgradeWebSocket(req)              | 升级 WebSocket | ✅       | 可与 shu:server WebSocket 对接                  |

### 1.8 Deno.\* 补充符号（来自官方 all_symbols，未在上表逐条列出）

以下为官方文档中存在、上文未单独成行的 API 或类型，实现 Deno 兼容层时需一并考虑：

| Deno API / 类型                                                  | 说明                                          | shu 覆盖建议                        |
| ---------------------------------------------------------------- | --------------------------------------------- | ----------------------------------- |
| Deno.connectQuic / Deno.ConnectQuicOptions                       | QUIC 连接                                     | ❌ 可占位                           |
| Deno.Proxy / Deno.CreateHttpClientOptions                        | HTTP 代理与客户端选项                         | ⚠ 可占位或与 fetch 扩展配合         |
| Deno.BasicAuth                                                   | 代理 Basic 认证                               | ⚠ 与 Proxy 配套                     |
| Deno.bundle.\* (Format, Options, Result, OutputFile, Message 等) | 打包相关类型                                  | ❌ 构建时；可占位                   |
| Deno.FsFile                                                      | 打开文件的句柄（rid + read/write/seek/close） | ⚠ 需与 Deno.open/close 配套         |
| Deno.Reader / Deno.Writer / Deno.Closer                          | 流式读写接口                                  | ⚠ 若暴露 stdin/stdout 等需实现      |
| Deno.Addr / Deno.Conn                                            | 网络地址与连接接口                            | ✅ 与 shu:net 返回对象对齐即可      |
| Deno.CaaRecord / DNS 记录类型                                    | resolveDns 返回类型                           | ✅ shu:dns 可返回兼容结构           |
| Deno.BenchDefinition                                             | bench 选项                                    | ⚠ 与 Deno.bench 一起实现            |
| Deno.TestDefinition / Deno.TestContext                           | test 选项与上下文                             | ✅ shu:test 可对齐                  |
| Deno.errors.\* (NotFound, PermissionDenied 等)                   | 错误类                                        | ⚠ 建议提供占位或与 Node errors 对齐 |
| Deno.brand                                                       | 内部品牌                                      | 可忽略或只读属性                    |
| Deno.ConditionalAsync                                            | 条件异步                                      | 可占位                              |

---

## 2. deno: 说明符

Deno 官方**不提供** `deno:xxx` 内置模块；标准库通过 **JSR**（如 `@std/fs`、`@std/path`）发布。若 shu 要支持 `deno:` 协议，可做如下规划（与 `builtin.zig` 一致）：

| 拟议 deno: 说明符 | 建议对应                  | 说明                                |
| ----------------- | ------------------------- | ----------------------------------- |
| deno:assert       | @std/assert 或 shu:assert | 断言                                |
| deno:node         | node: 兼容层              | 暴露 node: 模块供 Deno 风格代码使用 |
| deno:permissions  | 运行时权限                | 可映射到 shu:permissions            |

当前 **DENO_BUILTIN_NAMES 为空**，无 deno: 解析实现；兼容重点在 **Deno.\* 命名空间** 与 **node:** 的提供。

---

## 3. 全局对象与方法（Deno 环境）

Deno 继承标准 Web 全局，并增加 `Deno` 对象。与 Node 重叠部分见 node/COMPATIBILITY.md。

| 全局                                      | Deno 行为    | shu 覆盖 | 说明                                       |
| ----------------------------------------- | ------------ | -------- | ------------------------------------------ |
| Deno                                      | 命名空间对象 | ⚠ 待实现 | 需在 bindings 注册 Deno 对象并挂载上述 API |
| fetch / Request / Response                | 标准         | ✅       | shu:fetch                                  |
| console                                   | 标准         | ✅       | shu:console                                |
| setTimeout / setInterval / queueMicrotask | 标准         | ✅       | shu:timers                                 |
| URL / URLSearchParams                     | 标准         | ✅       | shu:url                                    |
| TextEncoder / TextDecoder                 | 标准         | ✅       | shu:text_encoding                          |
| atob / btoa                               | 标准         | ✅       | shu:encoding                               |
| crypto (Web Crypto)                       | 标准         | ✅       | shu:crypto                                 |
| performance                               | 标准         | ✅       | shu:performance                            |
| AbortController                           | 标准         | ✅       | shu:abort                                  |
| WebSocket                                 | 标准         | ✅       | shu:websocket_client                       |
| process                                   | Node 兼容    | ✅       | Deno 支持 Node 时存在；shu 已提供          |
| Buffer                                    | Node 兼容    | ✅       | shu:buffer                                 |
| require                                   | Node 兼容    | ✅       | 引擎                                       |

**缺口：** 需提供 **全局 Deno** 对象，并将上述 Deno.\* API 逐项挂载（部分可直接委托给 shu:process/shu:fs/shu:net 等）。

---

## 4. 小结与实施优先级

- **已可由 shu 覆盖的 Deno 能力**：文件读写、TCP/TLS、HTTP/serve、fetch、WebSocket、子进程（Command）、权限查询/请求、测试（test）、DNS、cwd/exit/env、部分 fs 高级 API。缺少的是**统一 Deno 命名空间**的挂载与少量 API（chdir、open/close/rid、signal、kv、bench、errors.\*）。
- **优先实现**：
  1. 在 bindings 中注册 **Deno** 对象。
  2. 实现 Deno.args、Deno.cwd、Deno.exit、Deno.env、Deno.build（部分）、Deno.readFile/readTextFile、Deno.writeFile/writeTextFile、Deno.serve、Deno.test、Deno.permissions、Deno.Command、Deno.connect、Deno.listen 等与 shu 已有模块的映射。
  3. 补 Deno.chdir、Deno.open/close/rid（若需 FsFile）、Deno.errors.\*。
- **可选/后续**：Deno.kv、Deno.bench、Deno.bundle、信号监听、stdin/stdout/stderr 的 Reader/Writer 抽象。

本文档与 `modules/deno/builtin.zig`、`compat/deno/mod.zig` 一致，供 Deno 兼容层开发与测试使用。
