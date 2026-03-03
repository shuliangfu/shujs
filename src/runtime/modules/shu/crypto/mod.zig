// shu:crypto：哈希、对称加密、非对称加密（X25519），供全局 crypto 与 Shu.crypto / require("shu:crypto") 共用
// 提供 randomUUID、digest、encrypt/decrypt、算法常量、generateKeyPair、encryptWithPublicKey、decryptWithPrivateKey

const std = @import("std");
const jsc = @import("jsc");
const globals = @import("../../../globals.zig");

const ChaCha = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const AesGcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const Sha1 = std.crypto.hash.Sha1;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha384 = std.crypto.hash.sha2.Sha384;
const Sha512 = std.crypto.hash.sha2.Sha512;
const X25519 = std.crypto.dh.X25519;

const alg_chacha: u8 = 0;
const alg_aes_gcm: u8 = 1;

/// 安全擦除敏感内存，防止编译器优化掉；密钥、明文等用完后调用，符合行业准则
fn secureZeroBytes(s: []u8) void {
    std.crypto.secureZero(u8, @as([*]volatile u8, @ptrCast(s.ptr))[0..s.len]);
}

/// 创建并返回 crypto 对象（方法 + 算法常量），不挂到任何父对象
fn makeCryptoObject(ctx: jsc.JSGlobalContextRef) jsc.JSObjectRef {
    const crypto_obj = jsc.JSObjectMake(ctx, null, null);
    setMethod(ctx, crypto_obj, "randomUUID", randomUUIDCallback);
    setMethod(ctx, crypto_obj, "digest", digestCallback);
    setMethod(ctx, crypto_obj, "encrypt", encryptCallback);
    setMethod(ctx, crypto_obj, "decrypt", decryptCallback);
    setMethod(ctx, crypto_obj, "getRandomValues", getRandomValuesStubCallback);
    setMethod(ctx, crypto_obj, "generateKeyPair", generateKeyPairCallback);
    setMethod(ctx, crypto_obj, "encryptWithPublicKey", encryptWithPublicKeyCallback);
    setMethod(ctx, crypto_obj, "decryptWithPrivateKey", decryptWithPrivateKeyCallback);
    setPropertyString(ctx, crypto_obj, "CHACHA20_POLY1305", "chacha20-poly1305");
    setPropertyString(ctx, crypto_obj, "AES_256_GCM", "aes-256-gcm");
    return crypto_obj;
}

/// 返回 shu:crypto 的 exports（即 globalThis.crypto，与 Shu.crypto 同一引用）；供 require('shu:crypto') 与引擎挂载
pub fn getExports(ctx: jsc.JSContextRef, _: std.mem.Allocator) jsc.JSValueRef {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const name = jsc.JSStringCreateWithUTF8CString("crypto");
    defer jsc.JSStringRelease(name);
    return jsc.JSObjectGetProperty(ctx, global, name, null);
}

/// §1.1 显式 allocator 收敛：register 时注入，crypto 回调优先使用
threadlocal var g_crypto_allocator: ?std.mem.Allocator = null;

/// 向全局对象注册 crypto（globalThis.crypto），供无 RunOptions 时或兼容 Web 使用；engine 通过 bindings 调用；allocator 传入时注入
pub fn register(ctx: jsc.JSGlobalContextRef, allocator: ?std.mem.Allocator) void {
    if (allocator) |a| g_crypto_allocator = a;
    const global = jsc.JSContextGetGlobalObject(ctx);
    const name_crypto = jsc.JSStringCreateWithUTF8CString("crypto");
    defer jsc.JSStringRelease(name_crypto);
    const crypto_obj = makeCryptoObject(ctx);
    _ = jsc.JSObjectSetProperty(ctx, global, name_crypto, crypto_obj, jsc.kJSPropertyAttributeNone, null);
}

/// 将已存在的 globalThis.crypto 挂到 Shu 上，供 Shu.crypto 与 shu:crypto 协议；engine/shu/mod.zig 在注册 Shu 时调用
pub fn attachToShu(ctx: jsc.JSGlobalContextRef, shu_obj: jsc.JSObjectRef) void {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const name_crypto = jsc.JSStringCreateWithUTF8CString("crypto");
    defer jsc.JSStringRelease(name_crypto);
    const crypto_val = jsc.JSObjectGetProperty(ctx, global, name_crypto, null);
    _ = jsc.JSObjectSetProperty(ctx, shu_obj, name_crypto, crypto_val, jsc.kJSPropertyAttributeNone, null);
}

