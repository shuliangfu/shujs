# shu:test 与 Node / Deno / Bun 测试 API 兼容说明

本模块以 **node:test** 为基准实现，并通过对齐与别名**兼容 Deno、Bun** 的常用测试写法，便于同一套测试代码或迁移时减少改动。

---

## 1. 三端对比总览

| 能力 | Node (node:test) | Deno (@std/testing/bdd + @std/assert) | Bun (bun:test) | shu:test |
|------|------------------|----------------------------------------|----------------|----------|
| **入口** | `node --test` 自动执行，无需 run | `deno test` 自动发现 | `bun test` 自动执行 | **不导出 run()**，加载后 **setImmediate 自动执行**（与三端一致） |
| **describe / it / test** | ✅ | ✅ describe / it | ✅ describe / test 或 it | ✅ |
| **beforeAll / afterAll / beforeEach / afterEach** | ✅ | ✅ | ✅ | ✅ |
| **skip** | it(..., { skip }) / it.skip | it.ignore / it.skip | test.skip | ✅ it.skip / test.skip；**it.ignore** = it.skip |
| **todo** | it(..., { todo }) / it.todo | — | test.todo | ✅ |
| **only** | it.only / it(..., { only }) | it.only / describe.only | test.only / describe.only | ✅ it.only / test.only；**describe.only** |
| **条件跳过** | test.skipIf(condition) | 手写 if + it.skip | 手写 | ✅ test.skipIf(condition) |
| **timeout** | it(..., { timeout }) | Deno.test({ ... }) 无 timeout 选项 | test(..., { timeout }) | ✅ it(..., { timeout }) 已解析存储 |
| **断言风格** | assert.strictEqual / deepStrictEqual / throws / rejects | assertEquals / assertStrictEquals / assertThrows / assertRejects | expect(x).toBe() / toEqual() / toThrow() | **assert**（Node 风格）；**Deno 别名**；**expect(value).toBe/toEqual/toThrow/toReject**（Bun/Jest 风格） |
| **测试上下文 t** | t.done() / t.skip() / t.todo() / t.name | — | done 回调 / t | ✅ t.done() / t.skip() / t.todo() / t.name；**t.step(name, fn)**（Deno） |
| **子步骤** | — | t.step("name", fn) | — | ✅ **t.step(name, fn)**（返回 Promise） |
| **mock** | node:test mock (fn/method) | 无内置，多用手写或第三方 | mock() 单函数 | ✅ mock.fn() / mock.method()（与 Node 对齐） |
| **snapshot** | 实验性 | 无内置 | 有 | ✅ snapshot(name, value) 最小实现 |
| **describe.skip/ignore** | — | describe.ignore | describe.skip | ✅ **describe.skip** / **describe.ignore**（整 suite 跳过） |
| **test.each** | — | — | test.each(table)(name, fn) | ✅ **it.each(table)(name, fn)** / **test.each(table)(name, fn)** |
| **test.serial** | — | — | test.serial | ✅ **test.serial = test**（顺序执行，与当前一致） |
| **多文件并发（CLI）** | node --test 可并行 | deno test 可并行 | bun test 可并行 | ✅ **shu test** 默认按 **CPU 核心数**并行；**--jobs=1** 顺序；**--filter=pattern** 路径过滤；**--test-name-pattern** / **-t**、**--test-skip-pattern** 用例名过滤；**--bail** / **--fail-fast** 首失败即停；**--shard=i/n** 分片；**--timeout=N**、**--retry=N** |

---

## 2. Node (node:test) 对齐

- **describe / it / test**、**beforeAll / afterAll / beforeEach / afterEach**；失败时 `process.exitCode = 1`。与 **node --test** 一致，**无需手动 run()**，shu 在加载后通过 setImmediate 自动执行。
- **assert**：ok、strictEqual、deepStrictEqual、throws、doesNotThrow、fail、rejects、doesNotReject。
- **t**：t.done()、t.skip()、t.todo()、t.name。
- **it / test** 第三参 options：skip、todo、only、skipIf、**timeout**（毫秒）。
- **mock**：mock.fn([impl])、mock.method(object, methodName)；返回带 .calls、.callCount。
- **snapshot(name, value)**：同 name 以 JSON 比较。

与 node:test 的差异：单测的 timeout 仅解析存储，未接入实际计时；不导出 run()。

---

## 3. Deno 兼容

### 3.1 执行模型

- Deno 无显式 `run()`，由 `deno test` 扫描并执行。shu **不导出 run()**，require('shu:test') 后脚本同步部分执行完即通过 setImmediate 自动开始跑测，与 Deno 行为一致。

### 3.2 BDD 与选项

- **describe / it**、**beforeAll / afterAll / beforeEach / afterEach** 与 @std/testing/bdd 一致。
- **it.only**、**describe.only**：与 Node 一致，已支持 it.only / test.only。
- **it.ignore / it.skip**：Deno 用 `.ignore` 跳过用例；shu 提供 **it.ignore** 与 **test.ignore**，行为同 **it.skip** / test.skip（即 skip: true）。

