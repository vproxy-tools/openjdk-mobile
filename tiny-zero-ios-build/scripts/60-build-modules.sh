#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
source "$(dirname "$0")/lib/runtime-image.sh"

# JDK 28 jmod/jlink contract workarounds (release descriptor sync and
# --target-platform macos-aarch64) live in lib/runtime-image.sh.
sync_jmod_release_descriptor "$JDK_MODULE_DIR" "$BOOT_JDK" "$WORK_DIR/host-release"
create_module_jmods "$JDK_MODULE_DIR" "$JMOD_DIR" "$BOOT_JDK"

jlink_tiny_runtime "$JMOD_DIR" "$JAVA_BUNDLE_DIR" "$BOOT_JDK"

echo "Three-module jimage OK"