/// 在对象上设置字符串属性（用于算法常量等）
fn setPropertyString(ctx: jsc.JSGlobalContextRef, obj: jsc.JSObjectRef, name: [*]const u8, value: [*]const u8) void {
    const name_ref = jsc.JSStringCreateWithUTF8CString(name);
    defer jsc.JSStringRelease(name_ref);
    const value_ref = jsc.JSStringCreateWithUTF8CString(value);
    defer jsc.JSStringRelease(value_ref);
    _ = jsc.JSObjectSetProperty(ctx, obj, name_ref, jsc.JSValueMakeString(ctx, value_ref), jsc.kJSPropertyAttributeNone, null);
}

fn setMethod(ctx: jsc.JSGlobalContextRef, obj: jsc.JSObjectRef, name: [*]const u8, callback: jsc.JSObjectCallAsFunctionCallback) void {
    const name_ref = jsc.JSStringCreateWithUTF8CString(name);
    defer jsc.JSStringRelease(name_ref);
    const fn_ref = jsc.JSObjectMakeFunctionWithCallback(ctx, name_ref, callback);
    _ = jsc.JSObjectSetProperty(ctx, obj, name_ref, fn_ref, jsc.kJSPropertyAttributeNone, null);
}

/// crypto.randomUUID()：返回符合 RFC 4122 的 UUID v4 字符串
/// 使用预定义格式串 + bufPrint 一次写出，减少分支，提升高频调用吞吐
fn randomUUIDCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    var buf: [37]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        bytes[0],  bytes[1],  bytes[2],  bytes[3],
        bytes[4],  bytes[5],  bytes[6],  bytes[7],
        bytes[8],  bytes[9],  bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15],
    }) catch return jsc.JSValueMakeUndefined(ctx);
    buf[36] = 0;
    const ref = jsc.JSStringCreateWithUTF8CString(&buf);
    defer jsc.JSStringRelease(ref);
    return jsc.JSValueMakeString(ctx, ref);
}

/// 从 JS 值取 UTF-8 字节（调用方负责 free 返回的 slice）
fn jsValueToUtf8Bytes(ctx: jsc.JSContextRef, value: jsc.JSValueRef, allocator: std.mem.Allocator) ?[]const u8 {
    const js_str = jsc.JSValueToStringCopy(ctx, value, null);
    defer jsc.JSStringRelease(js_str);
    const max_sz = jsc.JSStringGetMaximumUTF8CStringSize(js_str);
    if (max_sz == 0 or max_sz > 1024 * 1024) return null;
    const buf = allocator.alloc(u8, max_sz) catch return null;
    defer allocator.free(buf);
    const n = jsc.JSStringGetUTF8CString(js_str, buf.ptr, max_sz);
    if (n == 0) return null;
    return allocator.dupe(u8, buf[0 .. n - 1]) catch null;
}

/// 从密钥字符串得到 32 字节：若为 64 个十六进制字符则解码，否则对 UTF-8 做 SHA-256
fn keyTo32Bytes(key_utf8: []const u8) ?[32]u8 {
    if (key_utf8.len == 64 and isHex(key_utf8)) {
        var out: [32]u8 = undefined;
        for (key_utf8[0..64], 0..) |c, i| {
            const nibble: u4 = if (c >= 'a') @intCast(c - 'a' + 10) else if (c >= 'A') @intCast(c - 'A' + 10) else @intCast(c - '0');
            if (i % 2 == 0) {
                out[i / 2] = @as(u8, nibble) << 4;
            } else {
                out[i / 2] |= nibble;
            }
        }
        return out;
    }
    var hash: [32]u8 = undefined;
    Sha256.hash(key_utf8, &hash, .{});
    return hash;
}

fn isHex(s: []const u8) bool {
    for (s) |c| {
        if ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F')) continue;
        return false;
    }
    return true;
}

