// JSC 占位：在未链接 JavaScriptCore 的构建中提供同名类型与空实现，避免未定义符号
// 当 have_webkit_jsc=false 且非 macOS 时由 build.zig 选用；不执行任何 JS

/// JSC 上下文组句柄（不透明指针）
pub const JSContextGroupRef = *anyopaque;
/// JSC 全局上下文句柄
pub const JSGlobalContextRef = *anyopaque;
/// JSC 上下文句柄
pub const JSContextRef = *anyopaque;
/// JSC 对象句柄
pub const JSObjectRef = *anyopaque;
/// JSC 值句柄
pub const JSValueRef = *anyopaque;
/// JSC 字符串句柄
pub const JSStringRef = *anyopaque;
/// JSC 类句柄
pub const JSClassRef = *anyopaque;

/// 从 JS 调用的 C 函数回调类型（与 jsc.zig 一致）
pub const JSObjectCallAsFunctionCallback = *const fn (
    JSContextRef,
    JSObjectRef,
    JSObjectRef,
    usize,
    [*]const JSValueRef,
    [*]JSValueRef,
) callconv(.c) JSValueRef;

pub const kJSPropertyAttributeNone: c_uint = 0;

// ---------- 空实现，永不调用到（engine.zig 在 have_jsc 为 false 时不调用 JSC） ----------

pub fn JSContextGroupCreate() JSContextGroupRef {
    return @ptrFromInt(0);
}
pub fn JSContextGroupRelease(_: JSContextGroupRef) void {}
pub fn JSGlobalContextCreateInGroup(_: JSContextGroupRef, _: ?JSClassRef) JSGlobalContextRef {
    return @ptrFromInt(0);
}
pub fn JSGlobalContextRelease(_: JSGlobalContextRef) void {}
pub fn JSContextGetGroup(_: JSContextRef) JSContextGroupRef {
    return @ptrFromInt(0);
}
pub fn JSGlobalContextRetain(_: JSGlobalContextRef) JSGlobalContextRef {
    return @ptrFromInt(0);
}
pub fn JSContextGetGlobalObject(_: JSContextRef) JSObjectRef {
    return @ptrFromInt(0);
}
pub fn JSStringCreateWithUTF8CString(_: [*]const u8) JSStringRef {
    return @ptrFromInt(0);
}
pub fn JSStringRelease(_: JSStringRef) void {}
pub fn JSEvaluateScript(_: JSContextRef, _: JSStringRef, _: ?JSObjectRef, _: ?JSStringRef, _: c_int, _: ?[*]JSValueRef) JSValueRef {
    return @ptrFromInt(0);
}
pub fn JSObjectSetProperty(_: JSContextRef, _: JSObjectRef, _: JSStringRef, _: JSValueRef, _: c_uint, _: ?[*]JSValueRef) bool {
    return false;
}
pub fn JSObjectMakeFunctionWithCallback(_: JSContextRef, _: JSStringRef, _: JSObjectCallAsFunctionCallback) JSObjectRef {
    return @ptrFromInt(0);
}
pub fn JSValueMakeUndefined(_: JSContextRef) JSValueRef {
    return @ptrFromInt(0);
}
pub fn JSValueToStringCopy(_: JSContextRef, _: JSValueRef, _: ?[*]JSValueRef) JSStringRef {
    return @ptrFromInt(0);
}
pub fn JSStringGetMaximumUTF8CStringSize(_: JSStringRef) usize {
    return 0;
}
pub fn JSStringGetUTF8CString(_: JSStringRef, _: [*]u8, _: usize) usize {
    return 0;
}
pub fn JSObjectMake(_: JSContextRef, _: ?JSClassRef, _: ?*anyopaque) JSObjectRef {
    return @ptrFromInt(0);
}
pub fn JSValueMakeString(_: JSContextRef, _: JSStringRef) JSValueRef {
    return @ptrFromInt(0);
}
pub fn JSValueMakeNumber(_: JSContextRef, _: f64) JSValueRef {
    return @ptrFromInt(0);
}
pub fn JSValueMakeBoolean(_: JSContextRef, _: bool) JSValueRef {
    return @ptrFromInt(0);
}
pub fn JSObjectMakeArray(_: JSContextRef, _: usize, _: [*]const JSValueRef, _: ?[*]JSValueRef) JSObjectRef {
    return @ptrFromInt(0);
}
pub fn JSObjectCallAsFunction(_: JSContextRef, _: JSObjectRef, _: ?JSObjectRef, _: usize, _: [*]const JSValueRef, _: ?[*]JSValueRef) JSValueRef {
    return @ptrFromInt(0);
}
pub fn JSValueProtect(_: JSContextRef, _: JSValueRef) void {}
pub fn JSValueUnprotect(_: JSContextRef, _: JSValueRef) void {}
pub fn JSObjectIsFunction(_: JSContextRef, _: JSObjectRef) bool {
    return false;
}
pub fn JSValueToNumber(_: JSContextRef, _: JSValueRef, _: ?[*]JSValueRef) f64 {
    return 0;
}
pub fn JSValueToObject(_: JSContextRef, _: JSValueRef, _: ?[*]JSValueRef) ?JSObjectRef {
    return null;
}
pub fn JSObjectGetProperty(_: JSContextRef, _: JSObjectRef, _: JSStringRef, _: ?[*]JSValueRef) JSValueRef {
    return @ptrFromInt(0);
}
pub fn JSObjectGetPropertyAtIndex(_: JSContextRef, _: JSObjectRef, _: c_uint, _: ?[*]JSValueRef) JSValueRef {
    return @ptrFromInt(0);
}
pub fn JSValueIsUndefined(_: JSContextRef, _: JSValueRef) bool {
    return true;
}
pub const JSPropertyNameArrayRef = *anyopaque;
pub fn JSObjectCopyPropertyNames(_: JSContextRef, _: JSObjectRef) JSPropertyNameArrayRef {
    return @ptrFromInt(0);
}
pub fn JSPropertyNameArrayRelease(_: JSPropertyNameArrayRef) void {}
pub fn JSPropertyNameArrayGetCount(_: JSPropertyNameArrayRef) usize {
    return 0;
}
pub fn JSPropertyNameArrayGetNameAtIndex(_: JSPropertyNameArrayRef, _: usize) JSStringRef {
    return @ptrFromInt(0);
}
pub fn JSStringGetLength(_: JSStringRef) usize {
    return 0;
}
pub fn JSStringCreateWithCharacters(_: [*]const u16, _: usize) JSStringRef {
    return @ptrFromInt(0);
}

