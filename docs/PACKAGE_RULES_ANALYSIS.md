# package 模块规则符合性分析

基于 `.cursor/rules/00-性能规则.mdc` 与 `01-代码规则.mdc` 对 `src/package/` 的逐项分析。

---

## 一、01-代码规则符合情况

### 1.1 分配器 (Allocator) — 总体符合

| 文件 | 符合点 | 说明 |
|------|--------|------|
| cache.zig | ✅ | 所有 pub/fn 均显式接收 `allocator`；模块头注释写明「调用方负责 free」getCacheRoot、getCachedTarball、getCachedUrlPath、urlCachePath；getCachedTarball 返回路径时用 defer free 清理失败路径。 |
| registry.zig | ✅ | resolveVersionAndTarball、httpGet、downloadUrlToPath、downloadToPath 等均传 allocator；文档注明「调用方 free」返回值；errdefer 释放 version。 |
| resolver.zig | ✅ | resolve、findProjectRoot、findNodeModulesPackage、resolvePackageEntry 等均传 allocator；注释写明「调用方负责 free」ResolveResult.file_path/cache_key。 |
| manifest.zig | ✅ | load/loadPackageOnly 用 Arena，文档说明「返回的 arena 由调用方 deinit」；stripJsoncComments、addPackageDependency、addDenoImport 显式 allocator，返回值或中间分配均有 defer/调用方 free 约定。 |
| lockfile.zig | ✅ | load/save 显式 allocator；load 返回的 map 文档注明「调用方 deinit」。 |
| install.zig | ✅ | install、extractTarballToNodeModules 接收 allocator；临时路径、resolved map 等均有 defer free 或循环内 free。 |
| export_map.zig | ✅ | resolve 接收 allocator；ResolveExportResult.caller_owns 明确「调用方须 free result.path」；allocPrint 分配时 caller_owns=true。 |

**已处理**：`manifest.zig` 中 deno 分支已加注释说明：仅当 `.jsonc` 时 `deno_to_parse` 为 stripJsoncComments 新分配（需 free）；`.json` 时为 `deno_content` 别名（arena），不 free，避免 double-free。

### 1.2 错误处理 — 符合

- 能传播的用 `!T` / `!void`，调用处 `try`；`catch` 有明确 fallback（如 resolver 中 `catch continue`、install 中 `catch {}` 等）。
- 清理用 `defer`/`errdefer` 放在分配/打开之后，多分支下未发现遗漏释放。

### 1.3 注释与文档 — 符合

- 模块顶有职责说明与 PACKAGE_DESIGN 引用。
- 公开函数用 `///` 写用途、参数、返回值与「谁 free」；内部函数有 `//` 说明。
- 修改时保留了原有注释风格。

### 1.4 打印输出 — 基本不涉及

- package 为库代码，无直接面向用户的 CLI 输出；若将来在 install 等处增加进度/错误提示，需遵守「一律英文」。

### 1.5 通用约定 — 符合

- 优先 `const`；缓冲区按需初始化；未发现依赖未定义行为。

---

## 二、00-性能规则符合情况

### 2.1 内存与分配（§1）

| 规则 | 符合情况 | 说明 |
|------|----------|------|
| §1.1 显式 allocator | ✅ | 全模块无隐式全局 allocator。 |
| §1.2 Arena 优先 | ✅ | manifest.load / loadPackageOnly、install 内对单次「加载 manifest / 单次 install」使用 Arena，任务结束 deinit。 |
| §1.3 栈优先 | ⚠️ 部分 | 小缓冲用栈（如 registry 中 redirect_buf、transfer_buf）；install 中 `readToEndAlloc(allocator, std.math.maxInt(usize))` 对大 tgz 整块进堆，符合「大块用堆」但可考虑流式解压以控制峰值内存。 |
| §1.5 容器显式 allocator | ✅ | ArrayList/HashMap 均 init(allocator)、append(allocator, ...)、deinit(allocator)。 |

### 2.2 I/O 与 io_core（§3.0）

| 规则 | 符合情况 | 说明 |
|------|----------|------|
| §3.0 统一经 io_core | ❌ 未满足 | 当前 package 全路径使用 `std.fs`（openFileAbsolute、createFile、readToEndAlloc、copyFileAbsolute、makePath、openDir 等）和 `std.http.Client`，未经过 `src/runtime/io_core`。规则允许的例外为「路径与目录、进程 stdio、启动与工具」；package 的「读 manifest、写 lock、解压到 node_modules、网络下载」属于热路径读写，规则要求逐步迁移至 io_core 并在未迁移处注释标注。 |

