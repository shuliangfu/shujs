# Package 与依赖解析设计（Node / Deno / Bun 兼容）

目标：**无缝兼容 Node、Deno、Bun**——除兼容 package.json 外，支持 deno.json、默认以 package.json 为主，并能**直接安装与解析 Deno JSR 包**。

**吸收 Deno 长处**：**一个 package.json 即可承载全部配置**——test、fmt、lint、compilerOptions 等与 deno.json **同结构**写入 package.json，**无需单独 tsconfig.json**；有 deno.json 时二者合并（deno 优先），无 deno 时仅读 package.json 即可。

---

## 1. Manifest 双轨：package.json + deno.json

### 1.1 发现顺序与默认

| 约定 | 说明 |
|------|------|
| **默认主 manifest** | 在项目根（或 `shu run/build` 的 cwd）优先查找 **package.json**；若存在则作为「主 manifest」，用于 scripts、dependencies、main、exports。 |
| **deno.json 可选** | 若存在 **deno.json**（或 deno.jsonc），作为**补充**：提供 `imports`（import map）、`tasks`；可与 package.json 并存。 |
| **主 manifest 可配置** | 后续可通过 `shu.json` 或环境变量指定「仅用 deno.json」等，便于纯 Deno 项目用 shu 跑；首版实现可固定为「有 package.json 则主用 package.json，deno.json 仅补 imports/tasks」。 |

### 1.2 package.json（Node 标准 + Deno 风格扩展）

- **用途**：name、version、main、**exports**、dependencies/devDependencies、scripts、type (module/commonjs)。**与 Deno 对齐**：package.json 亦可直接承载 **test**、**fmt**、**lint**、**compilerOptions**（与 deno.json 同结构），**无需 tsconfig.json**，一个文件搞定全部配置。
- **解析**：裸说明符 → 沿目录向上查 `node_modules/<specifier>` → 进包目录后按 **main** 或 **exports** 解析到真实文件。
- **与 require/ESM 对齐**：resolveRequest / ESM resolver 最终都要用「main + exports」决定包入口与子路径。
- **test / fmt / lint / compilerOptions**：与 deno.json 字段名与结构一致（include、exclude、permissions 等）。有 deno.json 时 **deno 优先**，无 deno 时仅读 package.json；合并后供 `shu test`、`shu fmt`、`shu lint` 及 TS 编译使用，不再依赖单独 tsconfig.json。

### 1.3 deno.json（Deno）

