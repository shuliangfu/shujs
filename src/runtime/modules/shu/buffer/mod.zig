// shu:buffer 内置：Node 风格 Buffer，纯 Zig + JSC Typed Array C API
// 提供 Buffer.alloc、allocUnsafe、from、isBuffer、concat 及构造函数，对应 node:buffer
// 零拷贝：from(string/array)、concat、以及 Shu.fs.readSync(..., { encoding: null }) 均用 JSObjectMakeTypedArrayWithBytesNoCopy 将 Zig 内存直接交给 JS，避免二次拷贝。
// 池化：Buffer.alloc(BUFFER_POOL_CHUNK_SIZE) 时从 io_core ChunkAllocator 取块，GC 时归还，减少 allocator 压力。

const std = @import("std");
const jsc = @import("jsc");
const io_core = @import("io_core");
const common = @import("../../../common.zig");
const globals = @import("../../../globals.zig");

/// 池块大小（64KB），与 server 侧 HighPerfIO 常用块一致；仅当 alloc(size) 且 size == 此值时从池取
const BUFFER_POOL_CHUNK_SIZE: usize = 64 * 1024;
/// 池总大小（4MB），约 64 块
const BUFFER_POOL_SIZE: usize = 4 * 1024 * 1024;

var g_buffer_pool: ?io_core.api.BufferPool = null;
var g_chunk_allocator: ?io_core.api.ChunkAllocator = null;
var g_buffer_pool_initialized: bool = false;

/// §1.1 显式 allocator 收敛：getExports 时注入，from/alloc/concat 优先使用；未注入时回退 current_allocator
threadlocal var g_buffer_allocator: ?std.mem.Allocator = null;

/// 池块归还上下文：JSC 回收时 release 回 ChunkAllocator
const PoolChunkContext = struct {
    allocator: std.mem.Allocator,
    chunk_allocator: *io_core.api.ChunkAllocator,
    chunk_index: usize,
};
fn poolChunkDeallocator(bytes: *anyopaque, deallocator_context: ?*anyopaque) callconv(.c) void {
    _ = bytes;
    const ctx = @as(*PoolChunkContext, @ptrCast(@alignCast(deallocator_context orelse return)));
    ctx.chunk_allocator.release(ctx.chunk_index);
    ctx.allocator.destroy(ctx);
}

/// JSC 回收 ArrayBuffer/TypedArray 时调用的释放回调；context 为 *DeallocContext
fn bytesDeallocator(bytes: *anyopaque, deallocator_context: ?*anyopaque) callconv(.c) void {
    _ = bytes;
    const ctx = @as(*DeallocContext, @ptrCast(@alignCast(deallocator_context orelse return)));
    ctx.allocator.free(ctx.slice);
    ctx.allocator.destroy(ctx);
}

/// §3.1 NoCopy 时使用：不释放内存（backing store 属原 TypedArray），调用方须保持原引用、不得 detach/修改
fn noOpDeallocator(_: *anyopaque, _: ?*anyopaque) callconv(.c) void {}

const DeallocContext = struct {
    allocator: std.mem.Allocator,
    slice: []u8,
};

/// Buffer 构造函数：new Buffer(size) 或 Buffer(size) => alloc；Buffer(string) / Buffer(array) => from
fn bufferConstructor(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount == 0) return jsc.JSValueMakeUndefined(ctx);
    const first = arguments[0];
    if (jsc.JSValueIsUndefined(ctx, first)) return jsc.JSValueMakeUndefined(ctx);
    const n = jsc.JSValueToNumber(ctx, first, null);
    const global = jsc.JSContextGetGlobalObject(ctx);
    var exc: jsc.JSValueRef = undefined;
    if (n >= 0 and n == @floor(n) and n <= 0x7FFFFFFF) {
        return allocCallback(ctx, global, global, 1, arguments, @ptrCast(&exc));
    }
    return fromCallback(ctx, global, global, argumentCount, arguments, @ptrCast(&exc));
}

