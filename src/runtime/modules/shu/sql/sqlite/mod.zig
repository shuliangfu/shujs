// SQLite 后端占位；同时提供 Node 风格 API（DatabaseSync、Database、Statement、constants、backup），供 shu:sqlite 与 sql 的 sqlite:// 共用。
//
// ========== API 点位（Node 22+ / Bun 兼容） ==========
//
// | 导出           | 说明 |
// |----------------|------|
// | DatabaseSync   | Node 同步库类；new DatabaseSync(path[, options])，实例有 exec、prepare、close、open |
// | Database       | Bun 风格别名，与 DatabaseSync 同点位 |
// | Statement      | prepare(sql) 返回的对象，有 run、all、get |
// | constants      | SQLITE_OK、SQLITE_DENY、SQLITE_CREATE_TABLE 等占位常量 |
// | backup         | 异步备份函数占位 |
//
// 实现时需对接真实 SQLite 并考虑 Bun API 兼容（Database.open、query、run 等）。

const std = @import("std");
const jsc = @import("jsc");
const common = @import("../../../../common.zig");

/// 统一抛错：shu:sqlite not implemented
fn throwNotImplemented(ctx: jsc.JSContextRef, exception: [*]jsc.JSValueRef) void {
    const msg = jsc.JSStringCreateWithUTF8CString("shu:sqlite not implemented");
    defer jsc.JSStringRelease(msg);
    const global = jsc.JSContextGetGlobalObject(ctx);
    const k_err = jsc.JSStringCreateWithUTF8CString("Error");
    defer jsc.JSStringRelease(k_err);
    const err_ctor = jsc.JSObjectGetProperty(ctx, global, k_err, null);
    const err_obj = jsc.JSValueToObject(ctx, err_ctor, null) orelse return;
    var args = [_]jsc.JSValueRef{jsc.JSValueMakeString(ctx, msg)};
    exception[0] = jsc.JSObjectCallAsConstructor(ctx, err_obj, 1, &args, null);
}

fn sqliteStubCallback(
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

/// DatabaseSync / Database 实例：prepare(sql) 返回的 Statement 占位，带 run、all、get
fn createStatementStub(ctx: jsc.JSContextRef) jsc.JSObjectRef {
    const stmt = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, stmt, "run", sqliteStubCallback);
    common.setMethod(ctx, stmt, "all", sqliteStubCallback);
    common.setMethod(ctx, stmt, "get", sqliteStubCallback);
    common.setMethod(ctx, stmt, "bind", sqliteStubCallback);
    return stmt;
}

/// DatabaseSync 实例的 prepare(sql)：返回 Statement 占位
fn dbPrepareCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    exception: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    _ = exception;
    return createStatementStub(ctx);
}

/// DatabaseSync / Database 工厂：new DatabaseSync(path) 或 new Database(path) 返回的实例占位
fn dbFactoryCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    exception: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    _ = exception;
    const instance = jsc.JSObjectMake(ctx, null, null);
    common.setMethod(ctx, instance, "exec", sqliteStubCallback);
    common.setMethod(ctx, instance, "prepare", dbPrepareCallback);
    common.setMethod(ctx, instance, "close", sqliteStubCallback);
    common.setMethod(ctx, instance, "open", sqliteStubCallback);
    common.setMethod(ctx, instance, "run", sqliteStubCallback);
    common.setMethod(ctx, instance, "query", dbPrepareCallback);
    common.setMethod(ctx, instance, "createTagStore", sqliteStubCallback);
    common.setMethod(ctx, instance, "createSession", sqliteStubCallback);
    common.setMethod(ctx, instance, "setAuthorizer", sqliteStubCallback);
    common.setMethod(ctx, instance, "applyChangeset", sqliteStubCallback);
    common.setMethod(ctx, instance, "aggregate", sqliteStubCallback);
    return instance;
}

/// backup(sourceDb, targetPath, options)：占位，调用抛 not implemented
fn backupCallback(
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

/// 构建 constants 对象：SQLITE_OK、SQLITE_DENY、SQLITE_CREATE_TABLE 等占位（与 SQLite C 常量一致便于后续实现）
fn createConstantsObject(ctx: jsc.JSContextRef) jsc.JSObjectRef {
    const obj = jsc.JSObjectMake(ctx, null, null);
    const k_ok = jsc.JSStringCreateWithUTF8CString("SQLITE_OK");
    defer jsc.JSStringRelease(k_ok);
    const k_deny = jsc.JSStringCreateWithUTF8CString("SQLITE_DENY");
    defer jsc.JSStringRelease(k_deny);
    const k_create_table = jsc.JSStringCreateWithUTF8CString("SQLITE_CREATE_TABLE");
    defer jsc.JSStringRelease(k_create_table);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_ok, jsc.JSValueMakeNumber(ctx, 0), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_deny, jsc.JSValueMakeNumber(ctx, 1), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, obj, k_create_table, jsc.JSValueMakeNumber(ctx, 17), jsc.kJSPropertyAttributeNone, null);
    return obj;
}

/// 返回 Node 风格 sqlite exports：DatabaseSync、Database、constants、backup、Statement；供 shu:sqlite 与 sql/mod.zig 共用。
pub fn getExports(ctx: jsc.JSContextRef, allocator: std.mem.Allocator) jsc.JSValueRef {
    _ = allocator;
    const exports = jsc.JSObjectMake(ctx, null, null);
    const k_db_sync = jsc.JSStringCreateWithUTF8CString("DatabaseSync");
    defer jsc.JSStringRelease(k_db_sync);
    const k_db = jsc.JSStringCreateWithUTF8CString("Database");
    defer jsc.JSStringRelease(k_db);
    const k_constants = jsc.JSStringCreateWithUTF8CString("constants");
    defer jsc.JSStringRelease(k_constants);
    const k_backup = jsc.JSStringCreateWithUTF8CString("backup");
    defer jsc.JSStringRelease(k_backup);
    const k_statement = jsc.JSStringCreateWithUTF8CString("Statement");
    defer jsc.JSStringRelease(k_statement);
    const dbSyncFn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_db_sync, dbFactoryCallback);
    const dbFn = jsc.JSObjectMakeFunctionWithCallback(ctx, k_db, dbFactoryCallback);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_db_sync, dbSyncFn, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_db, dbFn, jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_constants, createConstantsObject(ctx), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_backup, jsc.JSObjectMakeFunctionWithCallback(ctx, k_backup, backupCallback), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, exports, k_statement, createStatementStub(ctx), jsc.kJSPropertyAttributeNone, null);
    return exports;
}
