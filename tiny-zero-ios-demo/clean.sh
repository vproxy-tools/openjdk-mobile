#!/usr/bin/env bash
set -euo pipefail

# 清理 demo 的全部生成物:third_party/(静态库、runtime 树、jar)、
# xcodebuild 输出、xcodegen 生成的工程、jmod/jlink 中间产物。
# 清理后按 README 的一键脚本(./support/run-sim-demo.sh)重建即可;
# 模拟器 libffi(~/ios-sim-support)与设备流水线产物不在本目录,不受影响。

DEMO_ROOT="$(cd "$(dirname "$0")" && pwd)"
rm -rf \
  "$DEMO_ROOT/third_party" \
  "$DEMO_ROOT/build" \
  "$DEMO_ROOT/build-java" \
  "$DEMO_ROOT/work-generated" \
  "$DEMO_ROOT/TinyHttpServer.xcodeproj"

echo "Cleaned."