**建议**：在 cache.zig、registry.zig、install.zig、lockfile.zig、manifest.zig、resolver.zig 顶部或相关函数上加注释，例如：「待迁移至 io_core：当前使用 std.fs/std.net 做文件与网络 I/O，见规则 §3.0。」

### 2.3 网络与平台（§3.1–§4）

- **registry.zig**：使用 `std.http.Client` 同步 GET，未使用 io_uring/kqueue/IOCP；规则要求网络 I/O 经 io_core 并最终走平台特化路径，当前为「先跑通、后迁移」的合理状态，但需在文档/注释中标明为待迁移。
- **大文件读**：install 中整包 readToEndAlloc 再解压；规则 §1.7 建议大文件用 mmap。可后续改为流式解压或 io_core 的 mapFileReadOnly，减少峰值内存。

### 2.4 字符串与格式化（§7）

| 规则 | 符合情况 | 说明 |
|------|----------|------|
| 热路径避免 allocPrint/format 临时分配 | ⚠️ 部分 | lockfile.save 用 `list.writer(allocator)` + format 写 JSON，属于单次写锁文件，非极热路径，可接受。resolver 中多次 `std.fs.path.join(allocator, &.{...})`、`std.mem.concat` 为路径拼接必需。export_map 中 `allocPrint` 仅在对 exports 做模式展开时使用，频率与解析次数相关，可保留；若该路径变热可考虑复用 buffer。 |

### 2.5 Comptime（§2）

- 未将「协议前缀、固定字符串」等提到 comptime；当前体量下影响小，若后续在 resolver 中做大量字符串分支，可考虑 comptime 查找表或分支剪枝。

---

## 三、汇总与建议

### 已做得好的

1. **显式 allocator 与所有权**：全模块统一由调用方传入 allocator，返回值/中间分配的「谁 free」在注释或类型（如 caller_owns）中写清。
2. **Arena 使用**：manifest 加载、单次 install 流程用 Arena，符合请求级/任务级一次性释放。
3. **错误与清理**：`!T`、try、defer/errdefer 使用一致，无明显泄漏路径。
4. **文档与注释**：模块与公开 API 注释完整，符合 01 规则。

### 必须/建议改进

1. **§3.0 io_core**（必须标注，逐步迁移） — **已落实**
   - 已在 **cache.zig、registry.zig、install.zig、lockfile.zig、manifest.zig、resolver.zig** 模块顶增加 `// TODO: migrate to io_core (rule §3.0); ...` 注释。
   - 后续：在 io_core 提供「文件读/写/目录」「HTTP 客户端」等封装后，将 package 的下载、缓存、解压、lock 读写改为经 io_core。

2. **大 tgz 内存（建议）** — **已落实**
   - install 中 `extractTarballToNodeModules` 已改为使用 **io_core.mapFileReadOnly**（`src/runtime/io_core`）映射 .tgz，零拷贝、按需换页（§1.7），不再用 readToEndAlloc 整包进堆；解压与写文件仍为 std.fs，待 io_core 提供通用文件 API 后可继续迁移。

3. **面向用户输出（若将来加）**
   - 若在 install/add 等增加进度或错误文案，需全部使用英文，符合 01 规则「打印输出」一节。

### 可选优化（非必须）

- **Comptime/常量** — **已落实**：resolver.zig 已增加模块级常量 `prefix_https`、`prefix_http`、`prefix_jsr`，统一协议前缀并便于编译器优化（§2.1）。
- **lockfile.save**：已用 ArrayList + writer，格式化为单次写入，无需为性能优先改动。

---

## 四、结论

- **01-代码规则**：package 模块在分配器、错误处理、注释、通用约定上**符合**要求；无面向用户打印，暂无违反「英文输出」。
- **00-性能规则**：显式 allocator、Arena、容器 API **符合**；**不符合** §3.0「所有 I/O 经 io_core」—— 当前全部使用 std.fs/std.http，需在代码中标注「待迁移至 io_core」并在后续迭代中迁移。大文件读可考虑流式或 mmap 以进一步贴合 §1.3/§1.7。

**已完成的优化**（见上文）：io_core 迁移注释已加入 6 个 package 文件；manifest.zig deno_to_parse 所有权已注释澄清；**install.zig 解压 tgz 已迁至 io_core.mapFileReadOnly**（大文件零拷贝）；resolver.zig 协议前缀已改为模块常量。其余 cache/registry/lockfile/manifest/resolver 的文件与网络 I/O 仍待 io_core 提供通用文件/目录与 HTTP 客户端后再迁。
