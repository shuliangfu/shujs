// 全局 fetch(url) 注册与 C 回调；需 --allow-net；与 Bun/Deno 统一：返回 Promise<Response>，不阻塞主线程。
// 请求在后台 worker 线程执行，主线程在 runMicrotasks 前通过 drain_fetch_results 收割完成项并 resolve/reject。
// 由 bindings 在具备 RunOptions 时调用注册到 globalThis；本模块不依赖 engine。

const std = @import("std");
const jsc = @import("jsc");
const libs_io = @import("libs_io");
const errors = @import("errors");
const globals = @import("../../../globals.zig");
const common = @import("../../../common.zig");
const promise = @import("../promise.zig");

/// §1.1 显式 allocator 收敛：register 时注入，fetch 回调优先使用
threadlocal var g_fetch_allocator: ?std.mem.Allocator = null;

/// 静态错误文案，worker 在 dupeZ 失败时使用；drain 中不可 free 此切片
const ERR_MSG_FETCH_FAILED: []const u8 = "fetch request failed";
const Request = struct { id: u32, url: []const u8 };
const Result = struct {
    id: u32,
    resp: ?libs_io.http.Response = null,
    err: ?[]const u8 = null,
};
const PendingEntry = struct {
    ctx: jsc.JSGlobalContextRef,
    resolve: jsc.JSValueRef,
    reject: jsc.JSValueRef,
};

/// 无 io 场景下的自旋锁：0=未锁，1=已锁；Zig 0.16 无 std.Thread.Mutex 时使用
const Spinlock = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    fn lock(self: *Spinlock) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) == null) {
            std.Thread.yield() catch {};
        }
    }
    fn unlock(self: *Spinlock) void {
        self.state.store(0, .release);
    }
};

var g_fetch_init_mutex: Spinlock = .{};
var g_fetch_state: ?*FetchState = null;

const FetchState = struct {
    mutex: Spinlock = .{},
    allocator: std.mem.Allocator,
    request_queue: std.ArrayListUnmanaged(Request) = .{},
    result_queue: std.ArrayListUnmanaged(Result) = .{},
    pending: std.AutoHashMapUnmanaged(u32, PendingEntry) = .{},
    next_id: u32 = 1,
    worker: ?std.Thread = null,

    fn init(allocator: std.mem.Allocator) !FetchState {
        const req_q = std.ArrayListUnmanaged(Request).initCapacity(allocator, 0) catch return error.OutOfMemory;
        const res_q = std.ArrayListUnmanaged(Result).initCapacity(allocator, 0) catch return error.OutOfMemory;
        return .{
            .allocator = allocator,
            .request_queue = req_q,
            .result_queue = res_q,
            .pending = .{},
        };
    }

    fn deinit(self: *FetchState) void {
        self.request_queue.deinit(self.allocator);
        self.result_queue.deinit(self.allocator);
        self.pending.deinit(self.allocator);
    }
};

/// 返回全局 FetchState，首次调用时用 allocator 创建并启动 worker；调用方只读使用，不得长期持有
fn getOrCreateState(allocator: std.mem.Allocator) !*FetchState {
    g_fetch_init_mutex.lock();
    defer g_fetch_init_mutex.unlock();
    if (g_fetch_state) |s| return s;
    const state = try allocator.create(FetchState);
    state.* = try FetchState.init(allocator);
    state.worker = try std.Thread.spawn(.{}, workerRun, .{state});
    g_fetch_state = state;
    return state;
}

fn workerRun(state: *FetchState) void {
    while (true) {
        var req: ?Request = null;
        state.mutex.lock();
        if (state.request_queue.items.len > 0) {
            req = state.request_queue.orderedRemove(0);
        }
        state.mutex.unlock();
        if (req) |r| {
            defer state.allocator.free(r.url);
            const resp = libs_io.http.request(state.allocator, r.url, .{
                .method = .GET,
                .max_response_bytes = 2 * 1024 * 1024,
            }) catch {
                state.mutex.lock();
                state.result_queue.append(state.allocator, .{ .id = r.id, .err = state.allocator.dupeZ(u8, ERR_MSG_FETCH_FAILED) catch ERR_MSG_FETCH_FAILED }) catch {};
                state.mutex.unlock();
                continue;
            };
            state.mutex.lock();
            state.result_queue.append(state.allocator, .{ .id = r.id, .resp = resp }) catch {
                libs_io.http.freeResponse(state.allocator, &resp);
                state.result_queue.append(state.allocator, .{ .id = r.id, .err = state.allocator.dupeZ(u8, ERR_MSG_FETCH_FAILED) catch ERR_MSG_FETCH_FAILED }) catch {};
            };
            state.mutex.unlock();
        } else {
            for (0..100) |_| std.Thread.yield() catch {};
        }
    }
}

