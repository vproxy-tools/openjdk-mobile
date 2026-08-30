#!/usr/bin/env bash
set -euo pipefail

# Build a Zero JVM static library for the iOS Simulator (arm64).
#
# Reuses the source tree prepared by tiny-zero-ios-build (same pinned commit
# and the same generated symbol_keeper.cpp), so the simulator slice behaves
# like the device slice. All port fixes are merged into the repository (see
# the presence check below). The runtime image (lib/modules) is platform
# independent and is taken from the device build.

DEMO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TINY_ROOT="${TINY_ROOT:-$DEMO_ROOT/../tiny-zero-ios-build}"
# shellcheck disable=SC1091
source "$TINY_ROOT/config/build.env"

SRC="$TINY_ROOT/work/mobile"
[[ -d "$SRC" ]] || { echo "ERROR: $SRC missing; run tiny-zero-ios-build/build.sh first" >&2; exit 1; }

CONF=ios-aarch64-zero-sim-release
SIMSDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
SIMFFI="$HOME/ios-sim-support/libffi"
[[ -f "$SIMFFI/lib/libffi.a" ]] || { echo "ERROR: simulator libffi missing at $SIMFFI" >&2; exit 1; }

cd "$SRC"

# The simulator port fixes (MAP_JIT for exec mappings, zero interpreter
# entry fallback + on-demand linking, the Throwable pre-init guard,
# RTLD_DEFAULT native lookup for static links, bsd_zero crash pc, lazy W^X
# in the signal handler) are merged into this repository - git history is
# the single source of truth, nothing is patched here anymore. Verify the
# tree actually contains them and fail fast with a concrete remedy.
while read -r marker file; do
  [[ -n "$marker" ]] || continue
  grep -q "$marker" "$SRC/$file" || {
    echo "ERROR: $SRC/$file lacks '$marker' - tree predates the merged port fixes." >&2
    echo "       Re-run tiny-zero-ios-build/build.sh (fetches MOBILE_REF from config/build.env)." >&2
    exit 1
  }
done <<'MARKERS'
MAP_JIT src/hotspot/os/bsd/os_bsd.cpp
set_callee_entry_point src/hotspot/cpu/zero/zeroInterpreter_zero.cpp
VM.isBooted src/java.base/share/classes/java/lang/Throwable.java
RTLD_DEFAULT src/hotspot/os/posix/os_posix.cpp
ucontext_get_pc src/hotspot/os_cpu/bsd_zero/os_bsd_zero.cpp
lazy_wx_flip src/hotspot/os/posix/signals_posix.cpp
MARKERS

# Invalidate the configuration if it points at an SDK that no longer exists
# (e.g. after a macOS/Xcode upgrade), was produced by another clang, or
# predates the assembler flags fix (copy_bsd_aarch64.S used to compile to a
# macOS object because the .S step missed -target/-isysroot).
if [[ -f "build/$CONF/spec.gmk" ]] && ! grep -q "arm64-apple-ios14.5-simulator" build/$CONF/spec.gmk; then
  echo "stale configuration (SDK/asflags changed), reconfiguring..."
  rm -rf "build/$CONF"
fi

if [[ ! -f "build/$CONF/spec.gmk" ]]; then
  # JFR is disabled: it has no BSD SystemProcessInterface implementation
  # and the demo does not need it.
  bash configure \
    --with-conf-name="$CONF" \
    --with-debug-level=release \
    --disable-warnings-as-errors \
    --openjdk-target=aarch64-macos-ios \
    --with-jvm-variants=zero \
    --with-jvm-features="-jfr" \
    --with-native-debug-symbols=none \
    --enable-headless-only \
    --with-boot-jdk="$BOOT_JDK" \
    --with-libffi-include="$SIMFFI/include" \
    --with-libffi-lib="$SIMFFI/lib" \
    --with-cups-include="$CUPS_INCLUDE" \
    --with-sysroot="$SIMSDK" \
    --with-extra-asflags="-target arm64-apple-ios14.5-simulator -isysroot $SIMSDK" \
    2>&1 | tee "$TINY_ROOT/work/logs/configure-sim.log"
fi

make LOG=info JOBS="$JOBS" CONF="$CONF" static-libs-image jdk.unsupported-java

STATIC="build/$CONF/images/static-libs/lib"
for lib in libjava.a libjimage.a libnet.a libnio.a libzip.a; do
  [[ -f "$STATIC/$lib" ]] || { echo "ERROR: $STATIC/$lib missing" >&2; exit 1; }
done
[[ -f "$STATIC/zero/libjvm.a" ]] || { echo "ERROR: simulator libjvm.a missing" >&2; exit 1; }

cryptoki_libs=""
while IFS= read -r lib; do
  if [[ -n "$lib" ]]; then
    cryptoki_libs="$cryptoki_libs $lib"
  fi
done < <(find "build/$CONF/support/native/jdk.crypto.cryptoki" -type f -name '*.a' | LC_ALL=C sort)
[[ -n "$cryptoki_libs" ]] || { echo "ERROR: no cryptoki archive" >&2; exit 1; }

