// shu:vm — 沙箱执行 JS，对应 node:vm
// 纯 Zig 实现，与 Node vm API 兼容。无泄漏：createContext 后不用时请调用 disposeContext(sandbox)；
// runInNewContext / script.runInNewContext 内部会在执行后自动 dispose 临时 context。

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");

/// 用于“无异常”的哨兵（Zig 不允许指针为 0，用非零地址表示未设置）
var vm_no_exception_sentinel: u8 = 0;
const no_exception_ref: jsc.JSValueRef = @ptrCast(&vm_no_exception_sentinel);
/// 调用 C 回调时无 this/callee 时传入的占位（非空指针）
var vm_dummy_this_sentinel: u8 = 0;
const dummy_this_ref: jsc.JSObjectRef = @ptrCast(&vm_dummy_this_sentinel);

/// 已 contextify 的 sandbox 与其专属 VM 上下文的映射（同一 group，便于共享值）
var context_map: std.AutoHashMap(u64, jsc.JSGlobalContextRef) = undefined;
var map_init: bool = false;

/// 初始化 context_map（惰性，首次 createContext 时调用）；无 allocator 时不初始化，createContext 会失败
fn ensureMap() bool {
    if (!map_init) {
        const allocator = globals.current_allocator orelse return false;
        context_map = std.AutoHashMap(u64, jsc.JSGlobalContextRef).init(allocator);
        map_init = true;
    }
    return true;
}

/// 释放已 contextify 的 sandbox 对应的 VM 上下文，避免泄漏；与 Node 无对应 API，为 Shu 扩展
fn disposeContextCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1 or jsc.JSValueIsUndefined(ctx, arguments[0]) or jsc.JSValueIsNull(ctx, arguments[0])) {
        return jsc.JSValueMakeUndefined(ctx);
    }
    const sandbox = jsc.JSValueToObject(ctx, arguments[0], exception) orelse return jsc.JSValueMakeUndefined(ctx);
    if (!map_init) return jsc.JSValueMakeUndefined(ctx);
    const key = @intFromPtr(sandbox);
    if (context_map.fetchRemove(key)) |kv| {
        jsc.JSGlobalContextRelease(kv.value);
        if (context_map.count() == 0) {
            context_map.deinit();
            map_init = false;
        }
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// 将 source 对象上所有可枚举自有属性复制到 target 对象；在两个上下文内执行，值可跨上下文共享（同 group）
fn copyObjectToObject(
    source_ctx: jsc.JSContextRef,
    source_obj: jsc.JSObjectRef,
    target_ctx: jsc.JSContextRef,
    target_obj: jsc.JSObjectRef,
) void {
    const names = jsc.JSObjectCopyPropertyNames(source_ctx, source_obj);
    defer jsc.JSPropertyNameArrayRelease(names);
    const count = jsc.JSPropertyNameArrayGetCount(names);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const name_ref = jsc.JSPropertyNameArrayGetNameAtIndex(names, i);
        const value = jsc.JSObjectGetProperty(source_ctx, source_obj, name_ref, null);
        _ = jsc.JSObjectSetProperty(target_ctx, target_obj, name_ref, value, jsc.kJSPropertyAttributeNone, null);
        jsc.JSStringRelease(name_ref);
    }
}

/// vm.createContext([contextObject[, options]])
/// 将 contextObject 转为可执行沙箱；不传则创建新空对象并 contextify，返回该对象
fn createContextCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (!ensureMap()) return jsc.JSValueMakeUndefined(ctx);

    var sandbox: jsc.JSObjectRef = undefined;
    if (argumentCount == 0 or jsc.JSValueIsUndefined(ctx, arguments[0]) or jsc.JSValueIsNull(ctx, arguments[0])) {
        sandbox = jsc.JSObjectMake(ctx, null, null);
    } else {
        const obj = jsc.JSValueToObject(ctx, arguments[0], exception) orelse return jsc.JSValueMakeUndefined(ctx);
        sandbox = obj;
    }

    const key = @intFromPtr(sandbox);
    if (context_map.fetchRemove(key)) |kv| {
        jsc.JSGlobalContextRelease(kv.value);
    }

    const group = jsc.JSContextGetGroup(ctx);
    const vm_ctx = jsc.JSGlobalContextCreateInGroup(group, null);
    _ = jsc.JSGlobalContextRetain(vm_ctx);
    const vm_global = jsc.JSContextGetGlobalObject(vm_ctx);
    copyObjectToObject(ctx, sandbox, vm_ctx, vm_global);
    context_map.put(key, vm_ctx) catch {
        jsc.JSGlobalContextRelease(vm_ctx);
        return jsc.JSValueMakeUndefined(ctx);
    };
    return sandbox;
}

