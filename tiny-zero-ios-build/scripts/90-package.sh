#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

require_dir "$DIST_DIR"
require_file "$DIST_DIR/meta/SHA256SUMS"

archive="$ROOT_DIR/dist/tiny-openjdk-ios-device.tar.gz"
rm -f "$archive"

(
  cd "$ROOT_DIR/dist"
  tar -czf "$(basename "$archive")" device
)

shasum -a 256 "$archive" > "$archive.sha256"

echo "Created:"
echo "  $archive"
echo "  $archive.sha256"
