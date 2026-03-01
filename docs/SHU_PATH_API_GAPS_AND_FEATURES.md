# Shu.path API 缺口与特色能力分析

本文档对比当前 Shu.path 与 Node/Deno 的 path 模块，列出**建议补充**的 API，并区分「Node 兼容」与「Shu 特色」。

## 一、当前已有能力（简要）

| 方法/属性 | 说明 |
|-----------|------|
| **join(...parts)** | 多段路径用平台分隔符拼接 |
| **resolve(...parts)** | 相对 cwd 解析为绝对路径（从右到左） |
| **dirname(path)** | 目录部分（不含最后一段） |
| **basename(path [, ext])** | 最后一段；可选去掉后缀 ext |
| **extname(path)** | 扩展名（含点，如 ".zig"） |
| **normalize(path)** | 规范化（.、..、多余分隔符） |
| **isAbsolute(path)** | 是否绝对路径 |
| **relative(from, to)** | 从 from 到 to 的相对路径 |
| **filePathToUrl(path)** | 路径 → file: URL（等价 Node url.pathToFileURL） |
| **urlToFilePath(url)** | file: URL → 路径（等价 Node url.fileURLToPath） |
| **sep** | 路径分隔符（`/` 或 `\`） |
| **delimiter** | 环境变量分隔符（`:` 或 `;`） |

---

## 二、建议补充 — Node/Deno 兼容、常用

### 1. parse(path) — **优先补**

- **用途**：将路径拆成 `{ root, dir, base, name, ext }`，便于程序化修改再拼回。
- **Node**：`path.parse(path)` 返回 `{ root, dir, base, name, ext }`。
- **实现**：用现有 `dirname`/`basename`/`extname` 组合；`root` 按平台从绝对路径首部截取（POSIX 为 `"/"`，Windows 为 `"C:\\"` 或 `"\\\\server\\share"`）。
- **与 fs 的联动**：fs 的 `realpathSync` 等依赖路径解析；path 只做字符串解析，不访问文件系统。

### 2. format(pathObject) — **优先补**

- **用途**：从 `{ root, dir, base, name, ext }` 组装路径，与 `parse` 配对。
- **Node**：`path.format({ dir, base })` 或 `{ root, name, ext }` 等组合；若提供 `dir`+`base` 则 `dir + sep + base`，否则用 `root`+`name`+`ext`（缺省在 ext 前加点）。
- **实现**：按 Node 规则：有 `dir` 且（有 `base` 或 有 `name`/`ext`）则优先用 dir+base 或 dir+name+ext；否则 root+base 或 root+name+ext。

### 3. posix / win32 子对象 — **已实现**

- **用途**：跨平台脚本中强制用 POSIX 或 Windows 规则（如 Windows 上解析 POSIX 路径）。
- **Node**：`path.posix.join(...)`、`path.win32.basename(...)` 等，与默认 `path` 同 API 但 sep/规则固定。
- **实现**：`Shu.path.posix` / `Shu.path.win32` 子对象，相同方法 + 固定 sep/delimiter（posix: `/`、`:`，win32: `\`、`;`），方法实现与默认 path 共用。

### 4. toNamespacedPath(path) — **已实现**

- **用途**：将路径转为 Windows 长路径命名空间形式（`\\?\...`），用于超长路径。
- **实现**：先 resolve 为绝对路径；Windows 下加 `\\?\` 或 `\\?\UNC` 前缀，非 Windows 返回规范化路径。

---

## 三、建议补充 — Shu 特色（已实现）

- **path.root(path)**：仅返回「根」部分（如 `"/"`、`"C:\\"`），与 parse(path).root 一致。
- **path.name(path)**：仅返回「文件名无扩展名」（即 parse(path).name），与现有 `basename`/`extname` 并存。

---

## 四、与 fs 的依赖关系

- **path 为纯字符串/解析**：不访问文件系统，无 `--allow-read`/`--allow-write`。
- **fs.realpathSync** 等会用到「解析后的路径」再交给 `std.fs.realpath`；path 的 `resolve`/`normalize` 已可提供「逻辑上的绝对/规范路径」，realpath 再在 fs 层做「物理解析（跟符号链接）」。
- 先完善 path（parse/format），再在 fs 中实现 realpathSync 等，可复用 path 的 root/dir/base 等语义，保持与 Node 一致。

---

## 五、实施状态（均已实现）

| API | 状态 |
|-----|------|
| **parse(path)** | 已实现 |
| **format(pathObject)** | 已实现 |
| **posix / win32** | 已实现（子对象 + sep/delimiter，方法共用默认 path） |
| **toNamespacedPath(path)** | 已实现 |
| **root(path)** | 已实现（Shu 特色） |
| **name(path)** | 已实现（Shu 特色） |

实现遵循项目内显式 allocator、错误处理与注释规范。
