#!/usr/bin/env bash
set -euo pipefail

# Compile the demo Java sources with the JDK 28 boot JDK (the embedded JVM is
# JDK 28-dev, so classes must be class-file version 72) and pack the app jar.

DEMO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TINY_ROOT="${TINY_ROOT:-$DEMO_ROOT/../tiny-zero-ios-build}"
# shellcheck disable=SC1091
source "$TINY_ROOT/config/build.env"

OUT="$DEMO_ROOT/third_party"
BUILD="$DEMO_ROOT/build-java"
rm -rf "$BUILD"
mkdir -p "$BUILD/classes" "$OUT"

"$BOOT_JDK/bin/javac" --release 28 -Xlint:-options \
  -d "$BUILD/classes" "$DEMO_ROOT"/Java/*.java

"$BOOT_JDK/bin/jar" --create --file "$OUT/TinyHttpServer.jar" -C "$BUILD/classes" .

echo "OK: $OUT/TinyHttpServer.jar"
"$BOOT_JDK/bin/jar" --list --file "$OUT/TinyHttpServer.jar"
