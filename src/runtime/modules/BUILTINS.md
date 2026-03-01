# 内置函数与全局 API 清单

所有**由我们向 JS 暴露的宿主 API**都在此登记；新增时在此表补一行并在 `engine.zig` 的 init 中调用对应 `register`。

**范围说明**（本表只列「我们注册的」）  
- **不列**：ECMAScript 标准自带的全局（由 JSC 提供），如 `Object`、`Array`、`Math`、`JSON`、`Date`、`Promise`、`Map`、`Set`、`Symbol`、`Reflect`、`Proxy`、`globalThis`、`parseInt`/`parseFloat`、`encodeURI`/`decodeURI`、`isNaN`/`isFinite`、`eval`、`structuredClone` 等。  
- **只列**：我们在 Zig 里绑定到全局的宿主 API（console、定时器、fetch、process、Shu、Buffer、require、Bun.*、node:* 等）。

参考：`docs/SHU_RUNTIME_ANALYSIS.md` 四、功能清单。

**JS API 用户文档**：运行 `zig build js-api-docs` 或 `zig run scripts/generate_js_api_docs.zig` 可从本表自动生成面向用户的 `docs/JS_API_REFERENCE.md`。

---

## 一、已实现（已注册）


| 分类  | 名称                    | 说明          | 实现文件          | 权限/备注                      |
| --- | --------------------- | ----------- | ------------- | -------------------------- |
| 全局  | `console.log` / `warn` / `error` / `info` / `debug` | 控制台输出 | `console.zig` | 无                          |
| 全局  | `setTimeout(cb, ms)`  | 延迟执行        | `timers.zig`  | 返回 id                      |
| 全局  | `setInterval(cb, ms)` | 周期执行        | `timers.zig`  | 返回 id                      |
| 全局  | `clearTimeout(id)`    | 取消 timeout  | `timers.zig`  | 无                          |
| 全局  | `clearInterval(id)`   | 取消 interval | `timers.zig`  | 无                          |
| 全局  | `setImmediate(cb)`    | 下一轮事件循环执行（与 setTimeout(cb,0) 同源） | `timers.zig`  | 返回 id                      |
| 全局  | `clearImmediate(id)`  | 取消 setImmediate | `timers.zig`  | 与 clearTimeout 共用 id 空间   |
| 全局  | `queueMicrotask(fn)`  | 微任务：脚本结束后、runLoop 前执行 | `timers.zig` + `timer_state.zig` | 无                          |
| 全局  | `fetch(url)`          | 同步 HTTP GET | `fetch.zig`   | `--allow-net`              |
| 全局  | `atob(str)`           | Base64 解码为二进制字符串 | `encoding.zig` | 非法输入抛 DOMException     |
| 全局  | `btoa(str)`           | 二进制字符串编码为 Base64 | `encoding.zig` | 字符码点需 0–255            |
| 全局  | `TextEncoder` / `TextDecoder` | 字符串与 UTF-8 互转：new TextEncoder().encode(str) 返回 Uint8Array，new TextDecoder().decode(buffer) 返回字符串 | `text_encoding.zig` | 若 JSC 未提供则宿主注册 |
| 全局  | `URL` / `URLSearchParams` | 解析 URL：new URL(input [, base]) 得 href/origin/pathname/search/hash/searchParams；URLSearchParams 支持 get/getAll/toString | `url.zig` | 仅当 globalThis.URL 未定义时注册 |
| 全局  | `AbortController` / `AbortSignal` | 取消请求：new AbortController() 得 .signal、.abort()；signal.aborted 为 boolean | `abort/mod.zig` | 仅当未定义时注册 |
| 全局  | `performance` / `performance.now()` | 高精度计时（毫秒），用于测量耗时 | `performance.zig` | 仅当未定义时注册 |
| 全局  | `crypto.randomUUID()` | 返回 RFC 4122 UUID v4 字符串 | `modules/shu/crypto` | 无；bindings 调 shu_crypto.register，Shu.crypto 同源 |
| 全局  | `crypto.CHACHA20_POLY1305` / `crypto.AES_256_GCM` | 对称加密算法常量，可作为 encrypt 的第三个参数传入，无需手写字符串 | `modules/shu/crypto` | 只读字符串属性 |
| 全局  | `crypto.digest(algorithm, data)` | 哈希：支持 "SHA-1"、"SHA-256"、"SHA-384"、"SHA-512"，返回十六进制字符串 | `modules/shu/crypto` | data 为字符串，按 UTF-8 哈希 |
| 全局  | `crypto.encrypt(key, plaintext [, algorithm])` | 对称加密：algorithm 可选 crypto.CHACHA20_POLY1305（默认）、crypto.AES_256_GCM；key 为 64 位十六进制或任意密码字符串，返回 base64(alg\|nonce\|tag\|密文) | `modules/shu/crypto` | 无                          |
| 全局  | `crypto.decrypt(key, ciphertext)` | 对称解密：支持新格式（含 alg 字节）与旧格式（无 alg，仅 ChaCha），ciphertext 为 encrypt 返回的 base64 | `modules/shu/crypto` | 密钥错误或数据损坏抛错       |
| 全局  | `crypto.generateKeyPair(algorithm)` | 非对称密钥对生成，当前支持 "X25519"，返回 `{ publicKey, privateKey }`（base64 字符串） | `modules/shu/crypto` | 无                          |
| 全局  | `crypto.encryptWithPublicKey(recipientPublicKey, plaintext)` | 非对称加密：用对方公钥（base64）加密，内部 X25519 协商 + ChaCha20-Poly1305，返回 base64 | `modules/shu/crypto` | 公钥须为 generateKeyPair 产出的 base64 |
| 全局  | `crypto.decryptWithPrivateKey(privateKey, ciphertext)` | 非对称解密：用己方私钥（base64）解密 encryptWithPublicKey 的密文 | `modules/shu/crypto` | 私钥/密文错误抛错            |
| 全局  | `crypto.getRandomValues(typedArray)` | 用安全随机数填充 TypedArray | `modules/shu/crypto` | 当前占位（需 JSC TypedArray C API） |
| 全局  | `process`             | 进程信息        | `process.zig` | 需 RunOptions               |
|     | `process.cwd`         | 当前工作目录字符串   | 同上            | 只读                         |
|     | `process.argv`        | 命令行参数数组     | 同上            | 只读                         |
|     | `process.env`         | 环境变量对象      | 同上            | `--allow-env` 才有内容         |
|     | `process.send(msg)` / `process.receiveSync()` | 多进程/多线程 IPC（仅 fork 子进程或 thread 工作线程内可用） | `fork_child.zig` / `thread_worker.zig` | 见 Shu.system.fork、Shu.thread |
| 全局  | `__dirname`           | 当前文件所在目录    | `process.zig` | 只读                         |
| 全局  | `__filename`          | 当前文件绝对路径    | `process.zig` | 只读                         |
| Shu.fs | `Shu.fs.read(path)` / `Shu.fs.readSync(path)` | 异步 Promise\<string\> / 同步读文件为 string | `shu/fs.zig` | `--allow-read` |
| Shu.fs | `Shu.fs.write(path, content)` / `Shu.fs.writeSync(path, content)` | 异步 Promise\<void\> / 同步写文件 | `shu/fs.zig` | `--allow-write`，异步 content 上限 512KB |
| Shu.fs | `Shu.fs.readdir(path)` / `Shu.fs.readdirSync(path)` | 异步 Promise\<string[]\> / 同步 string[] | `shu/fs.zig` | `--allow-read` |
| Shu.fs | `Shu.fs.mkdir(path)` / `Shu.fs.mkdirSync(path)` | 异步 Promise\<void\> / 同步创建单层目录 | `shu/fs.zig` | `--allow-write` |
| Shu.fs | `Shu.fs.exists(path)` / `Shu.fs.existsSync(path)` | 异步 Promise\<boolean\> / 同步 boolean | `shu/fs.zig` | `--allow-read` |
| Shu.fs | `Shu.fs.stat(path)` / `Shu.fs.statSync(path)` | 异步 Promise\<stat\> / 同步 { isFile, isDirectory, size, mtimeMs } | `shu/fs.zig` | `--allow-read` |
| Shu.fs | `Shu.fs.unlink(path)` / `Shu.fs.unlinkSync(path)` | 异步 Promise\<void\> / 同步删文件 | `shu/fs.zig` | `--allow-write` |
| Shu.fs | `Shu.fs.rmdir(path)` / `Shu.fs.rmdirSync(path)` | 异步 Promise\<void\> / 同步删空目录 | `shu/fs.zig` | `--allow-write` |
| Shu.fs | `Shu.fs.rename(old, new)` / `Shu.fs.renameSync(old, new)` | 异步 Promise\<void\> / 同步重命名/移动 | `shu/fs.zig` | `--allow-read` + `--allow-write` |
| Shu.fs | `Shu.fs.copy(src, dest)` / `Shu.fs.copySync(src, dest)` | 异步 Promise\<void\> / 同步复制文件 | `shu/fs.zig` | `--allow-read` + `--allow-write` |
| Shu.fs | `Shu.fs.append(path, content)` / `Shu.fs.appendSync(path, content)` | 异步 Promise\<void\> / 同步追加写入（文件不存在则创建） | `shu/fs.zig` | `--allow-write`，异步 content 上限 512KB |
| Shu.fs | `Shu.fs.symlink(target, linkPath)` / `Shu.fs.symlinkSync(target, linkPath)` | 异步 Promise\<void\> / 同步创建符号链接 | `shu/fs.zig` | `--allow-write` |
| Shu.fs | `Shu.fs.readlink(path)` / `Shu.fs.readlinkSync(path)` | 异步 Promise\<string\> / 同步返回链接目标路径 | `shu/fs.zig` | `--allow-read` |
| Shu.fs | `Shu.fs.mkdirRecursive(path)` / `Shu.fs.mkdirRecursiveSync(path)` | 异步 Promise\<void\> / 同步递归创建目录（mkdir -p 风格） | `shu/fs.zig` | `--allow-write` |
| Shu.fs | `Shu.fs.rmdirRecursive(path)` / `Shu.fs.rmdirRecursiveSync(path)` | 异步 Promise\<void\> / 同步递归删除目录及内容（rm -rf 风格） | `shu/fs.zig` | `--allow-write` |
| Shu.path | `join`、`resolve`、`dirname`、`basename`、`extname`、`normalize`、`isAbsolute`、`relative`、`parse`、`format`、`root`、`name`、`toNamespacedPath`、`filePathToUrl`、`urlToFilePath`、`sep`、`delimiter`、`posix`、`win32` | 路径工具 | `shu/path.zig` | 无 |
| Shu.system | `Shu.system.exec(cmd)` / `execSync(cmd)` | 通过 shell 执行命令，返回 `{ stdout, stderr, code }` | `shu/system/exec.zig` | `--allow-run` |
| Shu.system | `Shu.system.run(options)` / `runSync(options)` | 不经过 shell 执行（options.cmd 数组、cwd），返回 `{ status, stdout, stderr }` | `shu/system/run.zig` | `--allow-run` |
| Shu.system | `Shu.system.spawn(options)` / `spawnSync(options)` | 同 run，当前实现与 run 一致 | `shu/system/spawn.zig` | `--allow-run` |
| Shu.system | `Shu.system.fork(modulePath [, args] [, options])` | Node 式多进程：启动子 Shu 进程，返回 `{ send, kill, receiveSync }`，子进程内 `process.send`/`receiveSync` | `shu/system/fork.zig` + `fork_parent.zig` + `fork_child.zig` | `--allow-run`，env SHU_FORKED 自动设置 |
| Shu.thread | `Shu.thread.spawn(scriptPath [, options])` | 多线程：在新线程中运行脚本，返回 `{ send, receiveSync, join }`，工作线程内 `process.send`/`receiveSync` | `shu/thread.zig` + `thread_worker.zig` | 无 |
| Shu | `Shu.crond(expression, callback)` | 计划任务：六段 cron 表达式（秒 分 时 日 月 周），如 `"* * * * * *"`，返回 `{ stop }` | `engine/shu/mod.zig` + `modules/shu/crond` | 支持 *、N、*/N、N-M |
| Shu / 全局 | `Shu.crondClear(id)` / `crondClear(id)` | 取消指定 id；不传参则清空所有由 Shu.crond 创建的任务 | `engine/shu/mod.zig` | 无 |
| Shu | `Shu.server(options)` | HTTP 服务端（非阻塞）：port/host/unix、handler/fetch、TLS、HTTP/2、WebSocket、压缩、keep-alive、onListen、onError、signal、reload/restart | `engine/shu/server/mod.zig` | `--allow-net` |
| Shu | `server.stop()` / `server.reload(newOptions)` / `server.restart(newOptions?)` | 停止监听、热重载、重启（不关 listen 或关后重 listen） | 同上 | 无 |
| 全局 | `WebSocket(url [, options])` | 客户端（对齐浏览器 API）：连接 ws://，同步握手；实例含 **readyState**（0/1/2/3）、**url**；**close(code?, reason?)** 发 close 帧并调用 **onclose**；**send(data)**、**receiveSync()**；支持 **onopen** / **onmessage** / **onerror** / **onclose**（options 或实例属性）；构造函数上挂 **WebSocket.CONNECTING/OPEN/CLOSING/CLOSED** | `engine/websocket_client.zig` | `--allow-net`，仅支持 ws://（不支持 wss://） |

