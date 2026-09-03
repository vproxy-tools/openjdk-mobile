#!/usr/bin/env bash
# Shared runtime-image helpers: jmod packaging, jlink, and assembly of the
# <bundle>/lib runtime tree used by both the device pipeline and the
# simulator demo build.

type die >/dev/null 2>&1 || die() { echo "ERROR: $*" >&2; exit 1; }

# shellcheck disable=SC1090
source "$(dirname "${BASH_SOURCE[0]}")/static-libs.sh"

RELEASE_TXT_REL="jdk/internal/misc/resources/release.txt"

# sync_jmod_release_descriptor <jdk_module_dir> <boot_jdk> <scratch_dir>
# JDK 28 jlink refuses to link a java.base whose build descriptor differs
# from the jlink runtime's. The target java.base is an adhoc in-tree build
# while the host tools are a published JDK build, so copy the descriptor
# resource from the boot JDK into the exploded module before jmod packaging.
# Metadata only; no runtime behavior change.
sync_jmod_release_descriptor() {
  local jdk_module_dir="$1" boot_jdk="$2" scratch="$3"
  rm -rf "$scratch"
  "$boot_jdk/bin/jimage" extract \
    --include "regex:.*$RELEASE_TXT_REL" \
    --dir "$scratch" \
    "$boot_jdk/lib/modules"
  local host_release="$scratch/java.base/$RELEASE_TXT_REL"
  [[ -f "$host_release" ]] || die "release descriptor not found in boot JDK jimage"
  local base_release="$jdk_module_dir/java.base/$RELEASE_TXT_REL"
  if [[ -f "$base_release" ]]; then
    cp "$host_release" "$base_release"
  fi
}

# create_module_jmods <jdk_module_dir> <jmod_out_dir> <boot_jdk>
# JDK 28 jlink resolves the ModuleTarget platform through its own java.base
# OperatingSystem enum, which has no "ios" member (only the mobile tree adds
# it). macos-aarch64 is the closest accepted value: same endianness and word
# size, so the generated jimage is identical. Only the OS_NAME entry of the
# link-time release metadata differs; os.name on the device comes from the
# VM, not from this file.
create_module_jmods() {
  local jdk_module_dir="$1" jmod_out="$2" boot_jdk="$3"
  rm -rf "$jmod_out"
  mkdir -p "$jmod_out"
  local module module_dir
  for module in "${TINY_RUNTIME_MODULES[@]}"; do
    module_dir="$jdk_module_dir/$module"
    [[ -d "$module_dir" ]] || die "missing exploded module: $module_dir"
    "$boot_jdk/bin/jmod" create \
      --class-path "$module_dir" \
      --target-platform macos-aarch64 \
      "$jmod_out/$module.jmod"
  done
}

# jlink_tiny_runtime <jmod_dir> <out_dir> <boot_jdk>
jlink_tiny_runtime() {
  local jmod_dir="$1" out_dir="$2" boot_jdk="$3"
  local modules
  modules="$(IFS=,; echo "${TINY_RUNTIME_MODULES[*]}")"
  rm -rf "$out_dir"
  "$boot_jdk/bin/jlink" \
    --module-path "$jmod_dir" \
    --add-modules "$modules" \
    --strip-debug \
    --no-header-files \
    --no-man-pages \
    --output "$out_dir"
  [[ -f "$out_dir/lib/modules" ]] || die "jlink did not produce $out_dir/lib/modules"
  [[ -f "$out_dir/release" ]] || die "jlink did not produce $out_dir/release"
}

# make_marker_dylibs <dest_lib_dir> <sdk: iphoneos|iphonesimulator>
# Builds the libjimage/libj2pkcs11 marker dylibs for one target platform as
# minimal VALID Mach-O files. The JVM builtin-lib protocol only needs the
# file to exist on the system library path - its content is never loaded
# (findBuiltinLib resolves JNI_OnLoad_<name> in the process image and skips
# dlopen) - but external signing tools (iLoader/Sideloadly/...) validate
# every *.dylib in the bundle and reject non-Mach-O files ("file is too
# small"), so 0-byte markers do not survive distribution. Device packaging
# regenerates these for iphoneos after a simulator build staged the
# simulator slice (same shared third_party/lib tree).
make_marker_dylibs() {
  local dest="$1" sdk="$2" tmp name
  tmp="$(mktemp -d)"
  cat >"$tmp/marker.c" <<'EOF'
/* Content never loads: the file's existence routes statically linked
   internal libraries through findBuiltinLib instead of dlopen. */
void tiny_zero_builtin_lib_marker(void) {}
EOF
  for name in jimage j2pkcs11; do
    xcrun --sdk "$sdk" clang -shared -arch arm64 \
      -Wl,-install_name,@rpath/lib$name.dylib \
      -o "$dest/lib$name.dylib" "$tmp/marker.c"
  done
  rm -rf "$tmp"
}

# stage_runtime_lib <jlink_out_dir> <boot_jdk> <dest_lib_dir>
# Assembles the tree that becomes <bundle>/lib (= java_home for a statically
# linked iOS JVM) in the app:
#   lib/modules + release          from the jlink image
#   conf/ + lib/tzdb.dat           from the boot JDK: the three-module jlink
#                                  image carries neither the security/policy
#                                  configuration nor the time-zone database
#                                  (sun.util.calendar.ZoneInfoFile reads
#                                  <java_home>/lib/tzdb.dat)
#   libjimage.dylib/libj2pkcs11.dylib
#                                  minimal valid Mach-O markers for the
#                                  given SDK (see make_marker_dylibs) for
#                                  JDK-internal libraries that are
#                                  statically linked but requested via
#                                  System.loadLibrary: the marker's
#                                  existence routes the load through
#                                  NativeLibraries.findBuiltinLib
#                                  (JNI_OnLoad_<name> in the process image)
#                                  and skips dlopen entirely.
# stage_runtime_lib <jlink_out_dir> <boot_jdk> <dest_lib_dir> [sdk]
stage_runtime_lib() {
  local runtime_out="$1" boot_jdk="$2" dest="$3" sdk="${4:-iphonesimulator}"
  [[ -f "$boot_jdk/lib/tzdb.dat" ]] || die "boot JDK lacks lib/tzdb.dat: $boot_jdk"
  [[ -d "$boot_jdk/conf" ]] || die "boot JDK lacks conf/: $boot_jdk"
  rm -rf "$dest"
  mkdir -p "$dest/lib"
  cp "$runtime_out/lib/modules" "$dest/lib/modules"
  cp "$runtime_out/release" "$dest/release"
  cp -R "$boot_jdk/conf" "$dest/conf"
  cp "$boot_jdk/lib/tzdb.dat" "$dest/lib/tzdb.dat"
  make_marker_dylibs "$dest" "$sdk"
}
