/**
 * TLS 服务端实现：OpenSSL SSL_CTX + SSL_accept/read/write。
 * 编译需链接 -lssl -lcrypto。
 * BIO 模式：用于 Windows IOCP，握手与连接读写由调用方用 overlapped recv/send 驱动。
 */
#include "tls.h"
#include <openssl/ssl.h>
#include <openssl/err.h>
#include <openssl/bio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct tls_ctx {
    SSL_CTX *ctx;
};

struct tls_conn {
    SSL *ssl;
    int fd;
    int last_ret; /* 上次 SSL_read/SSL_write 返回值，供 want_read/want_write */
};

/** 非阻塞握手中：持有 SSL 未完成握手，由 tls_accept_start 创建、tls_accept_step 推进或 tls_pending_free 释放 */
struct tls_pending {
    SSL_CTX *ctx;
    SSL *ssl;
    int fd;
    int last_ret; /* SSL_accept 上次返回值，供 want_read/want_write 用 */
};

/** 客户端 TLS 上下文：仅持有 SSL_CTX，用于 tls_connect */
struct tls_client_ctx {
    SSL_CTX *ctx;
};

tls_ctx_t *tls_ctx_create(const char *cert_path, const char *key_path) {
    const SSL_METHOD *method = TLS_server_method();
    if (!method) return NULL;
    SSL_CTX *ctx = SSL_CTX_new(method);
    if (!ctx) return NULL;
    if (SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION) != 1) {
        SSL_CTX_free(ctx);
        return NULL;
    }
    if (SSL_CTX_use_certificate_file(ctx, cert_path, SSL_FILETYPE_PEM) != 1) {
        SSL_CTX_free(ctx);
        return NULL;
    }
    if (SSL_CTX_use_PrivateKey_file(ctx, key_path, SSL_FILETYPE_PEM) != 1) {
        SSL_CTX_free(ctx);
        return NULL;
    }
    if (SSL_CTX_check_private_key(ctx) != 1) {
        SSL_CTX_free(ctx);
        return NULL;
    }
    /* ALPN: 服务端通告 h2，握手后可用 tls_get_alpn_selected 判断是否走 HTTP/2 */
    static const unsigned char alpn_protos[] = { 2, 'h', '2' };
    if (SSL_CTX_set_alpn_protos(ctx, alpn_protos, sizeof(alpn_protos)) != 0) {
        SSL_CTX_free(ctx);
        return NULL;
    }
    tls_ctx_t *t = (tls_ctx_t *)malloc(sizeof(tls_ctx_t));
    if (!t) {
        SSL_CTX_free(ctx);
        return NULL;
    }
    t->ctx = ctx;
    return t;
}

void tls_ctx_free(tls_ctx_t *t) {
    if (!t) return;
    if (t->ctx) SSL_CTX_free(t->ctx);
    free(t);
}

tls_conn_t *tls_accept(tls_ctx_t *t, int fd) {
    if (!t || fd < 0) return NULL;
    SSL *ssl = SSL_new(t->ctx);
    if (!ssl) return NULL;
    if (SSL_set_fd(ssl, fd) != 1) {
        SSL_free(ssl);
        return NULL;
    }
    if (SSL_accept(ssl) <= 0) {
        SSL_free(ssl);
        return NULL;
    }
    tls_conn_t *conn = (tls_conn_t *)malloc(sizeof(tls_conn_t));
    if (!conn) {
        SSL_free(ssl);
        return NULL;
    }
    conn->ssl = ssl;
    conn->fd = fd;
    conn->last_ret = 0;
    return conn;
}

/* 非阻塞握手：调用方须已将 fd 设为 non-blocking */
tls_pending_t *tls_accept_start(tls_ctx_t *t, int fd) {
    if (!t || fd < 0) return NULL;
    SSL *ssl = SSL_new(t->ctx);
    if (!ssl) return NULL;
    if (SSL_set_fd(ssl, fd) != 1) {
        SSL_free(ssl);
        return NULL;
    }
    tls_pending_t *p = (tls_pending_t *)malloc(sizeof(tls_pending_t));
    if (!p) {
        SSL_free(ssl);
        return NULL;
    }
    p->ctx = t->ctx;
    p->ssl = ssl;
    p->fd = fd;
    p->last_ret = 0;
    return p;
}

