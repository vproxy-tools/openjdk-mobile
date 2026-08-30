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

# The former source transforms (jni.cpp keeper anchor, JvmFeatures.gmk
# OPT_SPEED_SRC neutralization, plus the simulator port fixes applied by
# tiny-zero-ios-demo/support/build-sim-jvm.sh) are merged into this
# repository; git history is the single source of truth and no patches are
# applied or archived anymore. Fail fast if MOBILE_REF predates the merges
# so nobody builds an unpatched tree by accident.
grep -q 'tiny_symbol_keeper_anchor' "$SRC_DIR/src/hotspot/share/prims/jni.cpp" \
  || die "MOBILE_REF predates the merged Tiny Zero build hooks (jni.cpp keeper anchor missing); bump MOBILE_REF to a commit that contains them"
grep -q 'RTLD_DEFAULT' "$SRC_DIR/src/hotspot/os/posix/os_posix.cpp" \
  || die "MOBILE_REF predates the merged iOS port fixes (os_posix.cpp static native lookup missing); bump MOBILE_REF to a commit that contains them"
grep -q '  OPT_SPEED_SRC := *$' "$SRC_DIR/make/hotspot/lib/JvmFeatures.gmk" \
  || die "MOBILE_REF predates the merged Tiny Zero build hooks (JvmFeatures.gmk opt-size PCH consistency missing); bump MOBILE_REF to a commit that contains them"

git -C "$SRC_DIR" status --short > "$LOG_DIR/source-status-after-prepare.txt"
git -C "$SRC_DIR" rev-parse HEAD > "$LOG_DIR/mobile-commit.txt"

echo "Source prepared at $actual"
