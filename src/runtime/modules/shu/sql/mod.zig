// shu:sql — 与 Bun SQL API 点位兼容的占位；同时兼容 MySQL、MariaDB、PostgreSQL（Bun 提供 import { sql, SQL } from "bun" 统一接口）
//
// ========== 后端兼容 ==========
//
// MySQL 与 MariaDB 协议/方言一致，视为同一类后端；PostgreSQL 为另一类。实现时按 connectionString 或
// options 区分：postgresql://、mysql://、mariadb:// 等，分别对接对应驱动并统一 tagged template 与连接池语义。
//
// ========== API 点位（Bun 兼容） ==========
//
// | 导出 | 说明 |
// |------|------|
// | sql  | 默认 PostgreSQL tagged template，用法 sql`SELECT ...`；占位调用抛 not implemented |
// | SQL  | 类，new SQL(connectionString) 或 new SQL(options)，实例可当 tagged template；占位同 |
//
// 实现时需对接真实驱动（MySQL/MariaDB、PostgreSQL）并保持 Bun 的 tagged template 与连接池语义。

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../common.zig");
const sqlite = @import("sqlite/mod.zig");

/// 统一抛错：shu:sql not implemented
fn throwNotImplemented(ctx: jsc.JSContextRef, exception: [*]jsc.JSValueRef) void {
    const msg = jsc.JSStringCreateWithUTF8CString("shu:sql not implemented");
    defer jsc.JSStringRelease(msg);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_err = jsc.JSStringCreateWithUTF8CString("Error");
    defer jsc.JSStringRelease(k_err);
    const err_ctor = jsc.JSObjectGetProperty(ctx, global, k_err, null);
    const err_obj = jsc.JSValueToObject(ctx, err_ctor, null) orelse return;
    var args = [_]jsc.JSValueRef{jsc.JSValueMakeString(ctx, msg)};
    exception[0] = jsc.JSObjectCallAsConstructor(ctx, err_obj, 1, &args, null);
}

/// sql`...` 或 instance`...` 被调用时（tagged template 即函数调用，首参为 template 字符串数组）
fn sqlTaggedStubCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    exception: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    throwNotImplemented(ctx, exception);
    return jsc.JSValueMakeUndefined(ctx);
}

/// new SQL(connectionString) 或 new SQL(options)：返回可当 tagged template 的实例占位（实为函数，调用抛错）
fn sqlConstructorCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    exception: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    _ = exception;
    const k_empty = jsc.JSStringCreateWithUTF8CString("");
    defer jsc.JSStringRelease(k_empty);
    const instance = jsc.JSObjectMakeFunctionWithCallback(ctx, k_empty, sqlTaggedStubCallback);
    const k_begin = jsc.JSStringCreateWithUTF8CString("begin");
    defer jsc.JSStringRelease(k_begin);
    common.setMethod(ctx, instance, "begin", sqlTaggedStubCallback);
    return instance;
}

/// 返回 shu:sql 的 exports：sql（tagged template 占位）、SQL（构造函数占位）
pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    _ = allocator;
    const exports = jsc.JSObjectMake(ctx, null, null);
    const k_sql = jsc.JSStringCreateWithUTF8CString("sql");
    defer jsc.JSStringRelease(k_sql);
    const k_SQL = jsc.JSStringCreateWithUTF8CString("SQL");
    defer jsc.JSStringRelease(k_SQL);
    const sql_fn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_sql, sqlTaggedStubCallback);
    const SQL_ctor = jsc.JSObjectMakeFunctionWithCallback(ctx, k_SQL, sqlConstructorCallback);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_sql, sql_fn, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_SQL, SQL_ctor, jsc.kJSPropertyAttributeNone, null);
    return exports;
}

/// 返回 shu:sqlite 的 Node 风格 exports（DatabaseSync、Database、constants、backup、Statement），由 sql/sqlite/mod.zig 提供；供 builtin 的 shu:sqlite 解析使用。
pub fn getSqliteExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    return sqlite.getExports(ctx, allocator);
}
