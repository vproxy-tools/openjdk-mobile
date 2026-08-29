#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

require_file "$GEN_DIR/libjvm-pass1.sha256"
before="$(cat "$GEN_DIR/libjvm-pass1.sha256")"

cd "$SRC_DIR"
set -o pipefail
make LOG=cmdlines,info JOBS="$JOBS" CONF="$CONF_NAME" static-libs-image \
  2>&1 | tee "$LOG_DIR/build-pass2.log"

require_file "$STATIC_LIB_DIR/zero/libjvm.a"
after="$(sha256_file "$STATIC_LIB_DIR/zero/libjvm.a")"
echo "$after" > "$GEN_DIR/libjvm-pass2.sha256"

if [[ "$before" == "$after" ]]; then
  die "libjvm.a did not change after generated symbol_keeper.cpp; incremental HotSpot rebuild did not occur"
fi

# The keeper must be defined, and JNI_CreateJavaVM's object must retain an
# unresolved edge to it inside the archive. Together these guarantee that a
# normal final link rooted at JNI_CreateJavaVM pulls symbol_keeper.o.
xcrun nm -gU "$STATIC_LIB_DIR/zero/libjvm.a" > "$GEN_DIR/libjvm-pass2.defined.nm.txt" 2>/dev/null \
  || die "nm failed on pass-2 libjvm.a"
grep -Eq '(^|[[:space:]])_?tiny_symbol_keeper_anchor$' "$GEN_DIR/libjvm-pass2.defined.nm.txt" \
  || die "tiny_symbol_keeper_anchor is not defined in pass-2 libjvm.a"

xcrun nm -u "$STATIC_LIB_DIR/zero/libjvm.a" > "$GEN_DIR/libjvm-pass2.undefined.nm.txt" 2>/dev/null \
  || die "nm -u failed on pass-2 libjvm.a"
grep -Eq '(^|[[:space:]])_?tiny_symbol_keeper_anchor$' "$GEN_DIR/libjvm-pass2.undefined.nm.txt" \
  || die "JNI_CreateJavaVM does not appear to retain an archive edge to tiny_symbol_keeper_anchor"

echo "Pass 2 build OK; generated self-anchored symbol keeper is included"