**文件与目录操作对照（Node / Bun / Shu）** — 文件 API 在 `Shu.fs` 下（与 node:fs/deno:fs 命名统一）；路径在 `Shu.path` 下。

| 能力 | Node (node:fs) | Bun | Shu（当前） |
|------|----------------|-----|-------------|
| 读文件 | readFile / readFileSync | Bun.file().text() | **Shu.fs.read** / **Shu.fs.readSync** |
| 写文件 | writeFile / writeFileSync | Bun.write() | **Shu.fs.write** / **Shu.fs.writeSync** |
| 读目录 | readdir / readdirSync | — | **Shu.fs.readdir** / **Shu.fs.readdirSync** |
| 创建目录 | mkdir / mkdirSync | — | **Shu.fs.mkdir** / **Shu.fs.mkdirSync**（单层） |
| 是否存在 | exists / access | file.exists() | **Shu.fs.exists** / **Shu.fs.existsSync** |
| 元数据 | stat / statSync | file.stat() | **Shu.fs.stat** / **Shu.fs.statSync** |
| 删文件 | unlink / unlinkSync | file.delete() | **Shu.fs.unlink** / **Shu.fs.unlinkSync** |
| 删空目录 | rmdir / rmdirSync | — | **Shu.fs.rmdir** / **Shu.fs.rmdirSync** |
| 重命名/移动 | rename / renameSync | — | **Shu.fs.rename** / **Shu.fs.renameSync** |
| 路径 | path.join / path.resolve 等 | — | **Shu.path.join** / **Shu.path.resolve** 等 |
| 复制文件 | copyFile / copyFileSync | Bun.write(dest, Bun.file(src)) | **Shu.fs.copy** / **Shu.fs.copySync** |
| 追加写 | appendFile / appendFileSync | — | **Shu.fs.append** / **Shu.fs.appendSync** |
| 符号链接 | symlink / readlink | — | **Shu.fs.symlink** / **Shu.fs.symlinkSync**、**Shu.fs.readlink** / **Shu.fs.readlinkSync** |
| 递归删/建 | rm -rf / mkdir -p | — | **Shu.fs.mkdirRecursive** / **Shu.fs.mkdirRecursiveSync**、**Shu.fs.rmdirRecursive** / **Shu.fs.rmdirRecursiveSync** |

