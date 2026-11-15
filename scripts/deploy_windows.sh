#!/usr/bin/env bash
# 一键构建并部署 Seraphine 到 Windows 电脑
#
# PyInstaller 无法在 macOS 上交叉编译出 Windows 程序，所以流程是：
#   1. 在本机把当前 HEAD 的源码打成 zip（未提交的改动不会包含在内）
#   2. 通过 SSH 传到 Windows 上的构建目录
#   3. 在 Windows 上用构建目录里的 Python 3.8 环境执行 make.ps1 打包
#   4. 结束正在运行的 Seraphine，替换安装目录，更新桌面快捷方式
#   5. 如果部署前 Seraphine 正在运行，部署后在桌面会话中重新启动它
#
# 首次使用前需要在 Windows 上准备好构建环境，见 scripts/windows_deploy.ps1 顶部说明
#
# 可用环境变量覆盖默认配置：
#   SERAPHINE_WIN_HOST      SSH 主机名（~/.ssh/config 中的 Host），默认 windows-pc
#   SERAPHINE_BUILD_ROOT    Windows 上的构建目录，默认 F:/Seraphine-dev
#   SERAPHINE_INSTALL_DIR   Windows 上的安装目录，默认 D:/Seraphine

set -euo pipefail

HOST="${SERAPHINE_WIN_HOST:-windows-pc}"
BUILD_ROOT="${SERAPHINE_BUILD_ROOT:-F:/Seraphine-dev}"
INSTALL_DIR="${SERAPHINE_INSTALL_DIR:-D:/Seraphine}"

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$REPO_ROOT"

if [ -n "$(git status --porcelain)" ]; then
    echo "警告：工作区有未提交的改动，本次只会构建已提交的 HEAD ($(git rev-parse --short HEAD))" >&2
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "==> 打包源码 $(git rev-parse --short HEAD)"
git archive --format=zip -o "$TMP_DIR/src.zip" HEAD

echo "==> 上传到 $HOST:$BUILD_ROOT"
scp -q "$TMP_DIR/src.zip" "$HOST:/$BUILD_ROOT/src.zip"
scp -q scripts/windows_deploy.ps1 "$HOST:/$BUILD_ROOT/windows_deploy.ps1"

echo "==> 在 Windows 上构建并部署"
ssh "$HOST" "powershell -NoProfile -ExecutionPolicy Bypass -File \"$BUILD_ROOT/windows_deploy.ps1\" -BuildRoot \"$BUILD_ROOT\" -InstallDir \"$INSTALL_DIR\""
