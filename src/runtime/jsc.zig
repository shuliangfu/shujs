// JavaScriptCore C API 的 Zig 声明（macOS 系统框架）
// 参考：SHU_RUNTIME_ANALYSIS.md 2.0、https://karhm.com/javascriptcore_c_api/

const std = @import("std");

/// JSC 上下文组句柄（不透明指针）
pub const JSContextGroupRef = *anyopaque;
/// JSC 全局上下文句柄
pub const JSGlobalContextRef = *anyopaque;
/// JSC 上下文句柄（当前执行上下文）
pub const JSContextRef = *anyopaque;
/// JSC 对象句柄
pub const JSObjectRef = *anyopaque;
/// JSC 值句柄
pub const JSValueRef = *anyopaque;
/// JSC 字符串句柄
pub const JSStringRef = *anyopaque;
/// JSC 类句柄
pub const JSClassRef = *anyopaque;

/// 从 JS 调用的 C 函数回调类型（ctx, this, callee, argc, argv, exception）
pub const JSObjectCallAsFunctionCallback = *const fn (
    JSContextRef,
    JSObjectRef,
    JSObjectRef,
    usize,
    [*]const JSValueRef,
    [*]JSValueRef,
) callconv(.c) JSValueRef;

/// 属性无特殊标志（可枚举、可写、可配置）
pub const kJSPropertyAttributeNone: c_uint = 0;

pub extern "c" fn JSContextGroupCreate() JSContextGroupRef;
pub extern "c" fn JSContextGroupRelease(JSContextGroupRef) void;
pub extern "c" fn JSGlobalContextCreateInGroup(JSContextGroupRef, ?JSClassRef) JSGlobalContextRef;
pub extern "c" fn JSGlobalContextRelease(JSGlobalContextRef) void;
/// 获取上下文所属的上下文组（用于 vm 模块在同一组内创建新上下文）
pub extern "c" fn JSContextGetGroup(JSContextRef) JSContextGroupRef;
/// 增加全局上下文的引用计数（vm 模块持有子上下文时使用）
pub extern "c" fn JSGlobalContextRetain(JSGlobalContextRef) JSGlobalContextRef;
pub extern "c" fn JSContextGetGlobalObject(JSContextRef) JSObjectRef;
pub extern "c" fn JSStringCreateWithUTF8CString([*]const u8) JSStringRef;
pub extern "c" fn JSStringRelease(JSStringRef) void;
pub extern "c" fn JSEvaluateScript(
    JSContextRef,
    JSStringRef,
    ?JSObjectRef,
    ?JSStringRef,
    c_int,
    ?[*]JSValueRef,
) JSValueRef;
pub extern "c" fn JSObjectSetProperty(
    JSContextRef,
    JSObjectRef,
    JSStringRef,
    JSValueRef,
    c_uint,
    ?[*]JSValueRef,
) bool;
pub extern "c" fn JSObjectMakeFunctionWithCallback(
    JSContextRef,
    JSStringRef,
    JSObjectCallAsFunctionCallback,
) JSObjectRef;
pub extern "c" fn JSValueMakeUndefined(JSContextRef) JSValueRef;
pub extern "c" fn JSValueToStringCopy(JSContextRef, JSValueRef, ?[*]JSValueRef) JSStringRef;
pub extern "c" fn JSStringGetMaximumUTF8CStringSize(JSStringRef) usize;
pub extern "c" fn JSStringGetUTF8CString(JSStringRef, [*]u8, usize) usize;
pub extern "c" fn JSObjectMake(JSContextRef, ?JSClassRef, ?*anyopaque) JSObjectRef;
pub extern "c" fn JSValueMakeString(JSContextRef, JSStringRef) JSValueRef;
pub extern "c" fn JSValueMakeNumber(JSContextRef, f64) JSValueRef;
pub extern "c" fn JSValueMakeBoolean(JSContextRef, bool) JSValueRef;
pub extern "c" fn JSObjectMakeArray(JSContextRef, usize, [*]const JSValueRef, ?[*]JSValueRef) JSObjectRef;
pub extern "c" fn JSObjectCallAsFunction(JSContextRef, JSObjectRef, ?JSObjectRef, usize, [*]const JSValueRef, ?[*]JSValueRef) JSValueRef;
/// 以构造函数方式调用（即 new F(...args)）；arguments 为参数数组，exception 出参，返回新实例或 undefined
pub extern "c" fn JSObjectCallAsConstructor(JSContextRef, JSObjectRef, usize, [*]const JSValueRef, ?[*]JSValueRef) JSValueRef;
pub extern "c" fn JSValueProtect(JSContextRef, JSValueRef) void;
pub extern "c" fn JSValueUnprotect(JSContextRef, JSValueRef) void;
pub extern "c" fn JSObjectIsFunction(JSContextRef, JSObjectRef) bool;
pub extern "c" fn JSValueToNumber(JSContextRef, JSValueRef, ?[*]JSValueRef) f64;
/// 将 JS 值转为布尔（用于 options.reusePort 等）
pub extern "c" fn JSValueToBoolean(JSContextRef, JSValueRef) bool;

