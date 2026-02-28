// shu:stream 内置：Node 风格流（Readable、Writable、Duplex、Transform、PassThrough、pipeline、finished）
// 纯 Zig 实现，与 events 同构（_events + on/emit），对应 node:stream

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");

// ---------- 属性名字符串（首次 getExports 时初始化） ----------
var k_events: jsc.JSStringRef = undefined;
var k_length: jsc.JSStringRef = undefined;
var k_push: jsc.JSStringRef = undefined;
var k_prototype: jsc.JSStringRef = undefined;
var k_readableState: jsc.JSStringRef = undefined;
var k_writableState: jsc.JSStringRef = undefined;
var k_buffer: jsc.JSStringRef = undefined;
var k_ended: jsc.JSStringRef = undefined;
var k_finished: jsc.JSStringRef = undefined;
var k_pipeDest: jsc.JSStringRef = undefined;
var k_write: jsc.JSStringRef = undefined;
var k_end: jsc.JSStringRef = undefined;
var k_pipelineCb: jsc.JSStringRef = undefined;
var k_Readable: jsc.JSStringRef = undefined;
var k_Writable: jsc.JSStringRef = undefined;
var k_Duplex: jsc.JSStringRef = undefined;
var k_Transform: jsc.JSStringRef = undefined;
var k_PassThrough: jsc.JSStringRef = undefined;
var stream_strings_init: bool = false;

fn ensureStreamStrings() void {
    if (stream_strings_init) return;
    k_events = jsc.JSStringCreateWithUTF8CString("_events");
    k_length = jsc.JSStringCreateWithUTF8CString("length");
    k_push = jsc.JSStringCreateWithUTF8CString("push");
    k_prototype = jsc.JSStringCreateWithUTF8CString("prototype");
    k_readableState = jsc.JSStringCreateWithUTF8CString("_readableState");
    k_writableState = jsc.JSStringCreateWithUTF8CString("_writableState");
    k_buffer = jsc.JSStringCreateWithUTF8CString("buffer");
    k_ended = jsc.JSStringCreateWithUTF8CString("ended");
    k_finished = jsc.JSStringCreateWithUTF8CString("finished");
    k_pipeDest = jsc.JSStringCreateWithUTF8CString("_pipeDest");
    k_write = jsc.JSStringCreateWithUTF8CString("write");
    k_end = jsc.JSStringCreateWithUTF8CString("end");
    k_pipelineCb = jsc.JSStringCreateWithUTF8CString("_pipelineCb");
    k_Readable = jsc.JSStringCreateWithUTF8CString("Readable");
    k_Writable = jsc.JSStringCreateWithUTF8CString("Writable");
    k_Duplex = jsc.JSStringCreateWithUTF8CString("Duplex");
    k_Transform = jsc.JSStringCreateWithUTF8CString("Transform");
    k_PassThrough = jsc.JSStringCreateWithUTF8CString("PassThrough");
    stream_strings_init = true;
}

/// 在 stream 对象上绑定 on：向 this._events[name] 数组 push(fn)
fn streamOn(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
) void {
    if (argumentCount < 2) return;
    const events_val = jsc.JSObjectGetProperty(ctx, thisObject, k_events, null);
    const events = jsc.JSValueToObject(ctx, events_val, null) orelse return;
    const name_str = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(name_str);
    const list_val = jsc.JSObjectGetProperty(ctx, events, name_str, null);
    const list_obj = jsc.JSValueToObject(ctx, list_val, null);
    if (list_obj == null) {
        var one: [1]jsc.JSValueRef = .{arguments[1]};
        const new_arr = jsc.JSObjectMakeArray(ctx, 1, &one, null);
        _ = jsc.JSObjectSetProperty(ctx, events, name_str, new_arr, jsc.kJSPropertyAttributeNone, null);
        return;
    }
    const global = jsc.JSContextGetGlobalObject(ctx);
    const arr_name = jsc.JSStringCreateWithUTF8CString("Array");
    defer jsc.JSStringRelease(arr_name);
    const arr_val = jsc.JSObjectGetProperty(ctx, global, arr_name, null);
    const arr_obj = jsc.JSValueToObject(ctx, arr_val, null) orelse return;
    const proto_val = jsc.JSObjectGetProperty(ctx, arr_obj, k_prototype, null);
    const proto_obj = jsc.JSValueToObject(ctx, proto_val, null) orelse return;
    const push_val = jsc.JSObjectGetProperty(ctx, proto_obj, k_push, null);
    const push_fn = jsc.JSValueToObject(ctx, push_val, null) orelse return;
    var args: [1]jsc.JSValueRef = .{arguments[1]};
    _ = jsc.JSObjectCallAsFunction(ctx, push_fn, list_obj, 1, &args, null);
}