/// vm.runInContext(code, contextifiedObject[, options])
/// 在已 contextify 的对象对应的上下文中执行 code，返回执行结果；执行前后同步 sandbox 与 global
fn runInContextCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    if (!ensureMap()) return jsc.JSValueMakeUndefined(ctx);

    const code_val = arguments[0];
    const contextified_val = arguments[1];
    if (jsc.JSValueIsUndefined(ctx, code_val) or jsc.JSValueIsNull(ctx, contextified_val)) return jsc.JSValueMakeUndefined(ctx);
    const contextified = jsc.JSValueToObject(ctx, contextified_val, exception) orelse return jsc.JSValueMakeUndefined(ctx);

    const key = @intFromPtr(contextified);
    const vm_ctx = context_map.get(key) orelse {
        const global = jsc.JSContextGetGlobalObject(ctx);
        const err_name = jsc.JSStringCreateWithUTF8CString("Error");
        defer jsc.JSStringRelease(err_name);
        const err_ctor = jsc.JSObjectGetProperty(ctx, global, err_name, null);
        const err_obj = jsc.JSValueToObject(ctx, err_ctor, null) orelse return jsc.JSValueMakeUndefined(ctx);
        const msg = jsc.JSStringCreateWithUTF8CString("context is not contextified");
        defer jsc.JSStringRelease(msg);
        var args = [_]jsc.JSValueRef{jsc.JSValueMakeString(ctx, msg)};
        exception[0] = jsc.JSObjectCallAsConstructor(ctx, err_obj, 1, &args, null);
        return jsc.JSValueMakeUndefined(ctx);
    };
    const vm_global = jsc.JSContextGetGlobalObject(vm_ctx);

    const code_str = jsc.JSValueToStringCopy(ctx, code_val, exception);
    defer jsc.JSStringRelease(code_str);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(code_str);
    if (max_sz == 0 or max_sz > 1024 * 1024) return jsc.JSValueMakeUndefined(ctx);
    const code_buf = allocator.alloc(u8, max_sz) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(code_buf);
    _ = jsc.JSStringGetUTF8CString(code_str, code_buf.ptr, max_sz);
    const code_z = allocator.dupeZ(u8, code_buf[0 .. max_sz - 1]) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(code_z);

    var source_url: ?jsc.JSStringRef = null;
    if (argumentCount >= 3) {
        const options = jsc.JSValueToObject(ctx, arguments[2], null);
        if (options) |opt_obj| {
            const filename_key = jsc.JSStringCreateWithUTF8CString("filename");
            defer jsc.JSStringRelease(filename_key);
            const filename_val = jsc.JSObjectGetProperty(ctx, opt_obj, filename_key, null);
            if (!jsc.JSValueIsUndefined(ctx, filename_val)) {
                const fstr = jsc.JSValueToStringCopy(ctx, filename_val, null);
                defer jsc.JSStringRelease(fstr);
                const fmax = jsc.JSStringGetMaximumUTF8CStringSize(fstr);
                if (fmax > 0 and fmax < 2048) {
                    const fb = allocator.alloc(u8, fmax) catch return jsc.JSValueMakeUndefined(ctx);
                    defer allocator.free(fb);
                    _ = jsc.JSStringGetUTF8CString(fstr, fb.ptr, fmax);
                    const fz = allocator.dupeZ(u8, fb[0 .. fmax - 1]) catch return jsc.JSValueMakeUndefined(ctx);
                    defer allocator.free(fz);
                    source_url = jsc.JSStringCreateWithUTF8CString(fz.ptr);
                }
            }
        }
    }
    defer if (source_url != null) jsc.JSStringRelease(source_url.?);

    copyObjectToObject(ctx, contextified, vm_ctx, vm_global);
    const script_ref = jsc.JSStringCreateWithUTF8CString(code_z.ptr);
    defer jsc.JSStringRelease(script_ref);
    var exception_slot: [1]jsc.JSValueRef = .{no_exception_ref};
    const result = jsc.JSEvaluateScript(vm_ctx, script_ref, null, source_url, 1, exception_slot[0..].ptr);
    copyObjectToObject(vm_ctx, vm_global, ctx, contextified);
    if (exception_slot[0] != no_exception_ref) {
        exception[0] = exception_slot[0];
        return jsc.JSValueMakeUndefined(ctx);
    }
    return result;
}

