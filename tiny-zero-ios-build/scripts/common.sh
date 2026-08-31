#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$ROOT_DIR/config/build.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: missing $ENV_FILE" >&2
  echo "Create it with the keys documented in README.md (BOOT_JDK, LIBFFI_INCLUDE," >&2
  echo "LIBFFI_LIB_DIR, CUPS_INCLUDE; optional: IOS_SDK, JOBS, CONF_NAME)." >&2
  exit 2
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

: "${BOOT_JDK:?BOOT_JDK is required}"
: "${LIBFFI_INCLUDE:?LIBFFI_INCLUDE is required}"
: "${LIBFFI_LIB_DIR:?LIBFFI_LIB_DIR is required}"
: "${CUPS_INCLUDE:?CUPS_INCLUDE is required}"
: "${JOBS:=8}"
: "${CONF_NAME:=ios-aarch64-zero-tiny-release}"

# The source tree is the repository that contains this script directory: the
# pipeline builds the working tree directly (no clone/fetch/checkout), so
# whatever is checked out - including uncommitted changes - is what builds.
SRC_DIR="$(cd "$ROOT_DIR/.." && pwd)"

WORK_DIR="$ROOT_DIR/work"
LOG_DIR="$WORK_DIR/logs"
GEN_DIR="$WORK_DIR/generated"
JMOD_DIR="$WORK_DIR/jmods-device"
JAVA_BUNDLE_DIR="$WORK_DIR/java-bundle-device"
DIST_DIR="$ROOT_DIR/dist/device"

BUILD_DIR="$SRC_DIR/build/$CONF_NAME"
STATIC_LIB_DIR="$BUILD_DIR/images/static-libs/lib"
JDK_MODULE_DIR="$BUILD_DIR/jdk/modules"

mkdir -p "$WORK_DIR" "$LOG_DIR" "$GEN_DIR"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

require_file() {
  [[ -f "$1" ]] || die "required file not found: $1"
}

require_dir() {
  [[ -d "$1" ]] || die "required directory not found: $1"
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

# Tiny Zero feature contract, asserted against a spec.gmk JVM_FEATURES_zero
# line after configure (20) and again from the archived copy in dist meta
# (80). The forbidden list lives only here.
assert_tiny_jvm_features() {
  local feature_line="$1"
  local active=" ${feature_line#*=} "
  local f
  for f in zero serialgc opt-size; do
    [[ "$active" == *" $f "* ]] || die "required JVM feature is missing: $f ($feature_line)"
  done
  for f in cds compiler1 compiler2 dtrace epsilongc g1gc jfr jni-check jvmti link-time-opt management minimal parallelgc services shenandoahgc vm-structs zgc; do
    [[ "$active" != *" $f "* ]] || die "forbidden JVM feature is active: $f ($feature_line)"
  done
}

# $1 = nm output file that must define the symbol keeper anchor.
assert_keeper_anchor() {
  grep -Eq '(^|[[:space:]])_?tiny_symbol_keeper_anchor$' "$1" \
    || die "tiny_symbol_keeper_anchor is not defined in $1"
}

if [[ -z "${IOS_SDK:-}" ]]; then
  IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
fi

export ROOT_DIR WORK_DIR SRC_DIR LOG_DIR GEN_DIR JMOD_DIR JAVA_BUNDLE_DIR
export DIST_DIR BUILD_DIR STATIC_LIB_DIR JDK_MODULE_DIR IOS_SDK