**node:xxx 与 shu:xxx 同步情况**（`modules/node/builtin.zig` / `modules/shu/builtin.zig`）  
以下为当前已支持：`require("node:xxx")` 或 `import from "node:xxx"` 会返回与 **shu:xxx** 同一实现（或 Shu 子对象）。

| 已同步 node: | 对应 shu: / 实现 | 说明 |
|-------------|------------------|------|
| node:path | shu:path（Shu.path） | 已兼容 |
| node:fs | shu:fs（Shu.fs，脚本封装为 Node 命名 readFileSync 等） | 已兼容 |
| node:zlib | shu:zlib（Shu.zlib） | 已兼容 |
| node:crypto | shu:crypto（Shu.crypto） | 已兼容 |
| node:assert | shu:assert（Zig） | 已兼容 |
| node:events | shu:events（Zig） | 已兼容 |
| node:util | shu:util（Zig） | 已兼容 |
| node:querystring | shu:querystring（Zig） | 已兼容 |
| node:url | shu:url（Zig） | 已兼容 |
| node:string_decoder | shu:string_decoder（Zig） | 已兼容 |
| node:os | shu:os（Zig） | 已兼容 |

**尚未同步到 shu: 的 node: 模块**（Node 有、当前无 shu:xxx 或 node: 分支）：

| node: 模块 | 用途 | 建议 |
|------------|------|------|
| node:buffer | Buffer 类 | 实现 shu:buffer 或占位，再让 node:buffer 复用 |
| node:stream | 可读/可写/Transform 流 | 纯 JS 子集或 Zig，工作量中 |
| node:process | 进程信息 | 已有全局 process，node:process 可别名导出 |
| node:timers | setTimeout/setInterval 等 | 已有全局，node:timers 可再导出 |
| node:console | 控制台 | 已有全局 console，可再导出 |
| node:child_process | spawn/exec/fork | Shu.system 已有，可做 shu:child_process 薄封装 |
| node:worker_threads | 工作线程 | Shu.thread 已有，可薄封装 |
| node:http / node:https | HTTP 服务/客户端 | Shu.server 已有，可薄封装 createServer/request |
| node:net | TCP/Unix socket | 需底层 socket |
| node:tls | TLS 套接字 | Shu.server 支持 TLS，可做简化 |
| node:dgram | UDP | 需网络扩展 |
| node:dns | DNS 解析 | 需网络扩展 |
| node:readline | 逐行 stdin | 可做简化版 |
| node:punycode | 域名编码 | 小模块，易做 |
| node:vm | 独立上下文 | 可占位或极简 |
| node:async_hooks / node:async_context | 异步上下文 | 需事件循环深度集成 |
| node:perf_hooks | 性能钩子 | 可子集 |
| node:module / node:repl / node:test / node:inspector / node:v8 / node:wasi / node:domain / node:diagnostics_channel / node:report / node:tracing / node:tty / node:permissions / node:intl / node:webcrypto / node:webstreams / node:cluster / node:debugger | 各类专项 | 按需再补或占位 |

**Node 内置与 Shu 实现对照（node:xxx 可直接复用 Shu）** — Node 常用的 **node:fs**、**node:path** 能力在 Shu 中均已实现；实现 `node:fs` / `node:path` 时只需做薄封装：在 require/import 解析到 `node:fs` 或 `node:path` 时返回一个按 Node 命名的模块对象，内部直接调用 Shu.fs / Shu.path 即可。

| Node 模块 | Node 常用 API | Shu 对应实现 | 说明 |
|-----------|----------------|--------------|------|
| **node:path** | path.join、path.resolve、path.dirname、path.basename、path.extname、path.normalize、path.isAbsolute、path.relative、path.parse、path.format、path.toNamespacedPath、path.posix、path.win32、path.sep、path.delimiter | **Shu.path** 同名或等价；另有 root、name（Shu 特色）、filePathToUrl、urlToFilePath | 一一对应，**已同步** |
| **node:fs** | readFileSync、writeFileSync、readdirSync、mkdirSync、existsSync、statSync、unlinkSync、rmdirSync、renameSync、copyFileSync、appendFileSync、symlinkSync、readlinkSync | **Shu.fs**→readFileSync 等（脚本薄封装） | **已同步** |
| **node:http** | createServer、request 等 | **Shu.server** 已提供 HTTP 服务端；可薄包装为 Node 的 createServer/IncomingMessage/ServerResponse 风格 | 未同步，需适配请求/响应对象形态 |

