#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

cd "$SRC_DIR"
set -o pipefail
# static-libs-image only compiles exploded classes for modules that produce a
# native static library. jdk.unsupported has no native archive, so its module
# classes must be requested explicitly for the later jmod/jlink step.
make LOG=cmdlines,info JOBS="$JOBS" CONF="$CONF_NAME" \
  static-libs-image jdk.unsupported-java \
  2>&1 | tee "$LOG_DIR/build-pass1.log"

require_file "$STATIC_LIB_DIR/zero/libjvm.a"
for lib in libjava.a libjimage.a libnet.a libnio.a libzip.a; do
  require_file "$STATIC_LIB_DIR/$lib"
done

for module in java.base jdk.unsupported jdk.crypto.cryptoki; do
  require_dir "$JDK_MODULE_DIR/$module"
done

# The exact static archive path for jdk.crypto.cryptoki is intentionally
# discovered from the build result rather than hard-coded.
if ! find "$BUILD_DIR/support/native/jdk.crypto.cryptoki" -type f -name '*.a' -print -quit | grep -q .; then
  # Some build revisions may already flatten it only into static-libs.
  if ! find "$STATIC_LIB_DIR" -maxdepth 1 -type f -name '*pkcs11*.a' -print -quit | grep -q .; then
    die "no static archive produced for jdk.crypto.cryptoki"
  fi
fi

sha256_file "$STATIC_LIB_DIR/zero/libjvm.a" > "$GEN_DIR/libjvm-pass1.sha256"
echo "Pass 1 build OK"