/* 返回 1=成功(out_conn 已写入并释放 pending)，0=需 poll 后再调，-1=错误 */
int tls_accept_step(tls_pending_t *pending, tls_conn_t **out_conn) {
    if (!pending || !pending->ssl) return -1;
    int r = SSL_accept(pending->ssl);
    pending->last_ret = r;
    if (r == 1) {
        tls_conn_t *conn = (tls_conn_t *)malloc(sizeof(tls_conn_t));
        if (!conn) return -1;
        conn->ssl = pending->ssl;
        conn->fd = pending->fd;
        conn->last_ret = 0;
        pending->ssl = NULL;
        tls_pending_free(pending);
        if (out_conn) *out_conn = conn;
        return 1;
    }
    switch (SSL_get_error(pending->ssl, r)) {
        case SSL_ERROR_WANT_READ:
        case SSL_ERROR_WANT_WRITE:
            return 0;
        default:
            return -1;
    }
}

int tls_pending_want_read(tls_pending_t *pending) {
    if (!pending || !pending->ssl) return 0;
    return (SSL_get_error(pending->ssl, pending->last_ret) == SSL_ERROR_WANT_READ) ? 1 : 0;
}

int tls_pending_want_write(tls_pending_t *pending) {
    if (!pending || !pending->ssl) return 0;
    return (SSL_get_error(pending->ssl, pending->last_ret) == SSL_ERROR_WANT_WRITE) ? 1 : 0;
}

void tls_pending_free(tls_pending_t *pending) {
    if (!pending) return;
    if (pending->ssl) {
        SSL_free(pending->ssl);
        pending->ssl = NULL;
    }
    pending->fd = -1;
    free(pending);
}

int tls_read(tls_conn_t *conn, void *buf, int len) {
    if (!conn || !conn->ssl || !buf || len <= 0) return -1;
    int n = SSL_read(conn->ssl, buf, len);
    conn->last_ret = n;
    if (n > 0) return n;
    if (n == 0) return (SSL_get_error(conn->ssl, 0) == SSL_ERROR_ZERO_RETURN) ? 0 : -1;
    switch (SSL_get_error(conn->ssl, n)) {
        case SSL_ERROR_WANT_READ:  return -2;
        case SSL_ERROR_WANT_WRITE: return -3;
        case SSL_ERROR_ZERO_RETURN: return 0;
        default: return -1;
    }
}

int tls_write(tls_conn_t *conn, const void *buf, int len) {
    if (!conn || !conn->ssl || !buf || len <= 0) return -1;
    int n = SSL_write(conn->ssl, buf, (int)len);
    conn->last_ret = n;
    if (n > 0) return n;
    if (n == 0) return -1;
    switch (SSL_get_error(conn->ssl, n)) {
        case SSL_ERROR_WANT_READ:  return -2;
        case SSL_ERROR_WANT_WRITE: return -3;
        default: return -1;
    }
}

int tls_conn_want_read(tls_conn_t *conn) {
    if (!conn || !conn->ssl) return 0;
    return (SSL_get_error(conn->ssl, conn->last_ret) == SSL_ERROR_WANT_READ) ? 1 : 0;
}

int tls_conn_want_write(tls_conn_t *conn) {
    if (!conn || !conn->ssl) return 0;
    return (SSL_get_error(conn->ssl, conn->last_ret) == SSL_ERROR_WANT_WRITE) ? 1 : 0;
}

