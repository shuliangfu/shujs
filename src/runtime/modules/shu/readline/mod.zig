// shu:readline 内置：逐行读取接口，对应 node:readline
// createInterface({ input, output? }) 返回 Interface（on('line'/'close'）、question、close、setPrompt、prompt、write）
// 通过订阅 input 的 'data' 事件缓冲并按行 emit('line')，兼容 Node 用法

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");

// ---------- 属性名与全局状态 ----------
var k_events: jsc.JSStringRef = undefined;
var k_length: jsc.JSStringRef = undefined;
var k_push: jsc.JSStringRef = undefined;
var k_prototype: jsc.JSStringRef = undefined;
var k_input: jsc.JSStringRef = undefined;
var k_output: jsc.JSStringRef = undefined;
var k_data: jsc.JSStringRef = undefined;
var k_on: jsc.JSStringRef = undefined;
var k_write: jsc.JSStringRef = undefined;
var strings_init: bool = false;

fn ensureStrings() void {
    if (strings_init) return;
    k_events = jsc.JSStringCreateWithUTF8CString("_events");
    k_length = jsc.JSStringCreateWithUTF8CString("length");
    k_push = jsc.JSStringCreateWithUTF8CString("push");
    k_prototype = jsc.JSStringCreateWithUTF8CString("prototype");
    k_input = jsc.JSStringCreateWithUTF8CString("input");
    k_output = jsc.JSStringCreateWithUTF8CString("output");
    k_data = jsc.JSStringCreateWithUTF8CString("data");
    k_on = jsc.JSStringCreateWithUTF8CString("on");
    k_write = jsc.JSStringCreateWithUTF8CString("write");
    strings_init = true;
}

/// 单个 Interface 的内部状态（行缓冲、question 回调等）
const InterfaceState = struct {
    allocator: std.mem.Allocator,
    /// 未完成一行的缓冲
    line_buffer: std.ArrayList(u8),
    /// question() 挂起的回调，收到一行后调用并置空
    question_callback: ?jsc.JSValueRef = null,
    closed: bool = false,
    /// 当前行内容（供 .line 属性）
    current_line: std.ArrayList(u8),
    /// prompt 字符串（setPrompt 设置）
    prompt_str: std.ArrayList(u8),
    input_ref: jsc.JSObjectRef,
    output_ref: ?jsc.JSObjectRef = null,
};

/// 按 input stream 分组：该 stream 上挂了多少个 readline Interface（用于注册/注销 data 监听）
var g_stream_interfaces: std.AutoHashMap(usize, std.ArrayList(jsc.JSObjectRef)) = undefined;
/// 每个 Interface 对象对应的状态
var g_interface_state: std.AutoHashMap(usize, InterfaceState) = undefined;
var g_readline_mutex: std.Thread.Mutex = .{};
var g_readline_init: bool = false;

/// 使用指定 allocator 初始化 readline 全局表；由 getExports 或 ensureReadlineGlobals 首次调用时注入（§1.1 显式 allocator）
fn initReadlineGlobals(allocator: std.mem.Allocator) void {
    g_readline_mutex.lock();
    defer g_readline_mutex.unlock();
    if (g_readline_init) return;
    g_stream_interfaces = std.AutoHashMap(usize, std.ArrayList(jsc.JSObjectRef)).init(allocator);
    g_interface_state = std.AutoHashMap(usize, InterfaceState).init(allocator);
    g_readline_init = true;
}

fn ensureReadlineGlobals() void {
    if (!g_readline_init) initReadlineGlobals(globals.current_allocator orelse std.heap.page_allocator);
}

/// 在 interface 对象上触发 event，传入给定参数（与 events.emit 一致）
fn interfaceEmit(
    ctx: jsc.JSContextRef,
    interface_obj: jsc.JSObjectRef,
    event_name: [*:0]const u8,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
) void {
    const k = jsc.JSStringCreateWithUTF8CString(event_name);
    defer jsc.JSStringRelease(k);
    const events_val = jsc.JSObjectGetProperty(ctx, interface_obj, k_events, null);
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
        _ = jsc.JSObjectCallAsFunction(ctx, fn_obj, interface_obj, argumentCount, arguments, null);
    }
}