- **用途**：`imports`（import map）、`tasks`、`compilerOptions`；可含 `name`/`version`（用于 JSR 发布）；**`lint`、`fmt`**（与 Deno 官方对齐）。
- **imports**：把「裸 key」映射到具体说明符，例如：
  - `"@luca/flag": "jsr:@luca/flag@^1.0.1"`
  - `"lodash": "npm:lodash@4"
- **与解析的关系**：解析裸说明符时，**先查 import map**（deno.json 的 imports），命中则用映射后的值再解析；未命中再走 node_modules。
- **lint**（Deno 官方格式）：`include`/`exclude` 路径或 glob；`rules` 下 `tags`、`include`、`exclude` 规则。package.json 亦可写同名字段，合并时 deno 优先。
- **fmt**（Deno 官方格式）：`useTabs`、`lineWidth`、`indentWidth`、`semiColons`、`singleQuote`、`proseWrap` 等；`include`/`exclude`。package.json 同上。
- **test**：`include`、`exclude`、`permissions`。package.json 同上，实现 `shu test` 时从合并配置读。
- **compilerOptions**：TypeScript 选项（lib、strict 等）。package.json 同上，**无需单独 tsconfig.json**。

### 1.4 统一抽象（建议 manifest.zig）

- **Manifest 类型**：可设计为「联合」或「单一结构体 + 可选字段」：
  - 从 **package.json** 解析：main、exports、dependencies、scripts、type；**test**、**fmt**、**lint**、**compilerOptions**（与 deno 同结构，实现后无需 tsconfig.json）。
  - 从 **deno.json** 解析：imports、tasks、**lint**、**fmt**、**test**、**compilerOptions**。
- **load 语义**：`load(allocator, dir)` 在 `dir` 下读 package.json（必选）与 deno.json（可选），**合并**为一份 manifest；**test / fmt / lint / compilerOptions** 的合并规则：同名字段 deno 优先，无 deno 则用 package。这样 `shu test`、`shu fmt`、`shu lint` 及 TS 编译统一从合并结果读取，一个 package.json 即可满足全部配置。
- **exports 解析**：Node 的 `exports` 条件导出（import/require、default、子路径）需单独实现或抽子模块（如 export_map.zig），供 resolver 查包入口与子路径。

### 1.5 配置字段一览（deno.json / package.json）

以下列出 **deno.json**（及 deno.jsonc）与 **package.json**（及 package.jsonc）中与 shu 相关的配置字段；「shu 当前」表示 manifest.zig 是否已解析/使用。

#### deno.json（Deno 官方 + shu 兼容）

| 字段 | 说明 | shu 当前 |
|------|------|----------|
| **imports** | Import map：裸说明符 → jsr:/npm:/路径 | ✅ 已解析 |
| **tasks** | 任务名 → 命令（等同 scripts 补充） | ✅ 已解析 |
| **compilerOptions** | TypeScript 编译选项（lib、strict 等） | 未用 |
| **lint** | Lint 配置：include、exclude、rules（tags/include/exclude） | 未解析（lint 占位） |
| **fmt** | 格式化：useTabs、lineWidth、indentWidth、semiColons、singleQuote、proseWrap、include、exclude | 未解析（fmt 占位） |
| **lock** | 锁文件：path、frozen；或 false 关闭 | 未用（shu 用 shu.lock） |
| **nodeModulesDir** | "none" \| "auto" \| "manual" | 未用 |
| **exclude** | 顶层排除：lint/fmt/test 等子命令默认排除的路径 | 未用 |
| **permissions** | 命名权限集；default / test / bench / compile 下权限 | 未用 |
| **test** | 测试：include、exclude、permissions | 未用 |
| **bench** | 基准：include、exclude、permissions | 未用 |
| **exports** | 包发布入口（JSR 等） | 未用 |
| **unstable** | 不稳定特性列表 | 未用 |
| **links** | 本地包覆盖（类 npm link） | 未用 |
| **publish** | 发布排除/包含 | 未用 |
| **name** / **version** | JSR 发布用，可与 package 并存 | 未解析 |

#### package.json（Node/npm 标准 + Deno 风格扩展，一个文件搞定全部配置）

| 字段 | 说明 | shu 当前 |
|------|------|----------|
| **name** | 包名 | ✅ 已解析 |
| **version** | 版本（semver） | ✅ 已解析 |
| **main** | 包入口文件 | ✅ 已解析 |
| **type** | "module" \| "commonjs" | ✅ 已解析 |
| **exports** | 条件导出（import/require、子路径） | ✅ 已解析（export_map） |
| **scripts** | 脚本名 → 命令 | ✅ 已解析 |
| **dependencies** | 运行时依赖 | ✅ 已解析（install 来源） |
| **devDependencies** | 开发依赖 | 未解析（可按需扩展 install） |
| **test** | 与 deno.json 同结构：include、exclude、permissions；无需 tsconfig | 未解析（test 实现时读） |
| **fmt** | 与 deno.json 同结构：useTabs、lineWidth、indentWidth、semiColons、singleQuote、include、exclude | 未解析（fmt 占位） |
| **lint** | 与 deno.json 同结构：include、exclude、rules | 未解析（lint 占位） |
| **compilerOptions** | 与 deno.json 同结构：TS 选项（lib、strict 等）；无需 tsconfig.json | 未解析 |
| **peerDependencies** | 对等依赖 | 未用 |
| **optionalDependencies** | 可选依赖 | 未用 |
| **bundledDependencies** | 打包进发布体的依赖 | 未用 |
| **bin** | 可执行文件映射 | 未用 |
| **engines** | Node/npm 版本要求 | 未用 |
| **files** | 发布包含文件列表 | 未用 |
| **repository** | 仓库 URL/type | 未用 |
| **license** | SPDX 许可证 | 未用 |
| **description** / **keywords** / **homepage** / **bugs** / **author** | 元数据 | 未用 |
| **private** | 禁止发布 | 未用 |
| **publishConfig** | 发布时配置 | 未用 |

---

## 2. 说明符类型与解析顺序

### 2.1 说明符种类

| 类型 | 示例 | 处理方 |
|------|------|--------|
| 相对路径 | `./foo`、`../bar` | path.resolve(parent_dir, specifier) |
| 绝对路径 / file: | `/tmp/x`、`file:///tmp/x` | 规范化后直接作为路径 |
| 协议内置 | `node:fs`、`shu:fs`、`deno:`、`bun:` | 不进入 package 解析，直接走内置表 |
| 裸说明符（npm） | `lodash`、`@babel/core` | node_modules 查找 + 包内 main/exports |
| 裸说明符（JSR） | `jsr:@luca/cases`、`jsr:@luca/cases@1` | 见下节 |
| Import map 映射 | 代码里写 `@luca/flag`，deno.json 里 `"@luca/flag":"jsr:..."` | 先查 imports，再对映射值做解析 |
| **直接 HTTPS 包（Deno 风格）** | `https://example.com/pkg/mod.ts` | `shu add` 下载到缓存，解析时用缓存路径；**仅支持 https://，不支持 http://**。 |

