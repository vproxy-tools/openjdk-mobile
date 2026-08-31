#!/usr/bin/env bash
set -euo pipefail

# 清理构建产物:dist/、work/ 与本仓库 build/ 下本管线的构建配置。
# 源码就是本仓库工作区本身,没有 checkout 需要保留或重建。
#
# 注意:生成的 symbol_keeper.cpp 保留在源码树中(gitignored);
# 设备流水线会在下次 build.sh 时重新生成。

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$(cd "$ROOT_DIR/.." && pwd)"

CONF_NAME="ios-aarch64-zero-tiny-release"
if [[ -f "$ROOT_DIR/config/build.env" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT_DIR/config/build.env"
  : "${CONF_NAME:=ios-aarch64-zero-tiny-release}"
fi

rm -rf "$ROOT_DIR/work"
rm -rf "$ROOT_DIR/dist"
rm -rf "$SRC_DIR/build/$CONF_NAME"

echo "Cleaned."