**Node 内置模块完整列表与兼容性** — 以下为 Node 官方 `node:` 内置模块；**理论上都可以做兼容**，区别在于：已有 Shu 能力的可薄封装（fs/path 已做），需新能力的要按优先级实现或做子集。

| 模块 | 用途 | Shu 现状 | 兼容方式 |
|------|------|----------|----------|
| **node:assert** | 断言（strictEqual、deepStrictEqual 等） | 无 | 纯 JS 或 Zig 实现断言函数，易做 |
| **node:buffer** | Buffer 类（二进制） | 占位 | 实现 Buffer.from/alloc/toString 等，与 encoding/二进制配合 |
| **node:child_process** | spawn/exec/fork/execSync | **Shu.system.exec/run/spawn**、**Shu.system.fork** | 薄封装为 execSync/spawnSync/exec 等，可做 |
| **node:cluster** | 多进程调度 | 无 | 可用 Shu.system.fork 做简化版或占位 |
| **node:crypto** | 哈希/加解密/随机数 | **crypto.zig**（digest/encrypt/decrypt/randomUUID 等） | 薄封装为 Node 命名（createHash、randomBytes 等），可做 |
| **node:dgram** | UDP 套接字 | 无 | 需网络层扩展，P2 |
| **node:dns** | DNS 解析 | 无 | 需网络层，P2 |
| **node:events** | EventEmitter | 无 | 纯 JS 实现 EventEmitter，易做 |
| **node:fs** | 文件系统 | **已实现**（Shu.fs） | 已兼容 |
| **node:http** | HTTP 服务/客户端 | **Shu.server**、fetch | 包装 createServer/request，P1 |
| **node:https** | TLS HTTP | **Shu.server** 支持 TLS | 同 http 包装，P1 |
| **node:net** | TCP/Unix socket | 无 | 需底层 socket，P2 |
| **node:os** | 系统信息（platform、cpus、homedir 等） | 部分在 process | 用 Zig 取 OS 信息暴露，可做 |
| **node:path** | 路径工具 | **已实现**（Shu.path） | 已兼容 |
| **node:process** | 进程信息 | **process.zig**（cwd、argv、env） | 已挂全局 process，node:process 可再导出或别名 |
| **node:querystring** | 查询字符串解析 | **URLSearchParams** | 薄封装或复用 URL 解析，易做 |
| **node:readline** | 逐行读 stdin | 无 | 需 stdin 交互，可做简化版 |
| **node:stream** | 可读/可写/Transform 流 | 无 | 纯 JS 子集或与 Shu 二进制 API 结合，工作量中 |
| **node:string_decoder** | 字节→字符串解码 | **TextDecoder** | 薄封装，易做 |
| **node:timers** | setTimeout/setInterval 等 | **timers.zig** 已挂全局 | node:timers 可再导出或别名 |
| **node:tls** | TLS 套接字 | **Shu.server** TLS | 可做简化版或与 http 一起 |
| **node:url** | URL 解析 | **url.zig**（URL/URLSearchParams） | 薄封装为 Node 的 url.parse/format，易做 |
| **node:util** | util.inspect、util.promisify、类型判断等 | 无 | 纯 JS 或少量 Zig，易做子集 |
| **node:vm** | 独立 JS 上下文/执行 | JSC 不同模型 | 可做占位或极简 runInContext |
| **node:worker_threads** | 工作线程 | **Shu.thread.spawn** | 薄封装为 Worker 形态，可做 |
| **node:zlib** | gzip/deflate/br | **已实现**（复用 Shu.zlib） | 见下「shu:zlib 与压缩统一」 |

结论：**都能写兼容**；已实现的 3 个（fs、path、zlib），其余按上表「兼容方式」逐项做即可，优先做 http/https、buffer、crypto、os、util、events、child_process 等常用且底层已有能力的模块。