/// 将 digest 字节转为小写十六进制并写入 buf（含结尾 0），使用 std.fmt.bytesToHex 避免手写循环
fn digestToHexBuf(comptime digest_len: usize, out: *const [digest_len]u8, buf: *[digest_len * 2 + 1]u8) void {
    const hex_arr = std.fmt.bytesToHex(out[0..], .lower);
    @memcpy(buf[0..hex_arr.len], &hex_arr);
    buf[digest_len * 2] = 0;
}

/// crypto.digest(algorithm, data)：对 data 做哈希，支持 SHA-1/SHA-256/SHA-384/SHA-512，返回十六进制字符串
/// 使用 std.fmt.bytesToHex 写入缓冲区，避免手写 hex 循环与冗余分配
fn digestCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return throwCryptoError(ctx, "crypto.digest requires (algorithm, data)");
    const allocator = g_crypto_allocator orelse globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    const data_bytes = jsValueToUtf8Bytes(ctx, arguments[1], allocator) orelse return throwCryptoError(ctx, "crypto.digest: data must be a string");
    defer allocator.free(data_bytes);
    const alg_js = jsc.JSValueToStringCopy(ctx, arguments[0], null);
    defer jsc.JSStringRelease(alg_js);
    var alg_buf: [32]u8 = undefined;
    const n = jsc.JSStringGetUTF8CString(alg_js, &alg_buf, alg_buf.len);
    if (n == 0) return jsc.JSValueMakeUndefined(ctx);
    const alg = alg_buf[0 .. n - 1];
    if (std.mem.eql(u8, alg, "SHA-1")) {
        var out: [Sha1.digest_length]u8 = undefined;
        Sha1.hash(data_bytes, &out, .{});
        var hex_buf: [Sha1.digest_length * 2 + 1]u8 = undefined;
        digestToHexBuf(Sha1.digest_length, &out, &hex_buf);
        const ref = jsc.JSStringCreateWithUTF8CString(&hex_buf);
        defer jsc.JSStringRelease(ref);
        return jsc.JSValueMakeString(ctx, ref);
    }
    if (std.mem.eql(u8, alg, "SHA-256")) {
        var out: [Sha256.digest_length]u8 = undefined;
        Sha256.hash(data_bytes, &out, .{});
        var hex_buf: [Sha256.digest_length * 2 + 1]u8 = undefined;
        digestToHexBuf(Sha256.digest_length, &out, &hex_buf);
        const ref = jsc.JSStringCreateWithUTF8CString(&hex_buf);
        defer jsc.JSStringRelease(ref);
        return jsc.JSValueMakeString(ctx, ref);
    }
    if (std.mem.eql(u8, alg, "SHA-384")) {
        var out: [Sha384.digest_length]u8 = undefined;
        Sha384.hash(data_bytes, &out, .{});
        var hex_buf: [Sha384.digest_length * 2 + 1]u8 = undefined;
        digestToHexBuf(Sha384.digest_length, &out, &hex_buf);
        const ref = jsc.JSStringCreateWithUTF8CString(&hex_buf);
        defer jsc.JSStringRelease(ref);
        return jsc.JSValueMakeString(ctx, ref);
    }
    if (std.mem.eql(u8, alg, "SHA-512")) {
        var out: [Sha512.digest_length]u8 = undefined;
        Sha512.hash(data_bytes, &out, .{});
        var hex_buf: [Sha512.digest_length * 2 + 1]u8 = undefined;
        digestToHexBuf(Sha512.digest_length, &out, &hex_buf);
        const ref = jsc.JSStringCreateWithUTF8CString(&hex_buf);
        defer jsc.JSStringRelease(ref);
        return jsc.JSValueMakeString(ctx, ref);
    }
    return throwCryptoError(ctx, "crypto.digest supports SHA-1, SHA-256, SHA-384, SHA-512 only");
}

