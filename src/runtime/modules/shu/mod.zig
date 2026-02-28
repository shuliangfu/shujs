// shu:* 内置模块（shu:fs、shu:env 等）
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1、BUILTINS.md P2 协议
//
// 本目录为 Shu.fs、Shu.path、Shu.system 的唯一实现；engine 不再保留重复代码。
// engine/shu/mod.zig 通过 @import("../modules/shu/fs/mod.zig") 等直接调用；
// process、system/fork_child 等在本目录内互相引用（如 ipc.zig、run.zig、fork_child.zig）。
//
// JS/TS 端预期用法（待 loader 接入后）：
//   静态：import * as fs from "shu:fs";  // fs.readSync(path) 等
//   动态：const fs = await import("shu:fs");  // 注意需 await，在 async 中或 .then()
// 当前未接入时，文件能力请用全局 Shu.fs（Shu.fs.readSync、Shu.fs.writeSync 等）。

const std = @import("std");

/// Shu 模块命名空间（shu:fs、shu:env 等）
pub const shu = struct {
    /// 注册 Shu 模块（占位；Shu.fs/path/system 由 engine/shu/mod.zig 引用本目录下 fs/、path/、system/ 注册）
    pub fn init() void {
        _ = std;
    }
};