/// 将 input 收到的 chunk 喂给所有绑定在该 stream 上的 Interface；§4 缩短持锁：≤32 个 interface 时栈拷贝，避免锁内 clone
fn feedChunkToInterfaces(ctx: jsc.JSContextRef, input_stream_ref: jsc.JSObjectRef, chunk_val: jsc.JSValueRef) void {
    const allocator = globals.current_allocator orelse return;
    const key = @intFromPtr(input_stream_ref);
    var stack_refs: [32]jsc.JSObjectRef = undefined;
    var heap_copy: ?std.ArrayList(jsc.JSObjectRef) = null;
    defer if (heap_copy) |*h| h.deinit(allocator);

    g_readline_mutex.lock();
    const list_opt = g_stream_interfaces.getPtr(key);
    if (list_opt == null) {
        g_readline_mutex.unlock();
        return;
    }
    const list = list_opt.?;
    const n = list.items.len;
    const slice: []const jsc.JSObjectRef = if (n <= 32) blk: {
        @memcpy(stack_refs[0..n], list.items);
        g_readline_mutex.unlock();
        break :blk stack_refs[0..n];
    } else blk: {
        heap_copy = list.clone(allocator) catch {
            g_readline_mutex.unlock();
            return;
        };
        g_readline_mutex.unlock();
        break :blk heap_copy.?.items;
    };

    // chunk 转为 UTF-8 字符串（支持 string 或 Buffer.toString()）
    var chunk_utf8: []const u8 = "";
    const str_ref = jsc.JSValueToStringCopy(ctx, chunk_val, null);
    defer jsc.JSStringRelease(str_ref);
    const max_len = jsc.JSStringGetMaximumUTF8CStringSize(str_ref);
    if (max_len > 0 and max_len <= 1024 * 1024) {
        const buf = allocator.alloc(u8, max_len) catch return;
        defer allocator.free(buf);
        const n2 = jsc.JSStringGetUTF8CString(str_ref, buf.ptr, max_len);
        if (n2 > 0) chunk_utf8 = buf[0 .. n2 - 1];
    }

    for (slice) |iface_ref| {
        feedChunk(ctx, iface_ref, chunk_utf8, allocator);
    }
}

/// 给单个 Interface 追加数据并按行拆分，触发 'line' 与 question 回调
fn feedChunk(ctx: jsc.JSContextRef, interface_ref: jsc.JSObjectRef, chunk_utf8: []const u8, allocator: std.mem.Allocator) void {
    const key = @intFromPtr(interface_ref);
    g_readline_mutex.lock();
    const state_ptr = g_interface_state.getPtr(key);
    if (state_ptr == null or state_ptr.?.closed) {
        g_readline_mutex.unlock();
        return;
    }
    var state = state_ptr.?;
    state.line_buffer.appendSlice(allocator, chunk_utf8) catch {
        g_readline_mutex.unlock();
        return;
    };
    const buf = state.line_buffer.items;
    g_readline_mutex.unlock();

    var start: usize = 0;
    var i: usize = 0;
    while (i < buf.len) {
        if (buf[i] == '\n') {
            const line = buf[start..i];
            const line_str = allocator.dupe(u8, line) catch continue;
            defer allocator.free(line_str);
            // 去掉末尾 \r
            const trimmed = if (line_str.len > 0 and line_str[line_str.len - 1] == '\r') line_str[0 .. line_str.len - 1] else line_str;
            const line_z = allocator.dupeZ(u8, trimmed) catch continue;
            defer allocator.free(line_z);
            const line_js = jsc.JSStringCreateWithUTF8CString(line_z.ptr);
            defer jsc.JSStringRelease(line_js);
            const line_val = jsc.JSValueMakeString(ctx, line_js);

            g_readline_mutex.lock();
            const st = g_interface_state.getPtr(key) orelse {
                g_readline_mutex.unlock();
                return;
            };
            if (st.closed) {
                g_readline_mutex.unlock();
                return;
            }
            st.current_line.clearRetainingCapacity();
            st.current_line.appendSlice(allocator, trimmed) catch {};
            const qcb = st.question_callback;
            if (qcb != null) {
                st.question_callback = null;
            }
            g_readline_mutex.unlock();

            var one: [1]jsc.JSValueRef = .{line_val};
            interfaceEmit(ctx, interface_ref, "line", 1, &one);
            if (qcb) |cb| {
                const fn_obj = jsc.JSValueToObject(ctx, cb, null) orelse continue;
                var one_arg: [1]jsc.JSValueRef = .{line_val};
                _ = jsc.JSObjectCallAsFunction(ctx, fn_obj, interface_ref, 1, &one_arg, null);
            }
            i += 1;
            start = i;
            continue;
        }
        i += 1;
    }

    g_readline_mutex.lock();
    if (g_interface_state.getPtr(key)) |st| {
        if (start > 0 and start <= st.line_buffer.items.len) {
            st.line_buffer.replaceRange(st.allocator, 0, start, "") catch {};
        }
    }
    g_readline_mutex.unlock();
}

