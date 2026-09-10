#!/usr/bin/env bash
set -euo pipefail

# Stage one per-SDK variant of the vproxy native frameworks into
# third_party/Frameworks/, which project.yml embeds into the app bundle.
# build-java.sh builds both variants into third_party/vproxy-frameworks/<sdk>/
# with vproxy's `make ios-vfdposix`; this script copies the requested one into
# the single embedded path (same in-place swap pattern the builtin-lib marker
# dylibs in third_party/lib use). The two directories must stay spelled
# differently: the default APFS volume is case-insensitive, and the embedded
# one has to be exactly "Frameworks" for the app's @executable_path/Frameworks
# rpath.
#
# Usage: stage-frameworks.sh <iphoneos|iphonesimulator>

DEMO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ $# -ne 1 || "$1" != iphoneos && "$1" != iphonesimulator ]]; then
  echo "usage: $0 <iphoneos|iphonesimulator>" >&2
  exit 1
fi
SDK="$1"

STORE="$DEMO_ROOT/third_party/vproxy-frameworks/$SDK"
for fw in libpni libvfdposix; do
  [[ -d "$STORE/$fw.framework" ]] || {
    echo "ERROR: $STORE/$fw.framework missing" >&2
    echo "       run ./support/build-java.sh first (it runs 'make ios-vfdposix'" >&2
    echo "       in the vproxy checkout for both SDKs)" >&2
    exit 1
  }
done

DST="$DEMO_ROOT/third_party/Frameworks"
rm -rf "$DST"
mkdir -p "$DST"
cp -R "$STORE/libpni.framework" "$STORE/libvfdposix.framework" "$DST/"
echo "OK: staged $SDK frameworks -> $DST"
