#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

require_file "$GEN_DIR/libjvm-pass1.sha256"
before="$(cat "$GEN_DIR/libjvm-pass1.sha256")"

cd "$SRC_DIR"
make LOG=cmdlines,info JOBS="$JOBS" CONF="$CONF_NAME" static-libs-image \
  2>&1 | tee "$LOG_DIR/build-pass2.log"

require_file "$STATIC_LIB_DIR/zero/libjvm.a"
after="$(sha256_file "$STATIC_LIB_DIR/zero/libjvm.a")"
echo "$after" > "$GEN_DIR/libjvm-pass2.sha256"

if [[ "$before" == "$after" ]]; then
  die "libjvm.a did not change after generated symbol_keeper.cpp; incremental HotSpot rebuild did not occur"
fi

# The keeper anchor must be defined in the archive. Nothing inside libjvm.a
# references it on purpose: the embedding app calls tiny_symbol_keeper_anchor()
# once before JNI_CreateJavaVM, which pulls symbol_keeper.o (and with it every
# symbol in the keeper table) into the final link.
xcrun nm -gU "$STATIC_LIB_DIR/zero/libjvm.a" > "$GEN_DIR/libjvm-pass2.defined.nm.txt" 2>/dev/null \
  || die "nm failed on pass-2 libjvm.a"
assert_keeper_anchor "$GEN_DIR/libjvm-pass2.defined.nm.txt"

echo "Pass 2 build OK; generated symbol keeper is included"