/// 触发 this._events[name] 中所有监听器，传入 ...args；event_name 需为以 0 结尾的 UTF-8
fn streamEmit(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    event_name: [*:0]const u8,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
) void {
    const k = jsc.JSStringCreateWithUTF8CString(event_name);
    defer jsc.JSStringRelease(k);
    const events_val = jsc.JSObjectGetProperty(ctx, thisObject, k_events, null);
    const events = jsc.JSValueToObject(ctx, events_val, null) orelse return;
    const list_val = jsc.JSObjectGetProperty(ctx, events, k, null);
    const list_obj = jsc.JSValueToObject(ctx, list_val, null) orelse return;
    if (jsc.JSValueIsUndefined(ctx, list_val)) return;
    const len_val = jsc.JSObjectGetProperty(ctx, list_obj, k_length, null);
    const len: usize = @intFromFloat(jsc.JSValueToNumber(ctx, len_val, null));
    if (len == 0) return;
    var i: c_uint = 0;
    while (i < len) : (i += 1) {
        const fn_val = jsc.JSObjectGetPropertyAtIndex(ctx, list_obj, i, null);
        const fn_obj = jsc.JSValueToObject(ctx, fn_val, null) orelse continue;
        _ = jsc.JSObjectCallAsFunction(ctx, fn_obj, thisObject, argumentCount, arguments, null);
    }
}

// ---------- Readable ----------

fn readableConstructor(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    thisObject: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    _ = jsc.JSObjectSetProperty(ctx, thisObject, k_events, jsc.JSObjectMake(ctx, null, null), jsc.kJSPropertyAttributeNone, null);
    const state = jsc.JSObjectMake(ctx, null, null);
    var empty: [0]jsc.JSValueRef = undefined;
    _ = jsc.JSObjectSetProperty(ctx, state, k_buffer, jsc.JSObjectMakeArray(ctx, 0, &empty, null), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, state, k_ended, jsc.JSValueMakeBoolean(ctx, false), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, thisObject, k_readableState, state, jsc.kJSPropertyAttributeNone, null);
    return jsc.JSValueMakeUndefined(ctx);
}

/// Readable.push(chunk)：将 chunk 放入 buffer 并 emit('data', chunk)
fn readablePushCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeBoolean(ctx, false);
    const state_val = jsc.JSObjectGetProperty(ctx, thisObject, k_readableState, null);
    const state = jsc.JSValueToObject(ctx, state_val, null) orelse return jsc.JSValueMakeBoolean(ctx, false);
    const buf_val = jsc.JSObjectGetProperty(ctx, state, k_buffer, null);
    const buf = jsc.JSValueToObject(ctx, buf_val, null) orelse return jsc.JSValueMakeBoolean(ctx, false);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const arr_name = jsc.JSStringCreateWithUTF8CString("Array");
    defer jsc.JSStringRelease(arr_name);
    const arr_val = jsc.JSObjectGetProperty(ctx, global, arr_name, null);
    const arr_obj = jsc.JSValueToObject(ctx, arr_val, null) orelse return jsc.JSValueMakeBoolean(ctx, false);
    const proto_val = jsc.JSObjectGetProperty(ctx, arr_obj, k_prototype, null);
    const proto_obj = jsc.JSValueToObject(ctx, proto_val, null) orelse return jsc.JSValueMakeBoolean(ctx, false);
    const push_val = jsc.JSObjectGetProperty(ctx, proto_obj, k_push, null);
    const push_fn = jsc.JSValueToObject(ctx, push_val, null) orelse return jsc.JSValueMakeBoolean(ctx, false);
    var one: [1]jsc.JSValueRef = .{arguments[0]};
    _ = jsc.JSObjectCallAsFunction(ctx, push_fn, buf, 1, &one, null);
    streamEmit(ctx, thisObject, "data".ptr, 1, arguments);
    return jsc.JSValueMakeBoolean(ctx, true);
}

