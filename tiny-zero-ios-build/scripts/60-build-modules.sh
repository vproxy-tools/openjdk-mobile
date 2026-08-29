#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

rm -rf "$JMOD_DIR" "$JAVA_BUNDLE_DIR"
mkdir -p "$JMOD_DIR"

# JDK 28 jlink refuses to link a java.base whose build descriptor differs from
# the one of the jlink runtime. The target java.base is an adhoc in-tree build
# while the host tools are a published JDK build, so copy the descriptor
# resource from the boot JDK into the exploded module before jmod packaging.
# This is metadata only; it does not affect runtime behavior.
RELEASE_TXT_REL="jdk/internal/misc/resources/release.txt"
HOST_RELEASE_DIR="$WORK_DIR/host-release"
rm -rf "$HOST_RELEASE_DIR"
"$BOOT_JDK/bin/jimage" extract \
  --include "regex:.*$RELEASE_TXT_REL" \
  --dir "$HOST_RELEASE_DIR" \
  "$BOOT_JDK/lib/modules"
HOST_RELEASE="$HOST_RELEASE_DIR/java.base/$RELEASE_TXT_REL"
require_file "$HOST_RELEASE"
BASE_RELEASE="$JDK_MODULE_DIR/java.base/$RELEASE_TXT_REL"
if [[ -f "$BASE_RELEASE" ]]; then
  cp "$HOST_RELEASE" "$BASE_RELEASE"
fi

for module in java.base jdk.unsupported jdk.crypto.cryptoki; do
  module_dir="$JDK_MODULE_DIR/$module"
  require_dir "$module_dir"

  # JDK 28 jlink resolves the ModuleTarget platform through its own
  # java.base OperatingSystem enum, which has no "ios" member (the mobile
  # tree adds it, published JDK builds do not). macos-aarch64 is the closest
  # accepted value: same endianness and word size, so the generated jimage is
  # identical. Only the OS_NAME entry of the link-time release metadata
  # differs; os.name on the device comes from the VM, not from this file.
  "$BOOT_JDK/bin/jmod" create \
    --class-path "$module_dir" \
    --target-platform macos-aarch64 \
    "$JMOD_DIR/$module.jmod"

  "$BOOT_JDK/bin/jmod" describe "$JMOD_DIR/$module.jmod" \
    > "$GEN_DIR/$module.jmod.describe.txt"
done

"$BOOT_JDK/bin/jlink" \
  --module-path "$JMOD_DIR" \
  --add-modules java.base,jdk.unsupported,jdk.crypto.cryptoki \
  --strip-debug \
  --no-header-files \
  --no-man-pages \
  --output "$JAVA_BUNDLE_DIR"

require_file "$JAVA_BUNDLE_DIR/lib/modules"
require_file "$JAVA_BUNDLE_DIR/release"

echo "Three-module jimage OK"
