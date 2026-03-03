// shu:util 内置：纯 Zig 实现 Node 风格 util（inspect、promisify、types）
// 供 require("shu:util") / node:util 共用，无内嵌 JS 脚本

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");

var k_JSON: jsc.JSStringRef = undefined;
var k_stringify: jsc.JSStringRef = undefined;
var k_String: jsc.JSStringRef = undefined;
var k_Object: jsc.JSStringRef = undefined;
var k_prototype: jsc.JSStringRef = undefined;
var k_toString: jsc.JSStringRef = undefined;
var k_call: jsc.JSStringRef = undefined;
var k_Array: jsc.JSStringRef = undefined;
var k_isArray: jsc.JSStringRef = undefined;
var k_Promise: jsc.JSStringRef = undefined;
var k_apply: jsc.JSStringRef = undefined;
var k___fn: jsc.JSStringRef = undefined;
var k_resolve: jsc.JSStringRef = undefined;
var k_reject: jsc.JSStringRef = undefined;
var k_holder: jsc.JSStringRef = undefined;
var util_strings_init: bool = false;

fn ensureUtilStrings() void {
    if (util_strings_init) return;
    k_JSON = jsc.JSStringCreateWithUTF8CString("JSON");
    k_stringify = jsc.JSStringCreateWithUTF8CString("stringify");
    k_String = jsc.JSStringCreateWithUTF8CString("String");
    k_Object = jsc.JSStringCreateWithUTF8CString("Object");
    k_prototype = jsc.JSStringCreateWithUTF8CString("prototype");
    k_toString = jsc.JSStringCreateWithUTF8CString("toString");
    k_call = jsc.JSStringCreateWithUTF8CString("call");
    k_Array = jsc.JSStringCreateWithUTF8CString("Array");
    k_isArray = jsc.JSStringCreateWithUTF8CString("isArray");
    k_Promise = jsc.JSStringCreateWithUTF8CString("Promise");
    k_apply = jsc.JSStringCreateWithUTF8CString("apply");
    k___fn = jsc.JSStringCreateWithUTF8CString("__fn");
    k_resolve = jsc.JSStringCreateWithUTF8CString("resolve");
    k_reject = jsc.JSStringCreateWithUTF8CString("reject");
    k_holder = jsc.JSStringCreateWithUTF8CString("holder");
    util_strings_init = true;
}