/// crypto.encrypt(key, plaintext [, algorithm])：对称加密
/// 单次 callback 内使用 ArenaAllocator，函数退出时一次性释放所有临时分配，避免长路径下的泄漏与 defer 顺序问题
fn encryptCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return throwCryptoError(ctx, "crypto.encrypt requires (key, plaintext)");
    const backing = g_crypto_allocator orelse globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();
    const key_bytes = jsValueToUtf8Bytes(ctx, arguments[0], allocator) orelse return throwCryptoError(ctx, "crypto.encrypt: key must be a string");
    const plain = jsValueToUtf8Bytes(ctx, arguments[1], allocator) orelse return throwCryptoError(ctx, "crypto.encrypt: plaintext must be a string");
    var key_32 = keyTo32Bytes(key_bytes) orelse return throwCryptoError(ctx, "crypto.encrypt: key derivation failed");
    var alg_byte: u8 = alg_chacha;
    if (argumentCount >= 3) {
        const alg_str_opt = jsValueToUtf8Bytes(ctx, arguments[2], allocator);
        if (alg_str_opt) |alg_str| {
            if (std.mem.eql(u8, alg_str, "aes-256-gcm")) alg_byte = alg_aes_gcm else if (!std.mem.eql(u8, alg_str, "chacha20-poly1305")) return throwCryptoError(ctx, "crypto.encrypt algorithm must be chacha20-poly1305 or aes-256-gcm");
        }
    }
    var nonce: [12]u8 = undefined;
    std.crypto.random.bytes(&nonce);
    const cipher = allocator.alloc(u8, plain.len) catch return jsc.JSValueMakeUndefined(ctx);
    var tag: [16]u8 = undefined;
    if (alg_byte == alg_aes_gcm) {
        AesGcm.encrypt(cipher, &tag, plain, "", nonce, key_32);
    } else {
        ChaCha.encrypt(cipher, &tag, plain, "", nonce, key_32);
    }
    const total_len = 1 + nonce.len + tag.len + cipher.len;
    const raw = allocator.alloc(u8, total_len) catch return jsc.JSValueMakeUndefined(ctx);
    raw[0] = alg_byte;
    @memcpy(raw[1..][0..nonce.len], &nonce);
    @memcpy(raw[1 + nonce.len ..][0..tag.len], &tag);
    @memcpy(raw[1 + nonce.len + tag.len ..], cipher);
    var encoder = std.base64.standard.Encoder;
    const enc_len = encoder.calcSize(total_len);
    const encoded = allocator.alloc(u8, enc_len + 1) catch return jsc.JSValueMakeUndefined(ctx);
    const written = encoder.encode(encoded[0..enc_len], raw);
    encoded[written.len] = 0;
    const ref = jsc.JSStringCreateWithUTF8CString(encoded.ptr);
    defer jsc.JSStringRelease(ref);
    secureZeroBytes(&key_32);
    return jsc.JSValueMakeString(ctx, ref);
}

const nonce_len: usize = 12;
const tag_len: usize = 16;

/// crypto.decrypt(key, ciphertext)：解密 encrypt 产生的 base64
/// 单次 callback 内使用 ArenaAllocator，函数退出时一次性释放所有临时分配
fn decryptCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return throwCryptoError(ctx, "crypto.decrypt requires (key, ciphertext)");
    const backing = g_crypto_allocator orelse globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();
    const key_bytes = jsValueToUtf8Bytes(ctx, arguments[0], allocator) orelse return throwCryptoError(ctx, "crypto.decrypt: key must be a string");
    const b64 = jsValueToUtf8Bytes(ctx, arguments[1], allocator) orelse return throwCryptoError(ctx, "crypto.decrypt: ciphertext must be a string");
    var key_32 = keyTo32Bytes(key_bytes) orelse return throwCryptoError(ctx, "crypto.decrypt: key derivation failed");
    const max_dec = (b64.len / 4) * 3 + 2;
    const decoded = allocator.alloc(u8, max_dec) catch return jsc.JSValueMakeUndefined(ctx);
    var decoder = std.base64.standard.Decoder;
    decoder.decode(decoded[0..], b64) catch return throwCryptoError(ctx, "crypto.decrypt: invalid base64");
    const total = (b64.len * 3) / 4;
    if (total < nonce_len + tag_len) return throwCryptoError(ctx, "crypto.decrypt: ciphertext too short");
    const new_format_min = 1 + nonce_len + tag_len;
    const has_alg_byte = total >= new_format_min and decoded[0] <= 1;
    const alg_byte: u8 = if (has_alg_byte) decoded[0] else alg_chacha;
    const off = if (has_alg_byte) @as(usize, 1) else @as(usize, 0);
    var nonce_arr: [nonce_len]u8 = undefined;
    @memcpy(&nonce_arr, decoded[off..][0..nonce_len]);
    var tag_arr: [tag_len]u8 = undefined;
    @memcpy(&tag_arr, decoded[off + nonce_len ..][0..tag_len]);
    const cipher_len = total - off - nonce_len - tag_len;
    const c = decoded[off + nonce_len + tag_len ..][0..cipher_len];
    const plain = allocator.alloc(u8, cipher_len) catch return jsc.JSValueMakeUndefined(ctx);
    if (alg_byte == alg_aes_gcm) {
        AesGcm.decrypt(plain, c, tag_arr, "", nonce_arr, key_32) catch return throwCryptoError(ctx, "crypto.decrypt: authentication failed (wrong key or corrupted data)");
    } else {
        ChaCha.decrypt(plain, c, tag_arr, "", nonce_arr, key_32) catch return throwCryptoError(ctx, "crypto.decrypt: authentication failed (wrong key or corrupted data)");
    }
    const z = allocator.alloc(u8, plain.len + 1) catch return jsc.JSValueMakeUndefined(ctx);
    @memcpy(z[0..plain.len], plain);
    z[plain.len] = 0;
    const ref = jsc.JSStringCreateWithUTF8CString(z.ptr);
    defer jsc.JSStringRelease(ref);
    secureZeroBytes(&key_32);
    secureZeroBytes(plain);
    secureZeroBytes(z[0..plain.len]);
    return jsc.JSValueMakeString(ctx, ref);
}

