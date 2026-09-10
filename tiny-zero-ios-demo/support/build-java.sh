#!/usr/bin/env bash
set -euo pipefail

# Package the demo payload: the stock vproxy jar, the bootstrap helper
# compiled from JvmEmbed/Java/ that redirects JVM stdout/stderr to the app UI
# (vproxy itself is used completely unmodified; the helper jar is appended
# after vproxy.jar on java.class.path), and the vproxy native frameworks for
# the -Dvfd=posix VFD implementation (libpni + libvfdposix).

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
  -d "$BUILD/classes" "$DEMO_ROOT"/JvmEmbed/Java/*.java

"$BOOT_JDK/bin/jar" --create --file "$OUT/vproxy-ios-bootstrap.jar" -C "$BUILD/classes" .
cp "$VPROXY_JAR" "$OUT/vproxy.jar"

# --- vproxy native frameworks (libpni + libvfdposix) -------------------------
# The demo starts vproxy with -Dvfd=posix, which loads libvfdposix through
# System.loadLibrary; the JVM finds it because java.library.path points into
# the embedded framework directories (see JvmModel.launchJVM), and dyld
# resolves libvfdposix's @rpath/libpni.framework/libpni.dylib dependency
# through the app's standard @executable_path/Frameworks rpath.
#
# One `make ios-vfdposix` in the vproxy root builds BOTH frameworks for one
# SDK; run it twice (device + simulator) and store each variant separately in
# third_party/vproxy-frameworks/<sdk>/. Device and simulator slices differ, so
# the flows that run xcodebuild stage the matching variant into
# third_party/Frameworks via support/stage-frameworks.sh (same in-place swap
# the builtin-lib markers in third_party/lib use; the store dir is spelled
# differently because the default APFS volume is case-insensitive).
VPROXY_ROOT="${VPROXY_ROOT:-$DEMO_ROOT/../../vproxy}"
if [[ ! -f "$VPROXY_ROOT/Makefile" ]]; then
  # VPROXY_JAR may point into another checkout: <root>/build/libs/vproxy.jar
  derived="$(cd "$(dirname "$VPROXY_JAR")/../.." 2>/dev/null && pwd)" || derived=""
  [[ -n "$derived" && -f "$derived/Makefile" ]] && VPROXY_ROOT="$derived"
fi
[[ -f "$VPROXY_ROOT/Makefile" ]] || {
  echo "ERROR: vproxy checkout not found at $VPROXY_ROOT" >&2
  echo "       The -Dvfd=posix demo needs the libpni/libvfdposix frameworks," >&2
  echo "       which are built from the vproxy source tree. Clone it next to" >&2
  echo "       this repository (see README) or export VPROXY_ROOT=<path>." >&2
  exit 1
}

for sdk in iphoneos iphonesimulator; do
  store="$OUT/vproxy-frameworks/$sdk"
  if [[ -d "$store/libpni.framework" && -d "$store/libvfdposix.framework" ]]; then
    echo "-- $sdk frameworks already in $store (delete to rebuild)"
    continue
  fi
  echo "==> make ios-vfdposix (SDK_NAME=$sdk)"
  (cd "$VPROXY_ROOT" && SDK_NAME="$sdk" make ios-vfdposix)
  mkdir -p "$store"
  cp -R "$VPROXY_ROOT/base/src/main/c/libpni.framework" \
        "$VPROXY_ROOT/base/src/main/c/libvfdposix.framework" "$store/"
done

# The documented default flow (run-sim-demo.sh, manual simulator steps) builds
# for the simulator next; device flows re-stage before their xcodebuild.
"$DEMO_ROOT/support/stage-frameworks.sh" iphonesimulator

echo "OK: $OUT/vproxy.jar"
echo "    $OUT/vproxy-ios-bootstrap.jar"
echo "    $OUT/vproxy-frameworks/{iphoneos,iphonesimulator}/lib{pni,vfdposix}.framework"
