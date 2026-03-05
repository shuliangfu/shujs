//! macOS：运行多轮 CFRunLoop 迭代，使 JSC 有机会执行 Promise then/catch 等微任务。
//! 从原生代码调用 resolve/reject 时，JSC 将 then/catch 放入内部队列，需 RunLoop 驱动才会执行。
//! 单次迭代可能不足以清空队列，故循环若干次（或直到 kCFRunLoopRunFinished）。

const c = @cImport({
    @cInclude("CoreFoundation/CoreFoundation.h");
});

const max_iterations = 64;

/// 运行多轮 CFRunLoop 迭代（0 秒超时），处理已就绪的源；固定跑多轮以给 JSC Promise 反应足够机会执行。
pub fn runOneIteration() void {
    var i: u32 = 0;
    while (i < max_iterations) : (i += 1) {
        _ = c.CFRunLoopRunInMode(c.kCFRunLoopDefaultMode, 0, 0);
    }
}
