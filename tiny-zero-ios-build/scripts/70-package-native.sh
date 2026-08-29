#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR/lib" "$DIST_DIR/include" "$DIST_DIR/runtime/lib" "$DIST_DIR/meta"

stage="$WORK_DIR/native-stage"
rm -rf "$stage"
mkdir -p "$stage"

copy_named() {
  local name="$1"
  require_file "$STATIC_LIB_DIR/$name"
  cp "$STATIC_LIB_DIR/$name" "$stage/$name"
}

copy_named libjava.a
copy_named libjimage.a
copy_named libnet.a
copy_named libnio.a
copy_named libzip.a
cp "$STATIC_LIB_DIR/zero/libjvm.a" "$stage/libjvm.a"
cp "$LIBFFI_LIB_DIR/libffi.a" "$stage/libffi.a"

# Copy all jdk.crypto.cryptoki static archives, refusing basename collisions.
cryptoki_count=0
if [[ -d "$BUILD_DIR/support/native/jdk.crypto.cryptoki" ]]; then
  while IFS= read -r lib; do
    [[ -n "$lib" ]] || continue
    base="$(basename "$lib")"
    [[ ! -e "$stage/$base" ]] || die "native archive basename collision: $base"
    cp "$lib" "$stage/$base"
    cryptoki_count=$((cryptoki_count + 1))
  done < <(find "$BUILD_DIR/support/native/jdk.crypto.cryptoki" -type f -name '*.a' -print | LC_ALL=C sort)
fi

if [[ "$cryptoki_count" -eq 0 ]]; then
  while IFS= read -r lib; do
    [[ -n "$lib" ]] || continue
    base="$(basename "$lib")"
    [[ ! -e "$stage/$base" ]] || die "native archive basename collision: $base"
    cp "$lib" "$stage/$base"
    cryptoki_count=$((cryptoki_count + 1))
  done < <(find "$STATIC_LIB_DIR" -maxdepth 1 -type f -name '*pkcs11*.a' -print | LC_ALL=C sort)
fi
[[ "$cryptoki_count" -gt 0 ]] || die "no cryptoki static archive available for packaging"

# Combine archives. This does NOT disable final Apple dead stripping; it only
# creates a single convenient device archive.
native_libs=( "$stage"/*.a )
libtool -static -o "$DIST_DIR/lib/libtinyjvm.a" "${native_libs[@]}"

# Headers: preserve original layout and also flatten the iOS-specific headers
# into the include root, matching the current ios-tools packaging approach.
require_dir "$BUILD_DIR/jdk/include"
cp -R "$BUILD_DIR/jdk/include/." "$DIST_DIR/include/"
if [[ -d "$DIST_DIR/include/ios" ]]; then
  cp "$DIST_DIR/include/ios/"* "$DIST_DIR/include/" 2>/dev/null || true
fi

cp "$JAVA_BUNDLE_DIR/lib/modules" "$DIST_DIR/runtime/lib/modules"
cp "$JAVA_BUNDLE_DIR/release" "$DIST_DIR/runtime/release"

printf '%s\n' "${native_libs[@]}" > "$DIST_DIR/meta/native-input-libs.txt"
cp "$GEN_DIR/native-keep-symbols.txt" "$DIST_DIR/meta/native-keep-symbols.txt"
cp "$GEN_DIR/symbol_keeper.cpp" "$DIST_DIR/meta/symbol_keeper.cpp"
cp "$GEN_DIR/tiny-jni-anchor.patch" "$DIST_DIR/meta/tiny-jni-anchor.patch"
cp "$GEN_DIR/tiny-opt-size-pch.patch" "$DIST_DIR/meta/tiny-opt-size-pch.patch"
cp "$GEN_DIR/libjvm-pass2.defined.nm.txt" "$DIST_DIR/meta/libjvm-pass2.defined.nm.txt"
cp "$GEN_DIR/libjvm-pass2.undefined.nm.txt" "$DIST_DIR/meta/libjvm-pass2.undefined.nm.txt"
cp "$LOG_DIR/jvm-features.txt" "$DIST_DIR/meta/jvm-features.txt"
cp "$LOG_DIR/environment.txt" "$DIST_DIR/meta/environment.txt"
cp "$LOG_DIR/mobile-commit.txt" "$DIST_DIR/meta/mobile-commit.txt"

echo "Native package OK: $DIST_DIR/lib/libtinyjvm.a"
