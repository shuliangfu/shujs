/**
 * TLS 服务端/客户端薄封装：基于 OpenSSL，供 Zig server 与 shu:tls 模块使用。
 * 服务端：证书/密钥创建 ctx，accept 得到 conn，read/write/close。
 * 客户端：CA/校验选项创建 client_ctx，connect(fd, servername) 得到 conn，复用同一 read/write/close。
 * 支持阻塞与非阻塞（accept/connect 的 start/step）；BIO 模式供 Windows IOCP。
 */
#ifndef SHU_TLS_H
#define SHU_TLS_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct tls_ctx tls_ctx_t;
typedef struct tls_conn tls_conn_t;
typedef struct tls_pending tls_pending_t;
typedef struct tls_client_ctx tls_client_ctx_t;

/** 从证书与私钥文件路径创建服务端 TLS 上下文；路径为 UTF-8，失败返回 NULL */
tls_ctx_t *tls_ctx_create(const char *cert_path, const char *key_path);
void tls_ctx_free(tls_ctx_t *ctx);

/** 对已 accept 的 socket fd 做服务端 TLS 握手，返回连接句柄；失败返回 NULL（调用方需 close(fd)）。阻塞式。 */
tls_conn_t *tls_accept(tls_ctx_t *ctx, int fd);

/** 非阻塞握手：fd 须已设为 non-blocking。返回握手中句柄，失败返回 NULL（调用方需 close(fd)） */
tls_pending_t *tls_accept_start(tls_ctx_t *ctx, int fd);
/** 推进握手：out_conn 可为 NULL。返回 1=成功且 out_conn 已写入，0=未完成需 poll 后再调，-1=错误（调用方 tls_pending_free 并 close(fd)） */
int tls_accept_step(tls_pending_t *pending, tls_conn_t **out_conn);
/** 未完成时当前需等待可读则为 1，否则 0 */
int tls_pending_want_read(tls_pending_t *pending);
/** 未完成时当前需等待可写则为 1，否则 0 */
int tls_pending_want_write(tls_pending_t *pending);
/** 释放握手中句柄（不关 fd）；握手成功时由 tls_accept_step 内部释放，勿再 free */
void tls_pending_free(tls_pending_t *pending);

/** 取 ALPN 协商结果；buf 写入协议名（如 "h2"），buf_size 为 buf 大小；返回协议名长度，0 表示未选或失败 */
int tls_get_alpn_selected(tls_conn_t *conn, char *buf, unsigned int buf_size);

/** 从 TLS 连接读入数据；返回读到的字节数；0 表示对端关闭；-1 表示错误；-2 表示 WANT_READ；-3 表示 WANT_WRITE（fd 须已 non-blocking） */
int tls_read(tls_conn_t *conn, void *buf, int len);
/** 向 TLS 连接写入数据；返回写入的字节数；-1 表示错误；-2 表示 WANT_READ；-3 表示 WANT_WRITE（fd 须已 non-blocking） */
int tls_write(tls_conn_t *conn, const void *buf, int len);
/** 上次 read/write 返回 -2/-3 时，当前需等待可读则为 1 */
int tls_conn_want_read(tls_conn_t *conn);
/** 上次 read/write 返回 -2/-3 时，当前需等待可写则为 1 */
int tls_conn_want_write(tls_conn_t *conn);

/** 关闭并释放 TLS 连接（会 SSL_shutdown + SSL_free；不关闭 fd，由调用方关闭） */
void tls_close(tls_conn_t *conn);

/* ---------- 客户端 API（与 server 共用 tls_conn_t / tls_read / tls_write / tls_close） ---------- */
/** 创建客户端 TLS 上下文。ca_path 为 CA 证书文件或目录路径（PEM），可为 NULL 使用系统默认；verify_peer 非 0 时验证服务端证书。失败返回 NULL */
tls_client_ctx_t *tls_client_ctx_create(const char *ca_path, int verify_peer);
void tls_client_ctx_free(tls_client_ctx_t *ctx);
/** 对已连接的 fd 做客户端 TLS 握手；servername 用于 SNI，可为 NULL。阻塞式。失败返回 NULL（调用方需 close(fd)） */
tls_conn_t *tls_connect(tls_client_ctx_t *ctx, int fd, const char *servername);

/* ---------- BIO 模式：供 Windows IOCP 用 overlapped recv/send 驱动，无 fd 读写 ---------- */
/** 创建握手中句柄（BIO 模式）：无 fd，调用方用 tls_pending_feed_read + tls_pending_get_send 与 overlapped I/O 配合 */
tls_pending_t *tls_accept_start_bio(tls_ctx_t *ctx);
/** 向握手中 SSL 的读 BIO 喂入加密数据（来自 WSARecv 完成）；返回 0 成功，-1 错误 */
int tls_pending_feed_read(tls_pending_t *pending, const void *buf, int len);
/** 从握手中 SSL 的写 BIO 取出待发送加密数据；返回字节数，0 表示无数据。buf 由调用方提供，用于 post WSASend */
int tls_pending_get_send(tls_pending_t *pending, void *buf, int max_len);
/** 推进 BIO 模式握手；返回 1=成功(out_conn 已写入)，0=需再喂数据/取数据后重试，-1=错误。成功时 pending 被内部释放，勿再 free */
int tls_pending_accept_step_bio(tls_pending_t *pending, tls_conn_t **out_conn);

/** 判断 conn 是否为 BIO 模式（由 tls_pending_accept_step_bio 得到的 conn；fd 为 -1） */
int tls_conn_is_bio(tls_conn_t *conn);
/** 向已握手连接的读 BIO 喂入加密数据；返回 0 成功，-1 错误 */
int tls_conn_feed_read(tls_conn_t *conn, const void *buf, int len);
/** 喂入后从 SSL 读明文；语义同 tls_read：返回 >0 字节数，0 对端关闭，-2 WANT_READ，-3 WANT_WRITE，-1 错误 */
int tls_conn_read_after_feed(tls_conn_t *conn, void *buf, int len);
/** 从写 BIO 取出待发送加密数据；返回字节数，0 表示无。用于 WSASend 投递 */
int tls_conn_get_send(tls_conn_t *conn, void *buf, int max_len);
/** 应用层写（明文）；语义同 tls_write：返回 >0 字节数，-2 WANT_READ，-3 WANT_WRITE，-1 错误。可能使写 BIO 有数据，需 tls_conn_get_send 取出 */
int tls_conn_write_app(tls_conn_t *conn, const void *buf, int len);

#ifdef __cplusplus
}
#endif

#endif /* SHU_TLS_H */
