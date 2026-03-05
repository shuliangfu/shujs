// 异步上下文：为 async_hooks 与事件循环（timers 等）提供 executionAsyncId、triggerAsyncId、栈与钩子调用
// 供 modules/shu/timers、async/hooks.zig、async/async_context.zig 共用

const std = @import("std");
const jsc = @import("jsc");

const AsyncFrame = struct {
    async_id: u64,
    trigger_async_id: u64,
    resource: jsc.JSValueRef,
};

/// AsyncLocalStorage 存储表键；(storage_id, async_id) -> store，供 async_context.zig 使用
const StorageKey = struct {
    storage_id: u32,
    async_id: u64,
};
const StorageEntry = struct { ref: jsc.JSValueRef, ctx: jsc.JSContextRef };

var g_alloc: std.mem.Allocator = std.heap.page_allocator;
/// Unmanaged，append/orderedRemove/deinit 显式传 g_alloc（01 §1.2）
var g_stack: std.ArrayListUnmanaged(AsyncFrame) = .{};
var g_hooks: std.ArrayListUnmanaged(jsc.JSObjectRef) = .{};
var g_next_id: std.atomic.Value(u64) = .{ .raw = 1 };
var g_inited: bool = false;
/// Unmanaged，put/fetchRemove 显式传 g_alloc
var g_storage_map: std.AutoHashMapUnmanaged(StorageKey, StorageEntry) = .{};
var g_storage_id_next: std.atomic.Value(u32) = .{ .raw = 1 };

/// 由 async hooks getExports 在首次加载时调用，初始化栈、钩子列表与 AsyncLocalStorage 存储表
pub fn init(allocator: std.mem.Allocator) void {
    if (g_inited) return;
    g_alloc = allocator;
    g_inited = true;
}

/// 分配新 async id，trigger 为当前 executionAsyncId
pub fn allocId() struct { async_id: u64, trigger_async_id: u64 } {
    if (!g_inited) return .{ .async_id = 0, .trigger_async_id = 0 };
    const trigger = currentExecutionId();
    const id = g_next_id.fetchAdd(1, .monotonic);
    return .{ .async_id = id, .trigger_async_id = trigger };
}

/// 当前执行上下文 async id；栈空时返回 1（bootstrap）
pub fn currentExecutionId() u64 {
    if (!g_inited or g_stack.items.len == 0) return 1;
    return g_stack.items[g_stack.items.len - 1].async_id;
}

/// 当前 trigger async id；栈空时返回 0
pub fn currentTriggerId() u64 {
    if (!g_inited or g_stack.items.len == 0) return 0;
    return g_stack.items[g_stack.items.len - 1].trigger_async_id;
}

/// 当前资源对象；栈空时返回 undefined（由调用方转为空对象或 undefined）
pub fn currentResource(ctx: jsc.JSContextRef) jsc.JSValueRef {
    if (!g_inited or g_stack.items.len == 0) return jsc.JSValueMakeUndefined(ctx);
    const r = g_stack.items[g_stack.items.len - 1].resource;
    if (jsc.JSValueIsUndefined(ctx, r) or jsc.JSValueIsNull(ctx, r)) return jsc.JSValueMakeUndefined(ctx);
    return r;
}

fn callHookMethod(ctx: jsc.JSContextRef, hook_obj: jsc.JSObjectRef, method_name: []const u8, args: []const jsc.JSValueRef) void {
    const k = jsc.JSStringCreateWithUTF8CString(method_name.ptr);
    defer jsc.JSStringRelease(k);
    const fn_val = jsc.JSObjectGetProperty(ctx, hook_obj, k, null);
    if (jsc.JSValueIsUndefined(ctx, fn_val) or jsc.JSValueIsNull(ctx, fn_val)) return;
    const fn_obj = jsc.JSValueToObject(ctx, fn_val, null) orelse return;
    if (!jsc.JSObjectIsFunction(ctx, fn_obj)) return;
    _ = jsc.JSObjectCallAsFunction(ctx, fn_obj, null, @intCast(args.len), args.ptr, null);
}

/// 入栈并在所有已启用钩子上调用 before(asyncId)
pub fn pushContext(ctx: jsc.JSContextRef, async_id: u64, trigger_async_id: u64, resource: jsc.JSValueRef) void {
    if (!g_inited) return;
    g_stack.append(g_alloc, .{
        .async_id = async_id,
        .trigger_async_id = trigger_async_id,
        .resource = resource,
    }) catch return;
    var one: [1]jsc.JSValueRef = .{jsc.JSValueMakeNumber(ctx, @floatFromInt(async_id))};
    for (g_hooks.items) |h| callHookMethod(ctx, h, "before", &one);
}

