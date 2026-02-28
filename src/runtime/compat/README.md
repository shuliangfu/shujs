# runtime/compat — Node / Deno / Bun 兼容层说明

本目录放的是**运行时行为兼容**代码，与 **modules/node、modules/deno、modules/bun** 分工不同：


| 层级            | 职责                                                                                 | 位置                                                                                    |
| ------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- |
| **模块解析与内置导出** | `require("node:fs")` / `import "deno:fs"` / `import "bun:sqlite"` 等解析、返回对应 exports | **modules/node/builtin.zig**、**modules/deno/builtin.zig**、**modules/bun/builtin.zig** |
| **兼容层（本目录）**  | 与「宿主风格」相关的**运行时行为**：启动参数、全局差异、权限模型、环境变量约定等                                         | **compat/node**、**compat/deno**、**compat/bun**                                        |


当前 **compat 仅占位**，未在 bindings/engine 中调用；实现下列能力时再在此补代码。

---

## compat/node — 写什么

- **Node 风格启动**：`process.argv`、`process.execPath` 的语义（与现有 process.zig 协作或扩展）。
- **Node 特有全局**：如 `global` 与 `globalThis` 的别名、`process.nextTick`（若与 timers 分开实现）。
- **CJS/ESM 互操作**：`require.extensions`、`Module._load` 等内部钩子（若做 Node 风格 CJS 时）。
- **Buffer / process 与 Node 的细微差异**：如 `Buffer.isEncoding`、`process.binding` 占位等。

不放在 compat 的：`node:xxx` 的解析与 exports 已在 **modules/node/builtin.zig** 中实现（复用 shu:xxx）。

---

## compat/deno — 写什么

- **deno: 协议解析**：当 loader/require 遇到 `deno:xxx` 时，如何解析到 @std 或 shu:xxx（与 modules/deno/builtin.zig 配合）。
- **Import Map**：解析 import map，重写说明符（与 ESM 加载器配合）。
- **权限风格 API**：若实现 `Deno.permissions.query/request`、`--allow-`* 与 Deno 语义对齐，可在此或与 run_options 协作。
- **Deno 全局命名空间**：`Deno.args`、`Deno.build`、`Deno.serve` 等（若做 Deno 风格入口时）。

不放在 compat 的：deno: 说明符列表与规划在 **modules/deno/builtin.zig**。

---

## compat/bun — 写什么

- **Bun 风格启动**：`Bun.main`、`Bun.env` 与 process 的差异；热重载/单次执行等入口行为。
- **Bun 与 Node 的差异**：如 `Bun.sleep` vs `setTimeout`、`Bun.file` 与 Node `fs` 的对照（具体 API 已在 engine/bun 或 modules 实现，此处做策略或桥接）。
- **bun:xxx 的解析策略**：若在 loader 中识别 `bun:ffi`、`bun:sqlite` 等并转发到 modules/bun 或原生实现。

不放在 compat 的：Bun.serve、Bun.file、Bun.write 等已在 **engine/bun** 实现；bun: 说明符列表在 **modules/bun/builtin.zig**。

---

## 小结

- **modules/*/builtin.zig**：管「说明符 → 导出对象」；**compat/**：管「宿主风格下的运行时行为与解析策略」。
- 当前三者均为占位；需要 Node/Deno/Bun 的**行为对齐**时，再在对应 compat 子目录内实现并在 **bindings** 或 **loader** 中按需调用。

