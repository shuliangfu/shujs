# shu:build 设计：服务端编译、客户端编译与 bundle

本文档定义 `shu build` 与 `shu:build` 模块的三种编译模式，以及它们与浏览器测试（TSX 编译）的关系。

---

## 一、目标与背景

- **CLI**：`shu build [入口] [选项]` 支持将 TS/TSX/JS 源码编译为可运行或可发布的产物。
- **运行时 API**：`import 'shu:build'` 或 `require('shu:build')` 提供程序化编译接口，供脚本内调用（例如测试脚手架、构建脚本）。
- **浏览器测试前置**：浏览器测试需要把 TSX 编译成可在浏览器中执行的 JS，因此需先实现 shu:build 的**客户端编译**与**bundle** 能力。

现有能力：

- `transpiler/strip_types.zig`：TS/TSX 类型擦除，供 `shu run` 与 `shu:module.stripTypeScriptTypes` 使用。
- `transpiler/ts.zig`：完整 TS 转译占位，未实现。
- `cli/build.zig`：占位，仅打印「尚未实现」。

---

## 二、三种编译模式

### 2.1 服务端编译（Server-side compile）

**含义**：产出在 **ShuJS 运行时**（JSC）中执行的代码。

| 项目 | 说明 |
|------|------|
| 输入 | `.ts` / `.tsx` / `.mts` / `.js` / `.mjs` 单文件或入口 + 依赖图 |
| 处理 | TS/TSX → 类型擦除或完整转译 → 纯 JS；可选保留 ESM 结构或转为 CJS |
| 输出 | 单文件 JS，或按入口/分块输出多个 JS，供 `shu run <out>` 执行 |
| 典型用法 | `shu build src/main.ts -o dist/main.js`，再 `shu run dist/main.js` |

**与现有能力的关系**：

- Phase 0：复用 `strip_types.strip()` 做类型擦除，单入口单文件输出即可。
- Phase 1：若需解析 `import` 并递归处理依赖，可走 ESM 图（与 `esm_loader` 或独立解析器一致），再对每个 TS 文件 strip 后按依赖顺序拼接或分块输出。

**选项示例（后续 CLI）**：

- `--out` / `-o`：输出路径（文件或目录）。
- `--target=shu`（默认）：服务端，不注入浏览器 polyfill。
- `--format=esm|cjs`：输出模块格式。

---

### 2.2 客户端编译（Client-side compile）

**含义**：产出在 **浏览器**（或浏览器测试环境）中执行的代码。

| 项目 | 说明 |
|------|------|
| 输入 | `.ts` / `.tsx` / `.js` / `.mjs`，通常为前端入口或浏览器测试入口 |
| 处理 | TS/TSX → 转译（类型擦除 + JSX → JS）；可选 minify、target ES 版本、注入 polyfill |
| 输出 | 单文件或分块 JS，可在 `<script type="module">` 或测试页中直接加载 |
| 典型用法 | 浏览器测试前把 `tests/browser/foo.test.tsx` 编译成 `dist/browser/foo.test.js`，再由 runner 页面加载 |

**与浏览器测试的关系**：

- 浏览器测试（见 `src/runtime/modules/shu/test/BROWSER_TESTING.md`）需要把 TSX 编译成浏览器可执行 JS；客户端编译即为此服务。
- 可选：在 `shu test --browser` 中内部调用 shu:build 的客户端编译，再启动静态服务 + 无头浏览器加载产物。

**选项示例**：

- `--target=browser`：客户端；可扩展为 `--target=es2020` 等。
- `--jsx=preserve|transform`：JSX 保留或转为 `createElement`/`jsx` 调用。
- `--minify`：压缩。
- `--out`：输出路径。

**实现要点**：

- TS/TSX 类型擦除：复用或共用 `strip_types`；JSX 需单独处理（可先做简单正则/手写解析，或后续接 swc/esbuild 等）。
- 不依赖 Node/Shu 专有 API 的代码可直接在浏览器运行；若用了 `process` 等，需在 bundle 时 external 或替换为浏览器用 stub。

---

### 2.3 Bundle 编译（Bundle）

**含义**：将**多模块**（含依赖树）打包成**一个或若干 chunk**，减少请求、便于部署与浏览器测试单页加载。

| 项目 | 说明 |
|------|------|
| 输入 | 一个或多个入口（如 `src/main.tsx`、`tests/browser/runner.tsx`），自动解析 import/require |
| 处理 | 依赖图构建 → 树摇（可选）→ 合并为单 bundle 或按 chunk 拆分（如 entry + async chunks） |
| 输出 | 一个或多个 JS 文件（ESM 或 IIFE/CJS），可选 source map |
| 典型用法 | `shu build src/app.tsx --bundle -o dist/app.js`；或浏览器测试 `shu build tests/browser/index.tsx --bundle --target=browser -o tests/browser/dist/index.js` |

**与三种模式的关系**：

