#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
source "$(dirname "$0")/lib/static-libs.sh"

KEEPER="$SRC_DIR/src/hotspot/os/bsd/symbol_keeper.cpp"
SYMBOLS="$GEN_DIR/native-keep-symbols.txt"
LIBLIST="$GEN_DIR/native-keeper-input-libs.txt"

libs=()
for lib in "${TINY_BASE_STATIC_LIBS[@]}"; do
  path="$STATIC_LIB_DIR/$lib"
  require_file "$path"
  libs+=("$path")
done

cryptoki="$(print_cryptoki_archives "$BUILD_DIR" "$STATIC_LIB_DIR")" \
  || die "cannot discover jdk.crypto.cryptoki native archive"
while IFS= read -r lib; do
  [[ -n "$lib" ]] || continue
  require_file "$lib"
  libs+=("$lib")
done <<< "$cryptoki"

printf '%s\n' "${libs[@]}" > "$LIBLIST"

# Apple nm:
#   -g external symbols only
#   -U omit undefined symbols
# Mach-O C symbols normally have a leading underscore; removed by sed below.
raw="$(for lib in "${libs[@]}"; do xcrun nm -gU "$lib" 2>/dev/null || exit 1; done)" \
  || die "nm failed on an input archive"

printf '%s\n' "$raw" \
  | awk '{print $NF}' \
  | sed 's/^_//' \
  | grep -E '^(Java_|JNI_OnLoad|JNI_OnUnload|JIMAGE_|JDK_)' \
  | LC_ALL=C sort -u > "$SYMBOLS" || true

count="$(wc -l < "$SYMBOLS" | tr -d ' ')"
[[ "$count" -gt 0 ]] || die "generated native symbol keeper is empty"

{
  echo "/* Auto-generated. Do not edit."
  echo " * Inputs are listed in: $LIBLIST"
  echo " * Symbols are listed in: $SYMBOLS"
  echo " *"
  echo " * This file intentionally gives most selected native entries a generic"
  echo " * C function declaration. The functions are never called through this"
  echo " * declaration; only their addresses are placed in a relocation table."
  echo " *"
  echo " * Exception: the JIMAGE_* API is already declared (as real signatures)"
  echo " * in jimage.hpp, which is visible in this compilation unit via the"
  echo " * HotSpot include chain. Re-declaring them as void(void) would be an"
  echo " * overload conflict, so the real header is included instead."
  echo " */"
  echo
  if grep -q '^JIMAGE_' "$SYMBOLS"; then
    echo '#include "jimage.hpp"'
    echo
  fi
  echo 'extern "C" {'
  while IFS= read -r sym; do
    case "$sym" in
      JIMAGE_*) ;;
      *) printf 'void %s(void);\n' "$sym" ;;
    esac
  done < "$SYMBOLS"
  echo '}'
  echo
  echo '// Function pointers are cast to void* so entries with different real'
  echo '// signatures can share one relocation table.'
  echo 'static void* const tiny_kept_symbols[] = {'
  while IFS= read -r sym; do
    printf '  reinterpret_cast<void*>(&%s),\n' "$sym"
  done < "$SYMBOLS"
  echo '};'
  echo
  echo 'extern "C" void tiny_symbol_keeper_anchor() {'
  echo '  // The embedding app calls this once before JNI_CreateJavaVM; the'
  echo '  // inline-asm input keeps the table reachable without walking it.'
  echo '  __asm__ __volatile__("" : : "r"(tiny_kept_symbols) : "memory");'
  echo '}'
  echo
  echo 'extern "C" void loadfunctions() {'
  echo '  // Compatibility with the current ios-tools symbol keeper API.'
  echo '  tiny_symbol_keeper_anchor();'
  echo '}'
} > "$KEEPER"

cp "$KEEPER" "$GEN_DIR/symbol_keeper.cpp"

echo "Generated symbol keeper with $count symbols"
