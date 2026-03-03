// shu:events 内置：纯 Zig 实现 Node 风格 EventEmitter（on/emit/off）
// 供 require("shu:events") / node:events 共用，与 assert 同结构，无内嵌 JS 脚本

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");

// 属性名字符串（用于 JSObjectGetProperty / JSObjectSetProperty），首次 getExports 时初始化
var k_events: jsc.JSStringRef = undefined;
var k_length: jsc.JSStringRef = undefined;
var k_push: jsc.JSStringRef = undefined;
var k_prototype: jsc.JSStringRef = undefined;
var k_EventEmitter: jsc.JSStringRef = undefined;
var strings_init: bool = false;

/// 初始化属性名字符串引用（仅执行一次）
fn ensureStrings() void {
    if (strings_init) return;
    k_events = jsc.JSStringCreateWithUTF8CString("_events");
    k_length = jsc.JSStringCreateWithUTF8CString("length");
    k_push = jsc.JSStringCreateWithUTF8CString("push");
    k_prototype = jsc.JSStringCreateWithUTF8CString("prototype");
    k_EventEmitter = jsc.JSStringCreateWithUTF8CString("EventEmitter");
    strings_init = true;
}

/// 构造函数：new EventEmitter() 时初始化 this._events = {}（空对象）
fn eventEmitterConstructor(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    thisObject: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const empty = jsc.JSObjectMake(ctx, null, null);
    _ = jsc.JSObjectSetProperty(ctx, thisObject, k_events, empty, jsc.kJSPropertyAttributeNone, null);
    return jsc.JSValueMakeUndefined(ctx);
}

/// 实例方法 on(name, fn)：在 this._events[name] 数组上 push(fn)，无则先建数组，返回 this
fn onCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return thisObject;
    const events_val = jsc.JSObjectGetProperty(ctx, thisObject, k_events, null);
    const events = jsc.JSValueToObject(ctx, events_val, null) orelse return thisObject;
    const name_val = arguments[0];
    const fn_val = arguments[1];
    const name_str = jsc.JSValueToStringCopy(ctx, name_val, null);
    defer jsc.JSStringRelease(name_str);
    const list_val = jsc.JSObjectGetProperty(ctx, events, name_str, null);
    const list_obj = jsc.JSValueToObject(ctx, list_val, null);
    if (list_obj == null) {
        var one: [1]jsc.JSValueRef = .{fn_val};
        const new_arr = jsc.JSObjectMakeArray(ctx, 1, &one, null);
        _ = jsc.JSObjectSetProperty(ctx, events, name_str, new_arr, jsc.kJSPropertyAttributeNone, null);
        return thisObject;
    }
    const global = jsc.JSContextGetGlobalObject(ctx);
    const arr_name = jsc.JSStringCreateWithUTF8CString("Array");
    defer jsc.JSStringRelease(arr_name);
    const arr_val = jsc.JSObjectGetProperty(ctx, global, arr_name, null);
    const arr_obj = jsc.JSValueToObject(ctx, arr_val, null) orelse return thisObject;
    const proto_val = jsc.JSObjectGetProperty(ctx, arr_obj, k_prototype, null);
    const proto_obj = jsc.JSValueToObject(ctx, proto_val, null) orelse return thisObject;
    const push_val = jsc.JSObjectGetProperty(ctx, proto_obj, k_push, null);
    const push_fn = jsc.JSValueToObject(ctx, push_val, null) orelse return thisObject;
    var args: [1]jsc.JSValueRef = .{fn_val};
    _ = jsc.JSObjectCallAsFunction(ctx, push_fn, list_obj, 1, &args, null);
    return thisObject;
}

