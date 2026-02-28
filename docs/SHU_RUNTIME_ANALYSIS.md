# Shu 运行时分析文档

> **Shu** — 基于 Zig 的下一代 JavaScript/TypeScript 运行时，模仿 Bun 并致力于超越 Bun。  
> 项目名取自作者姓氏拼音「舒」。

---

## 一、项目愿景与定位

### 1.1 目标

- **模仿 Bun**：在架构与能力上对齐 Bun（全栈 JS 运行时 + 包管理 + 打包 + 测试）。
- **超越 Bun**：在性能、安全性、可维护性、可扩展性上做差异化与改进。
- **技术栈**：使用 **Zig** 编写运行时与工具链，与 Bun 一致，便于借鉴与优化。

### 1.2 核心价值主张

| 维度 | Bun 现状 | Shu 目标 |
|------|----------|----------|
| 性能 | 已领先 Node/Deno | 保持同量级，在冷启动、内存、I/O 上做极致优化 |
| 安全 | 默认无权限模型 | **可选** 权限模型（类似 Deno），安全优先 |
| 生态 | NPM 兼容，生态较新 | 兼容 **Node、Deno、Bun** 三大生态，同时提供更清晰的模块边界 |
| 可维护性 | 单一巨型仓库 | 模块化设计，核心与工具可独立演进 |
| 扩展性 | 内置能力为主 | 插件/可插拔架构，便于社区扩展 |

---

## 二、Bun 核心能力分析（我们要模仿什么）

### 2.0 JS 引擎选型：JSC 与 V8

Shu 优先使用 **JavaScriptCore (JSC)**，若在文档或集成上遇到不可克服的困难，再考虑 **V8** 作为备选。

#### JavaScriptCore (JSC) — 优先选择