### 2.2 解析顺序（resolver 主流程）

1. **协议与内置**：若为 `node:` / `shu:` / `deno:` / `bun:`，直接返回或走内置，不查 manifest。
2. **Import map（deno.json imports）**：若项目有 deno.json 且 specifier 在 `imports` 中，用映射后的值（可能是 `jsr:...`、`npm:...`、相对路径）**递归解析**。
3. **相对/绝对路径**：按路径解析，不查 node_modules。
4. **裸说明符**：
   - 若以 `jsr:` 开头 → 走 **JSR 解析**（见 2.3）。
   - 否则 → 沿 parent_dir 向上查 **node_modules/<specifier>**，找到包目录后按 **main / exports** 得到入口文件。

### 2.3 JSR 的两种用法（无缝兼容 Deno + Node 生态）

| 方式 | 说明 | shu 实现建议 |
|------|------|----------------|
| **原生 jsr: 说明符** | 代码里直接 `import x from "jsr:@luca/cases@1"`；Deno 原生支持。 | **解析**：识别 `jsr:@scope/name` 或 `jsr:@scope/name@version`；**安装**时可将该包拉取到本地缓存或 node_modules（见下）。**运行时**：若 node_modules 中已有（通过 install 写入），则当普通包解析；若无则需「按需拉取」或报错提示 `shu add jsr:@scope/name`。 |
| **npm 兼容层（@jsr）** | JSR 提供 `https://npm.jsr.io`，包名映射为 `@jsr/scope__name`；`npm install @jsr/luca__cases` 即装到 node_modules。 | **安装**：`shu add jsr:@luca/cases` 可等价于在 package.json 写入 `"@luca/cases": "npm:@jsr/luca__cases@^1"` 并执行 install，或直接 `npm i @jsr/luca__cases`；这样 **解析** 只需按裸说明符 `@luca/cases` 查 node_modules，与 Node 一致。 |

**建议**：

- **首版**：支持「**安装时**」把 JSR 包落到 node_modules（通过 npm 兼容层或自研拉取 https://npm.jsr.io tarball），解析时只当普通 npm 包（main/exports）；同时支持 deno.json 的 `imports` 里写 `"@luca/flag": "jsr:@luca/flag@^1"`，解析到 `jsr:` 时再解析为「从 node_modules/@jsr/scope__name 或已安装的别名」。
- **后续**：可选支持「**运行时**」对未安装的 `jsr:` 做按需拉取并缓存（类似 Deno），与 install 二选一或并存。

---

## 3. 直接安装 Deno JSR 包

### 3.1 CLI：shu install（必须支持）

- **`shu run` 自动安装依赖（Deno 风格）**：执行 `shu run <entry>` 时，若当前目录存在 package.json，会**先自动执行一次依赖安装**（等价于 `shu install`），再运行入口；无 package.json 则跳过。与 Deno 一致；Node/Bun 默认不在此处自动安装。
- **`shu install`**（无参数）：根据当前目录 **package.json** 的 dependencies（及可选 lockfile）安装到 node_modules；若有 deno.json 的 imports 中的 jsr: 且未安装，可一并安装。
- **`shu install jsr:@aaa/bbb`**（直接说明符）：**必须支持**。不依赖 package.json 是否已写该依赖；直接安装 JSR 包到 node_modules，并写入 package.json dependencies（或 deno.json imports），以便后续 `shu install` 与解析一致。
  - 可支持多参数：`shu install jsr:@aaa/bbb jsr:@ccc/ddd lodash`（npm 包名与 JSR 混用）。
