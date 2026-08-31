#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
source "$(dirname "$0")/lib/static-libs.sh"

require_file "$DIST_DIR/lib/libtinyjvm.a"
require_file "$DIST_DIR/runtime/lib/modules"
require_file "$DIST_DIR/runtime/release"
require_file "$DIST_DIR/runtime/lib/tzdb.dat"
require_file "$DIST_DIR/runtime/conf/security/java.security"
require_file "$DIST_DIR/runtime/libjimage.dylib"
require_file "$DIST_DIR/runtime/libj2pkcs11.dylib"
require_file "$DIST_DIR/include/jni.h"

mkdir -p "$DIST_DIR/meta"

file "$DIST_DIR/lib/libtinyjvm.a" > "$DIST_DIR/meta/libtinyjvm.file.txt"
ar -t "$DIST_DIR/lib/libtinyjvm.a" > "$DIST_DIR/meta/libtinyjvm.members.txt"

# Static symbol checks only; this is not an iOS runtime test.
xcrun nm -gU "$DIST_DIR/lib/libtinyjvm.a" > "$DIST_DIR/meta/libtinyjvm.nm.txt" 2>/dev/null || \
  die "nm failed on final archive"

grep -q 'Java_sun_nio_ch_' "$DIST_DIR/meta/libtinyjvm.nm.txt" \
  || die "final archive does not expose expected NIO JNI symbols"

grep -Eq 'Java_sun_security_pkcs11_|JNI_OnLoad.*j2pkcs11|j2pkcs11' "$DIST_DIR/meta/libtinyjvm.nm.txt" \
  || die "final archive does not appear to contain PKCS#11 native symbols"

grep -q 'JIMAGE_' "$DIST_DIR/meta/libtinyjvm.nm.txt" \
  || die "final archive does not expose expected JIMAGE symbols"

assert_keeper_anchor "$DIST_DIR/meta/libtinyjvm.nm.txt"

# jlink writes the selected module set into the release file.
modules_line="$(grep '^MODULES=' "$DIST_DIR/runtime/release" || true)"
[[ -n "$modules_line" ]] || die "MODULES entry missing from jlink release file"

printf '%s\n' "$modules_line" > "$DIST_DIR/meta/runtime-modules.txt"
for module in "${TINY_RUNTIME_MODULES[@]}"; do
  [[ "$modules_line" == *"$module"* ]] || die "runtime image is missing module: $module"
done

# Reject obvious extra modules. Parse quoted space-separated MODULES value.
module_value="${modules_line#MODULES=}"
module_value="${module_value%\"}"
module_value="${module_value#\"}"
for module in $module_value; do
  case " ${TINY_RUNTIME_MODULES[*]} " in
    *" $module "*) ;;
    *) die "unexpected module in runtime image: $module" ;;
  esac
done

"$BOOT_JDK/bin/jimage" list "$DIST_DIR/runtime/lib/modules" \
  > "$DIST_DIR/meta/modules-jimage-list.txt"

# Re-check configured JVM feature contract.
assert_tiny_jvm_features "$(cat "$DIST_DIR/meta/jvm-features.txt")"

(
  cd "$DIST_DIR"
  # BSD/macOS sort has no -z. Artifact paths in this package are controlled
  # by this build and contain no newlines, so newline-delimited sorting is
  # deterministic and portable on macOS.
  find . -type f ! -path './meta/SHA256SUMS' -print \
    | LC_ALL=C sort \
    | while IFS= read -r file; do shasum -a 256 "$file"; done
) > "$DIST_DIR/meta/SHA256SUMS"

echo "Static artifact verification OK"