/// 事件循环每轮在 runMicrotasks 前调用：收割 worker 完成项，在主线程 resolve/reject 对应 Promise
pub fn drainFetchResults(ctx: jsc.JSGlobalContextRef) void {
    const state = g_fetch_state orelse return;
    while (true) {
        var res: ?Result = null;
        state.mutex.lock();
        if (state.result_queue.items.len > 0) {
            res = state.result_queue.orderedRemove(0);
        }
        state.mutex.unlock();
        if (res) |r| {
            const entry = state.pending.fetchRemove(r.id) orelse continue;
            if (r.resp) |*resp| {
                const resp_obj = buildResponseObject(ctx, state.allocator, resp.*);
                libs_io.http.freeResponse(state.allocator, resp);
                var args: [1]jsc.JSValueRef = .{resp_obj};
                _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(entry.value.resolve), null, 1, &args, null);
                jsc.JSValueUnprotect(@ptrCast(entry.value.ctx), entry.value.resolve);
                jsc.JSValueUnprotect(@ptrCast(entry.value.ctx), entry.value.reject);
            } else if (r.err) |err_msg| {
                if (err_msg.ptr != ERR_MSG_FETCH_FAILED.ptr) state.allocator.free(err_msg);
                const err_js = jsc.JSStringCreateWithUTF8CString(err_msg.ptr);
                defer jsc.JSStringRelease(err_js);
                var args: [1]jsc.JSValueRef = .{jsc.JSValueMakeString(ctx, err_js)};
                _ = jsc.JSObjectCallAsFunction(ctx, @ptrCast(entry.value.reject), null, 1, &args, null);
                jsc.JSValueUnprotect(@ptrCast(entry.value.ctx), entry.value.resolve);
                jsc.JSValueUnprotect(@ptrCast(entry.value.ctx), entry.value.reject);
            }
        } else break;
    }
}

fn buildResponseObject(ctx: jsc.JSContextRef, allocator: std.mem.Allocator, resp: libs_io.http.Response) jsc.JSValueRef {
    const status = resp.status;
    const ok = status >= 200 and status < 300;
    const body_slice = resp.body;
    const resp_obj = jsc.JSObjectMake(ctx, null, null);
    const name_ok = jsc.JSStringCreateWithUTF8CString("ok");
    defer jsc.JSStringRelease(name_ok);
    const name_status = jsc.JSStringCreateWithUTF8CString("status");
    defer jsc.JSStringRelease(name_status);
    const name_statusText = jsc.JSStringCreateWithUTF8CString("statusText");
    defer jsc.JSStringRelease(name_statusText);
    const name_body = jsc.JSStringCreateWithUTF8CString("body");
    defer jsc.JSStringRelease(name_body);
    _ = jsc.JSObjectSetProperty(ctx, resp_obj, name_ok, jsc.JSValueMakeBoolean(ctx, ok), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, resp_obj, name_status, jsc.JSValueMakeNumber(ctx, @floatFromInt(status)), jsc.kJSPropertyAttributeNone, null);
    const statusText_z = allocator.dupeZ(u8, resp.status_text) catch "";
    defer if (statusText_z.len > 0) allocator.free(statusText_z);
    const statusText_js = if (statusText_z.len > 0) jsc.JSStringCreateWithUTF8CString(statusText_z.ptr) else jsc.JSStringCreateWithUTF8CString("");
    defer jsc.JSStringRelease(statusText_js);
    _ = jsc.JSObjectSetProperty(ctx, resp_obj, name_statusText, jsc.JSValueMakeString(ctx, statusText_js), jsc.kJSPropertyAttributeNone, null);
    const body_z = if (body_slice.len > 0) allocator.dupeZ(u8, body_slice) catch "" else "";
    defer if (body_z.len > 0) allocator.free(body_z);
    const body_js = jsc.JSStringCreateWithUTF8CString(if (body_z.len > 0) body_z.ptr else "");
    defer jsc.JSStringRelease(body_js);
    _ = jsc.JSObjectSetProperty(ctx, resp_obj, name_body, jsc.JSValueMakeString(ctx, body_js), jsc.kJSPropertyAttributeNone, null);
    common.setMethod(ctx, resp_obj, "text", responseTextCallback);
    common.setMethod(ctx, resp_obj, "json", responseJsonCallback);
    return resp_obj;
}

/// 向全局对象注册 fetch，并注册 drain_fetch_results 供事件循环每轮调用
pub fn register(ctx: jsc.JSGlobalContextRef, allocator: ?std.mem.Allocator) void {
    if (allocator) |a| g_fetch_allocator = a;
    globals.drain_fetch_results = &drainFetchResults;
    const global = jsc.JSContextGetGlobalObject(ctx);
    const name_fetch = jsc.JSStringCreateWithUTF8CString("fetch");
    defer jsc.JSStringRelease(name_fetch);
    const fetch_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, name_fetch, callback);
    _ = jsc.JSObjectSetProperty(ctx, global, name_fetch, fetch_fn, jsc.kJSPropertyAttributeNone, null);
}

