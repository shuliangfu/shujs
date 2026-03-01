# Shu.fs API 缺口与特色能力分析

本文档对比当前 Shu.fs 与 Node/Bun/Deno，列出**已实现**的 API 与**可选/后续**建议补充项。

---

## 一、已实现清单（全部已挂到 Shu.fs）

以下 API 均已实现**同步 + 异步**（异步为 Promise，纯 Zig 延迟队列、无内联 JS），并遵循 `--allow-read` / `--allow-write` 权限。

### 1. 读/写

| 能力 | 同步 | 异步 | 说明 |
|------|------|------|------|
| 读文件 | **readFileSync** / readSync | **readFile** / read | 含 encoding、Buffer 零拷贝、大文件 mmap |
| 写文件 | **writeFileSync** / writeSync | **writeFile** / write | 异步 content 上限 512KB |

### 2. 目录

| 能力 | 同步 | 异步 | 说明 |
|------|------|------|------|
| 读目录 | **readdirSync** | **readdir** | 返回 string[] |
| 创建目录（单层） | **mkdirSync** | **mkdir** | |
| 递归创建 | **mkdirRecursiveSync** / **ensureDirSync** | **mkdirRecursive** / **ensureDir** | 幂等 |
| 删空目录 | **rmdirSync** | **rmdir** | |
| 递归删除 | **rmdirRecursiveSync** | **rmdirRecursive** | 递归删目录及内容 |

### 3. 存在/元信息

| 能力 | 同步 | 异步 | 说明 |
|------|------|------|------|
| 是否存在 | **existsSync** | **exists** | 返回 boolean |
| 元数据 | **statSync** | **stat** | 返回 isFile / isDirectory / size / mtimeMs |
| 不跟链接的 stat | **lstatSync** | **lstat** | 返回对象含 **isSymbolicLink** |
| 规范绝对路径 | **realpathSync** | **realpath** | 解析符号链接与 `.`/`..` |

### 4. 删除/重命名/复制/追加

| 能力 | 同步 | 异步 | 说明 |
|------|------|------|------|
| 删文件 | **unlinkSync** | **unlink** | |
| 重命名/移动 | **renameSync** | **rename** | |
| 复制文件 | **copySync** / **copyFileSync** | **copy** / **copyFile** | 大文件 copy 走 mmap |
| 追加写 | **appendSync** / **appendFileSync** | **append** / **appendFile** | 文件不存在则创建 |

### 5. 链接

| 能力 | 同步 | 异步 | 说明 |
|------|------|------|------|
| 创建符号链接 | **symlinkSync** | **symlink** | |
| 读链接目标 | **readlinkSync** | **readlink** | 返回 string |

### 6. Node 兼容命名（与上同实现）

| 同步 | 异步 |
|------|------|
| readFileSync、writeFileSync、copyFileSync、appendFileSync | readFile、writeFile、copyFile、appendFile |
| ensureDirSync（= mkdirRecursiveSync） | ensureDir（= mkdirRecursive） |

### 7. Shu 特色 / Node 常用补充（已实现）

| 能力 | 同步 | 异步 | 说明 |
|------|------|------|------|
| 截断文件 | **truncateSync** | **truncate** | 将文件截断到指定长度 |
| 权限检查 | **accessSync** | **access** | 按 R/W/X 检查可访问性 |
| 是否空目录 | **isEmptyDirSync** | **isEmptyDir** | 无任何条目为 true |
| 仅文件大小 | **sizeSync** | **size** | 仅文件，热路径少返回字段 |
| 是否文件/目录 | **isFileSync** / **isDirectorySync** | **isFile** / **isDirectory** | 返回 boolean |
| 目录项+stat | **readdirWithStatsSync** | **readdirWithStats** | 一步返回 name + 简化 stat，减少 N+1 stat |
| 幂等创建空文件 | **ensureFileSync** | **ensureFile** | 不存在则创建空文件（含父目录），存在则不动 |

---

## 二、建议补充 — Node 兼容（当前均已实现）

