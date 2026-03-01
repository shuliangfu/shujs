// 单次运行的选项：入口路径、cwd、argv、权限（供 process / __dirname / Shu.fs.read 等使用）
// 参考：SHU_RUNTIME_ANALYSIS.md Phase 1

/// 与 CLI 解析后的权限对齐，运行时据此做 --allow-read 等检查
/// 保留字段：locale 默认值（当前输出均为英文，不再使用 i18n）
pub const default_locale: []const u8 = "en-US";

/// 与 CLI 解析后的权限对齐；与 Deno 一致：--allow-net/read/env/write/run/hrtime/ffi
pub const Permissions = struct {
    allow_net: bool = false,
    allow_read: bool = false,
    allow_env: bool = false,
    allow_write: bool = false,
    /// 是否允许执行子进程（Shu.system.exec / run / spawn 等），对应 --allow-run
    allow_run: bool = false,
    /// 是否允许高精度时间（如 performance.now()），对应 --allow-hrtime；预留，当前未强制校验
    allow_hrtime: bool = false,
    /// 是否允许 FFI 动态库加载，对应 --allow-ffi；预留，当前未实现
    allow_ffi: bool = false,
};

/// 一次 shu run 的上下文（由 cli/run 构建并传给 VM）
pub const RunOptions = struct {
    /// 入口文件路径（可为相对或绝对，用于 __filename / __dirname）
    entry_path: []const u8,
    /// 当前工作目录（用于 process.cwd()、读文件时的基准）
    cwd: []const u8,
    /// 完整命令行参数（用于 process.argv）
    argv: []const []const u8,
    permissions: Permissions,
    /// 保留：语言/地区（当前未使用，输出为硬编码英文）
    locale: []const u8 = default_locale,
    /// 是否为 Shu.system.fork() 启动的子进程（env SHU_FORKED=1 时为 true，启用 process.send/receiveSync）
    is_forked: bool = false,
    /// 是否为 Shu.thread.spawn() 启动的工作线程；为 true 时 thread_channel 非 null，process.send/receiveSync 走 channel
    is_thread_worker: bool = false,
    /// 工作线程消息通道（仅 is_thread_worker 时有效，类型为 *thread_worker.ThreadChannel）
    thread_channel: ?*anyopaque = null,
};
