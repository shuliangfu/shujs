// shu:assert 内置：Zig 实现 Node 风格断言（strictEqual、deepStrictEqual、ok、fail、throws）
// 供 require("shu:assert") / node:assert 共用，运行效率高于脚本实现

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");

/// 在 JS 侧抛错：将 msg_js 设为 globalThis.__assert_msg 后执行 throw new Error(globalThis.__assert_msg)
fn throwAssertErrorWithJS(ctx: jsc.JSContextRef, msg_js: jsc.JSValueRef) jsc.JSValueRef {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k = jsc.JSStringCreateWithUTF8CString("__assert_msg");
    defer jsc.JSStringRelease(k);
    _ = jsc.JSObjectSetProperty(ctx, global, k, msg_js, jsc.kJSPropertyAttributeNone, null);
    const script = "throw new Error(globalThis.__assert_msg);";
    const script_ref = jsc.JSStringCreateWithUTF8CString(script);
    defer jsc.JSStringRelease(script_ref);
    _ = jsc.JSEvaluateScript(ctx, script_ref, null, null, 1, null);
    return jsc.JSValueMakeUndefined(ctx);
}

/// assert.strictEqual(actual, expected [, message])
fn strictEqualCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_a = jsc.JSStringCreateWithUTF8CString("__assert_a");
    defer jsc.JSStringRelease(k_a);
    const k_b = jsc.JSStringCreateWithUTF8CString("__assert_b");
    defer jsc.JSStringRelease(k_b);
    _ = jsc.JSObjectSetProperty(ctx, global, k_a, arguments[0], jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, global, k_b, arguments[1], jsc.kJSPropertyAttributeNone, null);
    const msg = if (argumentCount >= 3) blk: {
        const str_ref = jsc.JSValueToStringCopy(ctx, arguments[2], null);
        defer jsc.JSStringRelease(str_ref);
        const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(str_ref);
        if (max_sz == 0 or max_sz > 200) break :blk "strictEqual";
        const buf = allocator.alloc(u8, max_sz) catch break :blk "strictEqual";
        defer allocator.free(buf);
        const n = jsc.JSStringGetUTF8CString(str_ref, buf.ptr, max_sz);
        if (n == 0) break :blk "strictEqual";
        break :blk allocator.dupe(u8, buf[0 .. n - 1]) catch "strictEqual";
    } else "strictEqual";
    defer if (argumentCount >= 3 and msg.len > 0 and msg.ptr != "strictEqual".ptr) globals.current_allocator.?.free(msg);
    const script = "if(globalThis.__assert_a!==globalThis.__assert_b) throw new Error(globalThis.__assert_msg||'strictEqual');";
    const script_z = allocator.dupeZ(u8, script) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(script_z);
    if (argumentCount >= 3) {
        const k_msg = jsc.JSStringCreateWithUTF8CString("__assert_msg");
        defer jsc.JSStringRelease(k_msg);
        const msg_ref = jsc.JSStringCreateWithUTF8CString(if (msg.ptr != "strictEqual".ptr) msg.ptr else "strictEqual");
        defer jsc.JSStringRelease(msg_ref);
        _ = jsc.JSObjectSetProperty(ctx, global, k_msg, jsc.JSValueMakeString(ctx, msg_ref), jsc.kJSPropertyAttributeNone, null);
    }
    const script_ref = jsc.JSStringCreateWithUTF8CString(script_z.ptr);
    defer jsc.JSStringRelease(script_ref);
    _ = jsc.JSEvaluateScript(ctx, script_ref, null, null, 1, null);
    return jsc.JSValueMakeUndefined(ctx);
}

/// assert.deepStrictEqual(actual, expected [, message])：递归深度比较，不相等则抛错
fn deepStrictEqualCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_a = jsc.JSStringCreateWithUTF8CString("__assert_a");
    defer jsc.JSStringRelease(k_a);
    const k_b = jsc.JSStringCreateWithUTF8CString("__assert_b");
    defer jsc.JSStringRelease(k_b);
    _ = jsc.JSObjectSetProperty(ctx, global, k_a, arguments[0], jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, global, k_b, arguments[1], jsc.kJSPropertyAttributeNone, null);
    const script = "(function(a,b){ if(a===b) return; if(typeof a!=='object'||a===null||typeof b!=='object'||b===null) throw new Error('deepStrictEqual'); var ka=Object.keys(a),kb=Object.keys(b); if(ka.length!==kb.length) throw new Error('deepStrictEqual'); for(var i=0;i<ka.length;i++){ var k=ka[i]; if(!Object.prototype.hasOwnProperty.call(b,k)) throw new Error('deepStrictEqual'); arguments.callee(a[k],b[k]); } })(globalThis.__assert_a,globalThis.__assert_b);";
    const script_z = allocator.dupeZ(u8, script) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(script_z);
    const script_ref = jsc.JSStringCreateWithUTF8CString(script_z.ptr);
    defer jsc.JSStringRelease(script_ref);
    _ = jsc.JSEvaluateScript(ctx, script_ref, null, null, 1, null);
    return jsc.JSValueMakeUndefined(ctx);
}

/// assert.ok(value [, message])
fn okCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    if (!jsc.JSValueToBoolean(ctx, arguments[0])) {
        const msg_js = if (argumentCount >= 2) arguments[1] else blk: {
            const ref = jsc.JSStringCreateWithUTF8CString("assert.ok");
            defer jsc.JSStringRelease(ref);
            break :blk jsc.JSValueMakeString(ctx, ref);
        };
        _ = throwAssertErrorWithJS(ctx, msg_js);
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// assert.fail([message])
fn failCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const msg_js = if (argumentCount >= 1) arguments[0] else blk: {
        const ref = jsc.JSStringCreateWithUTF8CString("fail");
        defer jsc.JSStringRelease(ref);
        break :blk jsc.JSValueMakeString(ctx, ref);
    };
    _ = throwAssertErrorWithJS(ctx, msg_js);
    return jsc.JSValueMakeUndefined(ctx);
}

/// assert.throws(fn [, message])：fn 必须抛错，否则抛 AssertionError
fn throwsCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1 or !jsc.JSObjectIsFunction(ctx, @ptrCast(arguments[0]))) return jsc.JSValueMakeUndefined(ctx);
    const fn_ref = arguments[0];
    var no_args: [0]jsc.JSValueRef = undefined;
    _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(fn_ref), null, 0, &no_args, null);
    // 若能执行到这里说明 fn 未抛错，需抛 assert.throws 错误
    const msg_js = if (argumentCount >= 2) arguments[1] else blk: {
        const ref = jsc.JSStringCreateWithUTF8CString("throws");
        defer jsc.JSStringRelease(ref);
        break :blk jsc.JSValueMakeString(ctx, ref);
    };
    _ = throwAssertErrorWithJS(ctx, msg_js);
    return jsc.JSValueMakeUndefined(ctx);
}

/// 返回 shu:assert 的 exports 对象（strictEqual、deepStrictEqual、ok、fail、throws）
pub fn getExports(ctx: jsc.JSContextRef, _: std.mem.Allocator) jsc.JSValueRef {
    const obj = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, obj, "strictEqual", strictEqualCallback);
    common.setMethod(ctx, obj, "deepStrictEqual", deepStrictEqualCallback);
    common.setMethod(ctx, obj, "ok", okCallback);
    common.setMethod(ctx, obj, "fail", failCallback);
    common.setMethod(ctx, obj, "throws", throwsCallback);
    return obj;
}