- **`shu add` / `shu install` 直接 HTTPS 包（Deno 风格）**：说明符为 `https://...` 时，下载到缓存目录（如 `~/.shu/cache/url/`），并写入 deno.json 的 imports；**仅支持 https://，不支持 http://**。
  - 实现方式 A：JSR 包写入 `"@aaa/bbb": "npm:@jsr/aaa__bbb@^<version>"`，再走 npm 兼容层安装（需 .npmrc `@jsr:registry=https://npm.jsr.io`）。
  - 实现方式 B：自研：请求 https://npm.jsr.io 的 tarball（或 JSR API），解压到 node_modules，并写回 package.json。
- 若项目只有 **deno.json**：`shu install jsr:@aaa/bbb` 可在 deno.json 的 `imports` 中追加 `"@aaa/bbb": "jsr:@aaa/bbb@^<version>"`，并**同时**在 node_modules 安装（@jsr/aaa__bbb），保证运行时解析一致。

### 3.2 与默认 package.json 的关系

- **默认以 package.json 为主**：dependencies 写在 package.json，scripts、main、exports 均以 package.json 为准。
- deno.json 的 `imports` 仅作「说明符重写」；不替代 package.json 的 dependencies，但可与 dependencies 并存（例如 dependencies 里是 npm 包，imports 里是 JSR 包别名）。

### 3.3 同时存在 package.json(c) 与 deno.json(c) 时的行为

| 场景 | 行为说明 |
|------|----------|
| **发现与加载** | **package 为主**：项目根必须存在 package.json 或 package.jsonc 之一（优先 jsonc），否则 `Manifest.load` 报错。**deno 为补充**：若同目录下存在 deno.json 或 deno.jsonc（优先 jsonc），会再读一份并**合并**进同一份 Manifest：`dependencies`、`scripts`、`main`、`exports` 等仅来自 package；`imports`、`tasks` 来自 deno。 |
| **shu install（无参数）** | **只按 package 的 dependencies 安装**：要安装的依赖列表 = `manifest.dependencies`（即 package.json(c) 的 `dependencies`）。deno.json(c) 的 `imports` 仅用于**解析时的说明符重写**，**不会**被当作「需安装的包」去拉取；若 imports 里有 `jsr:` 等，需用户先执行 `shu install jsr:@x/y` 或把对应 npm 包写进 package 的 dependencies，再 install。 |
| **shu install &lt;specifier&gt;** | 新增的 npm 依赖写回 **package.json(c)**（`addPackageDependency`）；JSR 会同时写 **package 的 dependencies**（@jsr/scope__name）与 **deno.json(c) 的 imports**（`addDenoImport`），二者同时存在时各写各的，互不覆盖。 |
| **shu update** | 当前**未实现**。规划：在现有 install 基础上，对 dependencies（及可选 imports 中的 jsr:）按「放宽版本范围」再解析一次，更新 shu.lock 并重新安装；双 manifest 时与 install 一致，仍以 package 的 dependencies 为主，deno imports 可选地一并更新。 |

**总结**：双 manifest 时，**依赖的安装与锁定一律以 package.json(c) 的 dependencies 为准**；deno.json(c) 只提供 imports/tasks 的补充，不单独作为「待安装依赖」来源。若希望 imports 里的 JSR 包也被安装，需在 package 的 dependencies 中显式加入对应 @jsr 包（例如通过 `shu install jsr:@x/y` 自动写入）。

---

## 4. 目录与模块职责建议（src/package/）

