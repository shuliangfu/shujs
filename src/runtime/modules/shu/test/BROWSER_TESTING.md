# 浏览器测试分析（shu:test）

本文档分析在 shu:test 体系下「浏览器测试」的含义、可行方案与推荐写法。

---

## 一、当前 shu:test 的运行环境

- **运行时**：Zig 进程内嵌 **JavaScriptCore (JSC)**，无 DOM、无 `window`/`document`、无真实浏览器环境。
- **测试执行**：`describe` / `it` / `beforeAll` / `afterAll` / `run()` 等均在**同一 JSC 上下文**中执行，由 Zig 侧维护 suite 树与任务队列，纯 Zig 驱动 Promise 链与 `t.done()`。
- **适用场景**：单元测试、API 逻辑、异步流程、与 Node 风格一致的测试写法；**不适用**直接依赖 DOM、BOM 或浏览器专有 API 的用例。

因此，若测试代码需要 **DOM、真实浏览器或浏览器专有 API**，就需要「浏览器测试」方案。

---

## 二、「浏览器测试」的几种含义

| 含义 | 说明 | 典型需求 |
|------|------|----------|
| **在真实浏览器里跑同一套 describe/it** | 测试代码在浏览器上下文中执行，仍用 describe/it/run 等 API | 组件测试、依赖 document/window 的模块 |
| **E2E（端到端）** | 用自动化工具（如 Playwright）启动浏览器、加载页面、操作 DOM、断言 | 整页流程、多页交互、视觉/可访问性 |
| **无头 DOM 环境** | 在 JSC/Node 里用 jsdom/linkedom 等提供 DOM，再跑测试 | 不启动真实浏览器，但需要 DOM API |

下文主要讨论：**在真实浏览器里怎么写测试、以及如何与 shu:test 的 API 风格对齐**；E2E 作为补充方案简要说明。

---

## 三、方案概览

### 方案 A：浏览器内运行「与 shu:test 同风格的用例」

**思路**：把「测试列表 + 运行逻辑」打包成可在浏览器里执行的脚本，在浏览器中提供一套与 shu:test 兼容的 `describe` / `it` / `beforeAll` / `afterAll` / `run()` 等 API（可用简化版或同一套接口），由页面内的 runner 驱动执行并上报结果。

**写法要点**：

1. **单独入口**：例如 `tests/browser/main.mjs`，只包含要在浏览器里跑的用例（或通过配置/约定只收集带 `@browser` 或 `browser: true` 的 suite）。
2. **环境区分**：用例里用 `globalThis.window !== undefined` 或 `typeof document !== 'undefined'` 判断是否在浏览器；或通过构建时替换/条件导出，只把浏览器用例打进 bundle。
3. **Runner 注入**：页面加载一个「浏览器用 test runner」脚本（实现 describe/it/run 等），再加载上述入口；runner 在 `window.onload` 或 `DOMContentLoaded` 后执行 `run()`，将结果通过 `console` / `postMessage` / 自定义事件 回传给 CLI 或 CI。

**示例（概念）**：

```javascript
// tests/browser/dom-utils.test.mjs
// 约定：此目录下或带 browser 标记的只会在浏览器 runner 中执行

import { describe, it, beforeAll, afterAll, run } from './browser-runner.mjs'; // 浏览器用 runner

describe('DOM utils in browser', () => {
  beforeAll(() => {
    document.body.innerHTML = '<div id="root"></div>';
  });

  it('should find element by id', () => {
    const el = document.getElementById('root');
    if (!el) throw new Error('expected #root');
  });

  it('can use fetch in browser', async () => {
    const r = await fetch('/api/health');
    if (r.status !== 200) throw new Error('expected 200');
  });
});

run();
```

**优点**：与 shu:test 的 describe/it/run 写法一致，易迁移、易复用用例结构。  
**缺点**：需要维护一套「浏览器用 runner」和打包/注入流程。

---

### 方案 B：用 E2E 工具（如 Playwright）跑「整页」测试

**思路**：不要求在浏览器里实现 describe/it，而是用 Playwright（或 Puppeteer）启动浏览器，打开一个「测试页」；测试页加载你的应用脚本和测试用例，执行完后把结果写到页面（例如 `window.__testResults`），Playwright 再读取并断言。

**写法要点**：

1. **测试页**：例如 `tests/browser/runner.html`，引入打包后的应用 + 测试脚本；测试脚本内部可以仍用 describe/it 风格，但**不依赖 shu:test 的 Zig 实现**，只需在结束时把结果放到 `window.__testResults`（或通过 `postMessage` 发给父窗口）。
2. **Playwright 脚本**（在 Node/Shu 外、或通过子进程调用）：  
   `page.goto('/runner.html')` → 等待 `window.__testResults` 或特定事件 → `expect(results.passed).toBe(true)` 等。
3. **CLI 集成**：`shu test --browser` 可设计为：启动本地静态服务 + 启动 Playwright、打开 runner 页、收集结果并统一输出。

**示例（概念）**：