/// inspect(obj)：先尝试 JSON.stringify，失败则 String(obj)
fn inspectCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const json_val = jsc.JSObjectGetProperty(ctx, global, k_JSON, null);
    const json_obj = jsc.JSValueToObject(ctx, json_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const stringify_val = jsc.JSObjectGetProperty(ctx, json_obj, k_stringify, null);
    const stringify_fn = jsc.JSValueToObject(ctx, stringify_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    var one: [1]jsc.JSValueRef = .{arguments[0]};
    const result = jsc.JSObjectCallAsFunction(ctx, stringify_fn, null, 1, &one, null);
    if (!jsc.JSValueIsUndefined(ctx, result)) return result;
    const str_val = jsc.JSObjectGetProperty(ctx, global, k_String, null);
    const str_ctor = jsc.JSValueToObject(ctx, str_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    return jsc.JSObjectCallAsFunction(ctx, str_ctor, null, 1, &one, null);
}

/// promisify 返回的函数被调用时：创建 Promise(executor)，executor 内调用 fn(...args, nodeStyleCallback)
fn promisifiedCallCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    callee: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    _ = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const fn_val = jsc.JSObjectGetProperty(ctx, callee, k___fn, null);
    _ = jsc.JSValueToObject(ctx, fn_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const promise_val = jsc.JSObjectGetProperty(ctx, global, k_Promise, null);
    const promise_ctor = jsc.JSValueToObject(ctx, promise_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const executor_name = jsc.JSStringCreateWithUTF8CString("executor");
    defer jsc.JSStringRelease(executor_name);
    const executor_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, executor_name, promisifyExecutorCallback);
    const holder = jsc.JSObjectMake(ctx, null, null);
    _ = jsc.JSObjectSetProperty(ctx, holder, k___fn, fn_val, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, holder, k_resolve, jsc.JSValueMakeUndefined(ctx), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, holder, k_reject, jsc.JSValueMakeUndefined(ctx), jsc.kJSPropertyAttributeNone, null);
    const args_arr = jsc.JSObjectMakeArray(ctx, argumentCount, if (argumentCount > 0) arguments else @as([*]const jsc.JSValueRef, &[_]jsc.JSValueRef{}), null);
    _ = jsc.JSObjectSetProperty(ctx, holder, jsc.JSStringCreateWithUTF8CString("args"), args_arr, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, holder, jsc.JSStringCreateWithUTF8CString("that"), thisObject, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, executor_fn, k_holder, holder, jsc.kJSPropertyAttributeNone, null);
    var one: [1]jsc.JSValueRef = .{executor_fn};
    return jsc.JSObjectCallAsConstructor(ctx, promise_ctor, 1, &one, null);
}

fn promisifyExecutorCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    callee: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const holder_val = jsc.JSObjectGetProperty(ctx, callee, k_holder, null);
    const holder = jsc.JSValueToObject(ctx, holder_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    _ = jsc.JSObjectSetProperty(ctx, holder, k_resolve, arguments[0], jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, holder, k_reject, arguments[1], jsc.kJSPropertyAttributeNone, null);
    const fn_val = jsc.JSObjectGetProperty(ctx, holder, k___fn, null);
    const fn_obj = jsc.JSValueToObject(ctx, fn_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const args_val = jsc.JSObjectGetProperty(ctx, holder, jsc.JSStringCreateWithUTF8CString("args"), null);
    const that_val = jsc.JSObjectGetProperty(ctx, holder, jsc.JSStringCreateWithUTF8CString("that"), null);
    const apply_val = jsc.JSObjectGetProperty(ctx, fn_obj, k_apply, null);
    const apply_fn = jsc.JSValueToObject(ctx, apply_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const node_cb_name = jsc.JSStringCreateWithUTF8CString("nodeCb");
    defer jsc.JSStringRelease(node_cb_name);
    const node_cb = jsc.JSObjectMakeFunctionWithCallback(ctx, node_cb_name, promisifyNodeCallback);
    _ = jsc.JSObjectSetProperty(ctx, node_cb, k_holder, holder, jsc.kJSPropertyAttributeNone, null);
    const args_obj = jsc.JSValueToObject(ctx, args_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const len_val = jsc.JSObjectGetProperty(ctx, args_obj, jsc.JSStringCreateWithUTF8CString("length"), null);
    const len_f = jsc.JSValueToNumber(ctx, len_val, null);
    const len: usize = @intFromFloat(len_f);
    var args_with_cb: [65]jsc.JSValueRef = undefined;
    var i: usize = 0;
    while (i < len and i < 64) : (i += 1) {
        args_with_cb[i] = jsc.JSObjectGetPropertyAtIndex(ctx, args_obj, @intCast(i), null);
    }
    args_with_cb[i] = node_cb;
    i += 1;
    // fn.apply(that, args_with_cb)
    var apply_args: [2]jsc.JSValueRef = .{ that_val, jsc.JSObjectMakeArray(ctx, i, &args_with_cb, null) };
    _ = jsc.JSObjectCallAsFunction(ctx, apply_fn, fn_obj, 2, &apply_args, null);
    return jsc.JSValueMakeUndefined(ctx);
}

fn promisifyNodeCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    callee: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const holder_val = jsc.JSObjectGetProperty(ctx, callee, k_holder, null);
    const holder = jsc.JSValueToObject(ctx, holder_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const resolve_val = jsc.JSObjectGetProperty(ctx, holder, k_resolve, null);
    const reject_val = jsc.JSObjectGetProperty(ctx, holder, k_reject, null);
    const resolve_fn = jsc.JSValueToObject(ctx, resolve_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const reject_fn = jsc.JSValueToObject(ctx, reject_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    if (argumentCount > 0 and !jsc.JSValueIsUndefined(ctx, arguments[0])) {
        var err_arg: [1]jsc.JSValueRef = .{arguments[0]};
        _ = jsc.JSObjectCallAsFunction(ctx, reject_fn, null, 1, &err_arg, null);
    } else {
        var one_val: [1]jsc.JSValueRef = .{if (argumentCount > 1) arguments[1] else jsc.JSValueMakeUndefined(ctx)};
        _ = jsc.JSObjectCallAsFunction(ctx, resolve_fn, null, 1, &one_val, null);
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// promisify(fn)：返回一个函数，调用时返回 Promise
fn promisifyCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const fn_val = arguments[0];
    _ = jsc.JSValueToObject(ctx, fn_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const name_ref = jsc.JSStringCreateWithUTF8CString("promisified");
    defer jsc.JSStringRelease(name_ref);
    const wrapped = jsc.JSObjectMakeFunctionWithCallback(ctx, name_ref, promisifiedCallCallback);
    _ = jsc.JSObjectSetProperty(ctx, wrapped, k___fn, fn_val, jsc.kJSPropertyAttributeNone, null);
    return wrapped;
}

/// types.isArray：调用 Array.isArray
fn typesIsArrayCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeBoolean(ctx, false);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const arr_val = jsc.JSObjectGetProperty(ctx, global, k_Array, null);
    const arr_obj = jsc.JSValueToObject(ctx, arr_val, null) orelse return jsc.JSValueMakeBoolean(ctx, false);
    const is_array_val = jsc.JSObjectGetProperty(ctx, arr_obj, k_isArray, null);
    const is_array_fn = jsc.JSValueToObject(ctx, is_array_val, null) orelse return jsc.JSValueMakeBoolean(ctx, false);
    var one: [1]jsc.JSValueRef = .{arguments[0]};
    const result = jsc.JSObjectCallAsFunction(ctx, is_array_fn, null, 1, &one, null);
    return jsc.JSValueMakeBoolean(ctx, jsc.JSValueToBoolean(ctx, result));
}

/// types.isFunction：JSObjectIsFunction
fn typesIsFunctionCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeBoolean(ctx, false);
    const obj = jsc.JSValueToObject(ctx, arguments[0], null) orelse return jsc.JSValueMakeBoolean(ctx, false);
    return jsc.JSValueMakeBoolean(ctx, jsc.JSObjectIsFunction(ctx, obj));
}

/// types.isUndefined：JSValueIsUndefined
fn typesIsUndefinedCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeBoolean(ctx, false);
    return jsc.JSValueMakeBoolean(ctx, jsc.JSValueIsUndefined(ctx, arguments[0]));
}

pub fn getExports(ctx: jsc.JSContextRef, _: std.mem.Allocator) jsc.JSValueRef {
    ensureUtilStrings();
    const exports = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, exports, "inspect", inspectCallback);
    common.setMethod(ctx, exports, "promisify", promisifyCallback);
    const types = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, types, "isArray", typesIsArrayCallback);
    common.setMethod(ctx, types, "isFunction", typesIsFunctionCallback);
    common.setMethod(ctx, types, "isString", typeCheckCallback("String"));
    common.setMethod(ctx, types, "isNumber", typeCheckCallback("Number"));
    common.setMethod(ctx, types, "isBoolean", typeCheckCallback("Boolean"));
    common.setMethod(ctx, types, "isNull", typeCheckCallback("Null"));
    common.setMethod(ctx, types, "isUndefined", typesIsUndefinedCallback);
    _ = jsc.JSObjectSetProperty(ctx, exports, jsc.JSStringCreateWithUTF8CString("types"), types, jsc.kJSPropertyAttributeNone, null);
    return exports;
}

/// 用 Object.prototype.toString.call(v) 与 "[object Tag]" 比较（tag 不含 "[object " 前缀，内部拼上）
fn typeCheckCallback(comptime tag: []const u8) jsc.JSObjectCallAsFunctionCallback {
    const full_tag = "[object " ++ tag ++ "]";
    return struct {
        fn cb(
            ctx: jsc.JSContextRef,
            _: jsc.JSObjectRef,
            _: jsc.JSObjectRef,
            argc: usize,
            argv: [*]const jsc.JSValueRef,
            _: [*]jsc.JSValueRef,
        ) callconv(.c) jsc.JSValueRef {
            if (argc < 1) return jsc.JSValueMakeBoolean(ctx, false);
            const global = jsc.JSContextGetGlobalObject(ctx);
            const obj_val = jsc.JSObjectGetProperty(ctx, global, k_Object, null);
            const obj_obj = jsc.JSValueToObject(ctx, obj_val, null) orelse return jsc.JSValueMakeBoolean(ctx, false);
            const proto_val = jsc.JSObjectGetProperty(ctx, obj_obj, k_prototype, null);
            const proto_obj = jsc.JSValueToObject(ctx, proto_val, null) orelse return jsc.JSValueMakeBoolean(ctx, false);
            const to_str_val = jsc.JSObjectGetProperty(ctx, proto_obj, k_toString, null);
            const to_str_fn = jsc.JSValueToObject(ctx, to_str_val, null) orelse return jsc.JSValueMakeBoolean(ctx, false);
            const call_val = jsc.JSObjectGetProperty(ctx, to_str_fn, k_call, null);
            const call_fn = jsc.JSValueToObject(ctx, call_val, null) orelse return jsc.JSValueMakeBoolean(ctx, false);
            var one: [1]jsc.JSValueRef = .{argv[0]};
            const result = jsc.JSObjectCallAsFunction(ctx, call_fn, to_str_fn, 1, &one, null);
            const result_str = jsc.JSValueToStringCopy(ctx, result, null);
            defer jsc.JSStringRelease(result_str);
            var buf: [64]u8 = undefined;
            const n = jsc.JSStringGetUTF8CString(result_str, &buf, buf.len);
            const len = if (n > 0) n - 1 else 0;
            return jsc.JSValueMakeBoolean(ctx, std.mem.eql(u8, buf[0..len], full_tag));
        }
    }.cb;
}