/// vm.runInNewContext(code[, contextObject[, options]])
/// 等价于 createContext(contextObject) + runInContext(code, contextObject)；不传 contextObject 则用 {}
fn runInNewContextCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    var context_obj: jsc.JSValueRef = undefined;
    if (argumentCount >= 2 and !jsc.JSValueIsUndefined(ctx, arguments[1]) and !jsc.JSValueIsNull(ctx, arguments[1])) {
        context_obj = arguments[1];
    } else {
        context_obj = jsc.JSObjectMake(ctx, null, null);
    }
    var create_args = [_]jsc.JSValueRef{context_obj};
    const sandbox = createContextCallback(ctx, dummy_this_ref, dummy_this_ref, 1, &create_args, exception);
    if (jsc.JSValueIsUndefined(ctx, sandbox)) return jsc.JSValueMakeUndefined(ctx);
    var run_args = [_]jsc.JSValueRef{ arguments[0], sandbox };
    const result = runInContextCallback(ctx, dummy_this_ref, dummy_this_ref, 2, &run_args, exception);
    _ = disposeContextCallback(ctx, dummy_this_ref, dummy_this_ref, 1, &[_]jsc.JSValueRef{sandbox}, exception);
    return result;
}

/// vm.runInThisContext(code[, options])
/// 在当前全局上下文中执行 code，与 eval 类似但无局部作用域
fn runInThisContextCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const code_val = arguments[0];
    const code_str = jsc.JSValueToStringCopy(ctx, code_val, exception);
    defer jsc.JSStringRelease(code_str);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(code_str);
    if (max_sz == 0 or max_sz > 1024 * 1024) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const code_buf = allocator.alloc(u8, max_sz) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(code_buf);
    _ = jsc.JSStringGetUTF8CString(code_str, code_buf.ptr, max_sz);
    const code_z = allocator.dupeZ(u8, code_buf[0 .. max_sz - 1]) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(code_z);
    var source_url: ?jsc.JSStringRef = null;
    if (argumentCount >= 2) {
        const options = jsc.JSValueToObject(ctx, arguments[1], null);
        if (options) |opt_obj| {
            const filename_key = jsc.JSStringCreateWithUTF8CString("filename");
            defer jsc.JSStringRelease(filename_key);
            const filename_val = jsc.JSObjectGetProperty(ctx, opt_obj, filename_key, null);
            if (!jsc.JSValueIsUndefined(ctx, filename_val)) {
                const fstr = jsc.JSValueToStringCopy(ctx, filename_val, null);
                defer jsc.JSStringRelease(fstr);
                const fmax = jsc.JSStringGetMaximumUTF8CStringSize(fstr);
                if (fmax > 0 and fmax < 2048) {
                    const fb = allocator.alloc(u8, fmax) catch return jsc.JSValueMakeUndefined(ctx);
                    defer allocator.free(fb);
                    _ = jsc.JSStringGetUTF8CString(fstr, fb.ptr, fmax);
                    const fz = allocator.dupeZ(u8, fb[0 .. fmax - 1]) catch return jsc.JSValueMakeUndefined(ctx);
                    defer allocator.free(fz);
                    source_url = jsc.JSStringCreateWithUTF8CString(fz.ptr);
                }
            }
        }
    }
    defer if (source_url != null) jsc.JSStringRelease(source_url.?);
    var exception_slot: [1]jsc.JSValueRef = .{no_exception_ref};
    const script_ref = jsc.JSStringCreateWithUTF8CString(code_z.ptr);
    defer jsc.JSStringRelease(script_ref);
    const result = jsc.JSEvaluateScript(ctx, script_ref, null, source_url, 1, exception_slot[0..].ptr);
    if (exception_slot[0] != no_exception_ref) {
        exception[0] = exception_slot[0];
        return jsc.JSValueMakeUndefined(ctx);
    }
    return result;
}