mkdir -p "$DEMO_ROOT/third_party"
libtool -static -o "$DEMO_ROOT/third_party/libtinyjvm-sim.a" \
  "$STATIC/zero/libjvm.a" \
  "$SIMFFI/lib/libffi.a" \
  "$STATIC/libjava.a" \
  "$STATIC/libjimage.a" \
  "$STATIC/libnet.a" \
  "$STATIC/libnio.a" \
  "$STATIC/libzip.a" \
  $cryptoki_libs

# Build the runtime image from THIS build's exploded classes so the
# Throwable guard patch above is included. Layout note: for a statically
# linked iOS JVM, hotspot derives java_home = <executable dir>/lib
# (os_bsd.cpp, __IOS__ branch) and set_boot_path then looks for
# <java_home>/lib/modules, so the folder reference must end up as
# <bundle>/lib/lib/modules.
mkdir -p "$DEMO_ROOT/work-generated"
JMODS="$DEMO_ROOT/work-generated/sim-jmods"
rm -rf "$JMODS"
mkdir -p "$JMODS"

# JDK 28 jlink requires the target java.base build descriptor to match the
# jlink runtime's, so synchronize it from the boot JDK (metadata only).
REL="jdk/internal/misc/resources/release.txt"
HOST_REL_DIR="$DEMO_ROOT/work-generated/sim-host-release"
rm -rf "$HOST_REL_DIR"
"$BOOT_JDK/bin/jimage" extract --include "regex:.*$REL" --dir "$HOST_REL_DIR" \
  "$BOOT_JDK/lib/modules" >/dev/null
HOST_REL="$HOST_REL_DIR/java.base/$REL"

for module in java.base jdk.unsupported jdk.crypto.cryptoki; do
  MODDIR="build/$CONF/jdk/modules/$module"
  [[ -d "$MODDIR" ]] || { echo "ERROR: missing exploded module $module" >&2; exit 1; }
  if [[ -f "$MODDIR/$REL" && -f "$HOST_REL" ]]; then
    cp "$HOST_REL" "$MODDIR/$REL"
  fi
  "$BOOT_JDK/bin/jmod" create --class-path "$MODDIR" \
    --target-platform macos-aarch64 "$JMODS/$module.jmod"
done

RUNTIME_OUT="$DEMO_ROOT/work-generated/sim-runtime"
rm -rf "$RUNTIME_OUT"
"$BOOT_JDK/bin/jlink" \
  --module-path "$JMODS" \
  --add-modules java.base,jdk.unsupported,jdk.crypto.cryptoki \
  --strip-debug --no-header-files --no-man-pages \
  --output "$RUNTIME_OUT"

mkdir -p "$DEMO_ROOT/third_party/lib/lib"
cp "$RUNTIME_OUT/lib/modules" "$DEMO_ROOT/third_party/lib/lib/modules"
cp "$RUNTIME_OUT/release" "$DEMO_ROOT/third_party/lib/release"
# java.time / java.util TimeZone need <java_home>/lib/tzdb.dat
# (sun.util.calendar.ZoneInfoFile), which the three-module jlink image does
# not carry; take it from the boot JDK like conf/.
cp "$BOOT_JDK/lib/tzdb.dat" "$DEMO_ROOT/third_party/lib/lib/tzdb.dat"

# Marker files for statically linked JDK-internal native libraries
# (System.loadLibrary("jimage") & co). The marker's only job is to exist on
# the system library path so NativeLibraries.findFromPaths hands the mapped
# name to findBuiltinLib(); that native check strips the lib prefix/suffix
# and looks up JNI_OnLoad_<name> in the process (RTLD_DEFAULT via the
# os_posix patch + -export_dynamic; the symbol keeper anchors the
# DEF_STATIC_JNI_OnLoad definition from the static archives). The builtin
# path then skips dlopen entirely and uses the process handle — the upstream
# statically-linked-library protocol, no JVM code changes needed.
#
# Audit of the shipped modules (java.base + jdk.unsupported +
# jdk.crypto.cryptoki) — only System.loadLibrary throws on failure;
# BootLoader.loadLibrary fails silently and the natives keep resolving via
# process symbols (proven by the demo's ServerSocket/zip usage):
#   jimage       System.loadLibrary, jimage reader   -> marker REQUIRED
#   j2pkcs11     System.loadLibrary, SunPKCS11 use   -> marker REQUIRED
#   net          BootLoader.loadLibrary (6 sites)    -> no marker (its
#                JNI_OnLoad_net is UNDEFINED in the archive; a marker would
#                fall into real dlopen of a 0-byte file and misfire)
#   nio, zip     BootLoader.loadLibrary, silent      -> no marker needed
#   osxsecurity  KeychainStore, lib not linked       -> not possible
#   fallbackLinker (FFM) lib not built/linked        -> not possible; would
#                only trigger if java.lang.foreign is used with fallback
touch "$DEMO_ROOT/third_party/lib/libjimage.dylib" \
      "$DEMO_ROOT/third_party/lib/libj2pkcs11.dylib"
# java.home is <bundle>/lib; the runtime reads conf/security/java.security
# etc. from <java_home>/conf. The three-module jlink image does not carry
# them, so take the configuration set from the boot JDK.
rm -rf "$DEMO_ROOT/third_party/lib/conf"
cp -R "$BOOT_JDK/conf" "$DEMO_ROOT/third_party/lib/conf"

echo "OK: $DEMO_ROOT/third_party/libtinyjvm-sim.a"