| 文件 | 职责 |
|------|------|
| **manifest.zig** | 解析 package.json（main、exports、dependencies、scripts、type）；解析 deno.json（imports、tasks）；可选统一结构体 `Manifest`，或分 `NodeManifest` / `DenoManifest` 由上层组合。 |
| **export_map.zig**（可选） | Node `exports` 条件解析：import/require、default、子路径匹配；输入 (exports 对象, 子路径, 条件) → 输出入口路径。 |
| **resolver.zig** | **裸说明符 + 目录 → 绝对路径**：先 import map（deno），再 node_modules 查找，再 main/exports；内部调 manifest 与 export_map；与 require/mod.zig 的 resolveRequest、ESM resolver 对齐接口。 |
| **install.zig** | 根据 manifest 的 dependencies + deno imports 中的 jsr:，安装到 node_modules：**先查 cache**，命中则从缓存解压到 node_modules；未命中则下载、写入 cache、再解压；写 **shu.lock**（与 deno.lock、bun.lock 命名一致）。 |
| **cache.zig** | 依赖缓存：全局目录、缓存键（registry+name+version 或 integrity）、get/put tarball；供 install 复用，避免重复下载。 |
| **lockfile.zig** | 锁文件读写（兼容或自定义），供 install 与可选的 resolve 复现。 |

### 4.1 与现有 require 的对接

- **require/mod.zig** 当前：仅支持相对路径；裸说明符在 `resolveSpecifierForPackageJson` 里只做到「找到 node_modules/<specifier> 目录」，**未**读包内 package.json 的 main/exports。
- **下一步**：resolver.zig 提供 `resolveBare(allocator, parent_dir, specifier, options)`，内部完成「import map → node_modules → main/exports」；require 与 ESM 的 resolve 都改为调该接口；manifest.load 在需要时由 resolver 或上层按 cwd 调用。

---

## 5. 实现阶段建议

| 阶段 | 内容 | 验收 |
|------|------|------|
| **T0a** | manifest.zig：真实解析 package.json（main、exports、dependencies、scripts）；定义结构体，load(allocator, dir) 读文件并解析 JSON。 | 能 load 得到 main、exports、dependencies。 |
| **T0b** | manifest.zig：解析 deno.json（imports、tasks）；与 package 合并或分接口提供。 | 能读 imports 并用于解析。 |
| **T0c** | export_map.zig（或合在 manifest）：根据 exports 对象 + 子路径 + 条件(import/require) 解析出包内入口路径。 | 给定 exports 与 request，返回正确入口。 |
| **T0d** | resolver.zig：裸说明符 + dir → 先 import map，再 node_modules，再 main/exports；与 require 对接，支持 require('lodash') 等。 | require('lodash') 解析到 node_modules/lodash 的入口文件。 |
| **T0e** | 支持 jsr: 说明符：解析时识别 jsr:@scope/name；安装时 **`shu install jsr:@scope/name`** 写入 package.json（或 deno.json imports）并安装到 node_modules（npm 兼容层 @jsr/scope__name）。 | `shu install jsr:@aaa/bbb` 可安装并解析 JSR 包。 |

先完成 T0a～T0d，再补 T0e（JSR 直接安装）；deno.json 的完整 tasks 与 Deno 特有行为可后续迭代。

---

## 7. 依赖缓存（dependency cache）

### 7.1 目标

- **避免重复下载**：同一 (registry, name, version) 或同一 integrity 只下载一次，后续 install 从本地缓存解压到 node_modules。
- **离线/CI 友好**：lockfile 锁定版本后，若缓存已有，`shu install` 可不联网。
- **与 Node/Deno/Bun 对齐**：npm 用 ~/.npm/_cacache；Deno 用 DENO_DIR；pnpm 用 store；shu 用独立目录便于管理。

### 7.2 缓存根目录

| 环境 | 默认路径 | 可覆盖 |
|------|----------|--------|
| 全局（推荐） | `$HOME/.shu/cache`（Windows：`%LOCALAPPDATA%\shu\cache`） | 环境变量 `SHU_CACHE` 或 `SHU_CACHE_DIR` |
| 项目级（可选） | 项目根下 `.shu/cache` | 用于「仅当前项目」隔离或 CI 挂载；首版可只做全局。 |

实现：`cache.zig` 提供 `getCacheRoot(allocator)`，先读 `SHU_CACHE`/`SHU_CACHE_DIR`，否则用默认；返回路径由调用方 free。

### 7.3 缓存键与目录布局