fn getRandomValuesStubCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    _: usize,
    _: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    return throwCryptoError(ctx, "crypto.getRandomValues is not implemented in this build (requires JSC TypedArray C API)");
}

fn base64EncodeAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var encoder = std.base64.standard.Encoder;
    const enc_len = encoder.calcSize(raw.len);
    const encoded = try allocator.alloc(u8, enc_len + 1);
    const written = encoder.encode(encoded[0..enc_len], raw);
    encoded[written.len] = 0;
    return encoded[0 .. written.len + 1];
}

fn base64DecodeAlloc(allocator: std.mem.Allocator, b64: []const u8) ![]u8 {
    const max_dec = (b64.len / 4) * 3 + 2;
    const decoded = try allocator.alloc(u8, max_dec);
    var decoder = std.base64.standard.Decoder;
    try decoder.decode(decoded[0..], b64);
    const n = (b64.len * 3) / 4;
    return decoded[0..n];
}

/// crypto.generateKeyPair(algorithm)：当前支持 "X25519"，返回 { publicKey, privateKey }（base64）
/// 单次 callback 内使用 ArenaAllocator，函数退出时一次性释放
fn generateKeyPairCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 1) return throwCryptoError(ctx, "crypto.generateKeyPair requires (algorithm)");
    const backing = g_crypto_allocator orelse globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();
    const alg_opt = jsValueToUtf8Bytes(ctx, arguments[0], allocator);
    const alg = alg_opt orelse return throwCryptoError(ctx, "crypto.generateKeyPair: algorithm must be a string");
    if (!std.mem.eql(u8, alg, "X25519")) return throwCryptoError(ctx, "crypto.generateKeyPair: only X25519 is supported");
    var kp = X25519.KeyPair.generate();
    const pub_b64 = base64EncodeAlloc(allocator, &kp.public_key) catch return jsc.JSValueMakeUndefined(ctx);
    const sec_b64 = base64EncodeAlloc(allocator, &kp.secret_key) catch return jsc.JSValueMakeUndefined(ctx);
    const result = jsc.JSObjectMake(ctx, null, null);
    const name_pub = jsc.JSStringCreateWithUTF8CString("publicKey");
    defer jsc.JSStringRelease(name_pub);
    const name_priv = jsc.JSStringCreateWithUTF8CString("privateKey");
    defer jsc.JSStringRelease(name_priv);
    const pub_js = jsc.JSStringCreateWithUTF8CString(pub_b64.ptr);
    defer jsc.JSStringRelease(pub_js);
    const priv_js = jsc.JSStringCreateWithUTF8CString(sec_b64.ptr);
    defer jsc.JSStringRelease(priv_js);
    _ = jsc.JSObjectSetProperty(ctx, result, name_pub, jsc.JSValueMakeString(ctx, pub_js), jsc.kJSPropertyAttributeNone, null);
    _ = jsc.JSObjectSetProperty(ctx, result, name_priv, jsc.JSValueMakeString(ctx, priv_js), jsc.kJSPropertyAttributeNone, null);
    secureZeroBytes(&kp.secret_key);
    return result;
}

