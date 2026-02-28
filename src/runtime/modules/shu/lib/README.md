# shu/lib — 共享原生依赖

本目录存放被多个 shu 模块共用的**原生实现**（Zig + C），不归属单一功能模块（如 server、net）。

## 约定

- 每个子目录对应一类依赖：`lib/<name>/`（如 `lib/tls/`）。
- 后续若有新的共用依赖，按同样方式新建 `lib/<name>/` 并在 `build.zig` 中挂到 root 或对应模块。

## 当前子目录

| 目录   | 说明 |
|--------|------|
| **tls/** | TLS 薄封装（OpenSSL）：`tls.zig` + `tls.c` + `tls.h`。供 **server**（HTTPS）、**net**（TLS 升级）、**tls**（`tls.connect`）使用。由 root 的 `@import("tls")` 暴露。 |

## 构建

- TLS 由 `build.zig` 的 `-Dtls` 控制是否启用；启用时编译 `lib/tls/tls.c` 并链接 OpenSSL（ssl/crypto）。
