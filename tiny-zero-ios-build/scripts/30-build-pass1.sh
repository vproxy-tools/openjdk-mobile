#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
source "$(dirname "$0")/lib/static-libs.sh"

cd "$SRC_DIR"
# static-libs-image only compiles exploded classes for modules that produce a
# native static library. jdk.unsupported has no native archive, so its module
# classes must be requested explicitly for the later jmod/jlink step.
make LOG=cmdlines,info JOBS="$JOBS" CONF="$CONF_NAME" \
  static-libs-image jdk.unsupported-java \
  2>&1 | tee "$LOG_DIR/build-pass1.log"

require_file "$STATIC_LIB_DIR/zero/libjvm.a"
for lib in "${TINY_BASE_STATIC_LIBS[@]}"; do
  require_file "$STATIC_LIB_DIR/$lib"
done

for module in "${TINY_RUNTIME_MODULES[@]}"; do
  require_dir "$JDK_MODULE_DIR/$module"
done

print_cryptoki_archives "$BUILD_DIR" "$STATIC_LIB_DIR" > /dev/null \
  || die "no static archive produced for jdk.crypto.cryptoki"

sha256_file "$STATIC_LIB_DIR/zero/libjvm.a" > "$GEN_DIR/libjvm-pass1.sha256"
echo "Pass 1 build OK"
