#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
source "$(dirname "$0")/lib/runtime-image.sh"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR/lib" "$DIST_DIR/include" "$DIST_DIR/meta"

native_libs=()
for lib in "${TINY_BASE_STATIC_LIBS[@]}"; do
  require_file "$STATIC_LIB_DIR/$lib"
  native_libs+=("$STATIC_LIB_DIR/$lib")
done
require_file "$STATIC_LIB_DIR/zero/libjvm.a"
require_file "$LIBFFI_LIB_DIR/libffi.a"
native_libs+=("$STATIC_LIB_DIR/zero/libjvm.a" "$LIBFFI_LIB_DIR/libffi.a")

while IFS= read -r lib; do
  [[ -n "$lib" ]] || continue
  native_libs+=("$lib")
done < <(print_cryptoki_archives "$BUILD_DIR" "$STATIC_LIB_DIR")

# Combine archives. This does NOT disable final Apple dead stripping; it only
# creates a single convenient device archive.
libtool -static -o "$DIST_DIR/lib/libtinyjvm.a" "${native_libs[@]}"

# Headers: preserve original layout and also flatten the iOS-specific headers
# into the include root, matching the current ios-tools packaging approach.
require_dir "$BUILD_DIR/jdk/include"
cp -R "$BUILD_DIR/jdk/include/." "$DIST_DIR/include/"
if [[ -d "$DIST_DIR/include/ios" ]]; then
  cp "$DIST_DIR/include/ios/"* "$DIST_DIR/include/" 2>/dev/null || true
fi

# The runtime tree mirrors <bundle>/lib (java_home) in the app, including the
# boot-JDK-derived conf/ + lib/tzdb.dat and the builtin-lib marker files, so
# the deliverable is complete without a simulator build.
stage_runtime_lib "$JAVA_BUNDLE_DIR" "$BOOT_JDK" "$DIST_DIR/runtime" iphoneos

printf '%s\n' "${native_libs[@]}" > "$DIST_DIR/meta/native-input-libs.txt"
cp "$GEN_DIR/native-keep-symbols.txt" "$DIST_DIR/meta/native-keep-symbols.txt"
cp "$GEN_DIR/symbol_keeper.cpp" "$DIST_DIR/meta/symbol_keeper.cpp"
cp "$GEN_DIR/libjvm-pass2.defined.nm.txt" "$DIST_DIR/meta/libjvm-pass2.defined.nm.txt"
cp "$LOG_DIR/jvm-features.txt" "$DIST_DIR/meta/jvm-features.txt"
cp "$LOG_DIR/environment.txt" "$DIST_DIR/meta/environment.txt"
cp "$LOG_DIR/mobile-commit.txt" "$DIST_DIR/meta/mobile-commit.txt"

echo "Native package OK: $DIST_DIR/lib/libtinyjvm.a"