/// createWithExecutor 的 Zig 回调：将 resolve/reject 存入 pending[id] 并 Protect
fn fetchOnExecutor(ctx: jsc.JSContextRef, resolve: jsc.JSValueRef, reject: jsc.JSValueRef, user_data: ?*anyopaque) void {
    const p = @as(*const struct { id: u32, state: *FetchState }, @alignCast(@ptrCast(user_data orelse return)));
    jsc.JSValueProtect(@ptrCast(ctx), resolve);
    jsc.JSValueProtect(@ptrCast(ctx), reject);
    p.state.mutex.lock();
    p.state.pending.put(p.state.allocator, p.id, .{ .ctx = @ptrCast(ctx), .resolve = resolve, .reject = reject }) catch {};
    p.state.mutex.unlock();
}

/// Response.text() 的 C 回调：返回 Promise.resolve(this.body)，与标准 fetch Response 一致
fn responseTextCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const k_body = jsc.JSStringCreateWithUTF8CString("body");
    defer jsc.JSStringRelease(k_body);
    const body_val = jsc.JSObjectGetProperty(ctx, thisObject, k_body, null);
    return promise.resolve(ctx, body_val);
}

/// Response.json() 的 C 回调：用全局 JSON.parse(this.body) 解析，返回 Promise.resolve(parsed) 或 parse 失败时 Promise.reject
fn responseJsonCallback(
    ctx: jsc.JSContextRef,
    thisObject: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const k_body = jsc.JSStringCreateWithUTF8CString("body");
    defer jsc.JSStringRelease(k_body);
    const body_val = jsc.JSObjectGetProperty(ctx, thisObject, k_body, null);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_JSON = jsc.JSStringCreateWithUTF8CString("JSON");
    defer jsc.JSStringRelease(k_JSON);
    const JSON_obj = jsc.JSObjectGetProperty(ctx, global, k_JSON, null);
    if (jsc.JSValueIsUndefined(ctx, JSON_obj)) return promise.resolve(ctx, body_val);
    const k_parse = jsc.JSStringCreateWithUTF8CString("parse");
    defer jsc.JSStringRelease(k_parse);
    const parse_fn = jsc.JSObjectGetProperty(ctx, @ptrCast(JSON_obj), k_parse, null);
    if (!jsc.JSObjectIsFunction(ctx, @ptrCast(parse_fn))) return promise.resolve(ctx, body_val);
    var exception: jsc.JSValueRef = undefined;
    var argv: [1]jsc.JSValueRef = .{body_val};
    const parsed = jsc.JSObjectCallAsFunction(
        ctx,
        @ptrCast(parse_fn),
        @ptrCast(JSON_obj),
        1,
        &argv,
        @as(?[*]jsc.JSValueRef, @ptrCast(&exception)),
    );
    if (!jsc.JSValueIsUndefined(ctx, exception)) return promise.reject(ctx, exception);
    return promise.resolve(ctx, parsed);
}

/// fetch 的 C 回调：入队请求、创建 Promise(executor)、返回 Promise，不阻塞；无权限时同步 reject
fn callback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const opts = globals.current_run_options orelse return jsc.JSValueMakeUndefined(ctx);
    const allocator = g_fetch_allocator orelse globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    if (argumentCount == 0) return jsc.JSValueMakeUndefined(ctx);
    const url_val = arguments[0];
    const url_js = jsc.JSValueToStringCopy(ctx, url_val, null);
    defer jsc.JSStringRelease(url_js);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(url_js);
    if (max_sz == 0 or max_sz > 8192) return jsc.JSValueMakeUndefined(ctx);
    const url_buf = allocator.alloc(u8, max_sz) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(url_buf);
    const n = jsc.JSStringGetUTF8CString(url_js, url_buf.ptr, max_sz);
    if (n == 0) return jsc.JSValueMakeUndefined(ctx);
    const url = url_buf[0 .. n - 1];
    if (!opts.permissions.allow_net) {
        errors.reportToStderr(.{ .code = .permission_denied, .message = "fetch requires --allow-net" }) catch {};
        const err_msg = jsc.JSStringCreateWithUTF8CString("fetch requires --allow-net");
        defer jsc.JSStringRelease(err_msg);
        return promise.reject(ctx, jsc.JSValueMakeString(ctx, err_msg));
    }
    const state = getOrCreateState(allocator) catch return jsc.JSValueMakeUndefined(ctx);
    const url_dup = allocator.dupe(u8, url) catch return jsc.JSValueMakeUndefined(ctx);
    var id: u32 = 0;
    state.mutex.lock();
    id = state.next_id;
    state.next_id +%= 1;
    state.request_queue.append(state.allocator, .{ .id = id, .url = url_dup }) catch {
        state.mutex.unlock();
        allocator.free(url_dup);
        return jsc.JSValueMakeUndefined(ctx);
    };
    state.mutex.unlock();

    var payload = .{ .id = id, .state = state };
    return promise.createWithExecutor(ctx, fetchOnExecutor, @ptrCast(&payload));
}
