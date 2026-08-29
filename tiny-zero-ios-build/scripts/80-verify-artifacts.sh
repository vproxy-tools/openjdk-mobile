#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

require_file "$DIST_DIR/lib/libtinyjvm.a"
require_file "$DIST_DIR/runtime/lib/modules"
require_file "$DIST_DIR/runtime/release"
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

grep -Eq '(^|[[:space:]])_?tiny_symbol_keeper_anchor$' "$DIST_DIR/meta/libtinyjvm.nm.txt" \
  || die "final archive does not expose tiny_symbol_keeper_anchor"

# jlink writes the selected module set into the release file.
modules_line="$(grep '^MODULES=' "$DIST_DIR/runtime/release" || true)"
[[ -n "$modules_line" ]] || die "MODULES entry missing from jlink release file"

printf '%s\n' "$modules_line" > "$DIST_DIR/meta/runtime-modules.txt"
for module in java.base jdk.unsupported jdk.crypto.cryptoki; do
  [[ "$modules_line" == *"$module"* ]] || die "runtime image is missing module: $module"
done

# Reject obvious extra modules. Parse quoted space-separated MODULES value.
module_value="${modules_line#MODULES=}"
module_value="${module_value%\"}"
module_value="${module_value#\"}"
for module in $module_value; do
  case "$module" in
    java.base|jdk.unsupported|jdk.crypto.cryptoki) ;;
    *) die "unexpected module in runtime image: $module" ;;
  esac
done

"$BOOT_JDK/bin/jimage" list "$DIST_DIR/runtime/lib/modules" \
  > "$DIST_DIR/meta/modules-jimage-list.txt"

# Re-check configured JVM feature contract.
feature_line="$(cat "$DIST_DIR/meta/jvm-features.txt")"
active=" ${feature_line#*=} "
for required in zero serialgc opt-size; do
  [[ "$active" == *" $required "* ]] || die "final build metadata missing required JVM feature: $required"
done
for forbidden in cds compiler1 compiler2 dtrace epsilongc g1gc jfr jni-check jvmti link-time-opt management minimal parallelgc services shenandoahgc vm-structs zgc; do
  [[ "$active" != *" $forbidden "* ]] || die "final build metadata contains forbidden JVM feature: $forbidden"
done

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
