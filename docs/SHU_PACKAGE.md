# Package 实现设计：兼容 package.json 与 deno.json

本文档说明如何实现 **ShuJS** 的包与配置层，使之**同时兼容 Node 的 package.json** 与 **Deno 的 deno.json**，供 `shu run`、`require`、`shu build`、`shu install` 等共用。

---

## 一、目标与范围

| 目标 | 说明 |
|------|------|
| **package.json 兼容** | 解析 name、version、main、module、exports、scripts、dependencies 等，与 Node/npm 行为对齐；供 `require('lodash')`、`shu run dev`（scripts）、`shu build --bundle` 入口解析使用。 |
| **deno.json 兼容** | 解析 imports（Import Map）、tasks、exports、compilerOptions、lock 等，与 Deno 行为对齐；供裸说明符解析、`shu task start`、TS 配置等使用。 |
| **统一入口** | 同一项目可仅用 package.json、仅用 deno.json、或两者并存；解析与脚本执行共用一套「项目配置」抽象。 |

**不涉及**（可后续单独文档）：lockfile 格式与 install 下载流程、workspace 多包、发布 publish。

---

## 二、package.json 兼容

### 2.1 需解析的字段

| 字段 | 用途 | 说明 |
|------|------|------|
| **name** | 包名 | 供 display、install 写 node_modules 等。 |
| **version** | 版本 | 语义化版本，可选用于解析与锁文件。 |
| **main** | 默认入口（CJS） | 当 `require('package-name')` 且未命中 exports 时，解析到该文件。 |
| **module** | 默认入口（ESM） | 部分生态用其表示 ESM 入口；可与 main 并存。 |
| **exports** | 条件导出 | 子路径与条件（import/require、default）解析，优先级高于 main。见 [Node 文档](https://nodejs.org/api/packages.html#package-entry-points)。 |
| **scripts** | 脚本命令 | `shu run <script>` 时查找并执行对应命令（如 `dev` → `scripts.dev`）。 |
| **dependencies** / **devDependencies** | 依赖声明 | 供 `shu install` 与裸说明符→路径解析（在 node_modules 中查包名）。 |
| **type** | 模块类型 | `"module"` 时 .js 视为 ESM；缺省为 CJS。 |

**实现要点**：

- **manifest.zig**：用 `std.json` 解析 JSON，填充 `Manifest` 结构（含 `main`、`exports`、`scripts`、`dependencies`）。`exports` 可为字符串或嵌套对象，需支持条件键（`import`/`require`/`default`）与子路径（`.`、`./sub`）。
- **入口解析**：给定包目录，先查 `exports["."]` 或 `exports` 字符串，再 fallback 到 `module` 或 `main`；子路径查 `exports["./sub"]`。未实现 exports 时可仅用 main/module。

### 2.2 裸说明符→文件路径（Node 风格）

流程（与 Node 对齐）：

1. 从**当前模块所在目录**（或入口所在目录）向上查找，直到找到含 `node_modules` 的目录。
2. 在 `node_modules/<specifier>` 查找目录或包名；若为目录，读取其 **package.json**，用 **exports** 或 **main**/module 得到入口相对路径。
3. 拼接为绝对路径返回；若未找到，继续向父目录查找，直到根。

与 **require** / **esm_loader** 的 `resolveRequest` 对齐：该逻辑应放在 **package/resolver.zig**（或统一 resolve 模块），供 require、build --bundle、install 复用。

---

## 三、deno.json 兼容

### 3.1 需解析的字段

| 字段 | 用途 | 说明 |
|------|------|------|
| **imports** | Import Map | 裸说明符 → URL 或相对路径（如 `"@std/assert": "jsr:@std/assert@^1.0.0"`、`"@/": "./"`）。优先于 node_modules 查找（可配置）。 |
| **tasks** | 任务命令 | 与 package.json 的 scripts 等价；`shu task start` 执行 `tasks.start`。可与 scripts 统一为「脚本名→命令」。 |
| **exports** | 包入口 | 与 Node exports 语义类似，定义包对外暴露的路径。 |
| **compilerOptions** | TS 配置 | lib、strict、jsx 等，供 typecheck、build 的 TS 行为。 |
| **lock** | 锁文件 | 路径或 `false`；与 install/run 的完整性校验相关。 |
| **nodeModulesDir** | node_modules 策略 | `"none"` / `"auto"` / `"manual"`，影响是否使用本地 node_modules。 |

支持 **deno.jsonc**（带注释的 JSON），解析时需允许 `//` 注释并 strip 后再按 JSON 解析，或使用支持 jsonc 的解析器。

### 3.2 与 package.json 并存时的优先级

Deno 官方行为（可沿用）：

- 若**同时存在** deno.json 与 package.json：**依赖**可来自两者（imports + dependencies）；**Deno 特有配置**（tasks、compilerOptions、lint、fmt 等）以 deno.json 为准。
- 若**仅存在** package.json：按 Node 行为解析。
- 若**仅存在** deno.json：按 Deno 行为解析（imports、tasks 等）。

建议：Shu 在**同一目录**下**优先读取 deno.json / deno.jsonc**；若不存在再读 package.json。这样 Deno 项目无 package.json 也能跑；Node 项目仅 package.json 不受影响。

### 3.3 裸说明符→路径（Deno 风格）

- **imports** 为 Import Map：先查 `imports[specifier]` 或最长前缀匹配（如 `"bar/": "./bar/"` → `bar/file.ts` 映射到 `./bar/file.ts`）。
- 若为 URL（`npm:`、`jsr:`、`https:` 等），需按协议解析：npm 对应 node_modules 或远程拉取；jsr 对应 JSR  registry；https 直接使用。**首阶段可只实现「映射到相对路径」**，URL 协议可后续接 install 或 fetch。
- 若未命中 imports，再走 **Node 风格** node_modules + package.json main/exports。

---

## 四、统一抽象与检测顺序

### 4.1 项目配置抽象（建议结构）

在 **manifest.zig**（或单独 `project_config.zig`）中定义统一结构，能同时承载 package.json 与 deno.json 的并集，例如：

```zig
// 伪代码：统一项目配置
pub const ProjectConfig = struct {
    /// 来源：.package_json | .deno_json
    source: enum { package_json, deno_json },
    /// 配置文件所在目录（绝对路径）
    root_dir: []const u8,
    name: []const u8,
    version: []const u8,
    /// 入口：main / module / exports["."]，已解析为相对 root_dir 的路径
    main: ?[]const u8,
    /// 条件导出（Node exports 或 deno exports）
    exports: ?ExportsMap,
    /// 脚本名 → 命令（来自 scripts 或 tasks）
    scripts: StringArrayHashMap([]const u8),
    /// 依赖：package 的 dependencies；deno 的 imports 中 npm:/jsr: 等可转为依赖表
    dependencies: StringArrayHashMap([]const u8),
    /// Import Map（deno imports 或从 package 的 imports 字段）
    imports: ?ImportMap,
    /// 仅 deno：compilerOptions、lock、nodeModulesDir 等
    compiler_options: ?DenoCompilerOptions,
};
```

**加载顺序**（在给定目录 `dir` 下）：

1. 尝试读取 `dir/deno.jsonc` 或 `dir/deno.json`；若存在，解析为 Deno 配置并填充 `ProjectConfig`（imports、tasks→scripts、exports 等）。
2. 若不存在 deno.json(c)，读取 `dir/package.json`，解析为 Node 配置并填充。
3. 若两者都存在，可**合并**：scripts 与 tasks 合并（tasks 优先或按命名空间区分），imports 与 dependencies 合并，Deno 特有项来自 deno.json。

### 4.2 查找配置文件的目录

- **shu run**：从**当前工作目录**向上查找，直到找到包含 package.json 或 deno.json 的目录（或到根）。
- **require/import 解析**：从**当前模块所在目录**向上查找，确定「项目根」和对应配置，再在该根下解析裸说明符。
- **shu build**：从**入口文件所在目录**向上查找项目根。

与现有 **shu:module.findPackageJSON** 对齐：可扩展为 `findProjectConfig(allocator, dir)`，返回 `ProjectConfig` 及所在目录；内部先找 deno.json 再找 package.json。

---

## 五、实现步骤建议

### 5.1 阶段〇（当前 README 阶段〇）

| 步骤 | 内容 | 文件 |
|------|------|------|
| 1 | 实现 **package.json** 真实解析：JSON 读取、main、exports、scripts、dependencies 填入 Manifest | manifest.zig |
| 2 | 实现 **入口解析**：给定包目录 + 子路径，按 exports / main 返回相对路径 | manifest.zig 或 resolver.zig |
| 3 | 实现 **裸说明符→绝对路径**：沿目录向上找 node_modules/<specifier>，读包 package.json 并解析入口 | resolver.zig |
| 4 | 与 **require** / **esm_loader** 的 resolveRequest 对接，使 `require('lodash')` 能解析到 node_modules 内文件 | runtime require + package/resolver |

### 5.2 阶段〇+（deno.json 兼容）

| 步骤 | 内容 | 文件 |
|------|------|------|
| 5 | 增加 **deno.json / deno.jsonc** 解析：imports、tasks、exports、compilerOptions 等 | 新建 deno_config.zig 或并入 manifest.zig |
| 6 | 实现 **统一 ProjectConfig** 与 **findProjectConfig**：按目录向上查找，优先 deno.json 再 package.json，合并脚本与依赖 | manifest.zig / project_config.zig |
| 7 | **裸说明符解析**：先查 ProjectConfig.imports（Import Map），未命中再走 node_modules + package.json | resolver.zig |
| 8 | **shu run <script>** / **shu task <task>**：从 ProjectConfig.scripts 或 tasks 取命令并执行 | cli/run.zig |

### 5.3 与 build / install 的对接

- **shu build --bundle**：解析 import 时，裸说明符调用 **resolver.resolve(projectRoot, specifier)**，得到绝对路径后再读文件、strip、合并。
- **shu install**：读取 ProjectConfig.dependencies（及 devDependencies），下载并写入 node_modules；锁文件可选。

---

## 六、exports 解析要点（Node 与 Deno）

- **exports** 可为字符串或对象。对象时：
  - 键为子路径：`"."` 表示包根，`"./utils"` 表示子路径。
  - 值为字符串或条件对象：`{ "import": "./esm.js", "require": "./cjs.js", "default": "./default.js" }`。
- 解析时根据**当前解析场景**（import 或 require）选择 `import` / `require`，缺省用 `default`。
- Deno 的 exports 与 Node 的 exports 语义基本一致，可共用一套解析逻辑。

---

## 七、参考

- [Node Package entry points](https://nodejs.org/api/packages.html#package-entry-points)
- [Deno Configuration File](https://docs.deno.com/runtime/manual/getting_started/configuration_file/)
- [Import Maps](https://developer.mozilla.org/en-US/docs/Web/HTML/Import_maps)
- 本仓库：`src/package/manifest.zig`、`src/package/resolver.zig`、`README.md` 阶段〇