- **键**：同一包同一版本在同一个 registry 下唯一。建议格式：
  - npm：`npm/<registry_host>/<name>/<version>`，其中 name 含 scope 时用 `@scope__pkg` 等安全文件名（/ 与 @ 替换）。
  - JSR（npm 兼容层）：与 npm 一致，registry 为 `npm.jsr.io`，name 为 `@jsr/scope__name`。
- **内容**：首版**只存 tarball 文件**（与 npm 类似）；解压由 install 在写 node_modules 时做。目录布局示例：
  - `{cache_root}/content/{key_hash}.tgz` 或 `{cache_root}/npm/{host}/{scope}/pkg/{version}.tgz`（按需扁平或分层）。
- **Integrity（可选）**：若 lockfile 记录 integrity（如 sha512），可用 integrity 作二级键或文件名，实现内容寻址与防篡改；首版可用 (registry, name, version) 即可。

### 7.4 API（cache.zig）

| 函数 | 说明 |
|------|------|
| **getCacheRoot(allocator)** | 返回缓存根目录路径；调用方 free。 |
| **cacheKey(allocator, registry_host, name, version)** | 生成缓存键字符串（用于路径或文件名）；name 需做安全化（/ → 某字符）。 |
| **getCachedTarball(allocator, cache_root, key)** | 若缓存中存在该 key 的 tarball，返回其绝对路径（调用方不 free，仅只读使用）；否则返回 null。 |
| **putCachedTarball(allocator, cache_root, key, tarball_path)** | 将 tarball_path 指向的文件复制到 cache_root 下 key 对应路径；若目录不存在则创建。 |

install 流程：对每个要安装的 (registry, name, version)，先 `getCachedTarball`；命中则解压到 node_modules；未命中则下载到临时文件，`putCachedTarball` 后解压到 node_modules。

### 7.5 实现阶段

| 阶段 | 内容 | 验收 |
|------|------|------|
| **T0f** | cache.zig：getCacheRoot、cacheKey、getCachedTarball、putCachedTarball；目录布局按 7.3；install 接入「先查缓存再下载」。 | 二次 install 同一包不重复下载。 |

---

## 8. Package 高性能设计（与 00-性能规则 对齐）

以下按**热路径**与**冷路径**区分，目标是在合理工程范围内压榨 package 解析与安装的性能。

### 8.1 热路径 vs 冷路径

| 路径 | 调用频率 | 优化重点 |
|------|----------|----------|
| **resolve**（裸说明符 → 绝对路径） | 每个 require/import 一次 | 最少分配、结果缓存、少 syscall |
| **manifest 查找 / load** | 每项目或每包目录一次，可复用 | 按目录缓存、按需解析、零拷贝或流式 JSON |
| **exports 条件匹配** | 每包入口/子路径一次 | comptime 键表、少分支、inline |
| **node_modules 向上查** | 每裸说明符一次，可能多级目录 | 减少 openDir/join、可记录「已找到的 node_modules 根」 |
| **install / cache put** | 仅 `shu install` 时 | 并行下载与解压、零拷贝写入缓存、Arena per-package |
| **cache get** | install 时每包一次 | 键生成少 alloc、存在性检查一次、路径拼接栈上或复用 |

### 8.2 内存与分配（§1.1、§1.2、§1.3）

- **resolve 整条链路**：由 **run 级或请求级 Arena** 驱动；单次 run 内所有解析结果（路径、manifest 引用）放在同一 Arena，run 结束一次性释放。调用方（require、ESM）传入该 Arena 的 allocator。
- **路径拼接**：小路径（&lt; 512B）优先 **栈上 buffer**（如 `var buf: [512]u8` + 手动拼接或 `std.fs.path.join` 写栈），避免为每次 join 分配堆。超过再 fallback 到 Arena。
- **manifest.load**：单次 load 使用 **Arena**；返回的 Manifest 内字符串/表均指向 Arena 内存，调用方保证在 Arena 生命周期内使用；不 toOwnedSlice，避免二次拷贝。
- **cache key**：`cacheKey(registry, name, version)` 中 name/version 通常很短；可先尝试 **栈上 BoundedArray(u8, 256)** 或固定 buffer 生成 key，失败再 alloc。
- **禁止**：在 resolve 热路径中使用全局 allocator 或逐项 free 的细粒度分配。

### 8.3 解析与查找（§2.1、§2.4）

