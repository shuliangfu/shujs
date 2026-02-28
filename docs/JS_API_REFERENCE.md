# Shu 运行时 JavaScript API 参考

本文档由 `scripts/generate_js_api_docs.zig` 从 `src/runtime/engine/BUILTINS.md` 自动生成，仅包含**已实现并注册**的宿主 API。

---

## 全局

| API | 说明 | 权限/备注 |
|-----|------|----------|
| `console.log` / `warn` / `error` / `info` / `debug` | 控制台输出 | 无 |
| `setTimeout(cb, ms)` | 延迟执行 | 返回 id |
| `setInterval(cb, ms)` | 周期执行 | 返回 id |
| `clearTimeout(id)` | 取消 timeout | 无 |
| `clearInterval(id)` | 取消 interval | 无 |
| `setImmediate(cb)` | 下一轮事件循环执行（与 setTimeout(cb,0) 同源） | 返回 id |
| `clearImmediate(id)` | 取消 setImmediate | 与 clearTimeout 共用 id 空间 |
| `queueMicrotask(fn)` | 微任务：脚本结束后、runLoop 前执行 | 无 |
| `fetch(url)` | 同步 HTTP GET | `--allow-net` |
| `atob(str)` | Base64 解码为二进制字符串 | 非法输入抛 DOMException |
| `btoa(str)` | 二进制字符串编码为 Base64 | 字符码点需 0–255 |
| `TextEncoder` / `TextDecoder` | 字符串与 UTF-8 互转：new TextEncoder().encode(str) 返回 Uint8Array，new TextDecoder().decode(buffer) 返回字符串 | 若 JSC 未提供则宿主注册 |
| `URL` / `URLSearchParams` | 解析 URL：new URL(input [, base]) 得 href/origin/pathname/search/hash/searchParams；URLSearchParams 支持 get/getAll/toString | 仅当 globalThis.URL 未定义时注册 |
| `AbortController` / `AbortSignal` | 取消请求：new AbortController() 得 .signal、.abort()；signal.aborted 为 boolean | 仅当未定义时注册 |
| `performance` / `performance.now()` | 高精度计时（毫秒），用于测量耗时 | 仅当未定义时注册 |
| `crypto.randomUUID()` | 返回 RFC 4122 UUID v4 字符串 | 无 |
| `crypto.CHACHA20_POLY1305` / `crypto.AES_256_GCM` | 对称加密算法常量，可作为 encrypt 的第三个参数传入，无需手写字符串 | 只读字符串属性 |
| `crypto.digest(algorithm, data)` | 哈希：支持 "SHA-1"、"SHA-256"、"SHA-384"、"SHA-512"，返回十六进制字符串 | data 为字符串，按 UTF-8 哈希 |
| `crypto.encrypt(key, plaintext [, algorithm])` | 对称加密：algorithm 可选 crypto.CHACHA20_POLY1305（默认）、crypto.AES_256_GCM；key 为 64 位十六进制或任意密码字符串，返回 base64(alg\ | tag\ |
| `crypto.decrypt(key, ciphertext)` | 对称解密：支持新格式（含 alg 字节）与旧格式（无 alg，仅 ChaCha），ciphertext 为 encrypt 返回的 base64 | 密钥错误或数据损坏抛错 |
| `crypto.generateKeyPair(algorithm)` | 非对称密钥对生成，当前支持 "X25519"，返回 `{ publicKey, privateKey }`（base64 字符串） | 无 |
| `crypto.encryptWithPublicKey(recipientPublicKey, plaintext)` | 非对称加密：用对方公钥（base64）加密，内部 X25519 协商 + ChaCha20-Poly1305，返回 base64 | 公钥须为 generateKeyPair 产出的 base64 |
| `crypto.decryptWithPrivateKey(privateKey, ciphertext)` | 非对称解密：用己方私钥（base64）解密 encryptWithPublicKey 的密文 | 私钥/密文错误抛错 |
| `crypto.getRandomValues(typedArray)` | 用安全随机数填充 TypedArray | 当前占位（需 JSC TypedArray C API） |
| `process` | 进程信息 | 需 RunOptions |
| `__dirname` | 当前文件所在目录 | 只读 |
| `__filename` | 当前文件绝对路径 | 只读 |
## process（子属性/方法）

| API | 说明 | 权限/备注 |
|-----|------|----------|
| `process.cwd` | 当前工作目录字符串 | 只读 |
| `process.argv` | 命令行参数数组 | 只读 |
| `process.env` | 环境变量对象 | `--allow-env` 才有内容 |
| `process.send(msg)` / `process.receiveSync()` | 多进程/多线程 IPC（仅 fork 子进程或 thread 工作线程内可用） | 见 Shu.system.fork、Shu.thread |
## Shu.fs（文件系统，与 node:fs/deno:fs 命名统一）

| API | 说明 | 权限/备注 |
|-----|------|----------|
| `Shu.fs.read(path)` / `Shu.fs.readSync(path)` | 异步 Promise\<string\> / 同步读文件为 string | `--allow-read` |
| `Shu.fs.write(path, content)` / `Shu.fs.writeSync(path, content)` | 异步 Promise\<void\> / 同步写文件 | `--allow-write`，异步 content 上限 512KB |
| `Shu.fs.readdir(path)` / `Shu.fs.readdirSync(path)` | 异步 Promise\<string[]\> / 同步 string[] | `--allow-read` |
| `Shu.fs.mkdir(path)` / `Shu.fs.mkdirSync(path)` | 异步 Promise\<void\> / 同步创建单层目录 | `--allow-write` |
| `Shu.fs.exists(path)` / `Shu.fs.existsSync(path)` | 异步 Promise\<boolean\> / 同步 boolean | `--allow-read` |
| `Shu.fs.stat(path)` / `Shu.fs.statSync(path)` | 异步 Promise\<stat\> / 同步 { isFile, isDirectory, size, mtimeMs } | `--allow-read` |
| `Shu.fs.unlink(path)` / `Shu.fs.unlinkSync(path)` | 异步 Promise\<void\> / 同步删文件 | `--allow-write` |
| `Shu.fs.rmdir(path)` / `Shu.fs.rmdirSync(path)` | 异步 Promise\<void\> / 同步删空目录 | `--allow-write` |
| `Shu.fs.rename(old, new)` / `Shu.fs.renameSync(old, new)` | 异步 Promise\<void\> / 同步重命名/移动 | `--allow-read` + `--allow-write` |
| `Shu.fs.copy(src, dest)` / `Shu.fs.copySync(src, dest)` | 异步 Promise\<void\> / 同步复制文件 | `--allow-read` + `--allow-write` |
| `Shu.fs.append(path, content)` / `Shu.fs.appendSync(path, content)` | 异步 Promise\<void\> / 同步追加写入（文件不存在则创建） | `--allow-write`，异步 content 上限 512KB |
| `Shu.fs.symlink(target, linkPath)` / `Shu.fs.symlinkSync(target, linkPath)` | 异步 Promise\<void\> / 同步创建符号链接 | `--allow-write` |
| `Shu.fs.readlink(path)` / `Shu.fs.readlinkSync(path)` | 异步 Promise\<string\> / 同步返回链接目标路径 | `--allow-read` |
| `Shu.fs.mkdirRecursive(path)` / `Shu.fs.mkdirRecursiveSync(path)` | 异步 Promise\<void\> / 同步递归创建目录（mkdir -p 风格） | `--allow-write` |
| `Shu.fs.rmdirRecursive(path)` / `Shu.fs.rmdirRecursiveSync(path)` | 异步 Promise\<void\> / 同步递归删除目录及内容（rm -rf 风格） | `--allow-write` |
## Shu.path

| API | 说明 | 权限/备注 |
|-----|------|----------|
| `Shu.path.join(...parts)`、`Shu.path.resolve(...parts)`、`dirname`、`basename`、`extname`、`normalize`、`isAbsolute`、`relative`、`filePathToUrl`、`urlToFilePath`、`sep`、`delimiter` | 路径工具 | 无 |
## Shu.system

| API | 说明 | 权限/备注 |
|-----|------|----------|
| `Shu.system.exec(cmd)` / `execSync(cmd)` | 通过 shell 执行命令，返回 `{ stdout, stderr, code }` | `--allow-exec` |
| `Shu.system.run(options)` / `runSync(options)` | 不经过 shell 执行（options.cmd 数组、cwd），返回 `{ status, stdout, stderr }` | `--allow-exec` |
| `Shu.system.spawn(options)` / `spawnSync(options)` | 同 run，当前实现与 run 一致 | `--allow-exec` |
| `Shu.system.fork(modulePath [, args] [, options])` | Node 式多进程：启动子 Shu 进程，返回 `{ send, kill, receiveSync }`，子进程内 `process.send`/`receiveSync` | `--allow-exec`，env SHU_FORKED 自动设置 |
## Shu.thread

| API | 说明 | 权限/备注 |
|-----|------|----------|
| `Shu.thread.spawn(scriptPath [, options])` | 多线程：在新线程中运行脚本，返回 `{ send, receiveSync, join }`，工作线程内 `process.send`/`receiveSync` | 无 |
## Shu

| API | 说明 | 权限/备注 |
|-----|------|----------|
| `Shu.server(options)` | HTTP 服务端（非阻塞）：监听 `options.port`（或 `options.unix`），立即返回 server 对象；需 `options.fetch` 或 `options.handler`。支持 TLS、HTTP/2、WebSocket、压缩（br/gzip/deflate）、keep-alive、onListen、onError、signal。 | `--allow-net` |
| `server.stop()` | 停止监听并释放资源，下一轮 tick 生效。 | 无 |
| `server.reload(newOptions)` | 热重载：用 `newOptions` 更新 handler、config、compression、onError、runLoop、webSocket 等，不关 listener。 | 无 |
| `server.restart()` / `server.restart(newOptions?)` | 重启：下一轮 tick 关闭当前 listen，再用原地址或 `newOptions` 中的地址重新 listen；可同时更新配置。 | 无 |
| `Shu.crond(expression, callback)` | 计划任务：六段 cron 表达式（秒 分 时 日 月 周），如 `"* * * * * *"`，返回 `{ stop }` | 支持 *、N、*/N、N-M |
## Shu / 全局

| API | 说明 | 权限/备注 |
|-----|------|----------|
| `Shu.crondClear(id)` / `crondClear(id)` | 取消指定 id；不传参则清空所有由 Shu.crond 创建的任务 | 无 |
