#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${TINY_ZERO_ENV:-$ROOT_DIR/config/build.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: missing $ENV_FILE" >&2
  echo "Copy config/build.env.example to config/build.env and edit it." >&2
  exit 2
fi

# shellcheck disable=SC1090
source "$ENV_FILE"

: "${MOBILE_REPO:?MOBILE_REPO is required}"
: "${MOBILE_REF:?MOBILE_REF is required}"
: "${BOOT_JDK:?BOOT_JDK is required}"
: "${LIBFFI_INCLUDE:?LIBFFI_INCLUDE is required}"
: "${LIBFFI_LIB_DIR:?LIBFFI_LIB_DIR is required}"
: "${CUPS_INCLUDE:?CUPS_INCLUDE is required}"
: "${JOBS:=8}"
: "${CONF_NAME:=ios-aarch64-zero-tiny-release}"
: "${CLEAN_WORKTREE:=1}"

WORK_DIR="$ROOT_DIR/work"
SRC_DIR="$WORK_DIR/mobile"
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

if [[ -z "${IOS_SDK:-}" ]]; then
  IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
fi

export ROOT_DIR WORK_DIR SRC_DIR LOG_DIR GEN_DIR JMOD_DIR JAVA_BUNDLE_DIR
export DIST_DIR BUILD_DIR STATIC_LIB_DIR JDK_MODULE_DIR IOS_SDK