/// Readable.read(n)：从 buffer 取出一项返回，无则返回 null
fn readableReadCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const state_val = jsc.JSObjectGetProperty(ctx, thisObject, k_readableState, null);
    const state = jsc.JSValueToObject(ctx, state_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const buf_val = jsc.JSObjectGetProperty(ctx, state, k_buffer, null);
    const buf = jsc.JSValueToObject(ctx, buf_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const len_val = jsc.JSObjectGetProperty(ctx, buf, k_length, null);
    const len = jsc.JSValueToNumber(ctx, len_val, null);
    if (len < 1) return jsc.JSValueMakeUndefined(ctx);
    const first = jsc.JSObjectGetPropertyAtIndex(ctx, buf, 0, null);
    const shift_name = jsc.JSStringCreateWithUTF8CString("shift");
    defer jsc.JSStringRelease(shift_name);
    const shift_val = jsc.JSObjectGetProperty(ctx, buf, shift_name, null);
    const shift_fn = jsc.JSValueToObject(ctx, shift_val, null) orelse return first;
    var no_args: [0]jsc.JSValueRef = undefined;
    _ = jsc.JSObjectCallAsFunction(ctx, shift_fn, buf, 0, &no_args, null);
    return first;
}

/// pipe(dest) 时注册的 'data' 监听器：将 chunk 写入 dest
fn pipeOnDataCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const dest_val = jsc.JSObjectGetProperty(ctx, thisObject, k_pipeDest, null);
    const dest = jsc.JSValueToObject(ctx, dest_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const write_val = jsc.JSObjectGetProperty(ctx, dest, k_write, null);
    const write_fn = jsc.JSValueToObject(ctx, write_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    var one: [1]jsc.JSValueRef = .{arguments[0]};
    _ = jsc.JSObjectCallAsFunction(ctx, write_fn, dest, 1, &one, null);
    return jsc.JSValueMakeUndefined(ctx);
}

/// pipe(dest) 时注册的 'end' 监听器：调用 dest.end()
fn pipeOnEndCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const dest_val = jsc.JSObjectGetProperty(ctx, thisObject, k_pipeDest, null);
    const dest = jsc.JSValueToObject(ctx, dest_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const end_val = jsc.JSObjectGetProperty(ctx, dest, k_end, null);
    const end_fn = jsc.JSValueToObject(ctx, end_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    var no_args: [0]jsc.JSValueRef = undefined;
    _ = jsc.JSObjectCallAsFunction(ctx, end_fn, dest, 0, &no_args, null);
    return jsc.JSValueMakeUndefined(ctx);
}

/// Readable.pipe(dest)：设置 _pipeDest，注册 data/end，返回 dest
fn readablePipeCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const dest = arguments[0];
    _ = jsc.JSObjectSetProperty(ctx, thisObject, k_pipeDest, dest, jsc.kJSPropertyAttributeNone, null);
    const data_name = jsc.JSStringCreateWithUTF8CString("data");
    defer jsc.JSStringRelease(data_name);
    const end_name = jsc.JSStringCreateWithUTF8CString("end");
    defer jsc.JSStringRelease(end_name);
    const pipeDataFn = jsc.JSObjectMakeFunctionWithCallback(ctx, data_name, pipeOnDataCallback);
    const pipeEndFn = jsc.JSObjectMakeFunctionWithCallback(ctx, end_name, pipeOnEndCallback);
    var on_args_data: [2]jsc.JSValueRef = .{ jsc.JSValueMakeString(ctx, data_name), pipeDataFn };
    var on_args_end: [2]jsc.JSValueRef = .{ jsc.JSValueMakeString(ctx, end_name), pipeEndFn };
    const on_val = jsc.JSObjectGetProperty(ctx, thisObject, jsc.JSStringCreateWithUTF8CString("on"), null);
    const on_fn = jsc.JSValueToObject(ctx, on_val, null) orelse return dest;
    _ = jsc.JSObjectCallAsFunction(ctx, on_fn, thisObject, 2, &on_args_data, null);
    _ = jsc.JSObjectCallAsFunction(ctx, on_fn, thisObject, 2, &on_args_end, null);
    return dest;
}

fn readableOnCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    streamOn(ctx, thisObject, argumentCount, arguments);
    return thisObject;
}

fn readableEmitCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeBoolean(ctx, false);
    const name_str = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(name_str);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(name_str);
    if (max_sz == 0 or max_sz > 255) return jsc.JSValueMakeBoolean(ctx, false);
    var buf: [256]u8 = undefined;
    const n = jsc.JSStringGetUTF8CString(name_str, &buf, max_sz);
    const len = if (n > 0) n - 1 else 0;
    buf[len] = 0;
    const argc = argumentCount -% 1;
    var no_args: [0]jsc.JSValueRef = undefined;
    const argv: [*]const jsc.JSValueRef = if (argc > 0) arguments + 1 else &no_args;
    streamEmit(ctx, thisObject, @ptrCast(&buf), argc, argv);
    return jsc.JSValueMakeBoolean(ctx, true);
}