/// vm.isContext(object)
/// 判断 object 是否已被 createContext 过
fn isContextCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1 or jsc.JSValueIsUndefined(ctx, arguments[0]) or jsc.JSValueIsNull(ctx, arguments[0])) {
        return jsc.JSValueMakeBoolean(ctx, false);
    }
    const obj = jsc.JSValueToObject(ctx, arguments[0], null) orelse return jsc.JSValueMakeBoolean(ctx, false);
    if (!map_init) return jsc.JSValueMakeBoolean(ctx, false);
    const key = @intFromPtr(obj);
    return jsc.JSValueMakeBoolean(ctx, context_map.contains(key));
}

/// vm.Script(code[, options]) 构造函数：创建预编译脚本对象，带 __code 与 runInContext/runInNewContext/runInThisContext 方法
fn scriptConstructorCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) {
        const msg = jsc.JSStringCreateWithUTF8CString("Script requires at least 1 argument");
        defer jsc.JSStringRelease(msg);
        const global = jsc.JSContextGetGlobalObject(ctx);
        const err_name = jsc.JSStringCreateWithUTF8CString("TypeError");
        defer jsc.JSStringRelease(err_name);
        const err_ctor = jsc.JSObjectGetProperty(ctx, global, err_name, null);
        const err_obj = jsc.JSValueToObject(ctx, err_ctor, null) orelse return jsc.JSValueMakeUndefined(ctx);
        var args = [_]jsc.JSValueRef{jsc.JSValueMakeString(ctx, msg)};
        exception[0] = jsc.JSObjectCallAsConstructor(ctx, err_obj, 1, &args, null);
        return jsc.JSValueMakeUndefined(ctx);
    }
    const k_code = jsc.JSStringCreateWithUTF8CString("__code");
    defer jsc.JSStringRelease(k_code);
    _ = jsc.JSObjectSetProperty(ctx, this, k_code, arguments[0], jsc.kJSPropertyAttributeNone, null);
    common.setMethod(ctx, this, "runInContext", scriptRunInContextCallback);
    common.setMethod(ctx, this, "runInNewContext", scriptRunInNewContextCallback);
    common.setMethod(ctx, this, "runInThisContext", scriptRunInThisContextCallback);
    common.setMethod(ctx, this, "createCachedData", scriptCreateCachedDataCallback);
    const code_str = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(code_str);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(code_str);
    if (max_sz > 0 and max_sz < 4096) if (globals.current_allocator) |alloc| {
        const buf = alloc.alloc(u8, max_sz) catch return this;
        defer alloc.free(buf);
        const n = jsc.JSStringGetUTF8CString(code_str, buf.ptr, max_sz);
        const code_slice = if (n > 0) buf[0 .. n - 1] else buf[0..0];
        const prefix = "//# sourceMappingURL=";
        if (std.mem.indexOf(u8, code_slice, prefix)) |idx| {
            const start = idx + prefix.len;
            var end = code_slice.len;
            if (std.mem.indexOfScalar(u8, code_slice[start..], '\n')) |rel| {
                end = start + rel;
            }
            var url = code_slice[start..end];
            if (url.len > 0 and url[url.len - 1] == '\r') url = url[0 .. url.len - 1];
            const url_z = alloc.dupeZ(u8, url) catch return this;
            defer alloc.free(url_z);
            const k_smu = jsc.JSStringCreateWithUTF8CString("sourceMapURL");
            defer jsc.JSStringRelease(k_smu);
            const url_ref = jsc.JSStringCreateWithUTF8CString(url_z.ptr);
            defer jsc.JSStringRelease(url_ref);
            _ = jsc.JSObjectSetProperty(ctx, this, k_smu, jsc.JSValueMakeString(ctx, url_ref), jsc.kJSPropertyAttributeNone, null);
        }
    };
    return this;
}