### 3.3 断言别名（@std/assert 风格）

为便于 Deno 代码迁移或混写，assert 上提供以下**别名**（实现委托给现有 Node 风格断言）：

| Deno (@std/assert) | shu:test 实现 |
|--------------------|----------------|
| assertEquals(actual, expected [, msg]) | assert.deepStrictEqual(actual, expected [, msg]) |
| assertStrictEquals(actual, expected [, msg]) | assert.strictEqual(actual, expected [, msg]) |
| assertThrows(fn [, msg]) | assert.throws(fn [, msg]) |
| assertRejects(promiseOrFn [, msg]) | assert.rejects(promiseOrFn [, msg]) |

- **assertExists** / **assertTrue**：可用 **assert.ok(value)**。
- **assertFalse**：可用 **assert.ok(!value)** 或 **assert.strictEqual(value, false)**。
- **assertRejects** 返回 Promise，需 await，与 Node assert.rejects 一致。

### 3.4 Deno 子步骤

- **t.step("name", fn)**：已实现。在当前测试内顺序执行子步骤，`fn` 可为同步或返回 Promise；返回 Promise 供 `await t.step(...)` 使用，步骤内抛错或 reject 则当前测试失败。

### 3.5 Deno 特有、不适用 shu（不实现）

- **Deno.test()** 长表单的 **sanitizeOps / sanitizeResources / sanitizeExit**：为 **Deno 运行时**的泄漏/退出检查，与 Deno 的权限与资源计数模型绑定。**shu 运行时没有同一套「ops/资源/退出」计数模型**，因此**不实现**、也**不需要**写；无 no-op 占位。若从 Deno 迁移，可忽略这三项。
- **permissions** 按测试配置：由运行时权限模型决定，不在此模块实现。

---

## 4. Bun 兼容

### 4.1 执行模型

- Bun 无显式 `run()`，由 `bun test` 执行。shu **不导出 run()**，加载后自动执行，与 Bun 一致。

### 4.2 describe / test / it / 钩子

- **describe**、**test**、**it**、**beforeAll**、**afterAll**、**beforeEach**、**afterEach** 与 Bun 一致。
- **test.only** / **test.skip** / **test.todo**：对应 shu 的 it.only / it.skip / it.todo（test 与 it 同源）。

### 4.3 断言风格

- Bun 使用 **expect(value).toBe() / toEqual() / toThrow()** 等链式 API。shu 已提供最小 **expect(value)**：
  - **toBe(expected)**：对应 assert.strictEqual
  - **toEqual(expected)**：对应 assert.deepStrictEqual
  - **toThrow()** / **toThrow(message)**：对应 assert.throws
  - **toReject()**：返回 thenable，对应 assert.rejects
  - **toBeTruthy()** / **toBeFalsy()**：对应 assert.ok(value) / assert.ok(!value)

### 4.4 Mock

- **mock.fn()** / **mock.method()** 与 Node 一致，Bun 的 `mock(fn)` 可对应 **mock.fn(fn)**；**.calls** / **.callCount** 已支持。

### 4.5 Bun 特有、已实现或说明

- **test.each(table)(name, fn)** / **it.each(table)(name, fn)**：已实现；`table` 为数组的数组或对象数组，对每行注册一条用例，`name` 可为字符串或 `(row) => string`。
- **test.serial**：与 **test** 同实现（顺序执行），已提供 **test.serial** 别名。
- **test.concurrent**：当前未实现（后续可扩展为并发执行）。
- **expect** 链式 matchers：见 4.3，已实现最小集。

---

## 5. 使用建议

- **以 Node 为主**：直接按 node:test 写，**无需 run()**，加载后自动执行。
- **多文件测试**：**shu test** 默认按 CPU 核心数并行执行多文件；需顺序执行时传 **`shu test --jobs=1`**；**`shu test --jobs=N`** 可指定并发数。
- **从 Deno 迁移**：用 **assertEquals / assertStrictEquals / assertThrows / assertRejects** 与 **it.ignore**、**t.step**，其余与 @std/testing/bdd 一致。
- **从 Bun 迁移**：用 **describe / test / it**、**describe.skip/only**、**test.each**、**expect**、mock.fn/mock.method。
- **跨运行时共用**：只用 describe / it 或 test、beforeAll/afterAll/beforeEach/afterEach、assert（含 Deno 别名）或 expect、mock.fn/mock.method，不写 run()，可最大程度在三端与 shu 间复用。

---

## 6. 版本与更新

- 本文档随 shu:test 实现更新；Deno/Bun 官方 API 若有变更，以官方文档为准。
- 当前实现见 **mod.zig** 顶部注释与 **getExports** 导出列表。