// ---------- Writable ----------

fn writableConstructor(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    thisObject: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    _ = jsc.JSObjectSetProperty(ctx, thisObject, k_events, jsc.JSObjectMake(ctx, null, null), jsc.kJSPropertyAttributeNone, null);
    const state = jsc.JSObjectMake(ctx, null, null);
    var empty: [0]jsc.JSValueRef = undefined;
    _ = jsc.JSObjectSetProperty(ctx, state, k_buffer, jsc.JSObjectMakeArray(ctx, 0, &empty, null), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, state, k_finished, jsc.JSValueMakeBoolean(ctx, false), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, thisObject, k_writableState, state, jsc.kJSPropertyAttributeNone, null);
    return jsc.JSValueMakeUndefined(ctx);
}

fn writableWriteCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount >= 1) streamEmit(ctx, thisObject, "data", 1, arguments);
    if (argumentCount >= 3) {
        const cb = arguments[2];
        const cb_obj = jsc.JSValueToObject(ctx, cb, null);
        if (cb_obj) |obj| {
            var no_args: [0]jsc.JSValueRef = undefined;
            _ = jsc.JSObjectCallAsFunction(ctx, obj, thisObject, 0, &no_args, null);
        }
    }
    return jsc.JSValueMakeBoolean(ctx, true);
}

fn writableEndCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const state_val = jsc.JSObjectGetProperty(ctx, thisObject, k_writableState, null);
    const state = jsc.JSValueToObject(ctx, state_val, null);
    if (state != null) _ = jsc.JSObjectSetProperty(ctx, state.?, k_finished, jsc.JSValueMakeBoolean(ctx, true), jsc.kJSPropertyAttributeNone, null);
    var no_args: [0]jsc.JSValueRef = undefined;
    streamEmit(ctx, thisObject, "finish".ptr, 0, &no_args);
    if (argumentCount >= 3) {
        const cb = arguments[2];
        if (jsc.JSValueToObject(ctx, cb, null)) |obj|
            _ = jsc.JSObjectCallAsFunction(ctx, obj, thisObject, 0, &no_args, null);
    } else if (argumentCount >= 1) {
        const cb = arguments[0];
        if (jsc.JSValueToObject(ctx, cb, null)) |obj| {
            if (jsc.JSObjectIsFunction(ctx, obj))
                _ = jsc.JSObjectCallAsFunction(ctx, obj, thisObject, 0, &no_args, null);
        }
    }
    return jsc.JSValueMakeUndefined(ctx);
}

fn writableOnCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    streamOn(ctx, thisObject, argumentCount, arguments);
    return thisObject;
}

fn writableEmitCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeBoolean(ctx, false);
    const name_str = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(name_str);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(name_str);
    if (max_sz == 0 or max_sz > 255) return jsc.JSValueMakeBoolean(ctx, false);
    var buf: [256]u8 = undefined;
    const n = jsc.JSStringGetUTF8CString(name_str, &buf, max_sz);
    const len = if (n > 0) n - 1 else 0;
    buf[len] = 0;
    const argc = argumentCount -% 1;
    var no_args: [0]jsc.JSValueRef = undefined;
    const argv: [*]const jsc.JSValueRef = if (argc > 0) arguments + 1 else &no_args;
    streamEmit(ctx, thisObject, @ptrCast(&buf), argc, argv);
    return jsc.JSValueMakeBoolean(ctx, true);
}

