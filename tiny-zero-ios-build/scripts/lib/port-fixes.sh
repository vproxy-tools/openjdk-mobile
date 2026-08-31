#!/usr/bin/env bash
# Shared guard: verify the source tree contains the merged Tiny Zero iOS
# port fixes. There is no patch layer - git history is the single source of
# truth - so the build fails fast on a tree that predates the fixes instead
# of silently building an unfixed tree.
#
# Each marker must be a string that exists ONLY in the fixed tree (do not use
# generic tokens such as MAP_JIT or RTLD_DEFAULT, which upstream also has).

type die >/dev/null 2>&1 || die() { echo "ERROR: $*" >&2; exit 1; }

check_port_fixes() {
  local src="$1"
  local marker file
  while read -r marker file; do
    [[ -n "$marker" ]] || continue
    grep -qF "$marker" "$src/$file" || \
      die "$file lacks '$marker' - the source tree predates the merged Tiny Zero port fixes"
  done <<'MARKERS'
TARGET_OS_SIMULATOR src/hotspot/os/bsd/os_bsd.cpp
set_callee_entry_point src/hotspot/cpu/zero/zeroInterpreter_zero.cpp
VM.isBooted src/java.base/share/classes/java/lang/Throwable.java
is_vm_statically_linked src/hotspot/os/posix/os_posix.cpp
__ss.__pc src/hotspot/os_cpu/bsd_zero/os_bsd_zero.cpp
lazy_wx_flip src/hotspot/os/posix/signals_posix.cpp
MARKERS
}
