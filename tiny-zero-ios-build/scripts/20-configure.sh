#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

require_dir "$SRC_DIR"
require_file "$SRC_DIR/configure"

SOURCE_DATE_EPOCH="$(git -C "$SRC_DIR" show -s --format=%ct "$MOBILE_REF")"

# Baseline Tiny Zero policy:
# - Zero interpreter
# - Serial GC only
# - size-optimized libjvm
# - no CDS/JFR/JVMTI/management/services/extra collectors/VM structs
#
# C1, C2, minimal and ZGC are already unavailable for Zero in current
# openjdk/mobile, but we do not depend on that implicitly: the post-config
# feature assertion below is authoritative.
JVM_FEATURES="serialgc,opt-size,-cds,-dtrace,-epsilongc,-g1gc,-jfr,-jni-check,-jvmti,-link-time-opt,-management,-parallelgc,-services,-shenandoahgc,-vm-structs"

cd "$SRC_DIR"

set -o pipefail
bash configure \
  --with-conf-name="$CONF_NAME" \
  --with-debug-level=release \
  --disable-warnings-as-errors \
  --openjdk-target=aarch64-macos-ios \
  --with-jvm-variants=zero \
  --with-jvm-features="$JVM_FEATURES" \
  --with-native-debug-symbols=none \
  --enable-headless-only \
  --with-boot-jdk="$BOOT_JDK" \
  --with-libffi-include="$LIBFFI_INCLUDE" \
  --with-libffi-lib="$LIBFFI_LIB_DIR" \
  --with-cups-include="$CUPS_INCLUDE" \
  --with-sysroot="$IOS_SDK" \
  --with-source-date="$SOURCE_DATE_EPOCH" \
  2>&1 | tee "$LOG_DIR/configure.log"

SPEC="$BUILD_DIR/spec.gmk"
require_file "$SPEC"

feature_line="$(grep -E '^JVM_FEATURES_zero[[:space:]]*:=' "$SPEC" || true)"
[[ -n "$feature_line" ]] || die "cannot find JVM_FEATURES_zero in $SPEC"
echo "$feature_line" > "$LOG_DIR/jvm-features.txt"

active=" ${feature_line#*=} "
for required in zero serialgc opt-size; do
  [[ "$active" == *" $required "* ]] || die "required JVM feature is missing: $required ($feature_line)"
done

for forbidden in cds compiler1 compiler2 dtrace epsilongc g1gc jfr jni-check jvmti link-time-opt management minimal parallelgc services shenandoahgc vm-structs zgc; do
  [[ "$active" != *" $forbidden "* ]] || die "forbidden JVM feature is active: $forbidden ($feature_line)"
done

echo "Configure OK: $feature_line"