// ---------- Duplex（同时具备 Readable + Writable 状态与方法） ----------

fn duplexConstructor(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    thisObject: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    var no_args: [0]jsc.JSValueRef = undefined;
    var exc: jsc.JSValueRef = undefined;
    _ = readableConstructor(ctx, thisObject, thisObject, 0, &no_args, @ptrCast(&exc));
    _ = writableConstructor(ctx, thisObject, thisObject, 0, &no_args, @ptrCast(&exc));
    return jsc.JSValueMakeUndefined(ctx);
}

// ---------- Transform（Duplex，write 时 push 到 readable 侧，即 pass-through） ----------

fn transformWriteCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount >= 1) {
        const push_val = jsc.JSObjectGetProperty(ctx, thisObject, jsc.JSStringCreateWithUTF8CString("push"), null);
        const push_fn = jsc.JSValueToObject(ctx, push_val, null);
        if (push_fn != null) {
            var one: [1]jsc.JSValueRef = .{arguments[0]};
            _ = jsc.JSObjectCallAsFunction(ctx, push_fn.?, thisObject, 1, &one, null);
        }
    }
    if (argumentCount >= 3) {
        const cb = arguments[2];
        if (jsc.JSValueToObject(ctx, cb, null)) |obj| {
            var no_args: [0]jsc.JSValueRef = undefined;
            _ = jsc.JSObjectCallAsFunction(ctx, obj, thisObject, 0, &no_args, null);
        }
    }
    return jsc.JSValueMakeBoolean(ctx, true);
}

// ---------- pipeline 与 finished ----------

fn pipelineFinishCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const cb_val = jsc.JSObjectGetProperty(ctx, thisObject, k_pipelineCb, null);
    const cb = jsc.JSValueToObject(ctx, cb_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    var one: [1]jsc.JSValueRef = .{jsc.JSValueMakeUndefined(ctx)};
    _ = jsc.JSObjectCallAsFunction(ctx, cb, thisObject, 1, &one, null);
    return jsc.JSValueMakeUndefined(ctx);
}

fn pipelineErrorCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const cb_val = jsc.JSObjectGetProperty(ctx, thisObject, k_pipelineCb, null);
    const cb = jsc.JSValueToObject(ctx, cb_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    var one: [1]jsc.JSValueRef = .{if (argumentCount >= 1) arguments[0] else jsc.JSValueMakeUndefined(ctx)};
    _ = jsc.JSObjectCallAsFunction(ctx, cb, thisObject, 1, &one, null);
    return jsc.JSValueMakeUndefined(ctx);
}