/// Buffer.alloc(size [, fill [, encoding]])：创建零填充的 Uint8Array；size==64KB 时从 ChunkAllocator 池取块（NoCopy 归还），fill 暂不实现
fn allocCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const n = jsc.JSValueToNumber(ctx, arguments[0], null);
    if (n < 0 or n != @floor(n)) return jsc.JSValueMakeUndefined(ctx);
    const size = @min(0x7FFFFFFF, @as(usize, @intFromFloat(n)));
    const allocator = g_buffer_allocator orelse globals.current_allocator orelse {
        const obj = jsc.JSObjectMakeTypedArray(ctx, .Uint8Array, size);
        return if (obj != null) obj.? else jsc.JSValueMakeUndefined(ctx);
    };

    if (size == BUFFER_POOL_CHUNK_SIZE) {
        if (!g_buffer_pool_initialized) {
            g_buffer_pool = io_core.api.BufferPool.allocAligned(allocator, BUFFER_POOL_SIZE) catch null;
            if (g_buffer_pool) |*pool| {
                g_chunk_allocator = io_core.api.ChunkAllocator.init(allocator, pool, BUFFER_POOL_CHUNK_SIZE) catch blk: {
                    pool.deinit();
                    g_buffer_pool = null;
                    break :blk null;
                };
            }
            g_buffer_pool_initialized = true;
        }
        if (g_chunk_allocator) |*chunk_alloc| {
            const opt_index = chunk_alloc.take();
            if (opt_index) |chunk_index| {
                const chunk_slice = chunk_alloc.chunkSlice(chunk_index);
                if (chunk_slice.len == BUFFER_POOL_CHUNK_SIZE) {
                    const chunk_ctx = allocator.create(PoolChunkContext) catch null;
                    if (chunk_ctx) |c| {
                        c.* = .{
                            .allocator = allocator,
                            .chunk_allocator = chunk_alloc,
                            .chunk_index = chunk_index,
                        };
                        const arr = jsc.JSObjectMakeTypedArrayWithBytesNoCopy(
                            ctx,
                            .Uint8Array,
                            @ptrCast(@constCast(chunk_slice.ptr)),
                            BUFFER_POOL_CHUNK_SIZE,
                            poolChunkDeallocator,
                            c,
                            @ptrCast(&exception[0]),
                        );
                        if (arr != null) {
                            @memset(@as([*]u8, @ptrCast(@constCast(chunk_slice.ptr)))[0..BUFFER_POOL_CHUNK_SIZE], 0);
                            return arr.?;
                        }
                        allocator.destroy(c);
                    }
                    chunk_alloc.release(chunk_index);
                }
            }
        }
    }

    const obj = jsc.JSObjectMakeTypedArray(ctx, .Uint8Array, size);
    return if (obj != null) obj.? else jsc.JSValueMakeUndefined(ctx);
}

/// Buffer.allocUnsafe(size)：当前与 alloc 相同（JSC 侧零初始化）
fn allocUnsafeCallback(
    ctx: jsc.JSContextRef,
    this_obj: jsc.JSObjectRef,
    callee: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    exception: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    return allocCallback(ctx, this_obj, callee, argumentCount, arguments, exception);
}

