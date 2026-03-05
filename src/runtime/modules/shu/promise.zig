//! 共用 Promise 工具：供 cmd、fetch、fs、util 等造 Promise(executor) 与 resolve/reject 时复用。
//! 不依赖具体业务，仅提供：取构造函数、resolve/reject、通用 createWithExecutor（JSC 调用 executor 时转调 Zig 回调）。
//! 栈与 globals 一致使用 threadlocal，多线程下每线程独立。

const jsc = @import("jsc");

/// 当 JSC 以 (resolve, reject) 调用 Promise executor 时，会转调此类型；模块在回调内存 resolve/reject 并入队（微任务、pending、fs 队列等）。
pub const ExecutorCallback = *const fn (jsc.JSContextRef, jsc.JSValueRef, jsc.JSValueRef, ?*anyopaque) void;

const STACK_MAX = 8;
threadlocal var executor_stack: [STACK_MAX]struct { cb: ExecutorCallback, ud: ?*anyopaque } = undefined;
threadlocal var executor_stack_len: usize = 0;

fn genericExecutor(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2 or executor_stack_len == 0) return jsc.JSValueMakeUndefined(ctx);
    const top = executor_stack_len - 1;
    const cb = executor_stack[top].cb;
    const ud = executor_stack[top].ud;
    executor_stack_len -= 1;
    cb(ctx, arguments[0], arguments[1], ud);
    return jsc.JSValueMakeUndefined(ctx);
}

/// 从 globalThis 取 Promise 构造函数；无时返回 null。
pub fn getPromiseConstructor(ctx: jsc.JSContextRef) ?jsc.JSObjectRef {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k = jsc.JSStringCreateWithUTF8CString("Promise");
    defer jsc.JSStringRelease(k);
    const val = jsc.JSObjectGetProperty(ctx, global, k, null);
    return jsc.JSValueToObject(ctx, val, null);
}

/// 返回 Promise.resolve(value)；与标准一致，供 fetch/fs 等复用。
pub fn resolve(ctx: jsc.JSContextRef, value: jsc.JSValueRef) jsc.JSValueRef {
    const Promise = getPromiseConstructor(ctx) orelse return jsc.JSValueMakeUndefined(ctx);
    const k_resolve = jsc.JSStringCreateWithUTF8CString("resolve");
    defer jsc.JSStringRelease(k_resolve);
    const resolve_fn = jsc.JSObjectGetProperty(ctx, Promise, k_resolve, null);
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(resolve_fn))) return jsc.JSValueMakeUndefined(ctx);
    var args: [1]jsc.JSValueRef = .{value};
    return jsc.JSObjectCallAsFunction(ctx, @ptrCast(resolve_fn), Promise, 1, &args, null);
}

/// 返回 Promise.reject(reason)；与标准一致，供 fetch/fs 等复用。
pub fn reject(ctx: jsc.JSContextRef, reason: jsc.JSValueRef) jsc.JSValueRef {
    const Promise = getPromiseConstructor(ctx) orelse return jsc.JSValueMakeUndefined(ctx);
    const k_reject = jsc.JSStringCreateWithUTF8CString("reject");
    defer jsc.JSStringRelease(k_reject);
    const reject_fn = jsc.JSObjectGetProperty(ctx, Promise, k_reject, null);
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(reject_fn))) return jsc.JSValueMakeUndefined(ctx);
    var args: [1]jsc.JSValueRef = .{reason};
    return jsc.JSObjectCallAsFunction(ctx, @ptrCast(reject_fn), Promise, 1, &args, null);
}

/// 创建 new Promise(executor)；JSC 调用 executor(resolve, reject) 时会转调 callback(ctx, resolve, reject, user_data)。
/// 支持重入（嵌套造 Promise）时用栈保存当前 callback/user_data，最多 STACK_MAX 层。
pub fn createWithExecutor(ctx: jsc.JSContextRef, callback: ExecutorCallback, user_data: ?*anyopaque) jsc.JSValueRef {
    const Promise = getPromiseConstructor(ctx) orelse return jsc.JSValueMakeUndefined(ctx);
    if (executor_stack_len >= STACK_MAX) return jsc.JSValueMakeUndefined(ctx);
    executor_stack[executor_stack_len] = .{ .cb = callback, .ud = user_data };
    executor_stack_len += 1;
    const name = jsc.JSStringCreateWithUTF8CString("executor");
    defer jsc.JSStringRelease(name);
    const executor_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, name, genericExecutor);
    var one: [1]jsc.JSValueRef = .{executor_fn};
    return jsc.JSObjectCallAsConstructor(ctx, Promise, 1, &one, null);
}
