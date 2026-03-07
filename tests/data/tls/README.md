# 测试用 TLS 证书与私钥

供 `shu:server`、`shu:https`、`shu:http2` 等模块的 HTTPS/HTTP2 测试使用。

- **cert.pem**：自签名证书（CN=localhost，SAN: localhost, 127.0.0.1），有效期 10 年
- **key.pem**：对应私钥（无密码）

## 在测试中使用

```js
const path = require("shu:path");
const certPath = path.join(__dirname, "../../data/tls/cert.pem");
const keyPath = path.join(__dirname, "../../data/tls/key.pem");
// 或直接写相对项目根的路径：tests/data/tls/cert.pem / tests/data/tls/key.pem
```

环境变量（可选）：`TLS_CERT_PATH`、`TLS_KEY_PATH` 指向上述路径时，部分集成测试会启动真实 HTTPS 服务。

## 重新生成

```bash
cd tests/data/tls
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
```