fn pipelineCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const n = argumentCount;
    const last = arguments[n - 1];
    const last_obj = jsc.JSValueToObject(ctx, last, null);
    const is_fn = if (last_obj != null) jsc.JSObjectIsFunction(ctx, last_obj.?) else false;
    const num_streams = if (is_fn) n - 1 else n;
    if (num_streams == 0) return jsc.JSValueMakeUndefined(ctx);
    if (num_streams == 1 and is_fn) {
        const s = jsc.JSValueToObject(ctx, arguments[0], null) orelse return jsc.JSValueMakeUndefined(ctx);
        _ = jsc.JSObjectSetProperty(ctx, s, k_pipelineCb, last, jsc.kJSPropertyAttributeNone, null);
        const finish_name = jsc.JSStringCreateWithUTF8CString("finish");
        const error_name = jsc.JSStringCreateWithUTF8CString("error");
        const on_val = jsc.JSObjectGetProperty(ctx, s, jsc.JSStringCreateWithUTF8CString("on"), null);
        const on_fn = jsc.JSValueToObject(ctx, on_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
        const finishFn = jsc.JSObjectMakeFunctionWithCallback(ctx, finish_name, pipelineFinishCallback);
        const errorFn = jsc.JSObjectMakeFunctionWithCallback(ctx, error_name, pipelineErrorCallback);
        var on_finish_args: [2]jsc.JSValueRef = .{ jsc.JSValueMakeString(ctx, finish_name), finishFn };
        var on_error_args: [2]jsc.JSValueRef = .{ jsc.JSValueMakeString(ctx, error_name), errorFn };
        _ = jsc.JSObjectCallAsFunction(ctx, on_fn, s, 2, &on_finish_args, null);
        _ = jsc.JSObjectCallAsFunction(ctx, on_fn, s, 2, &on_error_args, null);
        return jsc.JSValueMakeUndefined(ctx);
    }
    if (num_streams < 2 and is_fn) {
        var one: [1]jsc.JSValueRef = .{jsc.JSValueMakeUndefined(ctx)};
        _ = jsc.JSObjectCallAsFunction(ctx, last_obj.?, @ptrFromInt(0), 1, &one, null);
        return jsc.JSValueMakeUndefined(ctx);
    }
    const pipe_name = jsc.JSStringCreateWithUTF8CString("pipe");
    defer jsc.JSStringRelease(pipe_name);
    const on_name = jsc.JSStringCreateWithUTF8CString("on");
    defer jsc.JSStringRelease(on_name);
    var i: usize = 0;
    while (i + 1 < num_streams) : (i += 1) {
        const s = jsc.JSValueToObject(ctx, arguments[i], null) orelse continue;
        const next = arguments[i + 1];
        const pipe_val = jsc.JSObjectGetProperty(ctx, s, pipe_name, null);
        const pipe_fn = jsc.JSValueToObject(ctx, pipe_val, null) orelse continue;
        var one: [1]jsc.JSValueRef = .{next};
        _ = jsc.JSObjectCallAsFunction(ctx, pipe_fn, s, 1, &one, null);
    }
    const last_stream = jsc.JSValueToObject(ctx, arguments[num_streams - 1], null) orelse return jsc.JSValueMakeUndefined(ctx);
    if (is_fn) {
        _ = jsc.JSObjectSetProperty(ctx, last_stream, k_pipelineCb, last, jsc.kJSPropertyAttributeNone, null);
        const finishFn = jsc.JSObjectMakeFunctionWithCallback(ctx, jsc.JSStringCreateWithUTF8CString("finish"), pipelineFinishCallback);
        const errorFn = jsc.JSObjectMakeFunctionWithCallback(ctx, jsc.JSStringCreateWithUTF8CString("error"), pipelineErrorCallback);
        const on_val = jsc.JSObjectGetProperty(ctx, last_stream, on_name, null);
        const on_fn = jsc.JSValueToObject(ctx, on_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
        var on_finish_args: [2]jsc.JSValueRef = .{ jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString("finish")), finishFn };
        var on_error_args: [2]jsc.JSValueRef = .{ jsc.JSValueMakeString(ctx, jsc.JSStringCreateWithUTF8CString("error")), errorFn };
        _ = jsc.JSObjectCallAsFunction(ctx, on_fn, last_stream, 2, &on_finish_args, null);
        _ = jsc.JSObjectCallAsFunction(ctx, on_fn, last_stream, 2, &on_error_args, null);
    }
    return jsc.JSValueMakeUndefined(ctx);
}

fn finishedCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const stream = jsc.JSValueToObject(ctx, arguments[0], null) orelse return jsc.JSValueMakeUndefined(ctx);
    const cb = arguments[1];
    const on_val = jsc.JSObjectGetProperty(ctx, stream, jsc.JSStringCreateWithUTF8CString("on"), null);
    const on_fn = jsc.JSValueToObject(ctx, on_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const end_name = jsc.JSStringCreateWithUTF8CString("end");
    const finish_name = jsc.JSStringCreateWithUTF8CString("finish");
    const error_name = jsc.JSStringCreateWithUTF8CString("error");
    var args: [2]jsc.JSValueRef = .{ jsc.JSValueMakeString(ctx, end_name), cb };
    _ = jsc.JSObjectCallAsFunction(ctx, on_fn, stream, 2, &args, null);
    args[0] = jsc.JSValueMakeString(ctx, finish_name);
    _ = jsc.JSObjectCallAsFunction(ctx, on_fn, stream, 2, &args, null);
    args[0] = jsc.JSValueMakeString(ctx, error_name);
    _ = jsc.JSObjectCallAsFunction(ctx, on_fn, stream, 2, &args, null);
    return jsc.JSValueMakeUndefined(ctx);
}