- **仅服务端**：bundle 产出供 `shu run` 执行；可把 `shu:xxx` 等 builtin 标记为 external，不打进 bundle。
- **仅客户端**：bundle 产出供浏览器或浏览器测试加载；通常需标记 Node/Shu 专有模块为 external 或替换为浏览器 stub。
- **服务端 + bundle**：同一套 bundle 管线，用 `--target=shu` 与 external 配置区分。
- **客户端 + bundle**：同一套管线，用 `--target=browser` 与 JSX/minify 等区分。

**选项示例**：

- `--bundle`：启用 bundle 模式（否则仅单文件编译）。
- `--external=shu:fs,shu:path`：不打包，运行时从 Shu 解析。
- `--splitting`：是否拆 chunk（如按动态 import）。
- `--sourcemap`：生成 source map。

**实现要点**：

- 依赖图：复用或复用思路来自现有 ESM loader（解析 import/export，解析 `shu:xxx` 等）；可先支持 ESM 单入口 + 静态 import。
- 合并：按拓扑顺序拼接已转译的模块体，用 IIFE 或 ESM 格式包裹；后续可接 minify、tree-shake。

---

## 三、统一参数约定（与 shu:test 一致）

与 `shu:test` 的「name, fn, options」约定类似，编译 API 建议**选项集中在一个 options 对象**中，且与 CLI 一一对应：

- **入口**：第 1 位，字符串或数组。
- **选项**：第 2 位，对象，例如：
  - `target: 'shu' | 'browser'`
  - `out: string`
  - `format: 'esm' | 'cjs'`
  - `bundle: boolean`
  - `minify: boolean`
  - `jsx: 'preserve' | 'transform'`
  - `external: string[]`
  - `sourcemap: boolean`

示例（程序化 API，后续实现）：

```javascript
const build = await import('shu:build');

// 服务端单文件编译
await build.compile('src/main.ts', { out: 'dist/main.js', target: 'shu' });

// 客户端 + bundle（供浏览器测试）
await build.compile('tests/browser/runner.tsx', {
  out: 'tests/browser/dist/runner.js',
  target: 'browser',
  bundle: true,
  jsx: 'transform',
});
```

---

## 四、实现阶段建议

| 阶段 | 内容 |
|------|------|
| **Phase 0（当前）** | CLI 占位 + 本文档；`shu:build` 未注册或仅 stub。 |
| **Phase 1** | **服务端编译**：单入口单文件，TS/TSX 用 `strip_types` 擦除后写出到 `-o`；CLI `shu build entry -o out.js`，可选 `shu:build.compile(entry, { out })`。 |
| **Phase 2** | **客户端编译**：在 Phase 1 基础上加 `--target=browser`，同一套 strip；若含 JSX，增加简单 JSX 转 JS（或对接 swc/esbuild 子进程）。输出可直接用于浏览器测试。 |
| **Phase 3** | **Bundle**：解析入口的 import，递归建图，对每个模块做 strip/转译，再按顺序合并为单文件（或简单 chunk）；支持 `--external`。先支持 ESM 静态 import。 |
| **Phase 4** | 可选：minify、source map、tree-shake、`shu:build` 完整 API 与 CLI 对齐。 |

浏览器测试依赖：至少完成 **Phase 2（客户端编译）**，TSX 能出浏览器可执行 JS；若测试入口有 import 依赖，则需 **Phase 3（bundle）** 打成一个文件再在测试页加载。

---

## 五、与现有代码的衔接

- **类型擦除**：统一使用 `transpiler/strip_types.zig`；如需更强 TS/JSX 支持，可扩展 `transpiler/ts.zig` 或调用外部工具（swc/esbuild）。
- **CLI**：在 `src/cli/build.zig` 中解析 `shu build [entry] -o <out> [--target=shu|browser] [--bundle] [--format=esm|cjs]` 等，调用 Zig 侧编译管线。
- **运行时模块**：新增 `src/runtime/modules/shu/build/mod.zig`，提供 `compile(entry, options)` 等，内部调 strip_types 与（Phase 3 起）bundle 逻辑；在 `builtin.zig` 中注册 `shu:build`。
- **浏览器测试**：在实现 `shu test --browser` 时，对标记为浏览器或目录在 `tests/browser/` 的用例，先调用 shu:build 客户端（+ 可选 bundle），再启动静态服务并加载产出。

---

## 六、小结

- **服务端编译**：TS/TSX → JS，产出给 `shu run` 执行；先单文件 + strip_types。
- **客户端编译**：TS/TSX → JS（+ JSX 处理），产出给浏览器或浏览器测试；与服务端共用 strip，用 `--target=browser` 区分。
- **Bundle 编译**：多模块打成一或多个 chunk，服务端与客户端共用同一管线，通过 target 与 external 区分。
- **选项**：统一放在一个 options 对象中，与 CLI 一一对应；浏览器测试依赖客户端编译与可选 bundle，建议在 shu:test 浏览器方案前实现 Phase 2（及按需 Phase 3）。
