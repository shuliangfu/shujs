// 服务端共享类型：供 parse / response / options / ws_server / conn / lifecycle 等子模块使用

const std = @import("std");
const jsc = @import("jsc");

/// 单次请求解析结果：请求行 + 原始头部块（供 getHeader 零拷贝查找）+ 可选 body
/// 使用 tryParseHeadersFromBufferZeroCopy 时，method/path/headers_head 均为 read_buf 内切片，上层不得复制整块头部；仅在与 C/JS 边界需 null 结尾时可对 method/path 做 dupeZ
pub const ParsedRequest = struct {
    method: []const u8,
    path: []const u8,
    headers_head: []const u8,
    body: ?[]const u8,
};

/// 服务端可配置项：从 options 解析后传入 listen / 请求处理 / 写响应 等
pub const ServerConfig = struct {
    keep_alive_timeout_sec: u32,
    chunked_response_threshold: usize,
    chunked_write_chunk_size: usize,
    max_request_line: usize,
    min_body_to_compress: usize,
    listen_backlog: u32,
    max_request_body: usize,
    max_connections: usize = 512,
    /// 单次 pollCompletions 最多返回的完成项数量（io_core 预分配）；可配置，默认 256，范围建议 64～5120
    max_completions: usize = 256,
    max_accept_per_tick: u32 = 8,
    ws_max_write_per_tick: usize = 128 * 1024,
    read_buffer_size: usize = 64 * 1024,
    write_buf_initial_capacity: usize = 4096,
    header_list_initial_capacity: usize = 4096,
    ws_read_buffer_size: usize = 128 * 1024,
    ws_max_payload_size: usize = 64 * 1024,
    ws_frame_buffer_size: usize = 64 * 1024,
    /// io_core 空闲时 pollCompletions 超时的**上限**（毫秒）：实际超时由运行时自适应在 0～此值之间调节；0=不允许阻塞；>0=空闲时最多阻塞 N 毫秒（options.pollIdleMs，默认 100）
    io_core_poll_idle_ms: i64 = 100,
    /// 可选 Server 头值（如 "Shu/1.0"）；为 null 时使用默认 "Shu"。预编码优化：响应中写 "Server: {value}\r\n"，可由 options.server 覆盖
    server_header: ?[]const u8 = null,
};

/// chunked 增量解析状态：读 size 行 或 读 chunk 数据（剩余字节数）
pub const ChunkedParseState = union(enum) {
    reading_size_line: void,
    reading_chunk_data: usize,
};

/// 非阻塞路径存 fd（入队 write_buf）；handoff 后阻塞路径存 write_fn+ctx
pub const WsSendEntry = union(enum) {
    fd: usize,
    blocking: struct {
        write_fn: *const fn (*anyopaque, []const u8) void,
        ctx: *anyopaque,
    },
};

/// options.webSocket 回调：onOpen?(ws)、onMessage(ws, data)、onClose?(ws)、onError?(ws, message)
pub const WsOptions = struct {
    on_open: ?jsc.JSValueRef,
    on_message: jsc.JSValueRef,
    on_close: ?jsc.JSValueRef,
    on_error: ?jsc.JSValueRef,
};