/// crypto.encryptWithPublicKey(recipientPublicKeyBase64, plaintext)
/// 单次 callback 内使用 ArenaAllocator，函数退出时一次性释放
fn encryptWithPublicKeyCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return throwCryptoError(ctx, "crypto.encryptWithPublicKey requires (recipientPublicKey, plaintext)");
    const backing = g_crypto_allocator orelse globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();
    const pub_b64 = jsValueToUtf8Bytes(ctx, arguments[0], allocator) orelse return throwCryptoError(ctx, "crypto.encryptWithPublicKey: recipientPublicKey must be a string");
    const plain = jsValueToUtf8Bytes(ctx, arguments[1], allocator) orelse return throwCryptoError(ctx, "crypto.encryptWithPublicKey: plaintext must be a string");
    var recipient_pub: [X25519.public_length]u8 = undefined;
    const decoded_pub = base64DecodeAlloc(allocator, pub_b64) catch return throwCryptoError(ctx, "crypto.encryptWithPublicKey: invalid publicKey base64");
    if (decoded_pub.len != X25519.public_length) return throwCryptoError(ctx, "crypto.encryptWithPublicKey: publicKey must be 32 bytes (base64 decoded)");
    @memcpy(&recipient_pub, decoded_pub[0..X25519.public_length]);
    var ephemeral = X25519.KeyPair.generate();
    var shared = X25519.scalarmult(ephemeral.secret_key, recipient_pub) catch return throwCryptoError(ctx, "crypto.encryptWithPublicKey: invalid recipient public key");
    var nonce: [nonce_len]u8 = undefined;
    std.crypto.random.bytes(&nonce);
    const cipher = allocator.alloc(u8, plain.len) catch return jsc.JSValueMakeUndefined(ctx);
    var tag: [tag_len]u8 = undefined;
    ChaCha.encrypt(cipher, &tag, plain, "", nonce, shared);
    const sym_len = 1 + nonce_len + tag_len + cipher.len;
    const sym_raw = allocator.alloc(u8, sym_len) catch return jsc.JSValueMakeUndefined(ctx);
    sym_raw[0] = alg_chacha;
    @memcpy(sym_raw[1..][0..nonce_len], &nonce);
    @memcpy(sym_raw[1 + nonce_len ..][0..tag_len], &tag);
    @memcpy(sym_raw[1 + nonce_len + tag_len ..], cipher);
    const total_raw = allocator.alloc(u8, X25519.public_length + sym_len) catch return jsc.JSValueMakeUndefined(ctx);
    @memcpy(total_raw[0..X25519.public_length], &ephemeral.public_key);
    @memcpy(total_raw[X25519.public_length..], sym_raw);
    const encoded = base64EncodeAlloc(allocator, total_raw) catch return jsc.JSValueMakeUndefined(ctx);
    const ref = jsc.JSStringCreateWithUTF8CString(encoded.ptr);
    defer jsc.JSStringRelease(ref);
    secureZeroBytes(ephemeral.secret_key[0..]);
    secureZeroBytes(shared[0..]);
    return jsc.JSValueMakeString(ctx, ref);
}

