// shu:diagnostics_channel — 与 node:diagnostics_channel API 兼容的命名通道 pub/sub，纯 Zig 实现
// channel(name)、subscribe(name, fn)、unsubscribe(name, fn)、hasSubscribers(name)；Channel#subscribe/unsubscribe/publish/hasSubscribers

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");

/// 单个订阅者：保存 JS 回调的 ctx 与 ref，订阅时 Protect、取消时 Unprotect
const Subscriber = struct { ctx: jsc.JSContextRef, ref: jsc.JSValueRef };

/// 某命名通道的订阅者列表（Zig 0.15：ArrayList 用 initCapacity/append(allocator, x)）
const ChannelState = struct {
    subscribers: std.ArrayList(Subscriber),
    fn init(allocator: std.mem.Allocator) ChannelState {
        return .{ .subscribers = std.ArrayList(Subscriber).initCapacity(allocator, 0) catch return .{ .subscribers = std.ArrayList(Subscriber).empty } };
    }
    fn deinit(self: *ChannelState) void {
        self.subscribers.deinit();
    }
};

/// 全局：通道名 -> ChannelState；首次使用时用 globals.current_allocator 初始化
var g_allocator: ?std.mem.Allocator = null;
var g_channels: ?std.StringHashMap(ChannelState) = null;
var g_lock: std.Thread.Mutex = .{};

fn ensureChannels() ?std.mem.Allocator {
    const allocator = globals.current_allocator orelse return null;
    g_lock.lock();
    defer g_lock.unlock();
    if (g_channels == null) {
        g_allocator = allocator;
        g_channels = std.StringHashMap(ChannelState).init(allocator);
    }
    return g_allocator;
}

/// 从 JS 值取 UTF-8 名称，调用方负责 free 返回值（若返回非 null）
fn getNameFromArg(allocator: std.mem.Allocator, ctx: jsc.JSContextRef, val: jsc.JSValueRef) ?[]const u8 {
    const str_ref = jsc.JSValueToStringCopy(ctx, val, null);
    defer jsc.JSStringRelease(str_ref);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(str_ref);
    if (max_sz == 0 or max_sz > 4096) return null;
    const buf = allocator.alloc(u8, max_sz) catch return null;
    const n = jsc.JSStringGetUTF8CString(str_ref, buf.ptr, max_sz);
    if (n == 0) {
        allocator.free(buf);
        return null;
    }
    return allocator.dupe(u8, buf[0 .. n - 1]) catch {
        allocator.free(buf);
        return null;
    };
}

/// 从 channel 对象上读取 __name 属性并转为 []const u8，调用方 free
fn getChannelNameFromThis(allocator: std.mem.Allocator, ctx: jsc.JSContextRef, this_obj: jsc.JSObjectRef) ?[]const u8 {
    const k_name = jsc.JSStringCreateWithUTF8CString("__name");
    defer jsc.JSStringRelease(k_name);
    const name_val = jsc.JSObjectGetProperty(ctx, this_obj, k_name, null);
    if (jsc.JSValueIsUndefined(ctx, name_val)) return null;
    return getNameFromArg(allocator, ctx, name_val);
}

/// 模块级 channel(name)：返回命名通道对象，同 name 共享同一 ChannelState；map 持有 key 所有权
fn channelCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const allocator = ensureChannels() orelse return jsc.JSValueMakeUndefined(ctx);
    const name = getNameFromArg(allocator, ctx, arguments[0]) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(name);
    const key = allocator.dupe(u8, name) catch return jsc.JSValueMakeUndefined(ctx);
    g_lock.lock();
    var channels = g_channels.?;
    const gop = channels.getOrPut(key) catch {
        allocator.free(key);
        g_lock.unlock();
        return jsc.JSValueMakeUndefined(ctx);
    };
    if (!gop.found_existing) {
        gop.value_ptr.* = ChannelState.init(allocator);
    } else {
        allocator.free(key);
    }
    g_lock.unlock();
    const channel_obj = jsc.JSObjectMake(ctx, null, null);
    const k_priv = jsc.JSStringCreateWithUTF8CString("__name");
    defer jsc.JSStringRelease(k_priv);
    _ = jsc.JSObjectSetProperty(ctx, channel_obj, k_priv, arguments[0], jsc.kJSPropertyAttributeNone, null);
    common.setMethod(ctx, channel_obj, "subscribe", channelSubscribeCallback);
    common.setMethod(ctx, channel_obj, "unsubscribe", channelUnsubscribeCallback);
    common.setMethod(ctx, channel_obj, "publish", channelPublishCallback);
    common.setMethod(ctx, channel_obj, "hasSubscribers", channelHasSubscribersCallback);
    return channel_obj;
}