以下为文档保留的「原建议项」，**状态均为已实现**。

### 1. realpathSync / realpath — **已实现**

- **用途**：解析符号链接与 `.`/`..`，得到规范绝对路径。
- **Node**：`fs.realpathSync(path)` / `fs.promises.realpath(path)`。
- **实现**：已挂到 Shu.fs，同步/异步均有。

### 2. lstatSync / lstat — **已实现**

- **用途**：对路径做 stat 但**不跟符号链接**，得到链接本身信息（如 isSymbolicLink、size 为链接目标路径长度）。
- **实现**：已挂到 Shu.fs，stat 返回对象含 `isSymbolicLink` 字段。

### 3. truncateSync / truncate — **已实现**

- **用途**：将文件截断到指定长度（如清空日志、预分配后收缩）。
- **实现**：已挂到 Shu.fs，同步/异步均有。

### 4. accessSync / access — **已实现**

- **用途**：检查路径是否可读/可写/可执行（Node 的 `fs.constants.R_OK | W_OK | X_OK`）。
- **实现**：已挂到 Shu.fs，支持按权限细粒度检查。

---

## 三、建议补充 — Shu 特色（当前均已实现）

以下为文档保留的「原建议项」，**状态均为已实现**。

### 1. isEmptyDirSync / isEmptyDir — **已实现**

- **用途**：判断目录是否为空（无任何条目）。
- **实现**：已挂到 Shu.fs，同步/异步均有。

### 2. sizeSync / size — **已实现**

- **用途**：只关心文件大小时，避免拿完整 stat 再取 size。
- **实现**：已挂到 Shu.fs，仅文件有定义。

### 3. isFileSync / isDirectorySync（及异步） — **已实现**

- **用途**：只问「是否文件/是否目录」，返回 boolean。
- **实现**：已挂到 Shu.fs，同步/异步均有。

### 4. readdirWithStatsSync / readdirWithStats — **已实现**

- **用途**：列出目录项并带每项 stat（name + isFile/isDirectory/size/mtime 等），避免 N 次 readdir + N 次 stat。
- **实现**：已挂到 Shu.fs，一步返回「name + 简化 stat」。

### 5. ensureFileSync / ensureFile — **已实现**

- **用途**：路径不存在则创建空文件（含父目录），存在则不动；类似 `touch` 的幂等创建。
- **实现**：已挂到 Shu.fs，与 ensureDir 对称。

---

## 四、可选 / 后续考虑（未实现）

| API | 说明 |
|-----|------|
| **watch / watchSync** | 文件/目录监视；实现复杂、平台差异大，可后续单独模块或依赖 io_core 事件。 |
| **chmodSync / chmod** | 改权限；跨平台语义不一，可按需再补。 |
| **glob / globSync** | 模式匹配；实现量大，可先不内置，或只做「单层匹配」简化版。 |
| **linkSync / link** | 硬链接；Node/Deno 有，使用频率较低，可后续补。 |
| **fsyncSync / fsync** | 刷盘；面向持久化保证，专业场景再补。 |

---

## 五、实施优先级参考（已实现项已标注）

| 优先级 | API | 状态 |
|--------|-----|------|
| P0 | realpathSync / realpath | **已实现** |
| P1 | isEmptyDirSync / isEmptyDir | **已实现** |
| P1 | readdirWithStatsSync / readdirWithStats | **已实现** |
| P2 | lstatSync / lstat | **已实现** |
| P2 | truncateSync / truncate | **已实现** |
| P2 | sizeSync / size | **已实现** |
| P3 | accessSync / access | **已实现** |
| P3 | isFileSync / isDirectorySync | **已实现** |
| P3 | ensureFileSync / ensureFile | **已实现** |

以上「建议补充」项均已实现；未实现部分见**四、可选/后续考虑**。实现时需遵循项目内 fs 的权限（--allow-read/--allow-write）、allocator 与错误处理约定，并在模块顶注释中更新 API 列表。
