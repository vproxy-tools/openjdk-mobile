#!/usr/bin/env bash
set -euo pipefail

# Cross-compile libffi for the iOS Simulator (arm64). Needed because the Gluon
# mobile-support package only ships a device libffi, and the simulator slice
# must have platform=7 (iOS Simulator) objects.

PREFIX="$HOME/ios-sim-support/libffi"
VERSION=3.4.6
WORK="$(mktemp -d)/libffi-$VERSION"
trap 'rm -rf "$(dirname "$WORK")"' EXIT
SIMSDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
MINVER=14.5

if [[ -f "$PREFIX/lib/libffi.a" ]]; then
  echo "already installed: $PREFIX/lib/libffi.a"
  exit 0
fi

mkdir -p "$WORK"
cd "$WORK"
curl -fL -sS -o "libffi-$VERSION.tar.gz" \
  "https://github.com/libffi/libffi/releases/download/v$VERSION/libffi-$VERSION.tar.gz"
tar xzf "libffi-$VERSION.tar.gz"
cd "libffi-$VERSION"

mkdir build-sim
cd build-sim
../configure --host=aarch64-apple-darwin --disable-shared --enable-static \
  CC=clang \
  CFLAGS="-target arm64-apple-ios${MINVER}-simulator -isysroot $SIMSDK" \
  LDFLAGS="-target arm64-apple-ios${MINVER}-simulator -isysroot $SIMSDK" \
  --prefix="$PREFIX"
make -j"$(sysctl -n hw.ncpu)"
make install

echo "OK: $PREFIX/lib/libffi.a"
ar x "$PREFIX/lib/libffi.a" types.o
otool -l types.o | grep -A1 LC_BUILD_VERSION
rm -f types.o