// ---------- 对象/属性访问（用于从 JS 读取 options.cmd、options.cwd 等） ----------
/// 将 JS 值转为对象；若不可转换则返回 null
pub extern "c" fn JSValueToObject(JSContextRef, JSValueRef, ?[*]JSValueRef) ?JSObjectRef;
/// 获取对象属性（propertyName 为 JSStringRef）
pub extern "c" fn JSObjectGetProperty(JSContextRef, JSObjectRef, JSStringRef, ?[*]JSValueRef) JSValueRef;
/// 按数字下标获取属性（用于数组元素），比 JSObjectGetProperty 更高效
pub extern "c" fn JSObjectGetPropertyAtIndex(JSContextRef, JSObjectRef, c_uint, ?[*]JSValueRef) JSValueRef;
/// 判断值是否为 undefined
pub extern "c" fn JSValueIsUndefined(JSContextRef, JSValueRef) bool;
/// 判断值是否为 null（用于 createConnection 回调 err 判断）
pub extern "c" fn JSValueIsNull(JSContextRef, JSValueRef) bool;
/// 判断值是否为字符串（用于 Web Crypto algorithm 参数等）
pub extern "c" fn JSValueIsString(JSContextRef, JSValueRef) bool;

// ---------- 属性名枚举（vm 模块复制 sandbox 与 global 间属性用） ----------
/// 属性名数组句柄（JSObjectCopyPropertyNames 返回，调用者 Release）
pub const JSPropertyNameArrayRef = *anyopaque;
pub extern "c" fn JSObjectCopyPropertyNames(JSContextRef, JSObjectRef) JSPropertyNameArrayRef;
pub extern "c" fn JSPropertyNameArrayRelease(JSPropertyNameArrayRef) void;
pub extern "c" fn JSPropertyNameArrayGetCount(JSPropertyNameArrayRef) usize;
pub extern "c" fn JSPropertyNameArrayGetNameAtIndex(JSPropertyNameArrayRef, usize) JSStringRef;

// ---------- 字符串（用于 atob/btoa 等） ----------
/// 获取字符串长度（UTF-16 码元数）
pub extern "c" fn JSStringGetLength(JSStringRef) usize;
/// 从 UTF-16 码元创建字符串（chars 不保留所有权）
pub extern "c" fn JSStringCreateWithCharacters([*]const u16, usize) JSStringRef;

// ---------- Typed Array / ArrayBuffer（macOS 10.12+，用于 Zig/C 直接创建 Uint8Array/ArrayBuffer） ----------
/// 用于释放传给 JSObjectMakeArrayBufferWithBytesNoCopy / JSObjectMakeTypedArrayWithBytesNoCopy 的字节的回调；(bytes, deallocatorContext)
pub const JSTypedArrayBytesDeallocator = *const fn (bytes: *anyopaque, deallocator_context: ?*anyopaque) callconv(.c) void;

/// Typed Array 类型枚举（与 JS 的 Uint8Array、ArrayBuffer 等对应）
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

/// 创建指定长度、零初始化的 Typed Array（如 Uint8Array）
pub extern "c" fn JSObjectMakeTypedArray(JSContextRef, JSTypedArrayType, usize) ?JSObjectRef;
/// 从已有字节指针创建 Typed Array，不拷贝；GC 回收时调用 deallocator(bytes, deallocatorContext)
pub extern "c" fn JSObjectMakeTypedArrayWithBytesNoCopy(
    JSContextRef,
    JSTypedArrayType,
    ?*anyopaque,
    usize,
    JSTypedArrayBytesDeallocator,
    ?*anyopaque,
    ?*JSValueRef,
) ?JSObjectRef;
/// 从已有字节指针创建 ArrayBuffer，不拷贝；GC 回收时调用 deallocator
pub extern "c" fn JSObjectMakeArrayBufferWithBytesNoCopy(
    JSContextRef,
    ?*anyopaque,
    usize,
    JSTypedArrayBytesDeallocator,
    ?*anyopaque,
    ?*JSValueRef,
) ?JSObjectRef;
/// 从 ArrayBuffer 创建 Typed Array 视图
pub extern "c" fn JSObjectMakeTypedArrayWithArrayBuffer(JSContextRef, JSTypedArrayType, JSObjectRef, ?*JSValueRef) ?JSObjectRef;
/// 从 ArrayBuffer 的指定偏移和长度创建 Typed Array 视图
pub extern "c" fn JSObjectMakeTypedArrayWithArrayBufferWithOffset(JSContextRef, JSTypedArrayType, JSObjectRef, usize, usize, ?*JSValueRef) ?JSObjectRef;

/// 获取 Typed Array 的底层数据指针（调用后该 ArrayBuffer 会被 pin，生命周期内不可移动）
pub extern "c" fn JSObjectGetTypedArrayBytesPtr(JSContextRef, JSObjectRef, ?*usize) ?*anyopaque;
/// 获取 Typed Array 元素个数
pub extern "c" fn JSObjectGetTypedArrayLength(JSContextRef, JSObjectRef) usize;
/// 获取 Typed Array 字节长度
pub extern "c" fn JSObjectGetTypedArrayByteLength(JSContextRef, JSObjectRef) usize;
/// 获取 ArrayBuffer 的数据指针
pub extern "c" fn JSObjectGetArrayBufferBytesPtr(JSContextRef, JSObjectRef, ?*usize) ?*anyopaque;
/// 获取 ArrayBuffer 字节长度
pub extern "c" fn JSObjectGetArrayBufferByteLength(JSContextRef, JSObjectRef) usize;
/// 获取值的 Typed Array 类型（非 Typed Array 返回 None）
pub extern "c" fn JSValueGetTypedArrayType(JSContextRef, JSValueRef, ?*JSValueRef) JSTypedArrayType;
