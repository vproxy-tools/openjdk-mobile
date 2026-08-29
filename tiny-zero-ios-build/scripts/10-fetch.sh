#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"

mkdir -p "$WORK_DIR"

if [[ ! -d "$SRC_DIR/.git" ]]; then
  git clone --no-checkout "$MOBILE_REPO" "$SRC_DIR"
fi

git -C "$SRC_DIR" remote set-url origin "$MOBILE_REPO"
git -C "$SRC_DIR" fetch --no-tags origin "$MOBILE_REF"

if [[ "$CLEAN_WORKTREE" == "1" ]]; then
  git -C "$SRC_DIR" reset --hard
  git -C "$SRC_DIR" clean -fdx
fi

git -C "$SRC_DIR" checkout --detach "$MOBILE_REF"

actual="$(git -C "$SRC_DIR" rev-parse HEAD)"
[[ "$actual" == "$MOBILE_REF" ]] || die "checkout mismatch: expected $MOBILE_REF, got $actual"

# Keep this file present from the first configure/build so HotSpot's source
# discovery knows about it. Pass 1 uses a stub; after native archives exist,
# 40-generate-symbol-keeper.sh replaces it with a generated precise keeper.
KEEPER="$SRC_DIR/src/hotspot/os/bsd/symbol_keeper.cpp"
cat > "$KEEPER" <<'EOF'
extern "C" void tiny_symbol_keeper_anchor() {
  // Pass-1 stub. Replaced automatically after native archives are built.
}

// Keep the upstream ios-tools symbol name available for compatibility.
extern "C" void loadfunctions() {
  tiny_symbol_keeper_anchor();
}
EOF

# Make the keeper self-anchoring: the final iOS application must not need
# -all_load/-force_load or an explicit call to loadfunctions(). JNI_CreateJavaVM
# is the natural root because any embedded JVM must reach it. The exact source
# shape is treated as a build contract: if upstream changes it, fail and review
# the patch instead of silently producing a broken static runtime.
JNI_CPP="$SRC_DIR/src/hotspot/share/prims/jni.cpp"
require_file "$JNI_CPP"
JNI_TMP="$JNI_CPP.tiny-zero.tmp"
if ! awk '
  BEGIN { decl=0; call=0 }
  {
    print $0
    if ($0 == "#include \"jni.h\"") {
      print "extern \"C\" void tiny_symbol_keeper_anchor();"
      decl++
    }
    if ($0 == "_JNI_IMPORT_OR_EXPORT_ jint JNICALL JNI_CreateJavaVM(JavaVM **vm, void **penv, void *args) {") {
      print "  tiny_symbol_keeper_anchor();"
      call++
    }
  }
  END {
    if (decl != 1 || call != 1) exit 42
  }
' "$JNI_CPP" > "$JNI_TMP"; then
  rm -f "$JNI_TMP"
  die "cannot apply Tiny Zero JNI anchor patch; upstream jni.cpp shape changed"
fi
mv "$JNI_TMP" "$JNI_CPP"

git -C "$SRC_DIR" diff -- src/hotspot/share/prims/jni.cpp > "$GEN_DIR/tiny-jni-anchor.patch"

# Tiny Zero builds with the opt-size JVM feature on the iOS static target.
# Upstream JvmFeatures.gmk promotes a list of performance-sensitive sources
# (OPT_SPEED_SRC) to -O3 when opt-size is active. The static build compiles a
# precompiled header with -Os (__OPTIMIZE_SIZE__ defined), and clang rejects
# any translation unit that reuses that PCH with a different optimization
# level. Tiny Zero is size-first, so the list is emptied and every file stays
# at -Os, matching the PCH exactly.
FEATURES_GMK="$SRC_DIR/make/hotspot/lib/JvmFeatures.gmk"
require_file "$FEATURES_GMK"
FEATURES_TMP="$FEATURES_GMK.tiny-zero.tmp"
if ! awk '
  BEGIN { stripped=0; skipping=0 }
  {
    if (skipping) {
      if ($0 == "      #") { skipping=0 }
      next
    }
    if ($0 == "  OPT_SPEED_SRC := \\") {
      print "  OPT_SPEED_SRC :="
      stripped++
      skipping=1
      next
    }
    print $0
  }
  END {
    if (stripped != 1) exit 42
  }
' "$FEATURES_GMK" > "$FEATURES_TMP"; then
  rm -f "$FEATURES_TMP"
  die "cannot neutralize OPT_SPEED_SRC; upstream JvmFeatures.gmk shape changed"
fi
mv "$FEATURES_TMP" "$FEATURES_GMK"
git -C "$SRC_DIR" diff -- make/hotspot/lib/JvmFeatures.gmk > "$GEN_DIR/tiny-opt-size-pch.patch"

git -C "$SRC_DIR" status --short > "$LOG_DIR/source-status-after-prepare.txt"
git -C "$SRC_DIR" rev-parse HEAD > "$LOG_DIR/mobile-commit.txt"

echo "Source prepared at $actual"