/// Buffer.from(value [, encodingOrOffset [, length]] | value, options)：支持 TypedArray/ArrayBuffer、array、string。
/// options 可为 { copy: false }：对 TypedArray 零拷贝引用其 backing store，不 dupe；约定：使用期间须保持原 TypedArray 引用，不得 detach/修改（§3.1）
fn fromCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = g_buffer_allocator orelse globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const value = arguments[0];
    var exception: ?jsc.JSValueRef = null;

    const typ = jsc.JSValueGetTypedArrayType(ctx, value, @ptrCast(&exception));
    if (typ != .None) {
        const obj = jsc.JSValueToObject(ctx, value, null) orelse return jsc.JSValueMakeUndefined(ctx);
        const byte_len = jsc.JSObjectGetTypedArrayByteLength(ctx, obj);
        const src_ptr = jsc.JSObjectGetTypedArrayBytesPtr(ctx, obj, null) orelse return jsc.JSValueMakeUndefined(ctx);
        // §3.1 Buffer.from(ta, { copy: false })：零拷贝引用，noOpDeallocator 回收时不释放；约定调用方保持原 TypedArray 引用
        const want_no_copy = argumentCount >= 2 and (jsc.JSValueToObject(ctx, arguments[1], null) != null) and blk: {
            const opts = jsc.JSValueToObject(ctx, arguments[1], null) orelse break :blk false;
            const k_copy = jsc.JSStringCreateWithUTF8CString("copy");
            defer jsc.JSStringRelease(k_copy);
            const v = jsc.JSObjectGetProperty(ctx, opts, k_copy, null);
            break :blk !jsc.JSValueIsUndefined(ctx, v) and !jsc.JSValueToBoolean(ctx, v);
        };
        if (want_no_copy and byte_len > 0) {
            const out = jsc.JSObjectMakeTypedArrayWithBytesNoCopy(
                ctx,
                .Uint8Array,
                @constCast(src_ptr),
                byte_len,
                noOpDeallocator,
                null,
                @ptrCast(&exception),
            );
            return if (out != null) out.? else jsc.JSValueMakeUndefined(ctx);
        }
        const copy = allocator.dupe(u8, @as([*]const u8, @ptrCast(src_ptr))[0..byte_len]) catch return jsc.JSValueMakeUndefined(ctx);
        var dc = allocator.create(DeallocContext) catch {
            allocator.free(copy);
            return jsc.JSValueMakeUndefined(ctx);
        };
        dc.allocator = allocator;
        dc.slice = copy;
        const out = jsc.JSObjectMakeTypedArrayWithBytesNoCopy(
            ctx,
            .Uint8Array,
            copy.ptr,
            copy.len,
            bytesDeallocator,
            dc,
            @ptrCast(&exception),
        );
        if (out == null) {
            allocator.free(copy);
            allocator.destroy(dc);
        }
        return if (out != null) out.? else jsc.JSValueMakeUndefined(ctx);
    }

    const obj = jsc.JSValueToObject(ctx, value, null);
    if (obj != null) {
        const k_length = jsc.JSStringCreateWithUTF8CString("length");
        defer jsc.JSStringRelease(k_length);
        const len_val = jsc.JSObjectGetProperty(ctx, obj.?, k_length, null);
        const len_f = jsc.JSValueToNumber(ctx, len_val, null);
        if (len_f >= 0 and len_f == @floor(len_f) and len_f <= 0x7FFFFFFF) {
            const len = @as(usize, @intFromFloat(len_f));
            // §3.1 小数组用栈缓冲逐元素读，再 dupe 交 JSC，减少热路径堆分配
            const STACK_BUF_LEN = 256;
            if (len <= STACK_BUF_LEN) {
                var stack_buf: [STACK_BUF_LEN]u8 = undefined;
                for (0..len) |i| {
                    const elem = jsc.JSObjectGetPropertyAtIndex(ctx, obj.?, @intCast(i), null);
                    const v = jsc.JSValueToNumber(ctx, elem, null);
                    stack_buf[i] = @intCast(@min(255, @max(0, @as(i32, @intFromFloat(v)))));
                }
                const slice = allocator.dupe(u8, stack_buf[0..len]) catch return jsc.JSValueMakeUndefined(ctx);
                var dc = allocator.create(DeallocContext) catch {
                    allocator.free(slice);
                    return jsc.JSValueMakeUndefined(ctx);
                };
                dc.allocator = allocator;
                dc.slice = slice;
                const out = jsc.JSObjectMakeTypedArrayWithBytesNoCopy(
                    ctx,
                    .Uint8Array,
                    slice.ptr,
                    slice.len,
                    bytesDeallocator,
                    dc,
                    @ptrCast(&exception),
                );
                if (out == null) {
                    allocator.free(slice);
                    allocator.destroy(dc);
                }
                return if (out != null) out.? else jsc.JSValueMakeUndefined(ctx);
            }
            const slice = allocator.alloc(u8, len) catch return jsc.JSValueMakeUndefined(ctx);
            for (0..len) |i| {
                const elem = jsc.JSObjectGetPropertyAtIndex(ctx, obj.?, @intCast(i), null);
                const v = jsc.JSValueToNumber(ctx, elem, null);
                slice[i] = @intCast(@min(255, @max(0, @as(i32, @intFromFloat(v)))));
            }
            var dc = allocator.create(DeallocContext) catch {
                allocator.free(slice);
                return jsc.JSValueMakeUndefined(ctx);
            };
            dc.allocator = allocator;
            dc.slice = slice;
            const out = jsc.JSObjectMakeTypedArrayWithBytesNoCopy(
                ctx,
                .Uint8Array,
                slice.ptr,
                slice.len,
                bytesDeallocator,
                dc,
                @ptrCast(&exception),
            );
            if (out == null) {
                allocator.free(slice);
                allocator.destroy(dc);
            }
            return if (out != null) out.? else jsc.JSValueMakeUndefined(ctx);
        }
    }

    const str_ref = jsc.JSValueToStringCopy(ctx, value, @ptrCast(&exception));
    defer if (@intFromPtr(str_ref) != 0) jsc.JSStringRelease(str_ref);
    if (@intFromPtr(str_ref) != 0) {
        const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(str_ref);
        if (max_sz > 0 and max_sz <= 0x7FFFFFFF) {
            const buf = allocator.alloc(u8, max_sz) catch return jsc.JSValueMakeUndefined(ctx);
            defer allocator.free(buf);
            const n = jsc.JSStringGetUTF8CString(str_ref, buf.ptr, max_sz);
            const content_len = if (n > 0) n - 1 else 0;
            const copy = allocator.dupe(u8, buf[0..content_len]) catch return jsc.JSValueMakeUndefined(ctx);
            var dc = allocator.create(DeallocContext) catch {
                allocator.free(copy);
                return jsc.JSValueMakeUndefined(ctx);
            };
            dc.allocator = allocator;
            dc.slice = copy;
            const out = jsc.JSObjectMakeTypedArrayWithBytesNoCopy(
                ctx,
                .Uint8Array,
                copy.ptr,
                copy.len,
                bytesDeallocator,
                dc,
                @ptrCast(&exception),
            );
            if (out == null) {
                allocator.free(copy);
                allocator.destroy(dc);
            }
            return if (out != null) out.? else jsc.JSValueMakeUndefined(ctx);
        }
    }
    return jsc.JSValueMakeUndefined(ctx);
}