/// 在所有已启用钩子上调用 after(asyncId) 后出栈
pub fn popContext(ctx: jsc.JSContextRef) void {
    if (!g_inited or g_stack.items.len == 0) return;
    const async_id = g_stack.items[g_stack.items.len - 1].async_id;
    var one: [1]jsc.JSValueRef = .{jsc.JSValueMakeNumber(ctx, @floatFromInt(async_id))};
    for (g_hooks.items) |h| callHookMethod(ctx, h, "after", &one);
    _ = g_stack.pop();
}

/// 资源创建时调用，对所有已启用钩子调用 init(asyncId, type, triggerAsyncId, resource)
pub fn emitInit(ctx: jsc.JSContextRef, async_id: u64, type_name: [*]const u8, trigger_async_id: u64, resource: jsc.JSValueRef) void {
    if (!g_inited) return;
    const type_str = jsc.JSStringCreateWithUTF8CString(type_name);
    defer jsc.JSStringRelease(type_str);
    var four: [4]jsc.JSValueRef = .{
        jsc.JSValueMakeNumber(ctx, @floatFromInt(async_id)),
        jsc.JSValueMakeString(ctx, type_str),
        jsc.JSValueMakeNumber(ctx, @floatFromInt(trigger_async_id)),
        resource,
    };
    for (g_hooks.items) |h| callHookMethod(ctx, h, "init", &four);
}

/// 资源销毁时调用，对所有已启用钩子调用 destroy(asyncId)
pub fn emitDestroy(ctx: jsc.JSContextRef, async_id: u64) void {
    if (!g_inited) return;
    var one: [1]jsc.JSValueRef = .{jsc.JSValueMakeNumber(ctx, @floatFromInt(async_id))};
    for (g_hooks.items) |h| callHookMethod(ctx, h, "destroy", &one);
}

/// createHook().enable() 时注册钩子对象
pub fn registerHook(ctx: jsc.JSContextRef, hook_obj: jsc.JSObjectRef) void {
    _ = ctx;
    if (!g_inited) return;
    for (g_hooks.items) |h| if (h == hook_obj) return;
    g_hooks.append(g_alloc, hook_obj) catch {};
}

/// createHook().disable() 时移除钩子对象
pub fn unregisterHook(ctx: jsc.JSContextRef, hook_obj: jsc.JSObjectRef) void {
    _ = ctx;
    if (!g_inited) return;
    var i: usize = 0;
    while (i < g_hooks.items.len) : (i += 1) {
        if (g_hooks.items[i] == hook_obj) {
            _ = g_hooks.orderedRemove(i);
            return;
        }
    }
}

/// 检查钩子对象是否已启用（_enabled 属性）
pub fn isHookEnabled(ctx: jsc.JSContextRef, hook_obj: jsc.JSObjectRef) bool {
    const k = jsc.JSStringCreateWithUTF8CString("_enabled");
    defer jsc.JSStringRelease(k);
    const val = jsc.JSObjectGetProperty(ctx, hook_obj, k, null);
    return jsc.JSValueToBoolean(ctx, val);
}

// ========== AsyncLocalStorage 存储（供 async/async_context.zig 使用） ==========

pub fn allocStorageId() u32 {
    return g_storage_id_next.fetchAdd(1, .monotonic);
}

pub fn getStorageStore(ctx: jsc.JSContextRef, storage_id: u32) jsc.JSValueRef {
    if (!g_inited) return jsc.JSValueMakeUndefined(ctx);
    const async_id = currentExecutionId();
    const key = StorageKey{ .storage_id = storage_id, .async_id = async_id };
    const entry = g_storage_map.get(key) orelse return jsc.JSValueMakeUndefined(ctx);
    return entry.ref;
}

pub fn setStorageStore(ctx: jsc.JSContextRef, storage_id: u32, async_id: u64, store: jsc.JSValueRef) void {
    if (!g_inited) return;
    const key = StorageKey{ .storage_id = storage_id, .async_id = async_id };
    if (g_storage_map.fetchRemove(key)) |kv| jsc.JSValueUnprotect(kv.value.ctx, kv.value.ref);
    jsc.JSValueProtect(ctx, store);
    g_storage_map.put(g_alloc, key, .{ .ref = store, .ctx = ctx }) catch {};
}

pub fn deleteStorageStore(_: jsc.JSContextRef, storage_id: u32, async_id: u64) void {
    if (!g_inited) return;
    const key = StorageKey{ .storage_id = storage_id, .async_id = async_id };
    if (g_storage_map.fetchRemove(key)) |kv| jsc.JSValueUnprotect(kv.value.ctx, kv.value.ref);
}
