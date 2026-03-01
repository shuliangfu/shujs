# 单元测试目录说明

## 为什么可以直接 `@import("../../transpiler/jsx.zig")`？

测试入口在 **`src/test_runner.zig`**（和 `src/main.zig` 同级的 `src/` 下），Zig 的**模块根**就是 **`src/`**。  
所以 `src/tests/` 下的任意文件都可以用相对路径导入 `src/` 里其它代码，例如：

- `src/tests/transpiler/jsx.zig` 里写 `@import("../../transpiler/jsx.zig")`
- `src/tests/runtime/foo.zig` 里写 `@import("../../runtime/xxx.zig")`

**不需要**在 build.zig 里为每个被测模块写 `addImport`。

## 目录放哪、入口放哪？

- **测试目录**：放在 **`src/tests/`**（和 `transpiler/`、`runtime/` 同级）即可。
- **测试入口**：必须是 **`src/` 下的一个 .zig**（例如 `src/test_runner.zig`），由 build.zig 指定为 test 的 `root_source_file`。这样模块根才是 `src/`，`tests/` 里才能直接导入兄弟目录。

若入口是 `src/tests/main.zig`，模块根会被当成 `src/tests/`，再写 `../../transpiler/xxx.zig` 就会报 “import of file outside module path”。

## 新增测试 / 新增被测模块

- **只加测试文件**：在 `src/tests/` 下新建（如 `src/tests/transpiler/bar.zig`），在 `src/tests/main.zig` 里加一行 `@import("transpiler/bar.zig")` 即可，**不用改 build.zig**。
- **被测代码**：只要是 `src/` 下的文件，测试里直接用相对路径导入即可，**不用改 build.zig**。若被测模块内部有 `@import("xxx")`（如 http2 依赖 hpack_huffman），需在 build.zig 里给 test_module 加 `addImport("xxx", xxx_module)`。

当前已迁入的 tests：`transpiler/strip_types`、`transpiler/jsx`、`runtime/modules/shu/server/http2`、`runtime/modules/shu/server/websocket` 等。统一用 `zig build test` 运行。

## 如何看到测试结果输出？

默认 `zig build test` 成功时终端可能没有任何输出。可用下面两种方式看到结果：

1. **构建摘要（推荐）**：执行  
   `zig build test --summary all`  
   会打印构建步骤树和「X/X tests passed」等摘要。

2. **每个测试名称与 OK**：先执行一次 `zig build test`，再直接运行生成的测试二进制（在 `.zig-cache/o/.../test`），例如：  
   `./.zig-cache/o/$(ls -t .zig-cache/o | head -1)/test`  
   或先 `zig build test` 后在 `.zig-cache/o` 下找到最新的 `test` 可执行文件并运行，即可看到逐条测试名和 `All N tests passed`。