**shu:xxx 与压缩统一** — 所有能力优先在 **modules/shu** 下以 **shu:xxx** 实现，Node/Server 再复用：
- **shu:fs**、**shu:path**、**shu:zlib**：`require("shu:fs")` / `import ... from "shu:zlib"` 等由 `modules/shu/builtin.zig` 解析，返回 `globalThis.Shu.fs` / `Shu.path` / `Shu.zlib`。
- **压缩**：gzip/deflate/brotli 实现统一在 **modules/shu/zlib/**（gzip.zig、brotli.zig、mod.zig）；**Shu.server** 响应压缩（Content-Encoding: gzip/br/deflate）直接 `@import("../../../modules/shu/zlib/mod.zig")` 调用同一套 API；**node:zlib**、**shu:zlib** 暴露给 JS 的 `gzipSync`/`deflateSync`/`brotliSync` 也来自 `Shu.zlib`（由 `modules/shu/zlib/mod.zig` 的 register/getExports 注册到全局）。

**占位注册（已挂到全局，调用时抛 "Not implemented"）** — 在 `stubs.zig` 中：`Buffer`。**require** 在「以入口方式运行」时由 runAsModule 注入作用域，不再使用全局占位；直接调用全局 `require()` 仍会走占位（未实现）。**WebSocket** 已有真实实现（`engine/websocket_client.zig`），在 `options != null` 且 `--allow-net` 时覆盖占位。**Bun.file**、**Bun.write**、**Bun.serve** 已由 `bun_impl.zig` 实现（file/write 用 Shu.fs，serve 用 Shu.server；需有 RunOptions，serve 需 `--allow-net`）。

**Bun.xxx** — **主用 Shu.server**，不主用 Bun.serve。`Bun.serve` 已实现（兼容层，内部调用 Shu.server）；`Bun.file`、`Bun.write` 已实现（内部调用 Shu.fs），见 `engine/bun/mod.zig`。Deno.serve 同理，兼容层内部使用 Shu.server。

**模块系统目标** — 与 Bun/Node 对齐，**CJS 与 ESM 均支持**：**CJS**（`require(id)`、`module.exports`、`exports`）与 **ESM**（`import`/`export`）**各写各的**，不混用转换；CJS 在 `engine/require.zig`，ESM 在 `engine/esm_loader.zig`（解析 import/export、模块图、按依赖顺序执行；入口为 .mjs/.mts 时自动走 ESM）。

---

## 二、计划中（未注册，待实现后再登记）


| 分类      | 名称                    | 说明             | 优先级 | 备注                                  |
| ------- | --------------------- | -------------- | --- | ----------------------------------- |
| 全局      | `Bun.serve(options)`    | **已实现**（bun_impl.zig）：port/hostname|host/fetch/onError 转 Shu.server，返回 stop/reload/restart | — | 需 `--allow-net` |
| ~~全局 WebSocket（客户端）~~ | ~~new WebSocket(url)~~ | **已实现**，见「一、已实现」；仅 ws://，wss 后续 | — |
| 模块 CJS | `require(id)` / `module` / `exports` | **已实现**（engine/require.zig）：入口与 require 进来的文件以 (module, exports, require, __filename, __dirname) 包装执行；单次 run 内按「解析后的绝对路径」缓存；id 可带 `?query`（如 `"xxx.ts?v=time"`），仅路径参与解析，缓存键含 query 从而不缓存或按 query 隔离；仅支持相对路径（./ ../），需 `--allow-read` | — | 见「模块系统目标」 |
| 模块 ESM | `import ... from "..."` / `export` / `export default` | **已实现**（engine/esm_loader.zig）：入口为 .mjs/.mts 时按 ESM 加载；解析 import/export、模块图、拓扑排序后按依赖执行；单次 run 内按模块键去重；说明符可带 `?query`（如 `"xxx.ts?v=time"`），仅路径参与解析，模块键含 query 实现不缓存/按 query 隔离；仅支持相对路径（./ ../），需 `--allow-read` | — | 与 CJS 并存 |
| Node 内置 | `node:fs`             | **已实现**（modules/node/builtin.zig）：require/import 解析到 node:fs 时返回薄封装 Shu.fs 的 Node 命名 API（readFileSync、writeFileSync 等）；需 `--allow-read` | — | 直接复用 Shu.fs |
| Node 内置 | `node:path`           | **已实现**（同上）：require/import 解析到 node:path 时返回 globalThis.Shu.path；需 `--allow-read` | — | 直接复用 Shu.path |
| Node 内置 | `node:zlib`           | **已实现**（同上）：require/import 解析到 node:zlib 时返回 globalThis.Shu.zlib（gzipSync/deflateSync/brotliSync） | — | 与 shu:zlib、Server 压缩共用 modules/shu/zlib |
| Node 内置 | `node:http`           | HTTP 服务/客户端    | P1  | modules/node/http.zig，可包装 Shu.server |
| Shu 协议  | `shu:fs` / `shu:path` / `shu:zlib` / `shu:crypto` | **已实现**（modules/shu/builtin.zig）：require/import 解析到 shu:xxx 时返回 Shu.fs / Shu.path / Shu.zlib / Shu.crypto；crypto 实现位于 modules/shu/crypto，bindings 调 register、Shu 注册时 attachToShu | — | 能力统一在 modules/shu，node: 薄封装复用 |
| Deno 风格 | `deno:` 协议、Import Map | 模块解析           | P2  | compat/deno                         |
| 其他      | SQLite 等              | 视 Bun 对齐       | P2  | 可选                                  |

**其他常见宿主全局（可选 / 待定）** — 若对齐 Node/Bun/Deno 可逐步补充登记或占位：

| 分类   | 名称 | 说明 |
|--------|------|------|
| ~~定时相关~~ | ~~`setImmediate` / `clearImmediate`~~ | **已实现**，见上表 |
| ~~微任务~~ | ~~`queueMicrotask(fn)`~~ | **已实现**，见上表 |
| ~~编码~~ | ~~`atob` / `btoa`~~ | **已实现**（`encoding.zig`），见上表 |
| ~~编码~~ | ~~`TextEncoder` / `TextDecoder`~~ | **已实现**（`text_encoding.zig`），与 fetch/文件等配合 |
| ~~URL~~ | ~~`URL` / `URLSearchParams`~~ | **已实现**（`url.zig`），若 JSC 未提供则宿主注册 |
| ~~网络~~ | ~~`AbortController` / `AbortSignal`~~ | **已实现**（`abort/mod.zig`），与 fetch 取消配合 |
| Fetch 配套 | `Request` / `Response` / `Headers` | 完整 fetch API 时需在全局或 fetch 返回值上可用 |
| 文件   | `File` / `Blob` | 文档提及的 Bun 风格，可与 Bun.file 一起 |
| 其他 Bun | `Bun.sleep(ms)`、`Bun.exit(code)` 等 | Bun 其它常用 API；Bun.file/Bun.write **已实现** |
| ~~性能~~ | ~~`performance` / `performance.now()`~~ | **已实现**（`performance.zig`），计时与性能观测 |
| ~~加密~~ | ~~`crypto`（加密方式 + 非对称，不含 JWT）~~ | **已实现**：randomUUID；算法常量；digest；encrypt/decrypt；generateKeyPair、encryptWithPublicKey、decryptWithPrivateKey；**getRandomValues 仍占位**（需 JSC TypedArray C API） |

---

## 三、全面对照：可能遗漏的宿主全局（按来源整理）

以下按 **Node / Bun / Deno / Web 标准** 对照，列出我们尚未登记或仅部分登记的宿主全局，便于后续补全或占位。

### 3.1 Node.js 有、我们未单独列出的

| 名称 | 说明 | 当前状态 |
|------|------|----------|
| `global` | 全局命名空间对象（与 `globalThis` 同指） | 通常由引擎提供，可不注册 |
| `navigator` | 宿主信息：`hardwareConcurrency`、`language`、`platform`、`userAgent`、`locks` 等 | 未列，可选 |
| `process.nextTick(cb)` | 下一次事件循环前执行回调 | 未列，Node 常用 |
| `MessageChannel` / `MessagePort` | 异步消息通道，与 postMessage 配合 | 未列，可选 |
| `performance` | 高精度时间与性能条目（`performance.now()` 等） | 已在「其他常见」 |
| `AbortController` / `AbortSignal` | 与 fetch 等取消配合 | 已在「其他常见」 |

### 3.2 Bun 有、我们未列出的（Bun.* 子集）

当前仅占位：`Bun.serve`、`Bun.file`、`Bun.write`。以下为 Bun 文档中的其它全局，可按需补充登记或占位：

| 分类 | 名称 | 说明 |
|------|------|------|
| 网络 | `Bun.listen()` / `Bun.connect()` | TCP 服务端/客户端 |
| 网络 | `Bun.udpSocket()` | UDP |
| 流 | `Bun.stdin` / `Bun.stdout` / `Bun.stderr` | 标准流 |
| 进程 | `Bun.spawn()` / `Bun.spawnSync()` | 子进程 |
| 构建 | `Bun.build()` / `Bun.Transpiler` | 打包与转译 |
| 数据 | `Bun.SQL()` / `Bun.sql`、`Bun.redis()` / `Bun.RedisClient` | 数据库与 Redis |
| 哈希/加密 | `Bun.password()`、`Bun.hash()`、`Bun.CryptoHasher`、`Bun.sha` | 密码与哈希 |
| 工具 | `Bun.version` / `Bun.revision`、`Bun.env`、`Bun.main` | 版本与入口 |
| 工具 | `Bun.sleep()` / `Bun.sleepSync()`、`Bun.nanoseconds()`、`Bun.randomUUIDv7()`、`Bun.which()` | 睡眠、时间、UUID、which |
| 工具 | `Bun.peek()`、`Bun.deepEquals()` | 调试与比较 |
| 路由/文件 | `Bun.FileSystemRouter`、`Bun.Glob` | 基于文件的路由与 glob |
| 其它 | `Bun.Cookie` / `Bun.CookieMap`、`Bun.plugin()`、`$`（Shell） | Cookie、插件、Shell |

### 3.3 Deno 有、我们未列出的（Deno.* 子集）

当前仅计划「deno: 协议、Import Map」。Deno 命名空间常见全局包括：

| 名称 | 说明 |
|------|------|
| `Deno.args` | 脚本参数 |
| `Deno.build` | 运行时构建信息（arch、os、env、target） |
| `Deno.serve` / `Deno.serveHttp` | HTTP 服务 |
| `Deno.listen` / `Deno.connect` | 网络监听/连接 |
| `Deno.Command` | 子进程 |
| `Deno.errors.*` | 错误类（如 `Deno.errors.NotFound`） |
| `Deno.bench`、`Deno.addSignalListener`、`Deno.resolveDns` 等 | 测试、信号、DNS 等 |

### 3.4 Web 标准 / 其它常见宿主

| 名称 | 说明 | 当前状态 |
|------|------|----------|
| `reportError(err)` | 报告未捕获异常（部分运行时提供） | 未列 |
| `Event` / `EventTarget` / `CustomEvent` | 事件对象与目标（部分引擎已带） | 未列，可先依赖引擎 |
| `MessageChannel` / `MessagePort` | 见 4.1 | 未列 |
| `BroadcastChannel` | 跨上下文广播 | 未列 |
| `Worker` / `SharedWorker` | 若未来支持 Worker 需挂全局 | 未列 |
| `queueMicrotask` | 已在「其他常见」 | 已列 |

---

**小结**：  
- **已写全的**：我们当前已实现、占位与「计划中 / 其他常见」中的宿主 API，以及本节三、的全面对照。  
- **若需「全部写上」到代码**：可从第三节中挑优先级高的（如 `navigator`、`process.nextTick`、`setImmediate`/`clearImmediate`、更多 `Bun.*`）在 `stubs.zig` 或对应模块中做占位注册，并在本表相应位置注明「已占位」。

---

## 四、注册方式约定

- 每个内置一组能力放在 `engine/` 下单独文件（如 `console.zig`、`fetch.zig`）。
- 文件内导出 `pub fn register(ctx: jsc.JSGlobalContextRef) void`（如需 allocator/options 则增加参数）。
- **统一入口**：`runtime/bindings/mod.zig` 的 `registerGlobals(ctx, allocator, options)` 负责按顺序调用各 `engine/*.register`；`engine.zig` 在创建 JSC 上下文后只调用 `bindings.registerGlobals(...)`，不再直接调用各 engine。
- 需要权限或 RunOptions 的，仅在 `options != null` 时在 bindings 内注册（process、Shu、fetch、Bun.file/Bun.write）；纯全局（console、timers、encoding、crypto、stubs 等）无 options 也注册。

新增内置时：

1. 在本文件「二、计划中」或「三、全面对照」中确认条目，移到「一、已实现」并填实现文件。
2. 在 `engine/` 下新增或复用实现文件，导出 `register`。
3. 在 **`runtime/bindings/mod.zig`** 的 `registerGlobals` 中按顺序调用该 `register`（并视需在条件 `if (options) |opts| { ... }` 内）。

---

## 五、Runtime 完善度分析

以下为当前 runtime 的完善度概览：已落地的部分与可补充的方向。

### 按优先级推进（当前建议顺序）

| 顺序 | 项 | 状态 | 说明 |
|------|----|------|------|
| 1 | **文档** | 已做 | `docs/PLATFORM_AND_JSC.md` 已说明 macOS/Linux/Windows 与 `-Djsc_prefix` |
| 2 | **atob/btoa** | 已实现 | `engine/encoding.zig`，已登记到「一、已实现」 |
| 3 | **P1 服务端** | **已做** | **Shu.server**（HTTP/WS/H2/TLS、热重载）已实现；Bun.serve 为兼容层待做 |
| 4 | **P1 模块** | 待做 | `module` / `exports`、真实 `require`，与 loader 配套 |
| 5 | **P2 Node 兼容** | 待做 | `node:fs`、`node:path`、`node:http`，可复用 Shu.fs/Shu.path |
| 6 | **P2 协议** | 待做 | `shu:env`、`shu:fs`、`deno:`、Import Map |
| 7 | **可选** | 部分已做 | atob/btoa、crypto.randomUUID 已做；crypto.getRandomValues 占位；URL、performance 等按需 |

### 5.1 已完善的部分

| 层级 | 内容 | 说明 |
|------|------|------|
| **核心** | `vm.zig`、`engine.zig`、`jsc.zig`/`jsc_stub.zig`、`run_options.zig`、权限 | VM/引擎生命周期、JSC 封装与跨平台 stub、运行选项、权限检查 |
| **全局** | console、setTimeout/setInterval/clear*、**setImmediate/clearImmediate**、**queueMicrotask**、fetch、process（cwd/argv/env/__dirname/__filename）、process.send/receiveSync（fork/thread 内） | 已实现并接入 |
| **Shu.fs** | read/write、readdir、mkdir、exists、stat、unlink、rmdir、rename、**copy、append、symlink、readlink、mkdirRecursive、rmdirRecursive**（均含 Sync + 异步） | 文件与目录能力已较完整 |
| **Shu.path** | join、resolve、dirname、basename、extname、normalize、isAbsolute、relative、filePathToUrl、urlToFilePath、sep、delimiter | 路径工具已覆盖常用 |
| **Shu.system** | exec/execSync、run/runSync、spawn/spawnSync、fork（多进程+IPC） | 需 `--allow-run` |
| **Shu.thread** | spawn、send、receiveSync、join（多线程） | 工作线程内 process.send/receiveSync |
| **Shu** | Shu.crond、crondClear | 计划任务 |
| **引擎子模块** | fork_child、thread_worker、timer_state、cron、globals | 支撑 fork/thread/crond |
| **占位但已挂上** | stubs.zig：Buffer、require、WebSocket、Bun.serve/Bun.file/Bun.write | 调用即抛 "Not implemented" |
| **跨平台** | macOS 用系统 JSC；Linux/Windows **必须**传有效的 `-Djsc_prefix` 才链接 WebKit JSC，**未传或路径无效则构建直接失败**（避免误发布无法执行 JS 的二进制） | build.zig + engine.zig 已分支 |

**结论**：单次 `shu run` 的脚本执行与上述 API 的整条链路已打通；**runtime/engine 对「单文件 run + 当前内置 API」已算完善**，文件/路径/进程/线程/定时器/计划任务与跨平台骨架均就绪。

### 5.2 尚未完善、可补充的部分

#### 仍为占位、未接入主流程

| 位置 | 说明 | 建议 |
|------|------|------|
| **runtime/modules/** | `node`、`shu`、`deno`、`bun` 的 mod.zig 均为空壳 | 实现 node:fs/path/http、shu:env 等后再在 loader/engine 中接入 |
| **runtime/compat/** | node/deno/bun 兼容层占位 | 与 modules 配合，做 require、deno: 协议、Import Map 等时再补 |
| **runtime/bindings/mod.zig** | **已实现**：`registerGlobals(ctx, allocator, options)` 统一调用各 engine 的 register，engine.zig 仅调用此入口 |
| **runtime/plugin.zig** | `Plugin.load` 占位，未真正加载插件 | 定好插件 ABI 后再实现 |

#### 计划中 API（按 BUILTINS 二、三节）

| 优先级 | 内容 | 备注 |
|--------|------|------|
| **P0** | `module` / `exports` | 若做 CJS，需与 require 一起补 |
| **P1** | Bun.serve（或等价 HTTP 服务）、node:fs/path/http、shu:env/shu:fs | 实现后替换或补充 stubs/modules |
| **P2** | deno: 协议、Import Map、SQLite 等 | 可选 |

#### Shu.fs 扩展

- 已实现：copy/copySync、append/appendSync、symlink/symlinkSync、readlink/readlinkSync、mkdirRecursive/mkdirRecursiveSync、rmdirRecursive/rmdirRecursiveSync。

#### 其他常见宿主 API（可选）

- ~~setImmediate / clearImmediate、queueMicrotask~~ **已实现**
- ~~atob / btoa~~ **已实现**（encoding.zig）
- TextEncoder / TextDecoder（若 JSC 未提供）
- URL / URLSearchParams、AbortController / AbortSignal、performance / performance.now()、crypto 等

### 5.3 可补充项与优先级建议（小结）

| 优先级 | 方向 | 说明 |
|--------|------|------|
| **文档** | 在用户文档中写明「仅 macOS 默认可跑 JS；Linux/Windows 需 -Djsc_prefix」及 WebKit JSC 获取方式 | 避免误以为非 macOS 版“坏了” |
| ~~**P1 体验**~~ | ~~`setImmediate` / `clearImmediate`、`queueMicrotask`~~ | **已实现**（timers.zig + timer_state.zig） |
| **P1 服务端** | ~~`Bun.serve()` 或等价 HTTP 服务~~ | **Shu.server 已实现**；Bun.serve 为兼容层，可薄包装 Shu.server 后替换 stubs |
| **P0 模块** | **CJS**（require/module/exports）+ **ESM**（import/export） | 两套均支持，与 Bun/Node 对齐；需 loader、解析器、模块图 |
| **P2 Node 兼容** | `node:fs`、`node:path`、`node:http` | 可与现有 Shu.fs/Shu.path 复用实现，通过 modules/node/* 暴露 |
| **P2 协议** | `shu:env`、`shu:fs`、`deno:`、Import Map | 提升多文件/生态兼容，依赖 loader 与模块图 |
| **可选** | atob/btoa、crypto.randomUUID 已做；crypto.getRandomValues 占位；URL、performance 等 | 按需求再补 |
| **结构** | runtime/modules、compat、bindings、plugin | 当前为空壳；做 require/node: 时再接入，不必提前铺满 |

**总结**：**runtime/engine 已完善**到「单文件 run + 当前 API 清单」可稳定使用的程度；**Shu.server**（HTTP/WebSocket/HTTP2/TLS、热重载）、**Bun.serve**、**WebSocket 客户端**与 **setImmediate/clearImmediate/queueMicrotask** 已实现。后续主要是**模块系统（CJS + ESM 均支持）**及 **Node/Deno 兼容（node:fs/path/http）**。

### 5.4 下一步建议（先把 runtime 写完成）

**当前已完成**：Shu.server（HTTP/WebSocket/HTTP2/TLS、热重载）、WebSocket 客户端（含浏览器 API 对齐）、Bun.file/Bun.write、定时器/编码/crypto/process/Shu.fs/Shu.path 等。

建议按以下顺序推进，形成「单文件 + Bun 风格服务 + 多文件 require」闭环：

| 优先级 | 项 | 说明 | 工作量 |
|--------|----|------|--------|
| ~~**1**~~ | ~~**WebSocket 客户端**~~ | **已实现**（engine/websocket_client.zig，含 readyState/url/close/onopen/onmessage/onclose）。 | — |
| ~~**2**~~ | ~~**Bun.serve 兼容层**~~ | **已实现**（bun_impl.zig）。 | — |
| **3** | **模块系统（CJS + ESM）** | P0：**CJS**（`require(id)`、`module`、`exports`）+ **ESM**（`import`/`export`）均支持；loader 解析相对路径、node:、.js/.mjs 等；模块图与按依赖执行。与 Bun/Node 对齐。 | 大 |
| **4** | **node:fs / node:path** | 在 `modules/node/fs.zig`、`path.zig` 中包装 Shu.fs、Shu.path，通过 loader 的 `node:fs` / `node:path` 暴露。依赖 require 与模块解析。 | 中 |
| **5** | **node:http** | 在 `modules/node/http.zig` 中包装 Shu.server（创建服务）与 fetch（客户端），使 `require('node:http')` 可用。 | 中 |
| **6** | **crypto.getRandomValues** | 当前占位；若需完整 Web Crypto 或 TypedArray 随机数填充，需 JSC TypedArray C API。 | 中（依赖 JSC API） |
| **7** | **shu:env / shu:fs、deno:、Import Map** | P2：协议与模块解析增强，可在 require 与 loader 稳定后再补。 | 中 |

**建议执行顺序**：集中做 **3（模块系统：CJS + ESM）**；3 完成后做 4、5。3 做完即可支撑「多文件 + require + import/export」；4～5 补齐 Node 兼容后，常见 npm 包可逐步跑通；6～7 按需推进。

#### 平台与文档

- **当前 JS 引擎**：仅 macOS 上初始化并运行 JS，使用的是系统自带的 **JavaScriptCore (JSC)**（`runtime/jsc.zig` 为其 C API 声明）。Linux / Windows 上未接入任何 JS 引擎，因此 `shu run` 在非 macOS 上目前不会执行 JS（属实现限制，非设计上“仅支持 macOS”）。
- 本文档「一、已实现」与「五、完善度分析」随实现变更需同步更新。

#### 跨平台兼容方案（已采用）：macOS 用系统 JSC，Linux/Windows 用 WebKit JSC

- **策略**：**macOS 继续使用系统自带的 JavaScriptCore**（`-framework JavaScriptCore`，不增加体积）；**Linux 与 Windows 使用 WebKit 版 JSC**（构建时链接为该平台编译的 JSC 库）。这样三平台都能执行 JS，且 macOS 二进制保持当前体积。
- **好处**：`jsc.zig` 的 C API 与现有 `engine/*.zig` 不变，只需在 build.zig 与 engine.zig 中按平台分支；同一套内置 API 在三个平台行为一致；无需维护两套引擎（仍只绑 JSC）。
- **已落地（代码层面）**：build.zig 在 Linux/Windows 目标下**必须**提供有效的 `-Djsc_prefix=<根目录>` 才会继续构建，未传或路径无效则**构建失败**并报错（避免误发布无法执行 JS 的二进制）；传入有效目录则链接该目录下 `include/`、`lib/` 的 WebKit JSC。engine.zig 已按“have_jsc（macOS 或 have_webkit_jsc）才初始化 JSC”分支；全量 `@import("jsc")` 由 build 在真实 `jsc.zig` 与 `jsc_stub.zig` 间切换（仅 macOS 或已提供 jsc_prefix 时用真实 jsc）。
- **后续步骤**：
  1. **获取 Linux/Windows 用 JSC**：见下方「如何获取 WebKit JSC」。
  2. **带 JSC 构建**：执行 `zig build -Djsc_prefix=/path/to/webkit-jsc`（并指定目标如 `-Dtarget=x86_64-linux-gnu`），按需调整 build.zig 中 `linkSystemLibrary` 的库名以匹配实际 JSC 库名。
  3. **CI/文档**：为 Linux/Windows 提供构建说明或 CI 产物，注明 JSC 来源与版本。

#### 如何获取 WebKit JSC（`jsc_prefix` 目录）

目标：得到一个**根目录**，其下包含 **`include/`**（头文件）和 **`lib/`**（如 `libJavaScriptCore.a` 或 `.so`），构建时将该根目录传给 `-Djsc_prefix=<根目录>`。

**方式一：使用 Bun 的预编译包（推荐先试）**

- Bun 官方提供预编译的 WebKit/JSC，按平台发布在 npm 上：
  - **Linux x64**：`bun-webkit-linux-amd64`
  - **Linux ARM64**：`bun-webkit-linux-arm64`
  - **Windows**：可查 [bun-webkit](https://www.npmjs.com/package/bun-webkit) 的 optionalDependencies 是否有 windows 包。
- **步骤**（以 Linux x64 为例）：
  1. 在项目外或临时目录执行：`npm pack bun-webkit-linux-amd64` 或 `npm install bun-webkit-linux-amd64`。
  2. 解压或进入 `node_modules/bun-webkit-linux-amd64`，查看其中是否包含 `include/`、`lib/` 或类似结构（Bun 的包可能把静态库放在根目录或 `lib/` 下，头文件在 `include/` 或单独目录）。
  3. 将**包含 include 与 lib 的那一层目录**的绝对路径作为 `jsc_prefix`。若包内结构不同（例如只有 `.a` 无 `include`），则需自行把对应头文件从 WebKit 源码拷出并拼成 `include/`、`lib/` 再指向该根目录。
- **注意**：Bun 的预编译库可能为静态库、库名或 ABI 与系统 JSC 略有差异，若链接报错需在 build.zig 中调整 `linkSystemLibrary` 的库名或改为直接链接 `.a` 文件。

**方式二：从 WebKit 源码自行构建**

- **适用**：需要完全可控的版本或 Bun 预编译不可用时。
- **依赖**（以 Linux 为例）：`libicu-dev`、`python`、`ruby`、`bison`、`flex`、`cmake`、`ninja-build`、`build-essential`、`git`、`gperf` 等（具体见 [WebKit 官方构建文档](https://webkit.org/building-webkit/)）。
- **步骤概要**：
  1. 克隆 WebKit（或 Bun 维护的 [oven-sh/WebKit](https://github.com/oven-sh/WebKit)）：
     ```bash
     git clone https://github.com/WebKit/WebKit.git  # 或 oven-sh/WebKit
     cd WebKit
     ```
  2. 仅构建 JSC（不构建完整 WebKit）：
     ```bash
     Tools/Scripts/build-webkit --jsc-only
     ```
     或使用 `build-jsc`（若存在）。构建产物通常在 `WebKitBuild/Release` 或 `WebKitBuild/Debug` 下。
  3. 在构建输出目录中找到：
     - 头文件所在目录（多为 `WebKitBuild/Release/...` 下的 include 或源码中的 `Source/JavaScriptCore/API` 等）；
     - 静态库或动态库（如 `libJavaScriptCore.a`、`libjsc.so`）。
  4. 整理成一个根目录，例如：
     ```
     /path/to/webkit-jsc/
       include/   <- 放 JSC 的 C API 头文件（如 JSContextRef.h、JSValueRef.h 等）
       lib/       <- 放 libJavaScriptCore.a 或 .so
     ```
     若 WebKit 默认输出未按此布局，可手动创建 `include/`、`lib/` 并拷贝对应文件，再将该根目录作为 `jsc_prefix`。
- **Windows**：需按 [Building WebKit on Windows](https://webkit.org/building-webkit-on-windows/) 安装环境并构建，同样将得到的 include/lib 整理成上述根目录结构。

**小结**：优先尝试 **方式一**（Bun 预编译），得到包含 `include/` 与 `lib/` 的根目录后，用 `-Djsc_prefix=<该根目录>` 构建；若库名或链接方式不符，再在 build.zig 中调整。若无法使用预编译，则用 **方式二** 自建 WebKit JSC 并整理成相同目录结构。