```javascript
// tests/e2e/app.spec.mjs (在 Node/Playwright 环境跑)
import { test, expect } from '@playwright/test';

test('app loads and runs browser tests', async ({ page }) => {
  await page.goto('/tests/browser/runner.html');
  await page.waitForFunction(() => window.__testResults != null, { timeout: 10000 });
  const results = await page.evaluate(() => window.__testResults);
  expect(results.failed).toBe(0);
});
```

**优点**：真实浏览器、真实网络与 DOM，适合 E2E。  
**缺点**：与 shu:test 的「同一进程、Zig 驱动」模型分离，需两套入口（单元 vs E2E）。

---

### 方案 C：在 JSC 内用 DOM  polyfill（如 linkedom）

**思路**：在现有 shu 进程中用 linkedom（或 jsdom）在 JSC 里构造 `document` / `window`，再在**同一 shu:test 流程**里跑依赖 DOM 的用例。

**写法要点**：

1. 在测试入口或 `beforeAll` 里执行 polyfill：  
   `const { document, window } = require('linkedom').parseHTML('');`，并挂到 `globalThis`。
2. 测试代码与普通 shu:test 写法一致，只是多了一个「有 DOM」的全局环境。

**优点**：无需启动浏览器、无需额外 runner，与现有 describe/it/run 完全一致。  
**缺点**：polyfill 与真实浏览器行为有差异；linkedom/jsdom 在 JSC 上的兼容性与性能需验证；不适合强依赖布局、渲染、真实 Cookie/Storage 的用例。

---

## 四、推荐分工与「浏览器测试」怎么写

| 需求 | 推荐方案 | 写法位置 |
|------|----------|----------|
| 纯逻辑、异步、无 DOM | 现有 shu:test（JSC） | 任意 `*.test.mjs`，用 `shu run` 跑 |
| 需要 DOM API、但可接受 polyfill | 方案 C（JSC + linkedom） | 同一 test 文件，在 suite 或 beforeAll 里注入 DOM |
| 必须在真实浏览器中跑、且希望 describe/it 风格 | 方案 A（浏览器内 runner） | 单独目录如 `tests/browser/`，由浏览器 runner 加载并执行 |
| 整页流程、多页、E2E | 方案 B（Playwright） | 独立 E2E 脚本（如 `tests/e2e/*.spec.mjs`），用 Playwright 打开测试页并断言 |

**「浏览器测试」推荐写法（方案 A）**：

1. **目录约定**：例如 `tests/browser/` 下放仅浏览器运行的用例，或通过标记（注释/配置）标明 `browser-only`。若使用 describe/it 的 options 标记，则统一为**第三参**：`describe('name', fn, { browser: true })`、`it('name', fn, { browser: true })`（第 1 参 name，第 2 参 fn，第 3 参 options）。
2. **提供浏览器 runner**：实现最小集合 `describe` / `it` / `beforeAll` / `afterAll` / `run()`，在页面加载后执行并收集结果；可选与 shu:test 的 API 对齐，便于复制粘贴用例。
3. **单文件示例**：
   - `tests/browser/runner.mjs`：导出 describe/it/run 等（浏览器用实现）。
   - `tests/browser/xxx.test.mjs`：仅 import 上述 runner，写 describe/it，最后 `run()`。
4. **结果上报**：`run()` 完成后将结果写入 `window.__shuBrowserTestResults` 或通过 `postMessage` 发给父窗口，便于 Playwright 或 CLI 收集。

**E2E（方案 B）**：不强制使用 describe/it；用 Playwright 的 `test()` 写「打开页面、操作、断言」即可；若希望与 shu 的 CLI 统一，可增加 `shu test --e2e` 子命令，内部调用 Playwright。

---

## 五、与 shu:test 的集成方向（后续可实现）

- **标签或配置**：在 describe/it 上支持第三个参数 options，统一约定为「第 1 个 name、第 2 个 fn、第 3 个 options」。例如 `test('name', fn, { browser: true })`、`describe('name', fn, { browser: true })`，以便工具区分「仅浏览器」用例。
- **CLI**：`shu test --browser`：启动静态服务 + 浏览器 runner 页，用无头浏览器执行并汇总结果；或 `shu test --e2e` 调用 Playwright。
- **统一报告**：浏览器/E2E 跑完后的结果格式与 shu:test 的终端输出对齐（通过数、失败数、错误信息），便于 CI 统一解析。

---

## 六、小结

- **当前**：shu:test 运行在 JSC 中，无 DOM；「浏览器测试」需要额外环境或 polyfill。
- **写法**：  
  - 真实浏览器内跑 describe/it 风格：用**方案 A**（浏览器 runner + 单独入口/目录）。  
  - 整页 E2E：用**方案 B**（Playwright + 测试页 + 结果上报）。  
  - 仅要 DOM API 且可接受差异：用**方案 C**（JSC + linkedom）。
- **文档与目录**：在 `shu/test` 下保留本分析文档，浏览器相关示例与 runner 可放在仓库的 `tests/browser/`（或与现有测试目录约定一致），便于后续实现 `--browser` / `--e2e` 时直接引用。