// ---------- getExports ----------

fn makeReadableProto(ctx: jsc.JSContextRef) jsc.JSObjectRef {
    const proto = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, proto, "on", readableOnCallback);
    common.setMethod(ctx, proto, "emit", readableEmitCallback);
    common.setMethod(ctx, proto, "push", readablePushCallback);
    common.setMethod(ctx, proto, "read", readableReadCallback);
    common.setMethod(ctx, proto, "pipe", readablePipeCallback);
    return proto;
}

fn makeWritableProto(ctx: jsc.JSContextRef) jsc.JSObjectRef {
    const proto = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, proto, "on", writableOnCallback);
    common.setMethod(ctx, proto, "emit", writableEmitCallback);
    common.setMethod(ctx, proto, "write", writableWriteCallback);
    common.setMethod(ctx, proto, "end", writableEndCallback);
    return proto;
}

/// 返回 shu:stream 的 exports：Readable、Writable、Duplex、Transform、PassThrough、pipeline、finished
pub fn getExports(ctx: jsc.JSContextRef, _: std.mem.Allocator) jsc.JSValueRef {
    ensureStreamStrings();
    const readable_proto = makeReadableProto(ctx);
    const writable_proto = makeWritableProto(ctx);

    const readable_ctor = jsc.JSObjectMakeFunctionWithCallback(ctx, k_Readable, readableConstructor);
    _ = jsc.JSObjectSetProperty(ctx, readable_ctor, k_prototype, readable_proto, jsc.kJSPropertyAttributeNone, null);

    const writable_ctor = jsc.JSObjectMakeFunctionWithCallback(ctx, k_Writable, writableConstructor);
    _ = jsc.JSObjectSetProperty(ctx, writable_ctor, k_prototype, writable_proto, jsc.kJSPropertyAttributeNone, null);

    const duplex_proto = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, duplex_proto, "on", readableOnCallback);
    common.setMethod(ctx, duplex_proto, "emit", readableEmitCallback);
    common.setMethod(ctx, duplex_proto, "push", readablePushCallback);
    common.setMethod(ctx, duplex_proto, "read", readableReadCallback);
    common.setMethod(ctx, duplex_proto, "pipe", readablePipeCallback);
    common.setMethod(ctx, duplex_proto, "write", writableWriteCallback);
    common.setMethod(ctx, duplex_proto, "end", writableEndCallback);
    const duplex_ctor = jsc.JSObjectMakeFunctionWithCallback(ctx, k_Duplex, duplexConstructor);
    _ = jsc.JSObjectSetProperty(ctx, duplex_ctor, k_prototype, duplex_proto, jsc.kJSPropertyAttributeNone, null);

    const transform_proto = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, transform_proto, "on", readableOnCallback);
    common.setMethod(ctx, transform_proto, "emit", readableEmitCallback);
    common.setMethod(ctx, transform_proto, "push", readablePushCallback);
    common.setMethod(ctx, transform_proto, "read", readableReadCallback);
    common.setMethod(ctx, transform_proto, "pipe", readablePipeCallback);
    common.setMethod(ctx, transform_proto, "write", transformWriteCallback);
    common.setMethod(ctx, transform_proto, "end", writableEndCallback);
    const transform_ctor = jsc.JSObjectMakeFunctionWithCallback(ctx, k_Transform, duplexConstructor);
    _ = jsc.JSObjectSetProperty(ctx, transform_ctor, k_prototype, transform_proto, jsc.kJSPropertyAttributeNone, null);

    const passThrough_ctor = jsc.JSObjectMakeFunctionWithCallback(ctx, k_PassThrough, duplexConstructor);
    _ = jsc.JSObjectSetProperty(ctx, passThrough_ctor, k_prototype, transform_proto, jsc.kJSPropertyAttributeNone, null);

    const exports = jsc.JSObjectMake(ctx, null, null);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_Readable, readable_ctor, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_Writable, writable_ctor, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_Duplex, duplex_ctor, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_Transform, transform_ctor, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_PassThrough, passThrough_ctor, jsc.kJSPropertyAttributeNone, null);
    common.setMethod(ctx, exports, "pipeline", pipelineCallback);
    common.setMethod(ctx, exports, "finished", finishedCallback);
    return exports;
}
