// 权限模型（--allow-net/read/env 等标志与运行时校验）
// 参考：SHU_RUNTIME_ANALYSIS.md 6.1

const std = @import("std");

/// 当前进程的权限掩码（与 cli.args.ParsedArgs 对齐）
pub const Permissions = struct {
    allow_net: bool = false,
    allow_read: bool = false,
    allow_env: bool = false,
    allow_write: bool = false,
    allow_exec: bool = false,

    /// 检查是否允许网络访问
    pub fn canNet(self: Permissions) bool {
        return self.allow_net;
    }
    /// 检查是否允许读文件
    pub fn canRead(self: Permissions) bool {
        return self.allow_read;
    }
    /// 检查是否允许读环境变量
    pub fn canEnv(self: Permissions) bool {
        return self.allow_env;
    }
    /// 检查是否允许写文件
    pub fn canWrite(self: Permissions) bool {
        return self.allow_write;
    }
    /// 检查是否允许执行系统命令（Shu.system.exec / run / spawn 等）
    pub fn canExec(self: Permissions) bool {
        return self.allow_exec;
    }
};