/// crypto.decryptWithPrivateKey(privateKeyBase64, ciphertextBase64)
/// 单次 callback 内使用 ArenaAllocator，函数退出时一次性释放
fn decryptWithPrivateKeyCallback(
    ctx: jsc.JSContextRef,
    _: jsc.JSObjectRef,
    _: jsc.JSObjectRef,
    argumentCount: usize,
    arguments: [*]const jsc.JSValueRef,
    _: [*]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    if (argumentCount < 2) return throwCryptoError(ctx, "crypto.decryptWithPrivateKey requires (privateKey, ciphertext)");
    const backing = g_crypto_allocator orelse globals.current_allocator orelse return jsc.JSValueMakeUndefined(ctx);
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const allocator = arena.allocator();
    const priv_b64 = jsValueToUtf8Bytes(ctx, arguments[0], allocator) orelse return throwCryptoError(ctx, "crypto.decryptWithPrivateKey: privateKey must be a string");
    const b64 = jsValueToUtf8Bytes(ctx, arguments[1], allocator) orelse return throwCryptoError(ctx, "crypto.decryptWithPrivateKey: ciphertext must be a string");
    var my_priv: [X25519.secret_length]u8 = undefined;
    const decoded_priv = base64DecodeAlloc(allocator, priv_b64) catch return throwCryptoError(ctx, "crypto.decryptWithPrivateKey: invalid privateKey base64");
    if (decoded_priv.len != X25519.secret_length) return throwCryptoError(ctx, "crypto.decryptWithPrivateKey: privateKey must be 32 bytes (base64 decoded)");
    @memcpy(&my_priv, decoded_priv[0..X25519.secret_length]);
    const decoded = base64DecodeAlloc(allocator, b64) catch return throwCryptoError(ctx, "crypto.decryptWithPrivateKey: invalid ciphertext base64");
    if (decoded.len < X25519.public_length + 1 + nonce_len + tag_len)
        return throwCryptoError(ctx, "crypto.decryptWithPrivateKey: ciphertext too short");
    var ephemeral_pub: [X25519.public_length]u8 = undefined;
    @memcpy(&ephemeral_pub, decoded[0..X25519.public_length]);
    var shared = X25519.scalarmult(my_priv, ephemeral_pub) catch return throwCryptoError(ctx, "crypto.decryptWithPrivateKey: key exchange failed");
    const sym = decoded[X25519.public_length..];
    const total = sym.len;
    const has_alg_byte = total >= (1 + nonce_len + tag_len) and sym[0] <= 1;
    const alg_byte: u8 = if (has_alg_byte) sym[0] else alg_chacha;
    const off: usize = if (has_alg_byte) 1 else 0;
    if (total < off + nonce_len + tag_len) return throwCryptoError(ctx, "crypto.decryptWithPrivateKey: ciphertext too short");
    var nonce_arr: [nonce_len]u8 = undefined;
    @memcpy(&nonce_arr, sym[off..][0..nonce_len]);
    var tag_arr: [tag_len]u8 = undefined;
    @memcpy(&tag_arr, sym[off + nonce_len ..][0..tag_len]);
    const cipher_len = total - off - nonce_len - tag_len;
    const c = sym[off + nonce_len + tag_len ..][0..cipher_len];
    const plain = allocator.alloc(u8, cipher_len) catch return jsc.JSValueMakeUndefined(ctx);
    if (alg_byte == alg_aes_gcm) {
        AesGcm.decrypt(plain, c, tag_arr, "", nonce_arr, shared) catch return throwCryptoError(ctx, "crypto.decryptWithPrivateKey: authentication failed");
    } else {
        ChaCha.decrypt(plain, c, tag_arr, "", nonce_arr, shared) catch return throwCryptoError(ctx, "crypto.decryptWithPrivateKey: authentication failed");
    }
    const z = allocator.alloc(u8, plain.len + 1) catch return jsc.JSValueMakeUndefined(ctx);
    @memcpy(z[0..plain.len], plain);
    z[plain.len] = 0;
    const ref = jsc.JSStringCreateWithUTF8CString(z.ptr);
    defer jsc.JSStringRelease(ref);
    secureZeroBytes(&my_priv);
    secureZeroBytes(&shared);
    secureZeroBytes(plain);
    secureZeroBytes(z[0..plain.len]);
    return jsc.JSValueMakeString(ctx, ref);
}

fn throwCryptoError(ctx: jsc.JSContextRef, msg: []const u8) jsc.JSValueRef {
    var buf: [384]u8 = undefined;
    const prefix = "throw new DOMException(\"";
    @memcpy(buf[0..prefix.len], prefix);
    var i: usize = prefix.len;
    for (msg) |c| {
        if (i >= buf.len - 20) break;
        if (c == '"' or c == '\\') {
            buf[i] = '\\';
            i += 1;
        }
        buf[i] = c;
        i += 1;
    }
    const suffix = "\", \"OperationError\");";
    @memcpy(buf[i..][0..suffix.len], suffix);
    i += suffix.len;
    buf[i] = 0;
    const script_ref = jsc.JSStringCreateWithUTF8CString(buf[0..].ptr);
    defer jsc.JSStringRelease(script_ref);
    _ = jsc.JSEvaluateScript(ctx, script_ref, null, null, 1, null);
    return jsc.JSValueMakeUndefined(ctx);
}