/// 模块级 subscribe(name, onMessage)
fn subscribeCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const allocator = ensureChannels() orelse return jsc.JSValueMakeUndefined(ctx);
    const name = getNameFromArg(allocator, ctx, arguments[0]) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(name);
    const on_message = arguments[1];
    const on_obj = jsc.JSValueToObject(ctx, on_message, null) orelse return jsc.JSValueMakeUndefined(ctx);
    if (!jsc.JSObjectIsFunction(ctx, on_obj)) return jsc.JSValueMakeUndefined(ctx);
    const key = allocator.dupe(u8, name) catch return jsc.JSValueMakeUndefined(ctx);
    g_lock.lock();
    var channels = g_channels.?;
    const gop = channels.getOrPut(key) catch {
        allocator.free(key);
        g_lock.unlock();
        return jsc.JSValueMakeUndefined(ctx);
    };
    if (!gop.found_existing) {
        gop.value_ptr.* = ChannelState.init(allocator);
    } else {
        allocator.free(key);
    }
    gop.value_ptr.subscribers.append(allocator, .{ .ctx = ctx, .ref = on_message }) catch {
        g_lock.unlock();
        return jsc.JSValueMakeUndefined(ctx);
    };
    jsc.JSValueProtect(ctx, on_message);
    g_lock.unlock();
    return jsc.JSValueMakeUndefined(ctx);
}

/// 模块级 unsubscribe(name, onMessage)
fn unsubscribeCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return jsc.JSValueMakeUndefined(ctx);
    const allocator = ensureChannels() orelse return jsc.JSValueMakeUndefined(ctx);
    const name = getNameFromArg(allocator, ctx, arguments[0]) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(name);
    const on_message = arguments[1];
    g_lock.lock();
    if (g_channels) |*channels| {
        if (channels.getPtr(name)) |state| {
            var i: usize = 0;
            while (i < state.subscribers.items.len) {
                if (state.subscribers.items[i].ref == on_message) {
                    jsc.JSValueUnprotect(state.subscribers.items[i].ctx, state.subscribers.items[i].ref);
                    _ = state.subscribers.orderedRemove(i);
                    break;
                }
                i += 1;
            }
        }
    }
    g_lock.unlock();
    return jsc.JSValueMakeUndefined(ctx);
}

/// 模块级 hasSubscribers(name)
fn hasSubscribersCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeBoolean(ctx, false);
    const allocator = ensureChannels() orelse return jsc.JSValueMakeBoolean(ctx, false);
    const name = getNameFromArg(allocator, ctx, arguments[0]) orelse return jsc.JSValueMakeBoolean(ctx, false);
    defer allocator.free(name);
    g_lock.lock();
    const has = if (g_channels) |*channels| blk: {
        break :blk if (channels.get(name)) |state| state.subscribers.items.len > 0 else false;
    } else false;
    g_lock.unlock();
    return jsc.JSValueMakeBoolean(ctx, has);
}

/// Channel 实例 subscribe(onMessage)
fn channelSubscribeCallback(
    ctx: jsc.JSContextRef,
    this_obj: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const allocator = ensureChannels() orelse return jsc.JSValueMakeUndefined(ctx);
    const name = getChannelNameFromThis(allocator, ctx, this_obj) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(name);
    const on_message = arguments[0];
    const on_obj = jsc.JSValueToObject(ctx, on_message, null) orelse return jsc.JSValueMakeUndefined(ctx);
    if (!jsc.JSObjectIsFunction(ctx, on_obj)) return jsc.JSValueMakeUndefined(ctx);
    g_lock.lock();
    if (g_channels) |*channels| {
        if (channels.getPtr(name)) |state| {
            state.subscribers.append(allocator, .{ .ctx = ctx, .ref = on_message }) catch {
                g_lock.unlock();
                return jsc.JSValueMakeUndefined(ctx);
            };
            jsc.JSValueProtect(ctx, on_message);
        }
    }
    g_lock.unlock();
    return jsc.JSValueMakeUndefined(ctx);
}