| 维度 | 说明 |
|------|------|
| **文档** | **不如 V8 成体系**。官方有 WebKit 文档（[Deep Dive / JSC](https://docs.webkit.org/Deep%20Dive/JSC/JavaScriptCore.html)）侧重引擎内部（Lexer、Parser、LLInt、DFG、FTL），**嵌入用 C API 没有像 V8 那样的「Embedding Guide」**；主要靠阅读 [Source/JavaScriptCore/API](https://github.com/WebKit/WebKit/tree/main/Source/JavaScriptCore/API) 头文件及社区文章（如 [How to use the JavaScriptCore C API](https://karhm.com/javascriptcore_c_api/)）。 |
| **能否写得来** | **可以**。JSC 暴露的是 **C API**（`JSGlobalContextRef`、`JSValueRef`、`JSEvaluateScript` 等），Zig 与 C 互操作简单，无需碰 C++。更重要的是 **Bun 已用 Zig + JSC 跑通整套运行时**（[jsc.zig](https://github.com/oven-sh/bun/blob/main/src/jsc.zig)、[javascript.zig](https://github.com/oven-sh/bun/blob/main/src/bun.js/javascript.zig)），我们有完整可参考实现，缺文档时可直接对照 Bun 源码。 |
| **优势** | 冷启动与内存表现优于 V8；与 Bun 技术栈一致，便于对齐行为与性能；C API 对 Zig 友好。 |

#### V8 — 备选方案

| 维度 | 说明 |
|------|------|
| **文档** | **更丰富**。[v8.dev/docs/embed](https://v8.dev/docs/embed) 有官方嵌入指南与 Hello World，[Embedder's Guide](https://github.com/v8/v8/wiki/Embedder's-Guide) 与 API 参考齐全。 |
| **与 Zig 的配合** | V8 是 **C++ API**，Zig 需通过 C 包装或 C++ 链接与之对接；社区有 [zig-v8](https://github.com/fubark/zig-v8) 等绑定，但成熟度与 Bun 的 Zig+JSC 不可同日而语。 |
| **何时考虑** | 若 JSC 在非 Apple 平台构建、或文档/调试成本长期过高，再评估切换到 V8；届时需接受 C++ 工具链与不同的性能/内存特性。 |

#### 结论与建议

- **首选 JSC**：在「文档不完美但可写」的前提下，优先采用 JSC，以 Bun 源码为主、WebKit API 头文件与社区教程为辅，完全能实现 Shu 运行时。
- **架构上预留抽象**：在运行时核心层对「引擎接口」做薄抽象（创建上下文、执行脚本、暴露全局、注册 C 回调等），便于未来若有需要再接入 V8 或其他引擎。

---

### 2.1 运行时层

- **JS 引擎**：采用 **JavaScriptCore (JSC)**（选型理由见 2.0），在启动时间与内存上优于 V8，且与 Bun 一致便于参考。
- **实现语言**：Zig，与系统层、内存布局、字符串与缓冲区操作紧密配合。
- **能力**：
  - 直接执行 `.js` / `.ts` / `.jsx` / `.tsx`（内置转译）。
  - 内置 `fetch`、`WebSocket`、`File`、`SQLite` 等 API。
  - Node 兼容层（`node:*` 模块、`process`、`Buffer` 等）。

**Shu 建议**：  
- 继续选用 **JSC**（或保留未来可切换引擎的抽象），用 Zig 做 FFI 与运行时封装。  
- 优先实现：执行 JS/TS、基础全局对象、`fetch`、定时器；兼容层按阶段支持 **Node**、**Deno**（`deno:`、权限模型）、**Bun**（`Bun.*`）三端。

### 2.2 包管理器

- **能力**：安装快、锁文件、workspace、脚本、兼容 `package.json`。
- **实现**：Zig 写的解析器与缓存，并行安装与依赖解析。

**Shu 建议**：  
- 兼容 `package.json` / `bun.lock` 或自研锁文件格式。  
- 优先：解析依赖、安装到 `node_modules`、运行 `scripts`，再考虑 workspace、离线与缓存策略。

### 2.3 打包器 (Bundler)

- **能力**：打包 TS/JS/JSX，tree-shaking，代码分割，可输出 ESM/CJS。
- **实现**：词法 → 语法 → AST → 变换 → 代码生成，与运行时共用解析器。

**Shu 建议**：  
- 先做单入口打包与 ESM 输出，再逐步做 tree-shaking、代码分割、多 target（browser/node）。

### 2.4 测试运行器

- **能力**：类 Jest API（`describe`/`it`/`expect`），内置断言、mock、覆盖率。  
- **实现**：在 Zig 侧调度测试用例，在 JSC 中执行。

**Shu 建议**：  
- 先实现 `describe`/`it`/`expect` 与基础断言，再考虑 mock、快照、覆盖率。

### 2.5 其他

- **Transpiler**：内联 TS/JSX 转译，供运行时与打包器共用。  
- **.env**：内置加载。  
- **Hot reload**：开发时重载。

**Shu 建议**：  
- 转译与 .env 与 Bun 对齐；Hot reload 可作为第二阶段的开发体验增强。

---

## 三、超越 Bun：差异化方向

### 3.1 安全（权限模型）

- **问题**：Bun 默认无权限限制，与 Deno 的「默认安全」形成对比。  
- **Shu**：  
  - 提供 **可选** 权限模型（类似 `deno run --allow-net`）。  
  - 默认可配置为「限制网络/文件/环境变量」等。  
  - 通过 CLI 与运行时标志控制，不破坏现有 Node/Deno/Bun 脚本的兼容性。

### 3.2 架构与可维护性

- **问题**：Bun 单仓巨大，耦合度高。  
- **Shu**：  
  - **模块化**：运行时核心 / 包管理 / 打包 / 测试 分目录或子仓库，便于阅读与贡献。  
  - **清晰 C API / 内部 API**：未来可被其他语言或工具调用（如 IDE、CLI 工具）。  
  - **文档与设计文档**：每个模块有 README 与架构说明（如本分析文档）。

### 3.3 性能与资源

- **保持**：冷启动、内存占用、I/O 与 Bun 同量级（JSC + Zig）。  
- **超越点**：  
  - 更小的二进制体积（按需编译、裁剪未用模块）。  
  - 可配置的「最小运行时」模式（仅执行单文件，无包管理/打包）。  
  - 在特定场景（如 Serverless）的冷启动与内存 benchmark 上对标或优于 Bun。

### 3.4 生态与兼容性

- **兼容 Node、Deno、Bun 三大生态**：  
  - **Node**：内置模块（`node:*`）、`process`、`Buffer`、常用 NPM 包与 `package.json` 工作流。  
  - **Deno**：`deno:` 协议、Import Map、权限标志（`--allow-net` 等）、标准库风格 API，便于 Deno 项目迁移。  
  - **Bun**：`Bun.*` API 子集（如 `Bun.file`、`Bun.serve`）、`bun.lock` 与安装行为，便于 Bun 项目迁移。  
- **扩展**：  
  - **插件**：用 Zig 或通过 C ABI 写扩展，在运行时注入原生模块或钩子。  
  - **可插拔**：打包器/包管理器可替换为适配器（例如只做「运行」不装包）。

### 3.5 开发体验

- **错误与日志**：  
  - 更清晰的错误码与文档链接。  
  - 结构化日志（如 JSON 输出）便于工具链集成。  
- **调试**：  
  - 与 Chrome DevTools 或 VS Code 调试协议兼容（长期目标）。  
- **文档**：  
  - 中文 + 英文文档，API 与 CLI 参考完整。

---

## 四、功能清单与完成策略

### 4.1 我们要完成哪些功能？（全量列表）

按模块整理，**不要求一次性做完**；优先级见 4.2。

#### A. 运行时核心（Runtime）

| 功能 | 说明 | 优先级 |
|------|------|--------|
| 执行 JS/TS/JSX/TSX | 直接运行单文件，内置转译 | P0 |
| 全局对象 | `console`、`setTimeout`/`setInterval`、`clearTimeout`/`clearInterval` | P0 |
| `fetch` | 内置 HTTP 客户端 | P0 |
| **内置 HTTP 服务器** | **`Bun.serve()` 或等价 API**：监听端口、处理请求/响应、路由，用于写 Web 服务（对齐 Bun/Node 的 `createServer`） | P1 |
| `WebSocket` | 基础 WebSocket 客户端 | P1 |
| **内置 Socket.IO** | **Socket.IO 服务端/客户端**：在 HTTP 服务器与 WebSocket 之上实现 Socket.IO 协议（房间、广播、回退轮询等），便于实时应用；可先保证 `socket.io` npm 包在 Shu 上可运行，再考虑原生高性能实现（如 `shu:io` 或 `Bun.serve` 的 Socket.IO 集成） | P2 |
| 内置模块 / API | `shu:fs`、`shu:env` 或等价（读文件、读 .env） | P1 |
| Node 兼容层 | `process`、`Buffer`、`require`/`module`、`__dirname`/`__filename` 最小集 | P0 |
| Node 内置模块 | `node:fs`、`node:path`、`node:http` 等常用子集 | P1 |
| Deno 风格 API | `deno:` 协议、Import Map、与 Deno 对齐的权限标志 | P2 |
| Bun 风格 API | `Bun.file`、`Bun.serve`、`Bun.write` 等子集 | P1 |
| SQLite / 其他内置能力 | 可选，视 Bun 对齐程度 | P2 |

#### B. 包管理（Package）

| 功能 | 说明 | 优先级 |
|------|------|--------|
| 解析 `package.json` | 依赖、scripts、main/module/exports | P0 |
| 依赖解析 | 版本范围、无循环、冲突处理 | P0 |
| `shu install` | 下载 tarball、解压到 `node_modules` | P0 |
| 锁文件 | 自定义或兼容 `bun.lock` | P0 |
| 解析 `node_modules` | `require`/`import` 能正确找到包 | P0 |
| 运行 scripts | `shu run <script>`（如 `shu run dev`） | P1 |
| Workspace（monorepo） | 多包联动安装与链接 | P2 |
| 离线 / 镜像 / 缓存策略 | 加速与可重复构建 | P2 |

#### C. 打包器（Bundler）

| 功能 | 说明 | 优先级 |
|------|------|--------|
| 单入口打包 | 输出单文件 ESM | P1 |
| TS/JSX 转译 | 与运行时共用转译管线 | P1 |
| Tree-shaking | 死代码消除 | P1 |
| 代码分割 / 多 chunk | 按需加载、多 target | P2 |
| 输出 CJS / 多格式 | 兼容旧版 Node | P2 |
| `shu build` CLI | 入口、出口、target 配置 | P1 |

#### D. 转译器（Transpiler）

| 功能 | 说明 | 优先级 |
|------|------|--------|
| 内联 TS  strip 类型 | 仅去掉类型，供运行与打包用 | P0 |
| 完整 TS 转译 | 含类型检查可选 | P1 |
| JSX 转译 | 与 Bun 兼容的 pragma 与运行时 | P1 |

#### E. 测试运行器（Test）

| 功能 | 说明 | 优先级 |
|------|------|--------|
| `shu test` | 发现测试文件并执行 | P1 |
| `describe` / `it` / `expect` | 类 Jest API | P1 |
| 基础断言 | `equal`、`ok`、`throws` 等 | P1 |
| Mock / 快照 / 覆盖率 | 增强测试能力 | P2 |
| **内置无头浏览器驱动** | 测试文件或配置中声明浏览器参数后，`shu test` 自动在无头 Chromium 中运行对应用例；通过 CDP 或类 Playwright API 控制页面、断言 DOM/网络（无需单独子命令） | P2 |

#### F. 安全与权限

| 功能 | 说明 | 优先级 |
|------|------|--------|
| 权限标志 | `--allow-net`、`--allow-read`、`--allow-env` 等 | P1 |
| 运行时权限检查 | 在调用敏感 API 时校验 | P1 |
| 可选「默认限制」模式 | 安全优先的默认配置 | P2 |

#### G. CLI 与开发体验

| 功能 | 说明 | 优先级 |
|------|------|--------|
| `shu run <file>` | 执行单文件 | P0 |
| `shu install` | 安装依赖 | P0 |
| `shu build` | 打包 | P1 |
| `shu test` | 跑测试 | P1 |
| `shu check` | TS 类型检查（对齐 deno check） | P2 |
| `shu lint` | 代码检查（对齐 deno lint） | P2 |
| `shu fmt` | 代码格式化（对齐 deno fmt） | P2 |
| `.env` 自动加载 | 与 Bun 一致 | P1 |
| Hot reload | 开发时热重载 | P2 |
| 错误码与文档链接 | 清晰报错与排错指引 | P1 |
| 结构化日志（如 JSON） | 便于工具链集成 | P2 |

#### H. 扩展与生态

| 功能 | 说明 | 优先级 |
|------|------|--------|
| 插件 / 扩展 ABI | Zig 或 C 写扩展，注入原生模块或钩子 | P2 |
| 可插拔包管理/打包 | 适配器模式，便于替换实现 | P3 |
| 最小二进制 / 裁剪构建 | 仅运行、无包管理/打包 | P2 |

#### I. 文档与生态

| 功能 | 说明 | 优先级 |
|------|------|--------|
| API / CLI 参考文档 | 中英文 | P1 |
| 与 Node/Deno/Bun 的兼容与迁移说明 | 差异表、迁移指南 | P1 |
| Benchmark 与对比 | 冷启动、吞吐、安装速度等 | P2 |

---

### 4.2 是否要做完「所有功能」？

**不必一次性做完。** 建议分阶段、按优先级推进：

| 阶段 | 目标 | 主要功能 |
|------|------|----------|
| **MVP（最小可用）** | 能跑起来、能装包 | P0：运行单文件 JS/TS、console/fetch/定时器、Node 兼容最小集、install + 锁文件 + node_modules 解析 |
| **核心对齐** | 对齐 Bun 日常用法 | P1：WebSocket、Bun.* 子集、打包与 tree-shaking、测试、权限、.env、错误与文档 |
| **差异化与增强** | 超越 Bun、生态友好 | P2：Deno API、workspace、mock/覆盖率、hot reload、插件、最小二进制 |
| **长期** | 可扩展与可维护 | P3：可插拔架构、更多生态工具 |

- **先做 P0**：保证「能运行、能安装」，再逐步加 P1、P2、P3。  
- **功能清单**用于对齐「我们要完成哪些功能」；**路线图（第七节）**用于排期与迭代顺序。两者结合即可：清单 = 全量，路线图 = 执行顺序与阶段划分。

---

## 五、技术选型：为什么用 Zig

- **与 Bun 一致**：Bun 已证明 Zig + JSC 在性能与可维护性上的可行性，可直接参考其设计。  
- **性能与控制力**：无 GC、手动内存、与 C 的互操作简单，适合做运行时、解析器、I/O 与缓冲区。  
- **可移植性**：交叉编译友好，便于生成多平台单一二进制。  
- **构建与依赖**：自带构建系统，不依赖庞大 C++ 工具链，编译速度快。  
- **安全**：未定义行为可通过编译选项与静态分析控制，适合做底层运行时。

**可选补充**：  
- 脚本/胶水逻辑可用少量 Zig 内联或子进程调用，保持主栈统一为 Zig。

---

## 六、推荐架构设计

### 6.1 顶层目录与模块

```
shu-core/                                    # 项目根目录
├── build.zig                                # Zig 构建配置，定义编译目标与依赖
├── .gitignore                               # Git 忽略规则（zig-out/、zig-cache/、node_modules/ 等）
├── src/                                     # 源代码目录
│   ├── main.zig                             # CLI 入口，解析子命令并分发到 run/install/build/test/check/lint/fmt
│   ├── errors.zig                           # 错误码与文档链接，供 CLI/runtime/transpiler 等统一报错
│   ├── cli/                                 # 子命令与参数解析
│   │   ├── args.zig                         # 全局参数解析（如 --allow-net、--allow-read 等）
│   │   ├── run.zig                          # shu run 子命令：执行单文件或 package.json scripts
│   │   ├── install.zig                      # shu install 子命令：安装依赖到 node_modules
│   │   ├── build.zig                        # shu build 子命令：打包入口为单文件或分块
│   │   ├── test.zig                         # shu test 子命令：发现并运行测试用例
│   │   ├── check.zig                        # shu check 子命令：TS 类型检查（对齐 deno check）
│   │   ├── lint.zig                         # shu lint 子命令：代码检查（对齐 deno lint）
│   │   └── fmt.zig                          # shu fmt 子命令：代码格式化（对齐 deno fmt）
│   ├── runtime/                             # 运行时核心
│   │   ├── engine.zig                       # JSC 封装与生命周期（创建/销毁 VM、上下文）
│   │   ├── vm.zig                           # 执行上下文、全局对象（console、定时器等）
│   │   ├── modules/                         # 内置模块（node:、shu:、deno:、Bun 命名空间/API 实现）
│   │   │   ├── node/                        # node:* 内置模块（node:fs、node:path、node:http 等）
│   │   │   ├── shu/                         # shu:* 内置模块（shu:fs、shu:env 等）
│   │   │   ├── deno/                        # deno:* 风格模块实现（与 compat/deno 配合）
│   │   │   └── bun/                         # Bun.* API 实现（Bun.serve、Bun.file 等，与 compat/bun 配合）
│   │   ├── bindings/                        # JS ↔ Zig 绑定（将 Zig 实现的 API 暴露给 JS）
│   │   ├── compat/                          # 各运行时兼容层（Node / Deno / Bun）
│   │   │   ├── node/                        # Node 兼容层（process、Buffer、require/module 等）
│   │   │   ├── deno/                        # Deno 兼容层（deno: 协议、权限风格 API，P2）
│   │   │   └── bun/                         # Bun 兼容层（Bun.serve、Bun.file 等 API 子集）
│   │   ├── permission.zig                   # 权限模型（--allow-net/read/env 等标志与运行时校验）
│   │   └── plugin.zig                       # 插件/扩展 ABI（加载 Zig/C 扩展，注入原生模块或钩子）
│   ├── package/                             # 包管理器
│   │   ├── manifest.zig                     # package.json 解析（依赖、scripts、exports 等）
│   │   ├── resolver.zig                     # 依赖解析（版本范围、无循环、冲突处理）
│   │   ├── install.zig                      # 安装与缓存（下载 tarball、解压到 node_modules）
│   │   └── lockfile.zig                     # 锁文件读写（自定义格式或兼容 bun.lock）
│   ├── bundler/                             # 打包器
│   │   ├── parse.zig                        # 词法/语法解析（可与 runtime 或 src/parser 共用）
│   │   ├── ast.zig                          # AST 与变换（tree-shaking、代码分割）
│   │   └── emit.zig                         # 代码生成（输出 ESM/CJS 单文件或分块）
│   ├── transpiler/                          # 转译（TS/JSX）
│   │   ├── strip_types.zig                  # 仅去掉 TS 类型，供运行与打包共用
│   │   ├── ts.zig                           # 完整 TS 转译（可选类型检查）
│   │   └── jsx.zig                          # JSX 转译（pragma 与运行时对齐 Bun）
│   ├── test/                                # 测试运行器
│   │   ├── runner.zig                       # 发现测试文件、调度执行、汇总结果
│   │   ├── jest_api.zig                     # describe / it / expect 等类 Jest API
│   │   ├── expect.zig                       # 断言实现（equal、ok、throws 等）
│   │   └── browser.zig                      # 内置无头浏览器驱动（CDP/Chromium；由测试文件/配置中的浏览器参数触发，无需单独子命令）
│   └── parser/                              # 可选：与 runtime、bundler 共用的词法/语法解析
│       ├── lexer.zig                        # 词法分析（若抽成独立模块）
│       └── parser.zig                       # 语法分析（若抽成独立模块）
├── docs/                                    # 设计文档与说明（如本分析文档）
├── tests/                                   # Zig 单元测试或集成测试
└── examples/                                # 可选：示例项目，便于文档与贡献者上手
```

### 6.2 核心数据流

- **运行**：`shu run <entry>` → CLI → 解析/转译 → 注入 Node/Deno/Bun/Shu 兼容层 → JSC 执行。  
- **安装**：`shu install` → 解析 manifest → 解析依赖 → 下载/解压 → 写 `node_modules` + 锁文件。  
- **打包**：`shu build <entry>` → 解析 → AST → 变换与 tree-shake → 生成单文件或分块。  
- **测试**：`shu test` → 发现测试文件 → 转译 → 在隔离环境中执行用例并汇总结果。  
- **浏览器测试**：`shu test` 时根据测试文件或配置中的浏览器参数（如 `browser: true` / `env: "browser"`）自动识别需在浏览器中运行的用例 → 启动无头 Chromium → 通过 CDP 注入并执行对应测试 → 断言 DOM/网络并汇总结果（无需单独子命令或 `--browser` 标志）。

### 6.3 与 JavaScriptCore 的集成

- 使用 **Zig 的 C 互操作** 调用 JSC 的 C API（或通过 thin C 包装）。  
- 在 Zig 中管理 JSC 的堆、全局对象、内置函数与模块加载器。  
- 将 Zig 实现的 API（如 `fetch`、`Bun.file`、`fs`）通过 JSC 绑定暴露给 JS。

---

## 七、实现路线图（分阶段）

### Phase 0：基础与可执行（约 2–4 周）

- [ ] Zig 项目骨架、`build.zig`、目录结构。  
- [ ] 集成 JSC（子模块或系统库），在 Zig 中创建 VM 并执行一段简单 JS。  
- [ ] CLI 入口：`shu run <file>` 执行单文件 JS。  
- [ ] 最小转译：仅 JS（或内联 TS 的去掉类型），保证 `console.log` 等可用。

### Phase 1：最小可用运行时（约 1–2 月）

- [ ] 全局对象：`console`、`setTimeout`/`setInterval`、`fetch`、`WebSocket` 基础版。  
- [ ] 内置模块：`shu:fs`、`shu:env` 或等价 API。  
- [ ] 基础 Node 兼容：`process`、`Buffer`、`require`/`module` 最小实现。  
- [ ] 权限：CLI 标志 `--allow-net`、`--allow-read` 等，并在运行时检查。

### Phase 2：包管理与安装（约 1–2 月）

- [ ] 解析 `package.json`，依赖解析（无循环、版本范围）。  
- [ ] `shu install`：下载 tarball、解压到 `node_modules`。  
- [ ] 锁文件（自定义或兼容 Bun lock）。  
- [ ] `shu run` 能解析 `node_modules` 中的 `require`/`import`。

### Phase 3：打包与转译（约 1–2 月）

- [ ] 完整 TS/JSX 转译（或接入现有轻量实现）。  
- [ ] 单入口打包，输出 ESM 单文件。  
- [ ] 简单 tree-shaking（死代码消除）。  
- [ ] `shu build` 与产物可被 `shu run` 或浏览器使用。

### Phase 4：测试与生态（约 1 月+）

- [ ] `shu test`：发现测试文件，`describe`/`it`/`expect`。  
- [ ] **内置无头浏览器驱动**：测试文件或配置中声明浏览器参数（如 `browser: true`）的用例，在 `shu test` 时自动在无头 Chromium 中运行；通过 CDP 或类 Playwright API 控制页面、断言 DOM/网络（可选构建，避免默认增大二进制）。  
- [ ] `shu check` / `shu lint` / `shu fmt`：对齐 deno，提供类型检查、代码检查、代码格式化。  
- [ ] 与 Bun 对齐的 `Bun.*` API 子集；Deno 风格 API 与权限标志（文档标明与 Node/Deno/Bun 的兼容与差异）。  
- [ ] 文档站、示例项目、与 Node/Deno/Bun 的对比 benchmark。

### Phase 5：超越与生态（持续）

- [ ] 插件/扩展 ABI 设计。  
- [ ] 更细粒度权限与策略（如按路径的读写）。  
- [ ] 冷启动与内存优化、最小二进制构建选项。  
- [ ] 调试协议支持、结构化错误与日志。

---

## 八、风险与依赖

| 风险 | 缓解 |
|------|------|
| JSC API 复杂、文档少 | 参考 Bun 源码与 WebKit 文档；抽象薄封装层，隔离变更。 |
| Node/Deno/Bun 兼容工作量大 | 只实现高频模块与 API 子集，优先兼容主流框架与库；按阶段分步支持三端。 |
| 生态与三大运行时重叠 | 明确「Shu 优先」场景（安全、可维护、可扩展），并做好兼容 Node/Deno/Bun 的文档与迁移指南。 |
| 单人/小团队维护 | 模块化与文档先行，便于贡献；优先把「可运行 + 可安装」做稳定。 |
| 内置浏览器驱动依赖 Chromium/CDP，二进制体积与跨平台 | 可选构建（不默认链接浏览器）、或按需下载/绑定驱动；文档标明平台要求。 |

---

## 九、成功指标（如何判断「模仿并超越」）

- **模仿**：  
  - 能运行主流 TS/JS 项目（如 Vite/React 应用、简单 Express 服务）。  
  - `shu install` + `shu run` 与 Bun 行为对齐（安装与执行结果一致或可接受差异）。  
  - 提供与 Bun 相近的 `Bun.*` 子集，以及 Node、Deno 的兼容层与迁移路径。  

- **超越**：  
  - **安全**：默认或可选权限模型被文档化并被用户使用。  
  - **可维护性**：新贡献者能在 1–2 天内理解核心目录并跑通一条链路（如 run）。  
  - **性能**：在 2–3 个关键场景（冷启动、HTTP 吞吐、安装速度）与 Bun 持平或更优。  
  - **扩展**：至少有一种可用的插件/扩展方式（如原生 addon 或配置驱动）。

---

## 十、参考资料与链接

- [Bun 官网](https://bun.sh)  
- [Bun GitHub 源码](https://github.com/oven-sh/bun)（Zig + JSC 结构，可作 JSC 嵌入参考）  
- [JavaScriptCore - WebKit 文档](https://docs.webkit.org/Deep%20Dive/JSC/JavaScriptCore.html)  
- [JSC C API 使用示例](https://karhm.com/javascriptcore_c_api/)（嵌入用 C API 入门）  
- [WebKit JSC API 头文件](https://github.com/WebKit/WebKit/tree/main/Source/JavaScriptCore/API)  
- [V8 嵌入指南](https://v8.dev/docs/embed)（备选方案参考）  
- [Zig 官方](https://ziglang.org/)  
- [Node.js 兼容性](https://nodejs.org/api/)  
- [Deno 手册](https://deno.land/manual)（权限模型、Import Map、标准库）  

---

*文档版本：1.0 | 目标运行时名称：Shu | 技术栈：Zig + JavaScriptCore*
