//! 非 macOS 平台：不驱动系统 RunLoop，runOneIteration 为空实现。

/// 不执行任何操作；非 Darwin 时 JSC 可能不依赖 CFRunLoop 处理 Promise 微任务。
pub fn runOneIteration() void {}
