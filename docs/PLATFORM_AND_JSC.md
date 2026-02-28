# 平台与 JavaScript 引擎说明

本文说明在不同操作系统上运行 Shu 时与 JavaScript 执行相关的行为，以及非 macOS 平台如何获取并链接 JavaScriptCore（JSC）。

## 当前行为概览

| 平台     | 默认能否执行 JS | 说明 |
|----------|------------------|------|
| **macOS** | 是               | 使用系统自带的 JavaScriptCore 框架，无需额外配置。 |
| **Linux** | 否（需配置后可以） | 需在构建时提供 WebKit JSC 的路径，见下文。 |
| **Windows** | 否（需配置后可以） | 同上。 |

若在 Linux 或 Windows 上直接执行 `zig build` 且**未**传入有效的 `-Djsc_prefix`，构建会**故意失败**并报错，以避免发布无法执行 JS 的二进制。

## 非 macOS 如何启用 JS（-Djsc_prefix）

在 Linux 或 Windows 上要运行 `shu run` 等依赖 JS 的功能，需要：

1. **获取 WebKit JSC**：得到包含 `include/`（头文件）和 `lib/`（如 `libJavaScriptCore.a` 或 `.so`）的根目录。
2. **构建时传入该目录**：  
   `zig build -Djsc_prefix=/path/to/webkit-jsc`

### 如何获取 WebKit JSC

详细步骤（含 Bun 预编译包、从 WebKit 源码自建等）见：

- **内置 API 与跨平台说明**： [src/runtime/engine/BUILTINS.md](../src/runtime/engine/BUILTINS.md) 中「跨平台兼容方案」与「如何获取 WebKit JSC」两节。

简要方式：

- **推荐先试**：使用 Bun 的预编译包（如 `bun-webkit-linux-amd64` 等），解压后得到含 `include/` 与 `lib/` 的目录，以其路径作为 `jsc_prefix`。
- **需要自建时**：从 WebKit 或 [oven-sh/WebKit](https://github.com/oven-sh/WebKit) 克隆并仅构建 JSC，将产物整理成上述目录结构后再用 `-Djsc_prefix` 指向该目录。

## 用户文档建议

若你在项目文档或 README 中介绍 `shu run` 或 JS 能力，建议写明：

- 仅 **macOS** 上默认即可运行 JS。
- **Linux / Windows** 需先按上文获取 JSC 并用 `-Djsc_prefix=<目录>` 构建后，才能执行 JS；否则相关二进制不会包含 JS 引擎。

这样可避免用户误以为非 macOS 构建“坏了”或“不支持 JS”。