/** 取 ALPN 协商结果；buf 为输出缓冲区，返回协议名长度，0 表示未协商或失败。调用方据此判断是否走 h2。 */
int tls_get_alpn_selected(tls_conn_t *conn, char *buf, unsigned int buf_size) {
    if (!conn || !conn->ssl || !buf || buf_size == 0) return 0;
    const unsigned char *out = NULL;
    unsigned int len = 0;
    SSL_get0_alpn_selected(conn->ssl, &out, &len);
    if (!out || len == 0 || len >= buf_size) return 0;
    memcpy(buf, out, len);
    buf[len] = '\0';
    return (int)len;
}

void tls_close(tls_conn_t *conn) {
    if (!conn) return;
    if (conn->ssl) {
        SSL_shutdown(conn->ssl);
        SSL_free(conn->ssl);
        conn->ssl = NULL;
    }
    /* fd 由调用方（Zig）通过 stream.close() 关闭；BIO 模式时 fd 为 -1 */
    conn->fd = -1;
    free(conn);
}

/* ---------- 客户端实现 ---------- */

tls_client_ctx_t *tls_client_ctx_create(const char *ca_path, int verify_peer) {
    const SSL_METHOD *method = TLS_client_method();
    if (!method) return NULL;
    SSL_CTX *ctx = SSL_CTX_new(method);
    if (!ctx) return NULL;
    if (SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION) != 1) {
        SSL_CTX_free(ctx);
        return NULL;
    }
    if (verify_peer) {
        SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
        if (ca_path && ca_path[0] != '\0') {
            if (SSL_CTX_load_verify_locations(ctx, ca_path, NULL) != 1 &&
                SSL_CTX_load_verify_locations(ctx, NULL, ca_path) != 1) {
                SSL_CTX_free(ctx);
                return NULL;
            }
        } else {
            if (SSL_CTX_set_default_verify_paths(ctx) != 1) {
                SSL_CTX_free(ctx);
                return NULL;
            }
        }
    } else {
        SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);
    }
    tls_client_ctx_t *t = (tls_client_ctx_t *)malloc(sizeof(tls_client_ctx_t));
    if (!t) {
        SSL_CTX_free(ctx);
        return NULL;
    }
    t->ctx = ctx;
    return t;
}

void tls_client_ctx_free(tls_client_ctx_t *t) {
    if (!t) return;
    if (t->ctx) SSL_CTX_free(t->ctx);
    free(t);
}

tls_conn_t *tls_connect(tls_client_ctx_t *t, int fd, const char *servername) {
    if (!t || !t->ctx || fd < 0) return NULL;
    SSL *ssl = SSL_new(t->ctx);
    if (!ssl) return NULL;
    if (SSL_set_fd(ssl, fd) != 1) {
        SSL_free(ssl);
        return NULL;
    }
    if (servername && servername[0] != '\0') {
        if (SSL_set_tlsext_host_name(ssl, servername) != 1) {
            SSL_free(ssl);
            return NULL;
        }
    }
    if (SSL_connect(ssl) <= 0) {
        SSL_free(ssl);
        return NULL;
    }
    tls_conn_t *conn = (tls_conn_t *)malloc(sizeof(tls_conn_t));
    if (!conn) {
        SSL_free(ssl);
        return NULL;
    }
    conn->ssl = ssl;
    conn->fd = fd;
    conn->last_ret = 0;
    return conn;
}

/* ---------- BIO 模式实现 ---------- */

tls_pending_t *tls_accept_start_bio(tls_ctx_t *t) {
    if (!t || !t->ctx) return NULL;
    SSL *ssl = SSL_new(t->ctx);
    if (!ssl) return NULL;
    BIO *rbio = BIO_new(BIO_s_mem());
    BIO *wbio = BIO_new(BIO_s_mem());
    if (!rbio || !wbio) {
        if (rbio) BIO_free(rbio);
        if (wbio) BIO_free(wbio);
        SSL_free(ssl);
        return NULL;
    }
    SSL_set_bio(ssl, rbio, wbio);
    tls_pending_t *p = (tls_pending_t *)malloc(sizeof(tls_pending_t));
    if (!p) {
        SSL_free(ssl);
        return NULL;
    }
    p->ctx = t->ctx;
    p->ssl = ssl;
    p->fd = -1;
    p->last_ret = 0;
    return p;
}

