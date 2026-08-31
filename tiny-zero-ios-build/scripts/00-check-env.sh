#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

[[ "$(uname -s)" == "Darwin" ]] || die "this build must run on macOS"

for c in git bash autoconf xcrun xcodebuild clang make libtool nm ar awk sed grep find shasum tar; do
  need_cmd "$c"
done

require_file "$BOOT_JDK/bin/java"
require_file "$BOOT_JDK/bin/javac"
require_file "$BOOT_JDK/bin/jmod"
require_file "$BOOT_JDK/bin/jlink"
require_file "$BOOT_JDK/bin/jimage"

require_dir "$LIBFFI_INCLUDE"
require_dir "$LIBFFI_LIB_DIR"
require_file "$LIBFFI_LIB_DIR/libffi.a"
require_dir "$CUPS_INCLUDE"
require_dir "$IOS_SDK"

if ! find "$LIBFFI_INCLUDE" -name ffi.h -type f -print -quit | grep -q .; then
  die "ffi.h not found below LIBFFI_INCLUDE=$LIBFFI_INCLUDE"
fi

{
  echo "date_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host=$(sw_vers 2>/dev/null | tr '\n' ';' || true)"
  echo "xcode=$(xcodebuild -version 2>/dev/null | tr '\n' ';' || true)"
  echo "sdk=$IOS_SDK"
  echo "sdk_version=$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || true)"
  echo "clang=$(clang --version | head -n 1)"
  echo "boot_jdk=$BOOT_JDK"
  "$BOOT_JDK/bin/java" -version 2>&1 | sed 's/^/boot_jdk_version=/'
  echo "libffi_sha256=$(sha256_file "$LIBFFI_LIB_DIR/libffi.a")"
  echo "source_tree=$SRC_DIR"
  echo "conf_name=$CONF_NAME"
} > "$LOG_DIR/environment.txt"

echo "Environment OK"