/// 全局 data 监听器：input 收到 data 时由 stream 调用，this = input stream，args[0] = chunk
fn globalReadlineDataCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    feedChunkToInterfaces(ctx, thisObject, arguments[0]);
    return jsc.JSValueMakeUndefined(ctx);
}

/// Interface 实例：on(name, fn)
fn interfaceOnCallback(
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
    const name_str = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(name_str);
    const list_val = jsc.JSObjectGetProperty(ctx, events, name_str, null);
    const list_obj = jsc.JSValueToObject(ctx, list_val, null);
    if (list_obj == null) {
        var one: [1]jsc.JSValueRef = .{arguments[1]};
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
    var args: [1]jsc.JSValueRef = .{arguments[1]};
    _ = jsc.JSObjectCallAsFunction(ctx, push_fn, list_obj, 1, &args, null);
    return thisObject;
}

/// Interface 实例：emit(name, ...args)
fn interfaceEmitCallback(
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
    const len: usize = @intFromFloat(jsc.JSValueToNumber(ctx, len_val, null));
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

/// Interface 实例：question(prompt, callback)
fn interfaceQuestionCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const key = @intFromPtr(thisObject);
    g_readline_mutex.lock();
    const state_ptr = g_interface_state.getPtr(key);
    if (state_ptr == null or state_ptr.?.closed) {
        g_readline_mutex.unlock();
        return jsc.JSValueMakeUndefined(ctx);
    }
    var state = state_ptr.?;
    const prompt_val = arguments[0];
    const callback_val = arguments[1];
    jsc.JSValueProtect(ctx, callback_val);
    state.question_callback = callback_val;
    const output_ref = state.output_ref;
    g_readline_mutex.unlock();

    if (output_ref) |out| {
        const prompt_str = jsc.JSValueToStringCopy(ctx, prompt_val, null);
        defer jsc.JSStringRelease(prompt_str);
        const max_len = jsc.JSStringGetMaximumUTF8CStringSize(prompt_str);
        if (max_len > 0 and max_len <= 4096) {
            const buf = allocator.alloc(u8, max_len) catch return jsc.JSValueMakeUndefined(ctx);
            defer allocator.free(buf);
            const n = jsc.JSStringGetUTF8CString(prompt_str, buf.ptr, max_len);
            if (n > 0) {
                const write_val = jsc.JSObjectGetProperty(ctx, out, k_write, null);
                const write_fn = jsc.JSValueToObject(ctx, write_val, null);
                if (write_fn) |wfn| {
                    const str_ref = jsc.JSStringCreateWithUTF8CString(buf.ptr);
                    defer jsc.JSStringRelease(str_ref);
                    const str_val = jsc.JSValueMakeString(ctx, str_ref);
                    var one: [1]jsc.JSValueRef = .{str_val};
                    _ = jsc.JSObjectCallAsFunction(ctx, wfn, out, 1, &one, null);
                }
            }
        }
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// Interface 实例：close()
fn interfaceCloseCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    _ = globals.current_allocator;
    const key = @intFromPtr(thisObject);
    g_readline_mutex.lock();
    const state_opt = g_interface_state.fetchRemove(key);
    if (state_opt == null) {
        g_readline_mutex.unlock();
        return jsc.JSValueMakeUndefined(ctx);
    }
    var state = state_opt.?.value;
    const input_ref = state.input_ref;
    if (state.question_callback) |cb| jsc.JSValueUnprotect(ctx, cb);
    state.line_buffer.deinit(state.allocator);
    state.current_line.deinit(state.allocator);
    state.prompt_str.deinit(state.allocator);

    const stream_key = @intFromPtr(input_ref);
    if (g_stream_interfaces.getPtr(stream_key)) |list| {
        var idx: usize = 0;
        while (idx < list.items.len) : (idx += 1) {
            if (list.items[idx] == thisObject) break;
        }
        if (idx < list.items.len) {
            _ = list.orderedRemove(idx);
            if (list.items.len == 0) {
                _ = g_stream_interfaces.remove(stream_key);
            }
        }
    }
    g_readline_mutex.unlock();

    var no_args: [0]jsc.JSValueRef = undefined;
    interfaceEmit(ctx, thisObject, "close", 0, &no_args);
    return jsc.JSValueMakeUndefined(ctx);
}

/// Interface 实例：setPrompt(prompt)
fn interfaceSetPromptCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const key = @intFromPtr(thisObject);
    g_readline_mutex.lock();
    const state_ptr = g_interface_state.getPtr(key);
    if (state_ptr == null) {
        g_readline_mutex.unlock();
        return jsc.JSValueMakeUndefined(ctx);
    }
    var st = state_ptr.?;
    st.prompt_str.clearRetainingCapacity();
    const prompt_str = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(prompt_str);
    const max_len = jsc.JSStringGetMaximumUTF8CStringSize(prompt_str);
    g_readline_mutex.unlock();
    if (max_len > 0 and max_len <= 1024) {
        const buf = allocator.alloc(u8, max_len) catch return jsc.JSValueMakeUndefined(ctx);
        defer allocator.free(buf);
        const n = jsc.JSStringGetUTF8CString(prompt_str, buf.ptr, max_len);
        if (n > 0) {
            g_readline_mutex.lock();
            st.prompt_str.appendSlice(st.allocator, buf[0 .. n - 1]) catch {};
            g_readline_mutex.unlock();
        }
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// Interface 实例：prompt([preserveCursor])
fn interfacePromptCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const key = @intFromPtr(thisObject);
    g_readline_mutex.lock();
    const state_ptr = g_interface_state.getPtr(key);
    if (state_ptr == null or state_ptr.?.closed) {
        g_readline_mutex.unlock();
        return jsc.JSValueMakeUndefined(ctx);
    }
    const output_ref = state_ptr.?.output_ref;
    const prompt_slice = state_ptr.?.prompt_str.items;
    g_readline_mutex.unlock();
    if (output_ref != null and prompt_slice.len > 0) {
        const out = output_ref.?;
        const str_z = allocator.dupeZ(u8, prompt_slice) catch return jsc.JSValueMakeUndefined(ctx);
        defer allocator.free(str_z);
        const str_ref = jsc.JSStringCreateWithUTF8CString(str_z.ptr);
        defer jsc.JSStringRelease(str_ref);
        const str_val = jsc.JSValueMakeString(ctx, str_ref);
        const write_val = jsc.JSObjectGetProperty(ctx, out, k_write, null);
        const write_fn = jsc.JSValueToObject(ctx, write_val, null);
        if (write_fn) |wfn| {
            var one: [1]jsc.JSValueRef = .{str_val};
            _ = jsc.JSObjectCallAsFunction(ctx, wfn, out, 1, &one, null);
        }
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// Interface 实例：write(data[, key]) — 写入 output 或仅做占位
fn interfaceWriteCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const key = @intFromPtr(thisObject);
    g_readline_mutex.lock();
    const state_ptr = g_interface_state.getPtr(key);
    const out = if (state_ptr != null) state_ptr.?.output_ref else null;
    g_readline_mutex.unlock();
    if (out) |out_obj| {
        const write_val = jsc.JSObjectGetProperty(ctx, out_obj, k_write, null);
        const write_fn = jsc.JSValueToObject(ctx, write_val, null);
        if (write_fn) |wfn| {
            _ = jsc.JSObjectCallAsFunction(ctx, wfn, out_obj, 1, arguments, null);
        }
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// createInterface(options)：options.input 必填，options.output 可选
fn createInterfaceCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const options = jsc.JSValueToObject(ctx, arguments[0], null) orelse return jsc.JSValueMakeUndefined(ctx);
    const input_val = jsc.JSObjectGetProperty(ctx, options, k_input, null);
    const input_obj = jsc.JSValueToObject(ctx, input_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const output_val = jsc.JSObjectGetProperty(ctx, options, k_output, null);
    const output_obj = if (jsc.JSValueIsUndefined(ctx, output_val) or jsc.JSValueIsNull(ctx, output_val)) null else jsc.JSValueToObject(ctx, output_val, null);

    const allocator = globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    ensureStrings();
    ensureReadlineGlobals();

    const iface = jsc.JSObjectMake(ctx, null, null);
    _ = jsc.JSObjectSetProperty(ctx, iface, k_events, jsc.JSObjectMake(ctx, null, null), jsc.kJSPropertyAttributeNone, null);
    common.setMethod(ctx, iface, "on", interfaceOnCallback);
    common.setMethod(ctx, iface, "emit", interfaceEmitCallback);
    common.setMethod(ctx, iface, "question", interfaceQuestionCallback);
    common.setMethod(ctx, iface, "close", interfaceCloseCallback);
    common.setMethod(ctx, iface, "setPrompt", interfaceSetPromptCallback);
    common.setMethod(ctx, iface, "prompt", interfacePromptCallback);
    common.setMethod(ctx, iface, "write", interfaceWriteCallback);

    var line_buf = std.ArrayList(u8).initCapacity(allocator, 256) catch return jsc.JSValueMakeUndefined(ctx);
    var current_line = std.ArrayList(u8).initCapacity(allocator, 256) catch return jsc.JSValueMakeUndefined(ctx);
    var prompt_str = std.ArrayList(u8).initCapacity(allocator, 64) catch return jsc.JSValueMakeUndefined(ctx);
    const state = InterfaceState{
        .allocator = allocator,
        .line_buffer = line_buf,
        .current_line = current_line,
        .prompt_str = prompt_str,
        .input_ref = input_obj,
        .output_ref = output_obj,
    };

    const iface_key = @intFromPtr(iface);
    const stream_key = @intFromPtr(input_obj);
    g_readline_mutex.lock();
    g_interface_state.put(iface_key, state) catch {
        g_readline_mutex.unlock();
        line_buf.deinit(allocator);
        current_line.deinit(allocator);
        prompt_str.deinit(allocator);
        return jsc.JSValueMakeUndefined(ctx);
    };
    const entry = g_stream_interfaces.getOrPut(stream_key) catch {
        g_readline_mutex.unlock();
        _ = g_interface_state.remove(iface_key);
        line_buf.deinit(allocator);
        current_line.deinit(allocator);
        prompt_str.deinit(allocator);
        return jsc.JSValueMakeUndefined(ctx);
    };
    if (!entry.found_existing) {
        entry.value_ptr.* = std.ArrayList(jsc.JSObjectRef).initCapacity(allocator, 4) catch {
            g_readline_mutex.unlock();
            _ = g_interface_state.remove(iface_key);
            line_buf.deinit(allocator);
            current_line.deinit(allocator);
            prompt_str.deinit(allocator);
            return jsc.JSValueMakeUndefined(ctx);
        };
    }
    entry.value_ptr.*.append(allocator, iface) catch {
        g_readline_mutex.unlock();
        _ = g_interface_state.remove(iface_key);
        line_buf.deinit(allocator);
        current_line.deinit(allocator);
        prompt_str.deinit(allocator);
        return jsc.JSValueMakeUndefined(ctx);
    };
    const need_register = entry.found_existing == false;
    g_readline_mutex.unlock();

    if (need_register) {
        const on_val = jsc.JSObjectGetProperty(ctx, input_obj, k_on, null);
        const on_fn = jsc.JSValueToObject(ctx, on_val, null);
        if (on_fn) |ofn| {
            const data_str = jsc.JSStringCreateWithUTF8CString("data");
            defer jsc.JSStringRelease(data_str);
            const data_val = jsc.JSValueMakeString(ctx, data_str);
            const cb_name = jsc.JSStringCreateWithUTF8CString("__readlineData");
            defer jsc.JSStringRelease(cb_name);
            const cb_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, cb_name, globalReadlineDataCallback);
            var two: [2]jsc.JSValueRef = .{ data_val, cb_fn };
            _ = jsc.JSObjectCallAsFunction(ctx, ofn, input_obj, 2, &two, null);
        }
    }

    return iface;
}

/// readline.clearLine(stream, dir[, callback])
fn clearLineCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const stream = jsc.JSValueToObject(ctx, arguments[0], null) orelse return jsc.JSValueMakeUndefined(ctx);
    const dir = @as(i32, @intFromFloat(jsc.JSValueToNumber(ctx, arguments[1], null)));
    _ = dir;
    const write_val = jsc.JSObjectGetProperty(ctx, stream, k_write, null);
    const write_fn = jsc.JSValueToObject(ctx, write_val, null);
    if (write_fn) |wfn| {
        const clear_ansi = jsc.JSStringCreateWithUTF8CString("\x1b[K");
        defer jsc.JSStringRelease(clear_ansi);
        const clear_val = jsc.JSValueMakeString(ctx, clear_ansi);
        var one: [1]jsc.JSValueRef = .{clear_val};
        _ = jsc.JSObjectCallAsFunction(ctx, wfn, stream, 1, &one, null);
    }
    if (argumentCount >= 3) {
        const cb = jsc.JSValueToObject(ctx, arguments[2], null);
        if (cb) |cbfn| {
            var no_args: [0]jsc.JSValueRef = undefined;
            _ = jsc.JSObjectCallAsFunction(ctx, cbfn, stream, 0, &no_args, null);
        }
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// readline.clearScreenDown(stream[, callback])
fn clearScreenDownCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const stream = jsc.JSValueToObject(ctx, arguments[0], null) orelse return jsc.JSValueMakeUndefined(ctx);
    const write_val = jsc.JSObjectGetProperty(ctx, stream, k_write, null);
    const write_fn = jsc.JSValueToObject(ctx, write_val, null);
    if (write_fn) |wfn| {
        const clear_ansi = jsc.JSStringCreateWithUTF8CString("\x1b[J");
        defer jsc.JSStringRelease(clear_ansi);
        const clear_val = jsc.JSValueMakeString(ctx, clear_ansi);
        var one: [1]jsc.JSValueRef = .{clear_val};
        _ = jsc.JSObjectCallAsFunction(ctx, wfn, stream, 1, &one, null);
    }
    if (argumentCount >= 2) {
        const cb = jsc.JSValueToObject(ctx, arguments[1], null);
        if (cb) |cbfn| {
            var no_args: [0]jsc.JSValueRef = undefined;
            _ = jsc.JSObjectCallAsFunction(ctx, cbfn, stream, 0, &no_args, null);
        }
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// readline.cursorTo(stream, x[, y][, callback])
fn cursorToCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const stream = jsc.JSValueToObject(ctx, arguments[0], null) orelse return jsc.JSValueMakeUndefined(ctx);
    const x = @as(i32, @intFromFloat(jsc.JSValueToNumber(ctx, arguments[1], null)));
    var y: i32 = 0;
    var cb_idx: usize = 2;
    if (argumentCount > 2) {
        const num = jsc.JSValueToNumber(ctx, arguments[2], null);
        if (num == num) {
            y = @as(i32, @intFromFloat(num));
            cb_idx = 3;
        }
    }
    const write_val = jsc.JSObjectGetProperty(ctx, stream, k_write, null);
    const write_fn = jsc.JSValueToObject(ctx, write_val, null);
    if (write_fn) |wfn| {
        var buf: [32]u8 = undefined;
        const n = (std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ y + 1, x + 1 }) catch buf[0..0]).len;
        if (n > 0 and n < buf.len) {
            buf[n] = 0;
            const seq_ref = jsc.JSStringCreateWithUTF8CString(&buf);
            defer jsc.JSStringRelease(seq_ref);
            const seq_val = jsc.JSValueMakeString(ctx, seq_ref);
            var one: [1]jsc.JSValueRef = .{seq_val};
            _ = jsc.JSObjectCallAsFunction(ctx, wfn, stream, 1, &one, null);
        }
    }
    if (argumentCount > cb_idx) {
        const cb = jsc.JSValueToObject(ctx, arguments[cb_idx], null);
        if (cb) |cbfn| {
            var no_args: [0]jsc.JSValueRef = undefined;
            _ = jsc.JSObjectCallAsFunction(ctx, cbfn, stream, 0, &no_args, null);
        }
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// readline.moveCursor(stream, dx, dy[, callback])
fn moveCursorCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 3) return jsc.JSValueMakeUndefined(ctx);
    const stream = jsc.JSValueToObject(ctx, arguments[0], null) orelse return jsc.JSValueMakeUndefined(ctx);
    const dx = @as(i32, @intFromFloat(jsc.JSValueToNumber(ctx, arguments[1], null)));
    const dy = @as(i32, @intFromFloat(jsc.JSValueToNumber(ctx, arguments[2], null)));
    const write_val = jsc.JSObjectGetProperty(ctx, stream, k_write, null);
    const write_fn = jsc.JSValueToObject(ctx, write_val, null);
    if (write_fn) |wfn| {
        var buf: [64]u8 = undefined;
        var n: usize = 0;
        if (dx > 0) n += (std.fmt.bufPrint(buf[n..], "\x1b[{d}C", .{dx}) catch buf[n..][0..0]).len
        else if (dx < 0) n += (std.fmt.bufPrint(buf[n..], "\x1b[{d}D", .{-dx}) catch buf[n..][0..0]).len;
        if (dy > 0) n += (std.fmt.bufPrint(buf[n..], "\x1b[{d}B", .{dy}) catch buf[n..][0..0]).len
        else if (dy < 0) n += (std.fmt.bufPrint(buf[n..], "\x1b[{d}A", .{-dy}) catch buf[n..][0..0]).len;
        if (n > 0 and n < buf.len) {
            buf[n] = 0;
            const seq_ref = jsc.JSStringCreateWithUTF8CString(&buf);
            defer jsc.JSStringRelease(seq_ref);
            const seq_val = jsc.JSValueMakeString(ctx, seq_ref);
            var one: [1]jsc.JSValueRef = .{seq_val};
            _ = jsc.JSObjectCallAsFunction(ctx, wfn, stream, 1, &one, null);
        }
    }
    if (argumentCount >= 4) {
        const cb = jsc.JSValueToObject(ctx, arguments[3], null);
        if (cb) |cbfn| {
            var no_args: [0]jsc.JSValueRef = undefined;
            _ = jsc.JSObjectCallAsFunction(ctx, cbfn, stream, 0, &no_args, null);
        }
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// 返回 shu:readline 的 exports（与 node:readline 对齐）
pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    initReadlineGlobals(allocator);
    ensureStrings();
    const exports = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, exports, "createInterface", createInterfaceCallback);
    common.setMethod(ctx, exports, "clearLine", clearLineCallback);
    common.setMethod(ctx, exports, "clearScreenDown", clearScreenDownCallback);
    common.setMethod(ctx, exports, "cursorTo", cursorToCallback);
    common.setMethod(ctx, exports, "moveCursor", moveCursorCallback);
    return exports;
}