int tls_pending_feed_read(tls_pending_t *pending, const void *buf, int len) {
    if (!pending || !pending->ssl || !buf || len <= 0) return -1;
    BIO *rbio = SSL_get_rbio(pending->ssl);
    if (!rbio) return -1;
    return (BIO_write(rbio, buf, len) > 0) ? 0 : -1;
}

int tls_pending_get_send(tls_pending_t *pending, void *buf, int max_len) {
    if (!pending || !pending->ssl || !buf || max_len <= 0) return 0;
    BIO *wbio = SSL_get_wbio(pending->ssl);
    if (!wbio) return 0;
    int n = BIO_read(wbio, buf, max_len);
    return (n > 0) ? n : 0;
}

int tls_pending_accept_step_bio(tls_pending_t *pending, tls_conn_t **out_conn) {
    if (!pending || !pending->ssl || !out_conn) return -1;
    int r = SSL_accept(pending->ssl);
    pending->last_ret = r;
    if (r == 1) {
        tls_conn_t *conn = (tls_conn_t *)malloc(sizeof(tls_conn_t));
        if (!conn) return -1;
        conn->ssl = pending->ssl;
        conn->fd = -1; /* BIO 模式，无 fd */
        conn->last_ret = 0;
        pending->ssl = NULL;
        free(pending);
        *out_conn = conn;
        return 1;
    }
    switch (SSL_get_error(pending->ssl, r)) {
        case SSL_ERROR_WANT_READ:
        case SSL_ERROR_WANT_WRITE:
            return 0;
        default:
            return -1;
    }
}

int tls_conn_is_bio(tls_conn_t *conn) {
    return (conn && conn->fd == -1) ? 1 : 0;
}

int tls_conn_feed_read(tls_conn_t *conn, const void *buf, int len) {
    if (!conn || !conn->ssl || conn->fd != -1 || !buf || len <= 0) return -1;
    BIO *rbio = SSL_get_rbio(conn->ssl);
    if (!rbio) return -1;
    return (BIO_write(rbio, buf, len) > 0) ? 0 : -1;
}

int tls_conn_read_after_feed(tls_conn_t *conn, void *buf, int len) {
    if (!conn || !conn->ssl || conn->fd != -1 || !buf || len <= 0) return -1;
    int n = SSL_read(conn->ssl, buf, len);
    conn->last_ret = n;
    if (n > 0) return n;
    if (n == 0) return (SSL_get_error(conn->ssl, 0) == SSL_ERROR_ZERO_RETURN) ? 0 : -1;
    switch (SSL_get_error(conn->ssl, n)) {
        case SSL_ERROR_WANT_READ:  return -2;
        case SSL_ERROR_WANT_WRITE: return -3;
        case SSL_ERROR_ZERO_RETURN: return 0;
        default: return -1;
    }
}

int tls_conn_get_send(tls_conn_t *conn, void *buf, int max_len) {
    if (!conn || !conn->ssl || conn->fd != -1 || !buf || max_len <= 0) return 0;
    BIO *wbio = SSL_get_wbio(conn->ssl);
    if (!wbio) return 0;
    int n = BIO_read(wbio, buf, max_len);
    return (n > 0) ? n : 0;
}

int tls_conn_write_app(tls_conn_t *conn, const void *buf, int len) {
    if (!conn || !conn->ssl || conn->fd != -1 || !buf || len <= 0) return -1;
    int n = SSL_write(conn->ssl, buf, (int)len);
    conn->last_ret = n;
    if (n > 0) return n;
    if (n == 0) return -1;
    switch (SSL_get_error(conn->ssl, n)) {
        case SSL_ERROR_WANT_READ:  return -2;
        case SSL_ERROR_WANT_WRITE: return -3;
        default: return -1;
    }
}
