# 测试效率提升指南

本文列出可提升 `shu test` 及单测执行效率的途径，并对比 **Node / Deno / Bun** 的测试 CLI 参数，给出 shu 可实现的实用参数建议。

---

## 0. Node / Deno / Bun 测试 CLI 参数对比

### 0.1 过滤与选择

| 能力                | Node (`node --test`)            | Deno (`deno test`)                               | Bun (`bun test`)                             | shu test                                                                           |
| ------------------- | ------------------------------- | ------------------------------------------------ | -------------------------------------------- | ---------------------------------------------------------------------------------- |
| **按文件/路径过滤** | 传文件或目录作参数              | 传文件或目录；config 中 `test.include`/`exclude` | 位置参数作 filter（路径匹配，暂不支持 glob） | ✅ **--filter=pattern**（路径子串匹配）                                            |
| **按测试名过滤**    | **--test-name-pattern**（正则） | **--filter** 字符串或 **--filter /regex/**       | **-t / --test-name-pattern**（正则）         | ✅ **--test-name-pattern** / **-t**（子串匹配，经 SHU_TEST_NAME_PATTERN 传子进程） |
| **跳过某类测试**    | **--test-skip-pattern**（正则） | 无专用 CLI；用 test 内 `ignore`                  | 无专用 CLI                                   | ✅ **--test-skip-pattern**（子串匹配，SHU_TEST_SKIP_PATTERN）                      |

- **结论**：shu 已具备「按路径过滤」与「按测试名/跳过名过滤」（--test-name-pattern、--test-skip-pattern，子串匹配）。

### 0.2 并发与执行控制

| 能力           | Node           | Deno                          | Bun                                                          | shu test                                                                                                  |
| -------------- | -------------- | ----------------------------- | ------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------- |
| **并发数**     | 有并发，可配置 | **--parallel** 并行跑测试模块 | 单进程内 **--concurrent** + **--max-concurrency**（默认 20） | ✅ **--jobs=N**（默认 1 单文件顺序；N>1 多文件并行）；**package.json test.include / test.exclude** 已支持 |
| **分片（CI）** | 无统一语法     | 无                            | 无                                                           | ✅ **--shard=index/total**（只跑第 index 份，共 total 份）                                                |
| **遇失败即停** | 可配置         | **--fail-fast**               | **--bail** / **--bail=N**                                    | ✅ **--bail** / **--fail-fast**（首失败即停；CLI 停后续文件，runtime 单文件内首失败即 reject）            |
| **单测超时**   | 可配置         | 可配置                        | **--timeout**（毫秒，默认 5000）                             | ✅ **--timeout=N**（经 SHU_TEST_TIMEOUT 设默认超时，与 run({ timeout }) 一致）                            |

- **结论**：**--bail** / **--fail-fast**、**--timeout**、**--shard**、**--reporter=junit** 已实现。

### 0.3 报告与输出

| 能力          | Node                                   | Deno                               | Bun                                                  | shu test                                                                                |
| ------------- | -------------------------------------- | ---------------------------------- | ---------------------------------------------------- | --------------------------------------------------------------------------------------- |
| **Reporter**  | **--test-reporter**（dot/spec/tap 等） | **--reporter**（pretty/dot/junit） | **--reporter**（junit/dots）+ **--reporter-outfile** | stdout 文本 + **--reporter=junit --reporter-outfile=path**                              |
| **JUnit XML** | 支持                                   | **--junit-path**                   | **--reporter=junit --reporter-outfile**              | ✅ **--reporter=junit --reporter-outfile=path**（子进程写 XML，多文件时最后一进程覆盖） |

- **结论**：CI 友好可用 **--reporter=junit --reporter-outfile=path**，便于集成到 GitLab/Jenkins 等。

### 0.4 其它常用

| 能力              | Node                      | Deno           | Bun                          | shu test                                                                                                              |
| ----------------- | ------------------------- | -------------- | ---------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| **Watch**         | 无内置                    | 无内置         | **--watch**                  | ❌ 未实现                                                                                                             |
| **重试失败**      | 无                        | 无             | **--retry N**                | ✅ **--retry=N**（SHU_TEST_RETRY，失败用例重试 N 次）                                                                 |
| **随机顺序**      | 有                        | 无             | **--randomize** + **--seed** | ✅ **--randomize**、**--seed=N**（打乱测试文件顺序，SHU_TEST_RANDOMIZE/SEED）                                         |
| **只跑 todo**     | 无                        | 无             | **--todo**                   | ✅ **--todo**（只跑 it.todo/test.todo，SHU_TEST_TODO_ONLY）                                                           |
| **更新 snapshot** | 无                        | 无             | **--update-snapshots / -u**  | ✅ **--update-snapshots** / **-u**（SHU_TEST_UPDATE_SNAPSHOTS；snapshot 持久化到项目根 **snapshots/** 目录）          |
| **Preload**       | 无                        | 无             | **--preload**                | ✅ **--preload=path**（跑测试前先 require 该脚本，SHU_TEST_PRELOAD）                                                  |
| **Coverage**      | 实验性 --test-coverage-\* | **--coverage** | **--coverage** 等            | ✅ **--coverage**、**--coverage-dir=path**（SHU_TEST_COVERAGE/COVERAGE_DIR；当前写占位 lcov.info，行/分支采集待后续） |

**说明**：snapshot 与 coverage 已完整实现（CLI 传 env + runtime 读/写文件）。若本地未生成 `snapshots/**/*.snap` 或 `coverage/lcov.info`，请在**项目根**执行、并尝试 `--jobs=1`；子进程依赖 `SHU_TEST_CWD` 解析路径，确保从根目录启动。

---

## 1. 已支持：立即可用

| 手段              | 用法                                                            | 说明                                                                                                                                                 |
| ----------------- | --------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| **并发数**        | `shu test --jobs=N`                                             | 默认等于 CPU 核心数；CI 或 I/O 较多时可试 `--jobs=2*cores`；需稳定顺序时用 `--jobs=1`。                                                              |
| **过滤文件**      | `shu test --filter=pattern` 或 `shu test --filter pattern`      | 只运行路径（含子路径）中包含 `pattern` 的测试文件，开发时只跑相关用例，缩短反馈时间。例：`shu test --filter example` 只跑路径里带 `example` 的文件。 |
| **按测试名过滤**  | `shu test --test-name-pattern=pat` 或 `-t pat`                  | 只跑完整名称（suite 链 + 用例名）包含 `pat` 的用例；经环境变量 SHU_TEST_NAME_PATTERN 传子进程。                                                      |
| **跳过某类用例**  | `shu test --test-skip-pattern=pat`                              | 跳过名称包含 `pat` 的用例（SHU_TEST_SKIP_PATTERN）。                                                                                                 |
| **首失败即停**    | `shu test --bail` 或 `--fail-fast`、`--bail=N`                  | 首个失败后不再跑后续文件（并行时 worker 间共享 bail 标志）；单文件内首失败即 reject。                                                                |
| **分片（CI）**    | `shu test --shard=index/total`                                  | 只跑第 index 份（0..total-1），用于 CI 多 job 分片。                                                                                                 |
| **默认超时**      | `shu test --timeout=N`                                          | 全局默认用例超时（毫秒），经 SHU_TEST_TIMEOUT 传子进程，与 run({ timeout }) 一致。                                                                   |
| **失败重试**      | `shu test --retry=N`                                            | 失败用例重试 N 次（SHU_TEST_RETRY）。                                                                                                                |
| **JUnit 报告**    | `shu test --reporter=junit --reporter-outfile=junit.xml`        | 子进程将用例结果写为 JUnit XML（SHU_TEST_REPORTER / SHU_TEST_REPORTER_OUTFILE）；多文件时每进程写同一路径，最后一进程覆盖。                          |
| **只跑 todo**     | `shu test --todo`                                               | 仅运行标记为 it.todo / test.todo 的用例（SHU_TEST_TODO_ONLY）。                                                                                      |
| **随机顺序**      | `shu test --randomize`、`shu test --randomize --seed=N`         | 打乱测试文件执行顺序；未指定 --seed 时种子为 0（可复现）。                                                                                           |
| **Preload**       | `shu test --preload=path`                                       | 每个测试文件执行前先 require(preload)，便于加载环境或 polyfill。                                                                                     |
| **更新 snapshot** | `shu test --update-snapshots` 或 `shu test -u`                  | 将 snapshot(name, value) 的当前值写回项目根 **snapshots/** 下对应路径（如 snapshots/tests/unit/shu/xxx.test.snap）；需 --allow-write。               |
| **Coverage**      | `shu test --coverage`、`shu test --coverage --coverage-dir=dir` | 启用覆盖率；输出目录默认 coverage，会生成占位 lcov.info（行/分支采集待后续）；需 --allow-write。                                                     |

---

## 2. 建议实现的实用参数（按优先级）

基于 §0 三端对比，以下参数**实用且与 Node/Deno/Bun 对齐**，建议按序实现。

| 优先级 | 参数                                               | 三端对标                     | 说明与实现要点                                                                                                      |
| ------ | -------------------------------------------------- | ---------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| **P0** | **--test-name-pattern**（或 **-t**）               | Node/Deno/Bun 均有           | ✅ **已实现**：子串匹配，CLI 经 SHU_TEST_NAME_PATTERN 传子进程，runtime 按 suite 链+用例名过滤。                    |
| **P0** | **--bail** / **--fail-fast**                       | Deno --fail-fast；Bun --bail | ✅ **已实现**：CLI 首失败停后续文件（原子标志）；单文件内首失败即 reject。                                          |
| **P1** | **--shard=i/n**                                    | 常见于 CI（无统一语法）      | ✅ **已实现**：CLI 对已排序文件列表按 `index % n == i` 过滤。                                                       |
| **P1** | **--timeout=N**                                    | Bun --timeout                | ✅ **已实现**：SHU_TEST_TIMEOUT 设默认超时，与 run({ timeout }) 一致。                                              |
| **P2** | **--reporter=junit** + **--reporter-outfile=path** | Node/Deno/Bun 均有           | ✅ **已实现**：CLI 经 SHU_TEST_REPORTER/SHU_TEST_REPORTER_OUTFILE 传子进程，runtime 收集用例结果并写 JUnit XML。    |
| **P2** | **--test-skip-pattern**                            | Node --test-skip-pattern     | ✅ **已实现**：子串匹配，SHU_TEST_SKIP_PATTERN。                                                                    |
| **P3** | **--todo**                                         | Bun --todo                   | ✅ **已实现**：SHU_TEST_TODO_ONLY，buildJobList 只加入 todo 用例。                                                  |
| **P3** | **--randomize** + **--seed**                       | Node/Bun 随机顺序            | ✅ **已实现**：CLI 打乱测试文件列表（SHU_TEST_RANDOMIZE/SEED 传子进程；当前仅文件级打乱）。                         |
| **P3** | **--preload=path**                                 | Bun --preload                | ✅ **已实现**：SHU_TEST_PRELOAD，run 前 require 该脚本。                                                            |
| **P3** | **--watch**                                        | Bun --watch                  | ❌ 未实现：需文件监听与增量调度。                                                                                   |
| **P3** | **--retry=N**                                      | Bun --retry                  | ✅ **已实现**：SHU_TEST_RETRY，runner 层失败用例重试 N 次。                                                         |
| **P3** | **--update-snapshots / -u**                        | Bun --update-snapshots       | ✅ **已实现**：snapshot 持久化到项目根 **snapshots/** 目录（与常见运行时约定一致），加载/比较/写回由 runtime 完成。 |
| **P3** | **--coverage**、**--coverage-dir**                 | Deno/Bun --coverage          | ✅ **已实现**：CLI 传 SHU_TEST_COVERAGE/COVERAGE_DIR；runtime 写占位 lcov.info，完整行/分支采集待 JSC 或插桩方案。  |

**说明**：**--filter** 在 shu 中为「路径子串」，与 Deno/Bun 的「按测试名」不同；若加 **--test-name-pattern**，则「路径过滤」与「名称过滤」可同时使用（先筛文件，再筛用例）。

---

## 3. 高收益、可逐步实现（架构级）

| 手段                                | 思路                                                                                                 | 说明                                                                                                                          |
| ----------------------------------- | ---------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| **单进程多文件**                    | 一个 `shu` 进程内按序执行多份测试文件（同一 JSC 上下文或按文件建上下文），而不是「每文件一子进程」。 | 减少进程 spawn/wait 与重复启动 JSC 的开销；可复用 require 缓存。需在 runtime 支持「一次 run 加载多个入口」或 CLI 传文件列表。 |
| **按名过滤（--test-name-pattern）** | 见 §2 表：在 runner 层按 it/describe 名匹配，只执行匹配的 job。                                      | 与 Node/Deno/Bun 一致，大文件内只跑少数用例时明显缩短时间。                                                                   |
| **分片（--shard）**                 | 见 §2 表：对已排序文件列表按 index % n == i 过滤。                                                   | CI 多节点并行时总墙钟时间近似线性下降。                                                                                       |
| **Watch 模式**                      | 监听 tests/ 变更，只重跑变更过的文件（或依赖图内受影响的文件）。                                     | 开发时保存即跑，反馈快；需文件变更检测与增量执行策略。                                                                        |

---

## 4. 中收益、可选

| 手段               | 思路                                                                       | 说明                                                                                                  |
| ------------------ | -------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| **子进程启动加速** | ReleaseFast 构建、减小二进制体积、延迟初始化非测试路径。                   | 每个 `shu run` 启动更快，多文件时总时间下降。                                                         |
| **CPU 亲和性**     | 将 test worker 线程或子进程绑到固定核（如 worker_i → cpu_i % cores）。     | 减少迁移与缓存抖动，对纯 CPU 密集、多核并行有一定帮助；收益通常小于「少跑用例」和「多进程改单进程」。 |
| **批量小文件**     | 将多个小测试文件合并为单进程内顺序执行（一个进程跑多文件，再并行多进程）。 | 在「文件很多、每文件很短」时减少进程数，降低 spawn 占比。                                             |

---

## 5. 使用建议小结

- **日常开发**：用 `--filter=pattern` 只跑当前改动的模块；实现 **--test-name-pattern** 后还可按用例名精筛；需要时配合 `--jobs=1` 保证顺序。
- **CI 全量**：用默认 `--jobs`（或略放大）；加 **--bail** 可省时间；加 **--shard=i/n** 做分片并行。
- **追求极致总时间**：优先「单进程多文件」和「--test-name-pattern / --shard」，再考虑 CPU 亲和性等。

当前 CLI 已支持 **--jobs** 与 **--filter**；§2 所列参数可在后续迭代中按优先级实现。