// ---------- Typed Array / ArrayBuffer 占位（与 jsc.zig 声明一致，空实现） ----------
pub const JSTypedArrayBytesDeallocator = *const fn (bytes: *anyopaque, deallocator_context: ?*anyopaque) callconv(.c) void;
pub const JSTypedArrayType = enum(c_int) {
    Int8Array = 0,
    Int16Array = 1,
    Int32Array = 2,
    Uint8Array = 3,
    Uint8ClampedArray = 4,
    Uint16Array = 5,
    Uint32Array = 6,
    Float32Array = 7,
    Float64Array = 8,
    ArrayBuffer = 9,
    None = 10,
};
pub fn JSObjectMakeTypedArray(_: JSContextRef, _: JSTypedArrayType, _: usize) ?JSObjectRef {
    return null;
}
pub fn JSObjectMakeTypedArrayWithBytesNoCopy(
    _: JSContextRef,
    _: JSTypedArrayType,
    _: ?*anyopaque,
    _: usize,
    _: JSTypedArrayBytesDeallocator,
    _: ?*anyopaque,
    _: ?*JSValueRef,
) ?JSObjectRef {
    return null;
}
pub fn JSObjectMakeArrayBufferWithBytesNoCopy(
    _: JSContextRef,
    _: ?*anyopaque,
    _: usize,
    _: JSTypedArrayBytesDeallocator,
    _: ?*anyopaque,
    _: ?*JSValueRef,
) ?JSObjectRef {
    return null;
}
pub fn JSObjectMakeTypedArrayWithArrayBuffer(_: JSContextRef, _: JSTypedArrayType, _: JSObjectRef, _: ?*JSValueRef) ?JSObjectRef {
    return null;
}
pub fn JSObjectMakeTypedArrayWithArrayBufferWithOffset(_: JSContextRef, _: JSTypedArrayType, _: JSObjectRef, _: usize, _: usize, _: ?*JSValueRef) ?JSObjectRef {
    return null;
}
pub fn JSObjectGetTypedArrayBytesPtr(_: JSContextRef, _: JSObjectRef, _: ?*usize) ?*anyopaque {
    return null;
}
pub fn JSObjectGetTypedArrayLength(_: JSContextRef, _: JSObjectRef) usize {
    return 0;
}
pub fn JSObjectGetTypedArrayByteLength(_: JSContextRef, _: JSObjectRef) usize {
    return 0;
}
pub fn JSObjectGetArrayBufferBytesPtr(_: JSContextRef, _: JSObjectRef, _: ?*usize) ?*anyopaque {
    return null;
}
pub fn JSObjectGetArrayBufferByteLength(_: JSContextRef, _: JSObjectRef) usize {
    return 0;
}
pub fn JSValueGetTypedArrayType(_: JSContextRef, _: JSValueRef, _: ?*JSValueRef) JSTypedArrayType {
    return .None;
}
