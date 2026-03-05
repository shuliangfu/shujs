# 测试目录约定

测试按层级分目录，便于区分职责和 CI 分阶段运行。

## 目录结构

| 目录 | 用途 | 说明 |
|------|------|------|
| **tests/unit/shu/** | 单元 · shu | 各 `shu:*` 模块 API 的逐项测试，单模块、单方法为主；部分用例含真实 I/O（如 fs 读写）。 |
| **tests/unit/node/** | 单元 · Node 兼容 | 与 Node.js API 行为对齐的用例（待补）。 |
| **tests/unit/deno/** | 单元 · Deno 兼容 | 与 Deno API 行为对齐的用例（待补）。 |
| **tests/unit/bun/** | 单元 · Bun 兼容 | 与 Bun API 行为对齐的用例（待补）。 |
| **tests/integration/** | 集成测试 | 多模块协作、真实 fs/网络/子进程等，不 mock 底层。 |
| **tests/e2e/** | 端到端测试 | 完整用户流程：CLI 命令、真实服务起停、浏览器等。 |

## 运行方式

- 全量：`shu test`（递归扫描 `tests/` 下所有 `*.test.js` / `*.spec.js`）。
- 只跑单元：`shu test tests/unit`。
- 只跑 shu 单元：`shu test tests/unit/shu`。
- 只跑集成：`shu test tests/integration`。
- 只跑 e2e：`shu test tests/e2e`。

## 测试公共输出目录

- 所有测试的读写统一使用 **`tests/test-data/`**（由 `tests/unit/utils.js` 提供 `getTestDataDir` / `ensureTestDataDir` / `cleanupTestDataDir`）。
- 单元测试可按子目录划分，如 `tests/test-data/fs`、`tests/test-data/unit/shu` 等，用例结束在 `afterAll` 中清理对应子目录或整目录。
- 该目录已加入 `.gitignore`，不纳入版本控制。

## 快照目录

- 使用 `shu:test` 的 `snapshot(name, value)` 时，快照文件写在**项目根**下的 **`snapshots/`** 目录（与常见运行时约定一致）。
- 路径规则：`snapshots/<测试文件相对路径>.snap`，例如 `snapshots/tests/unit/shu/shu-test.test.snap`。
- 更新快照：`shu test -u` 或 `shu test --update-snapshots`（需 `--allow-write`）。

## 约定

- 单元：单文件对应单模块或单能力，快、稳定，少依赖环境。
- 集成：可共用测试数据目录、临时端口等，测试结束清理。
- e2e：可依赖环境（如端口、浏览器），失败时便于从日志复现。