/// 实例方法 emit(name, ...args)：依次调用 this._events[name] 中每个监听器，无监听器返回 false
fn emitCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeBoolean(ctx, false);
    const events_val = jsc.JSObjectGetProperty(ctx, thisObject, k_events, null);
    const events = jsc.JSValueToObject(ctx, events_val, null) orelse return jsc.JSValueMakeBoolean(ctx, false);
    const name_str = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(name_str);
    const list_val = jsc.JSObjectGetProperty(ctx, events, name_str, null);
    const list_obj = jsc.JSValueToObject(ctx, list_val, null) orelse return jsc.JSValueMakeBoolean(ctx, false);
    if (jsc.JSValueIsUndefined(ctx, list_val)) return jsc.JSValueMakeBoolean(ctx, false);
    const len_val = jsc.JSObjectGetProperty(ctx, list_obj, k_length, null);
    const len_f = jsc.JSValueToNumber(ctx, len_val, null);
    const len: usize = @intFromFloat(len_f);
    if (len == 0) return jsc.JSValueMakeBoolean(ctx, false);
    const argc = argumentCount -% 1;
    var no_args: [0]jsc.JSValueRef = undefined;
    const argv: [*]const jsc.JSValueRef = if (argc > 0) arguments + 1 else &no_args;
    var i: c_uint = 0;
    while (i < len) : (i += 1) {
        const fn_val = jsc.JSObjectGetPropertyAtIndex(ctx, list_obj, i, null);
        const fn_obj = jsc.JSValueToObject(ctx, fn_val, null) orelse continue;
        _ = jsc.JSObjectCallAsFunction(ctx, fn_obj, thisObject, argc, argv, null);
    }
    return jsc.JSValueMakeBoolean(ctx, true);
}

/// 实例方法 off(name, fn?)：若未传 fn 则清空 name 的监听器；否则移除指定 fn，返回 this
fn offCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return thisObject;
    const events_val = jsc.JSObjectGetProperty(ctx, thisObject, k_events, null);
    const events = jsc.JSValueToObject(ctx, events_val, null) orelse return thisObject;
    const name_str = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(name_str);
    const list_val = jsc.JSObjectGetProperty(ctx, events, name_str, null);
    if (jsc.JSValueIsUndefined(ctx, list_val)) return thisObject;
    const list_obj = jsc.JSValueToObject(ctx, list_val, null) orelse return thisObject;
    const len_val = jsc.JSObjectGetProperty(ctx, list_obj, k_length, null);
    const len_f = jsc.JSValueToNumber(ctx, len_val, null);
    const len: usize = @intFromFloat(len_f);
    if (argumentCount < 2) {
        var empty_elems: [0]jsc.JSValueRef = undefined;
        const empty_arr = jsc.JSObjectMakeArray(ctx, 0, &empty_elems, null);
        _ = jsc.JSObjectSetProperty(ctx, events, name_str, empty_arr, jsc.kJSPropertyAttributeNone, null);
        return thisObject;
    }
    const fn_to_remove = arguments[1];
    var keep: [256]jsc.JSValueRef = undefined;
    var nkeep: usize = 0;
    var i: c_uint = 0;
    while (i < len and nkeep < 256) : (i += 1) {
        const v = jsc.JSObjectGetPropertyAtIndex(ctx, list_obj, i, null);
        if (v != fn_to_remove) {
            keep[nkeep] = v;
            nkeep += 1;
        }
    }
    var empty_off: [0]jsc.JSValueRef = undefined;
    const new_arr = jsc.JSObjectMakeArray(ctx, nkeep, if (nkeep > 0) &keep else &empty_off, null);
    _ = jsc.JSObjectSetProperty(ctx, events, name_str, new_arr, jsc.kJSPropertyAttributeNone, null);
    return thisObject;
}

/// 返回 shu:events 的 exports 对象（{ EventEmitter }）；EventEmitter 为构造函数，原型上挂 on/emit/off
pub fn getExports(ctx: jsc.JSContextRef, _: std.mem.Allocator) jsc.JSValueRef {
    ensureStrings();
    const proto = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, proto, "on", onCallback);
    common.setMethod(ctx, proto, "emit", emitCallback);
    common.setMethod(ctx, proto, "off", offCallback);
    const ctor_name = jsc.JSStringCreateWithUTF8CString("EventEmitter");
    defer jsc.JSStringRelease(ctor_name);
    const ctor = jsc.JSObjectMakeFunctionWithCallback(ctx, ctor_name, eventEmitterConstructor);
    _ = jsc.JSObjectSetProperty(ctx, ctor, k_prototype, proto, jsc.kJSPropertyAttributeNone, null);
    const exports = jsc.JSObjectMake(ctx, null, null);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_EventEmitter, ctor, jsc.kJSPropertyAttributeNone, null);
    return exports;
}