/// script.runInContext(contextifiedObject[, options])
fn scriptRunInContextCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const k_code = jsc.JSStringCreateWithUTF8CString("__code");
    defer jsc.JSStringRelease(k_code);
    const code_val = jsc.JSObjectGetProperty(ctx, this, k_code, null);
    if (jsc.JSValueIsUndefined(ctx, code_val)) return jsc.JSValueMakeUndefined(ctx);
    var run_args = [_]jsc.JSValueRef{ code_val, arguments[0] };
    return runInContextCallback(ctx, dummy_this_ref, dummy_this_ref, 2, &run_args, exception);
}

/// script.runInNewContext([contextObject[, options]])
fn scriptRunInNewContextCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const k_code = jsc.JSStringCreateWithUTF8CString("__code");
    defer jsc.JSStringRelease(k_code);
    const code_val = jsc.JSObjectGetProperty(ctx, this, k_code, null);
    if (jsc.JSValueIsUndefined(ctx, code_val)) return jsc.JSValueMakeUndefined(ctx);
    var context_obj: jsc.JSValueRef = undefined;
    if (argumentCount >= 1 and !jsc.JSValueIsUndefined(ctx, arguments[0]) and !jsc.JSValueIsNull(ctx, arguments[0])) {
        context_obj = arguments[0];
    } else {
        context_obj = jsc.JSObjectMake(ctx, null, null);
    }
    var create_args = [_]jsc.JSValueRef{context_obj};
    const sandbox = createContextCallback(ctx, dummy_this_ref, dummy_this_ref, 1, &create_args, exception);
    if (jsc.JSValueIsUndefined(ctx, sandbox)) return jsc.JSValueMakeUndefined(ctx);
    var run_args = [_]jsc.JSValueRef{ code_val, sandbox };
    const result = runInContextCallback(ctx, dummy_this_ref, dummy_this_ref, 2, &run_args, exception);
    _ = disposeContextCallback(ctx, dummy_this_ref, dummy_this_ref, 1, &[_]jsc.JSValueRef{sandbox}, exception);
    return result;
}

/// script.createCachedData() — Node 返回 V8 编译缓存 Buffer；JSC 无等价物，返回空 Uint8Array 以兼容 API
fn scriptCreateCachedDataCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    _ = argumentCount;
    _ = arguments;
    const empty = jsc.JSObjectMakeTypedArray(ctx, jsc.JSTypedArrayType.Uint8Array, 0);
    return if (empty) |obj| obj else jsc.JSValueMakeUndefined(ctx);
}

/// script.runInThisContext([options])
fn scriptRunInThisContextCallback(
    ctx: jsc.JSContextRef,
    this: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const k_code = jsc.JSStringCreateWithUTF8CString("__code");
    defer jsc.JSStringRelease(k_code);
    const code_val = jsc.JSObjectGetProperty(ctx, this, k_code, null);
    if (jsc.JSValueIsUndefined(ctx, code_val)) return jsc.JSValueMakeUndefined(ctx);
    var run_args: [2]jsc.JSValueRef = undefined;
    run_args[0] = code_val;
    if (argumentCount >= 1) {
        run_args[1] = arguments[0];
    } else {
        run_args[1] = jsc.JSValueMakeUndefined(ctx);
    }
    return runInThisContextCallback(ctx, dummy_this_ref, dummy_this_ref, 2, &run_args, exception);
}