/// Buffer.isBuffer(obj)：是否为 Uint8Array（本实现将 Uint8Array 视为 Buffer）
fn isBufferCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return jsc.JSValueMakeBoolean(ctx, false);
    const typ = jsc.JSValueGetTypedArrayType(ctx, arguments[0], null);
    return jsc.JSValueMakeBoolean(ctx, typ == .Uint8Array);
}

/// Buffer.concat(list [, totalLength])：Zig 分配一块内存，拷贝所有 list 项后通过 NoCopy 交给 JS，零拷贝暴露给 JS 侧
fn concatCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const allocator = g_buffer_allocator orelse globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    if (argumentCount < 1) return jsc.JSValueMakeUndefined(ctx);
    const list_val = arguments[0];
    const list_obj = jsc.JSValueToObject(ctx, list_val, null) orelse return jsc.JSValueMakeUndefined(ctx);
    const k_length = jsc.JSStringCreateWithUTF8CString("length");
    defer jsc.JSStringRelease(k_length);
    const len_val = jsc.JSObjectGetProperty(ctx, list_obj, k_length, null);
    var total: usize = 0;
    const list_len_raw = jsc.JSValueToNumber(ctx, len_val, null);
    const list_len = @min(1024 * 1024, @max(0, @as(usize, @intFromFloat(list_len_raw))));
    if (list_len == 0) {
        const empty = jsc.JSObjectMakeTypedArray(ctx, .Uint8Array, 0);
        return if (empty != null) empty.? else jsc.JSValueMakeUndefined(ctx);
    }
    var lengths = allocator.alloc(usize, list_len) catch return jsc.JSValueMakeUndefined(ctx);
    defer allocator.free(lengths);
    for (0..list_len) |i| {
        const item = jsc.JSObjectGetPropertyAtIndex(ctx, list_obj, @intCast(i), null);
        const obj = jsc.JSValueToObject(ctx, item, null);
        if (obj == null) {
            lengths[i] = 0;
            continue;
        }
        const byte_len = jsc.JSObjectGetTypedArrayByteLength(ctx, obj.?);
        lengths[i] = byte_len;
        total += byte_len;
    }
    if (argumentCount >= 2) {
        const want = @as(usize, @intFromFloat(jsc.JSValueToNumber(ctx, arguments[1], null)));
        if (want <= total) total = want;
    }
    const out_slice = allocator.alloc(u8, total) catch return jsc.JSValueMakeUndefined(ctx);
    var offset: usize = 0;
    for (0..list_len) |i| {
        if (offset >= total) break;
        const item = jsc.JSObjectGetPropertyAtIndex(ctx, list_obj, @intCast(i), null);
        const obj = jsc.JSValueToObject(ctx, item, null) orelse continue;
        const byte_len = lengths[i];
        if (byte_len == 0) continue;
        const copy_len = @min(byte_len, total - offset);
        const src_ptr = jsc.JSObjectGetTypedArrayBytesPtr(ctx, obj, null) orelse continue;
        @memcpy(out_slice[offset..][0..copy_len], @as([*]const u8, @ptrCast(src_ptr))[0..copy_len]);
        offset += copy_len;
    }
    var dc = allocator.create(DeallocContext) catch {
        allocator.free(out_slice);
        return jsc.JSValueMakeUndefined(ctx);
    };
    dc.allocator = allocator;
    dc.slice = out_slice;
    var exception: ?jsc.JSValueRef = null;
    const out = jsc.JSObjectMakeTypedArrayWithBytesNoCopy(
        ctx,
        .Uint8Array,
        out_slice.ptr,
        out_slice.len,
        bytesDeallocator,
        dc,
        @ptrCast(&exception),
    );
    if (out == null) {
        allocator.free(out_slice);
        allocator.destroy(dc);
        return jsc.JSValueMakeUndefined(ctx);
    }
    return out.?;
}

