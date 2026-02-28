#!/usr/bin/env bash
# 使用 Bun 官方预编译的 WebKit/JSC，免去自编 WebKit。产出供 shu 链接用的 include/ 与 lib/。
# 用法：在 shu-core 仓库根目录执行：./deps/download-jsc-from-bun.sh [linux-amd64|linux-arm64|macos-amd64|macos-arm64]
# 依赖：curl、tar（不依赖 Node.js/npm）。
# 说明：Bun 在 npm 上仅发布 Linux/macOS 预编译包，无 Windows 版；Windows 需用 GitHub Actions 或本机 deps/build-jsc-for-windows.ps1。

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHU_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLATFORM="${1:-linux-amd64}"
TMP_DIR="$SHU_ROOT/deps/.bun-webkit-tmp"
PKG_NAME="bun-webkit-$PLATFORM"

case "$PLATFORM" in
  linux-amd64|linux-arm64)
    OUTPUT_DIR="$SHU_ROOT/deps/install-linux"
    ;;
  macos-amd64|macos-arm64)
    OUTPUT_DIR="$SHU_ROOT/deps/install-macos"
    ;;
  windows*)
    echo "Bun 未在 npm 发布 Windows 版 bun-webkit，无法通过本脚本下载。" >&2
    echo "Windows 请使用：GitHub Actions 产出 artifact，或在本机 Windows 上执行 deps/build-jsc-for-windows.ps1" >&2
    exit 1
    ;;
  *)
    echo "用法: $0 [linux-amd64|linux-arm64|macos-amd64|macos-arm64]" >&2
    echo "说明: Windows 无 Bun 预编译包，请用 deps/build-jsc-for-windows.ps1 或 CI 构建。" >&2
    exit 1
    ;;
esac

echo "使用 Bun 预编译 JSC：$PLATFORM"
echo "产出目录: $OUTPUT_DIR"
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
cd "$TMP_DIR"

# 从 npm registry 拉取 tarball（不依赖 Node/npm，避免 nvm/fnm 等「node 服务」报错）
REGISTRY="${NPM_REGISTRY:-https://registry.npmjs.org}"
echo "从 $REGISTRY 获取 $PKG_NAME 最新版本..."
META=$(curl -sSfL "$REGISTRY/$PKG_NAME/latest") || { echo "error: 无法获取 $PKG_NAME 版本信息" >&2; exit 1; }
TARBALL=$(echo "$META" | grep -o '"tarball":"[^"]*"' | head -1 | sed 's/"tarball":"//;s/"$//')
if [[ -z "$TARBALL" ]]; then
  echo "error: 未解析到 tarball 地址" >&2
  exit 1
fi
echo "下载: $TARBALL"
curl -sSfL "$TARBALL" -o pkg.tgz || { echo "error: 下载失败" >&2; exit 1; }
tar -xzf pkg.tgz
# npm 包解压后根目录为 package/
PKG_DIR="$TMP_DIR/package"
if [[ ! -d "$PKG_DIR" ]]; then
  echo "error: 解压后未找到 package 目录" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR/include"
mkdir -p "$OUTPUT_DIR/lib"

# 拷贝库（Bun 包内多为 lib/*.a、*.so（Linux）或 *.dylib（macOS））
if [[ -d "$PKG_DIR/lib" ]]; then
  cp -r "$PKG_DIR/lib"/* "$OUTPUT_DIR/lib/" 2>/dev/null || true
fi
# 部分布局可能是根目录下的库文件
find "$PKG_DIR" -maxdepth 2 -type f \( -name "*.a" -o -name "*.so" -o -name "*.dylib" \) -exec cp {} "$OUTPUT_DIR/lib/" \; 2>/dev/null || true

# 头文件：Bun 包可能不含 C API 头文件，从 WebKit 仓库拉取 JavaScriptCore/API（与 Bun 使用的 JSC 版本兼容）
if [[ -d "$PKG_DIR/include" ]]; then
  cp -r "$PKG_DIR/include"/* "$OUTPUT_DIR/include/" 2>/dev/null || true
fi
if [[ ! -d "$OUTPUT_DIR/include" ]] || [[ -z "$(ls -A "$OUTPUT_DIR/include" 2>/dev/null)" ]]; then
  echo "从 WebKit 仓库拉取 JSC C API 头文件..."
  API_URL="https://raw.githubusercontent.com/WebKit/WebKit/main/Source/JavaScriptCore/API"
  for h in JSBase.h JSContextRef.h JSObjectRef.h JSStringRef.h JSValueRef.h JavaScriptCore.h; do
    curl -sSfL "$API_URL/$h" -o "$OUTPUT_DIR/include/$h" 2>/dev/null || true
  done
fi

rm -rf "$TMP_DIR"
echo "完成。JSC 已产出到: $OUTPUT_DIR"
echo "构建 shu 时使用: zig build -Djsc_prefix=$OUTPUT_DIR"