- **JSON（package.json / deno.json）**：
  - 只解析**必要字段**（main、exports、dependencies、imports）；可流式或按 token 扫描，避免先读全文件再整棵 AST。
  - 关键字 `"main"`、`"exports"`、`"imports"` 等可用 **comptime 预生成哈希**或小表，首次扫描即定位，减少逐字符比较。
  - 若使用通用 JSON 解析器，优先选**零拷贝**或**按需解析**实现；大 value 避免先复制再解析。
- **exports 条件**：条件键 `"import"`、`"require"`、`"default"` 等固定集合，用 **comptime 分支或表** 匹配，避免运行时多次字符串比较；子路径匹配用**最长前缀**一次确定，减少回溯。
- **node_modules 向上查**：
  - 每层目录只做**一次** `openDir("node_modules")` + `openDir(specifier)` 或等价存在性检查；路径拼接复用同一 buffer，不每层都 `path.join` 新分配。
  - 可选：对同一 run 内相同 `(parent_dir, specifier)` **缓存解析结果**（如 HashMap(specifier_key → resolved_path)），后续 require 相同 id 直接命中缓存。
- **import map（deno imports）**：键查找用 **HashMap**；key 为 specifier 切片，value 为映射后说明符（均指向 Arena），无额外拷贝。

### 8.4 I/O 与缓存（§3、io_core 约定）

- **规范约定**：热路径 I/O 应经 **io_core**；目录存在性、读 package.json 等当前可暂用 `std.fs`（见 00-性能规则 3.0 例外），后续在 io_core 暴露统一目录/文件 API 后迁移。
- **manifest 文件**：同一目录的 package.json / deno.json **只读一次**；结果按「目录绝对路径」缓存在 run 级或进程级（带 TTL 或 invalidation 可选），避免重复 open + read。
- **cache.getCachedTarball**：仅做**存在性检查**（如 openFileAbsolute 或 stat）并返回路径；不读内容。路径字符串由调用方在 Arena 内复制或持有。
- **cache.putCachedTarball**：写入缓存时优先 **零拷贝**（如 `copy_file_range`、`sendfile` 或平台等价），避免 read 整包再 write；大文件可考虑 mmap 只读 + 写回时按块拷贝。
- **install 解压**：tarball 解压可**流式**（边读边解边写 node_modules），避免整包进内存；单包内文件列表可 Arena 分配，解压完随 Arena 释放。

### 8.5 并发与并发安全（§3.5、§3.6）

- **resolve**：单线程执行即可；解析结果缓存若跨请求共享，需**无锁**或**每线程/每 run 独立**，避免锁竞争。
- **install**：多包可**并行下载**、**并行解压**；每包写独立 `node_modules/<pkg>` 目录，无共享写；lockfile 写可在全部安装完成后单线程写一次。
- **cache**：多进程/多线程同时 put 同一 key 时，可用**文件锁**或「写临时文件 + rename」保证原子性；get 只读，无需锁。

### 8.6 实现优先级（与 T0 对齐）

1. **先做对**：manifest 解析、resolver 语义、cache 键与路径正确。
2. **再压榨热路径**：resolve 用 Arena、manifest 按目录缓存、node_modules 查找少 alloc/少 openDir、exports 用 comptime 表。
3. **最后 I/O 与并发**：manifest 读/缓存迁移 io_core（若提供）、install 并行与零拷贝、cache put 零拷贝。

---

## 9. 参考

- npm [caching](https://docs.npmjs.com/cli/v10/configuring-npm/folders#cache)、pnpm [store](https://pnpm.io/package-store)、Deno [cache](https://docs.deno.com/runtime/manual/basics/modules/caching)
- Node [Package exports](https://nodejs.org/api/packages.html#package-exports)
- Deno [Modules and dependencies](https://docs.deno.com/runtime/manual/basics/modules/)、[deno.json](https://docs.deno.com/runtime/manual/getting_started/configuration_file)
- JSR [Using JSR with Deno](https://jsr.io/docs/with/deno)、[npm compatibility](https://jsr.io/docs/npm-compatibility)（@jsr 映射、npm.jsr.io）
- 现有代码：`src/runtime/modules/shu/require/mod.zig`（resolveRequest、resolveSpecifierForPackageJson）、`src/runtime/modules/shu/module/mod.zig`（findPackageJSON）