/// Channel 实例 unsubscribe(onMessage)
fn channelUnsubscribeCallback(
    ctx: jsc.JSContextRef,
    this_obj: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const allocator = ensureChannels() orelse return jsc.JSValueMakeUndefined(ctx);
    const name = getChannelNameFromThis(allocator, ctx, this_obj) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(name);
    const on_message = arguments[0];
    g_lock.lock();
    if (g_channels) |*channels| {
        if (channels.getPtr(name)) |state| {
            var i: usize = 0;
            while (i < state.subscribers.items.len) {
                if (state.subscribers.items[i].ref == on_message) {
                    jsc.JSValueUnprotect(state.subscribers.items[i].ctx, state.subscribers.items[i].ref);
                    _ = state.subscribers.orderedRemove(i);
                    break;
                }
                i += 1;
            }
        }
    }
    g_lock.unlock();
    return jsc.JSValueMakeUndefined(ctx);
}

/// Channel 实例 publish(message)：同步调用所有订阅者 (message, channelName)
fn channelPublishCallback(
    ctx: jsc.JSContextRef,
    this_obj: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = ensureChannels() orelse return jsc.JSValueMakeUndefined(ctx);
    const name = getChannelNameFromThis(allocator, ctx, this_obj) orelse return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(name);
    const message = if (argumentCount >= 1) arguments[0] else jsc.JSValueMakeUndefined(ctx);
    const name_js = jsc.JSStringCreateWithUTF8CString(name.ptr);
    defer jsc.JSStringRelease(name_js);
    const name_val = jsc.JSValueMakeString(ctx, name_js);
    g_lock.lock();
    const list = if (g_channels) |*channels| blk: {
        const state = channels.getPtr(name) orelse {
            g_lock.unlock();
            return jsc.JSValueMakeUndefined(ctx);
        };
        break :blk state.subscribers.items;
    } else {
        g_lock.unlock();
        return jsc.JSValueMakeUndefined(ctx);
    };
    const copy = allocator.dupe(Subscriber, list) catch {
        g_lock.unlock();
        return jsc.JSValueMakeUndefined(ctx);
    };
    defer allocator.free(copy);
    g_lock.unlock();
    for (copy) |sub| {
        var args = [_]jsc.JSValueRef{ message, name_val };
        _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(sub.ref), this_obj, 2, &args, null);
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// Channel 实例 hasSubscribers()：返回是否有订阅者（Node 为只读属性 hasSubscribers，此处用方法兼容）
fn channelHasSubscribersCallback(
    ctx: jsc.JSContextRef,
    this_obj: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = ensureChannels() orelse return jsc.JSValueMakeBoolean(ctx, false);
    const name = getChannelNameFromThis(allocator, ctx, this_obj) orelse return jsc.JSValueMakeBoolean(ctx, false);
    defer allocator.free(name);
    g_lock.lock();
    const has = if (g_channels) |*channels| blk: {
        break :blk if (channels.get(name)) |state| state.subscribers.items.len > 0 else false;
    } else false;
    g_lock.unlock();
    return jsc.JSValueMakeBoolean(ctx, has);
}

/// 返回 shu:diagnostics_channel 的 exports，与 node:diagnostics_channel API 一致
pub fn getExports(ctx: jsc.JSContextRef, _: std.mem.Allocator) jsc.JSValueRef {
    const exports = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, exports, "channel", channelCallback);
    common.setMethod(ctx, exports, "subscribe", subscribeCallback);
    common.setMethod(ctx, exports, "unsubscribe", unsubscribeCallback);
    common.setMethod(ctx, exports, "hasSubscribers", hasSubscribersCallback);
    return exports;
}
