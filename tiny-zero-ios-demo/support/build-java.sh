#!/usr/bin/env bash
set -euo pipefail

# Package the demo payload: the stock vproxy jar plus a tiny bootstrap
# helper compiled from Java/ that redirects JVM stdout/stderr to the app UI
# (vproxy itself is used completely unmodified). The helper jar is appended
# after vproxy.jar on java.class.path.

DEMO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TINY_ROOT="${TINY_ROOT:-$DEMO_ROOT/../tiny-zero-ios-build}"
# shellcheck disable=SC1091
source "$TINY_ROOT/config/build.env"

# vproxy is used completely unmodified. Build it from source:
#   git clone --recursive https://github.com/wkgcass/vproxy
#   cd vproxy && git submodule update --init --recursive && ./gradlew shadowjar
#   -> build/libs/vproxy.jar
# The default expects the vproxy checkout to sit next to this repository
# (…/openjdk-mobile and …/vproxy); export VPROXY_JAR to point elsewhere.
VPROXY_JAR="${VPROXY_JAR:-$DEMO_ROOT/../../vproxy/build/libs/vproxy.jar}"
[[ -f "$VPROXY_JAR" ]] || {
  echo "ERROR: vproxy jar not found: $VPROXY_JAR" >&2
  echo "       Build vproxy first: git clone --recursive https://github.com/wkgcass/vproxy" >&2
  echo "       then 'git submodule update --init --recursive && ./gradlew shadowjar'" >&2
  echo "       inside it (result: build/libs/vproxy.jar), or export" >&2
  echo "       VPROXY_JAR=<path/to/vproxy.jar>." >&2
  exit 1
}

OUT="$DEMO_ROOT/third_party"
BUILD="$DEMO_ROOT/build-java"
rm -rf "$BUILD"
mkdir -p "$BUILD/classes" "$OUT"

# The embedded JVM is JDK 28-dev, so classes must be class-file version 72.
"$BOOT_JDK/bin/javac" --release 28 -Xlint:-options \
  -d "$BUILD/classes" "$DEMO_ROOT"/Java/*.java

"$BOOT_JDK/bin/jar" --create --file "$OUT/vproxy-ios-bootstrap.jar" -C "$BUILD/classes" .
cp "$VPROXY_JAR" "$OUT/vproxy.jar"

echo "OK: $OUT/vproxy.jar"
echo "    $OUT/vproxy-ios-bootstrap.jar"
