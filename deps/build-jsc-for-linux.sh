#!/usr/bin/env bash
# 在 Mac 上通过 Docker 为 Linux 构建 JavaScriptCore（JSC），产出供 shu 在 Linux 上链接用的 include/ 与 lib/。
# 用法：在 shu-core 仓库根目录执行：./deps/build-jsc-for-linux.sh
# 依赖：本机已安装 Docker；WebKit 源码路径固定为 /home/shu/WebKit（可改下方 WEBKIT_SRC）。
#
# 说明：WebKit 不支持「在 Mac 上直接交叉编译出 Linux/Windows 的 jsc-only」（需目标系统工具链与构建环境）。
#       Linux 版：通过本脚本在 Docker 内按 Linux 环境构建；若默认源较慢或报 GPG 错误，脚本会尝试改用国内镜像。
#       Windows 版：需在 Windows 本机或 CI（如 GitHub Actions windows-latest）中构建。

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHU_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# WebKit 源码目录（已删除 deps/webkit 软链接，直接使用固定路径）
WEBKIT_SRC="${WEBKIT_SRC:-/home/shu/WebKit}"
INSTALL_LINUX="$SHU_ROOT/deps/install-linux"

if [[ ! -d "$WEBKIT_SRC" ]]; then
  echo "error: WebKit 源码目录不存在: $WEBKIT_SRC" >&2
  exit 1
fi
if ! command -v docker &>/dev/null; then
  echo "error: 未找到 docker，请先安装 Docker。" >&2
  exit 1
fi

echo "WebKit 源码: $WEBKIT_SRC"
echo "产出目录:    $INSTALL_LINUX"
echo "使用 Docker 镜像 Ubuntu 24.04 在容器内构建 JSC（需 GCC 12.2+，约需数分钟）..."
echo ""

# 使用 linux/amd64 以便产出 x86_64 Linux 可用的 JSC（若本机为 ARM Mac 会通过 QEMU 模拟，速度较慢但可行）
# 使用 Ubuntu 24.04：默认 GCC 13，满足 WebKit 对 GCC 12.2+ 的要求
docker run --rm --platform linux/amd64 \
  -v "$WEBKIT_SRC:/webkit_src:rw" \
  -v "$SHU_ROOT:/work:rw" \
  -w /webkit_src \
  ubuntu:24.04 \
  bash -c '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    # 先尝试默认源；若失败则改用国内镜像（Ubuntu 24.04 代号 noble）
    if ! apt-get update -qq 2>/dev/null; then
      echo "apt 默认源失败，尝试使用国内镜像..."
      MIRROR="mirrors.aliyun.com"
      cat > /etc/apt/sources.list <<MIRRORLIST
deb http://${MIRROR}/ubuntu/ noble main restricted universe multiverse
deb http://${MIRROR}/ubuntu/ noble-updates main restricted universe multiverse
deb http://${MIRROR}/ubuntu/ noble-security main restricted universe multiverse
deb http://${MIRROR}/ubuntu/ noble-backports main restricted universe multiverse
MIRRORLIST
      if ! apt-get update -qq 2>/dev/null; then
        MIRROR="mirrors.tuna.tsinghua.edu.cn"
        cat > /etc/apt/sources.list <<MIRRORLIST
deb http://${MIRROR}/ubuntu/ noble main restricted universe multiverse
deb http://${MIRROR}/ubuntu/ noble-updates main restricted universe multiverse
deb http://${MIRROR}/ubuntu/ noble-security main restricted universe multiverse
deb http://${MIRROR}/ubuntu/ noble-backports main restricted universe multiverse
MIRRORLIST
        apt-get update -qq || true
      fi
    fi
    apt-get install -y -qq ca-certificates 2>/dev/null || true
    apt-get update -qq 2>/dev/null || true
    # 若仍无可用包列表（GPG 等导致 update 失败），用允许未校验方式更新一次以便安装构建依赖
    if ! apt-cache show libicu-dev &>/dev/null; then
      echo "包列表不可用，尝试允许未校验的 update（仅用于本机构建）..."
      apt-get -o Acquire::AllowInsecureRepositories=true -o Acquire::AllowDowngradeToInsecureRepositories=true update -qq || true
    fi
    if ! apt-get install -y -qq \
      libicu-dev python3 ruby bison flex cmake ninja-build build-essential git gperf perl; then
      echo "常规安装失败，尝试允许未校验安装（仅用于本机构建）..."
      apt-get -o Acquire::AllowInsecureRepositories=true -o APT::Get::AllowUnauthenticated=true install -y -qq \
        libicu-dev python3 ruby bison flex cmake ninja-build build-essential git gperf perl \
        || { echo "error: 无法安装构建依赖。若报 disk space，请增大 Docker 磁盘或执行 docker system prune 后重试；或改在 Linux 本机/CI 构建，见 deps/README.md。" >&2; exit 1; }
    fi
    if [[ ! -x Tools/Scripts/build-jsc ]]; then
      echo "error: 未找到 Tools/Scripts/build-jsc，请确认 WebKit 源码目录为完整 WebKit 仓库。" >&2
      exit 1
    fi
    Tools/Scripts/build-jsc --jsc-only
    # JSCOnly 端口可能产出在 WebKitBuild/JSCOnly/Release 或 WebKitBuild/Release
    for cand in WebKitBuild/JSCOnly/Release WebKitBuild/Release WebKitBuild/JSCOnly/Debug WebKitBuild/Debug; do
      if [[ -d "$cand" ]]; then BUILD_DIR="$cand"; break; fi
    done
    if [[ -z "$BUILD_DIR" || ! -d "$BUILD_DIR" ]]; then
      echo "error: 未找到 WebKitBuild 下的构建产物目录（Release 或 JSCOnly/Release）。" >&2
      exit 1
    fi
    mkdir -p /work/deps/install-linux/include
    mkdir -p /work/deps/install-linux/lib
    shopt -s nullglob 2>/dev/null || true
    cp -r Source/JavaScriptCore/API/*.h /work/deps/install-linux/include/ 2>/dev/null || true
    # 拷贝库：可能是 libJavaScriptCore.so 或 libjavascriptcore.so 或静态库
    find "$BUILD_DIR" -maxdepth 4 -type f \( -name "libJavaScriptCore*" -o -name "libjavascriptcore*" \) -exec cp {} /work/deps/install-linux/lib/ \; 2>/dev/null || true
    if [[ -d "$BUILD_DIR/lib" ]]; then
      cp -r "$BUILD_DIR/lib"/* /work/deps/install-linux/lib/ 2>/dev/null || true
    fi
    # 若仍无库文件，尝试从构建根目录找 .so/.a
    if [[ -z "$(ls -A /work/deps/install-linux/lib 2>/dev/null)" ]]; then
      find "$BUILD_DIR" -maxdepth 2 -type f \( -name "*.so" -o -name "*.a" \) -exec cp {} /work/deps/install-linux/lib/ \; 2>/dev/null || true
    fi
    echo "install-linux 已写入 include/ 与 lib/。"
  '

echo ""
echo "完成。Linux 用 JSC 已产出到: $INSTALL_LINUX"
echo "在 Linux 上构建 shu 时使用: zig build -Djsc_prefix=$INSTALL_LINUX"
echo "（或将 install-linux 重命名为 install，并保证该路径在 Linux 上可用）"
