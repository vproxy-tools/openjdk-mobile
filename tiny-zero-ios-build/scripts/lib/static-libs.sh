#!/usr/bin/env bash
# Shared static-archive helpers for the Tiny Zero build.

type die >/dev/null 2>&1 || die() { echo "ERROR: $*" >&2; exit 1; }

# Base java.base native archives that always go into the combined library.
# libfallbackLinker.a is the libffi-based java.lang.foreign Linker backend:
# the Zero variant has no assembly linker, so without it Linker.nativeLinker()
# throws "Platform does not support native linker" and every FFM user
# (vproxy's PNI with -Dvfd=posix, jdk.internal.misc.Unsafe alternatives,
# ...) dies during class initialization.
# libsyslookup.a backs Linker.defaultLookup(): its DEF_STATIC_JNI_OnLoad
# (JNI_OnLoad_syslookup) routes System.loadLibrary("syslookup") through the
# builtin-lib protocol, and the process handle then resolves libc symbols
# across all loaded images (RTLD_DEFAULT fix) - on desktop the JDK dlopens a
# real libsyslookup.dylib for its dependency closure instead.
TINY_BASE_STATIC_LIBS=(libjava.a libjimage.a libnet.a libnio.a libzip.a libfallbackLinker.a libsyslookup.a)

# The three modules shipped in the runtime image.
TINY_RUNTIME_MODULES=(java.base jdk.unsupported jdk.crypto.cryptoki)

# print_cryptoki_archives <build_dir> <static_lib_dir>
# Prints every static archive produced for jdk.crypto.cryptoki, one per line,
# deterministically sorted. The module-specific support/native tree is
# preferred so the archive basename is never guessed; the static-libs
# directory is the fallback for build revisions that flatten it there.
# Returns 1 when no archive is found.
print_cryptoki_archives() {
  local build_dir="$1" static_lib_dir="$2"
  local libs=""
  if [[ -d "$build_dir/support/native/jdk.crypto.cryptoki" ]]; then
    libs="$(find "$build_dir/support/native/jdk.crypto.cryptoki" -type f -name '*.a' -print | LC_ALL=C sort)"
  fi
  if [[ -z "$libs" ]]; then
    libs="$(find "$static_lib_dir" -maxdepth 1 -type f -name '*pkcs11*.a' -print | LC_ALL=C sort)"
  fi
  [[ -n "$libs" ]] || return 1
  printf '%s\n' "$libs"
}
