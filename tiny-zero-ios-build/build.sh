#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

steps=(
  00-check-env.sh
  10-fetch.sh
  20-configure.sh
  30-build-pass1.sh
  40-generate-symbol-keeper.sh
  50-build-pass2.sh
  60-build-modules.sh
  70-package-native.sh
  80-verify-artifacts.sh
  90-package.sh
)

for step in "${steps[@]}"; do
  echo
  echo "================================================================"
  echo "== $step"
  echo "================================================================"
  "$ROOT_DIR/scripts/$step"
done

echo
echo "Build complete."
echo "Output: $ROOT_DIR/dist/device"
echo "Archive: $ROOT_DIR/dist/tiny-openjdk-ios-device.tar.gz"