/// vm.measureMemory([options]) — Node 返回 Promise<内存报告>；JSC 无 V8 内存 API，返回 Promise.resolve(占位对象) 以兼容
fn measureMemoryCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    _ = argumentCount;
    _ = arguments;
    const global = jsc.JSContextGetGlobalObject(ctx);
    const promise_name = jsc.JSStringCreateWithUTF8CString("Promise");
    defer jsc.JSStringRelease(promise_name);
    const promise_ctor = jsc.JSObjectGetProperty(ctx, global, promise_name, null);
    const promise_obj = jsc.JSValueToObject(ctx, promise_ctor, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const result_obj = jsc.JSObjectMake(ctx, null, null);
    const total_name = jsc.JSStringCreateWithUTF8CString("total");
    defer jsc.JSStringRelease(total_name);
    const total_obj = jsc.JSObjectMake(ctx, null, null);
    const jse_name = jsc.JSStringCreateWithUTF8CString("jsMemoryEstimate");
    defer jsc.JSStringRelease(jse_name);
    const jsr_name = jsc.JSStringCreateWithUTF8CString("jsMemoryRange");
    defer jsc.JSStringRelease(jsr_name);
    _ = jsc.JSObjectSetProperty(ctx, total_obj, jse_name, jsc.JSValueMakeNumber(ctx, 0), jsc.kJSPropertyAttributeNone, null);
    const range_arr = jsc.JSObjectMakeArray(ctx, 2, &[_]jsc.JSValueRef{ jsc.JSValueMakeNumber(ctx, 0), jsc.JSValueMakeNumber(ctx, 0) }, null);
    _ = jsc.JSObjectSetProperty(ctx, total_obj, jsr_name, range_arr, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, result_obj, total_name, total_obj, jsc.kJSPropertyAttributeNone, null);
    var resolve_args = [_]jsc.JSValueRef{result_obj};
    const resolve_name = jsc.JSStringCreateWithUTF8CString("resolve");
    defer jsc.JSStringRelease(resolve_name);
    const resolve_val = jsc.JSObjectGetProperty(ctx, promise_obj, resolve_name, null);
    const resolve_fn = jsc.JSValueToObject(ctx, resolve_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const promise_instance = jsc.JSObjectCallAsFunction(ctx, resolve_fn, promise_obj, 1, &resolve_args, null);
    return promise_instance;
}

/// 返回 shu:vm 的 exports：createContext、runInContext、runInNewContext、runInThisContext、isContext、disposeContext、measureMemory、Script、constants
pub fn getExports(ctx: jsc.JSContextRef, _: std.mem.Allocator) jsc.JSValueRef {
    const obj = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, obj, "createContext", createContextCallback);
    common.setMethod(ctx, obj, "runInContext", runInContextCallback);
    common.setMethod(ctx, obj, "runInNewContext", runInNewContextCallback);
    common.setMethod(ctx, obj, "runInThisContext", runInThisContextCallback);
    common.setMethod(ctx, obj, "isContext", isContextCallback);
    common.setMethod(ctx, obj, "disposeContext", disposeContextCallback);
    common.setMethod(ctx, obj, "measureMemory", measureMemoryCallback);

    const Script = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, Script, "runInContext", scriptRunInContextCallback);
    common.setMethod(ctx, Script, "runInNewContext", scriptRunInNewContextCallback);
    common.setMethod(ctx, Script, "runInThisContext", scriptRunInThisContextCallback);
    const script_name = jsc.JSStringCreateWithUTF8CString("Script");
    defer jsc.JSStringRelease(script_name);
    const script_ctor = jsc.JSObjectMakeFunctionWithCallback(ctx, script_name, scriptConstructorCallback);
    const k_script = jsc.JSStringCreateWithUTF8CString("Script");
    defer jsc.JSStringRelease(k_script);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_script, script_ctor, jsc.kJSPropertyAttributeNone, null);

    const constants = jsc.JSObjectMake(ctx, null, null);
    const k_dont = jsc.JSStringCreateWithUTF8CString("DONT_CONTEXTIFY");
    defer jsc.JSStringRelease(k_dont);
    _ = jsc.JSObjectSetProperty(ctx, constants, k_dont, jsc.JSValueMakeNumber(ctx, 1), jsc.kJSPropertyAttributeNone, null);
    const k_use_main = jsc.JSStringCreateWithUTF8CString("USE_MAIN_CONTEXT_DEFAULT_LOADER");
    defer jsc.JSStringRelease(k_use_main);
    _ = jsc.JSObjectSetProperty(ctx, constants, k_use_main, jsc.JSValueMakeNumber(ctx, 2), jsc.kJSPropertyAttributeNone, null);
    const k_constants = jsc.JSStringCreateWithUTF8CString("constants");
    defer jsc.JSStringRelease(k_constants);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_constants, constants, jsc.kJSPropertyAttributeNone, null);

    return obj;
}