/// 返回 shu:buffer 的 exports：{ Buffer, kMaxLength }，Buffer 上挂 alloc、allocUnsafe、from、isBuffer、concat、poolSize
/// §1.1 显式 allocator：将传入的 allocator 注入 g_buffer_allocator，供 from/alloc/concat 使用
pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    g_buffer_allocator = allocator;
    const k_Buffer = jsc.JSStringCreateWithUTF8CString("Buffer");
    defer jsc.JSStringRelease(k_Buffer);
    const k_kMaxLength = jsc.JSStringCreateWithUTF8CString("kMaxLength");
    defer jsc.JSStringRelease(k_kMaxLength);
    const ctor = jsc.JSObjectMakeFunctionWithCallback(ctx, k_Buffer, bufferConstructor);
    const buffer_ctor_obj = jsc.JSValueToObject(ctx, ctor, null) orelse return jsc.JSValueMakeUndefined(ctx);
    common.setMethod(ctx, buffer_ctor_obj, "alloc", allocCallback);
    common.setMethod(ctx, buffer_ctor_obj, "allocUnsafe", allocUnsafeCallback);
    common.setMethod(ctx, buffer_ctor_obj, "from", fromCallback);
    common.setMethod(ctx, buffer_ctor_obj, "isBuffer", isBufferCallback);
    common.setMethod(ctx, buffer_ctor_obj, "concat", concatCallback);
    const k_poolSize = jsc.JSStringCreateWithUTF8CString("poolSize");
    defer jsc.JSStringRelease(k_poolSize);
    _ = jsc.JSObjectSetProperty(ctx, buffer_ctor_obj, k_poolSize, jsc.JSValueMakeNumber(ctx, 8192), jsc.kJSPropertyAttributeNone, null);
    const exports = jsc.JSObjectMake(ctx, null, null);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_Buffer, ctor, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_kMaxLength, jsc.JSValueMakeNumber(ctx, 0x7FFFFFFF), jsc.kJSPropertyAttributeNone, null);
    return exports;
}
