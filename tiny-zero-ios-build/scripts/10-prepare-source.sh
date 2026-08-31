#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/common.sh"
source "$(dirname "$0")/lib/port-fixes.sh"

# The pipeline builds the enclosing repository's working tree directly - no
# clone/fetch/checkout. Whatever is checked out (including uncommitted
# changes) is what gets built; the recorded HEAD and status below say what
# that was.
require_file "$SRC_DIR/configure"
require_dir "$SRC_DIR/src/hotspot"

# Keep this file present from the first configure/build so HotSpot's source
# discovery knows about it. Pass 1 uses a stub; after native archives exist,
# 40-generate-symbol-keeper.sh replaces it with a generated precise keeper.
# The embedding app calls tiny_symbol_keeper_anchor() once before
# JNI_CreateJavaVM (see tiny-zero-ios-demo/JvmEmbed/Native/jvm_bridge.mm),
# which pulls this object out of the static archive together with every
# symbol in the keeper table - no -all_load/-force_load needed.
# The file is generated into the source tree and is gitignored.
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

# The port fixes are merged into this repository; git history is the single
# source of truth and no patches are applied or archived anymore. Fail fast
# if the working tree predates the merges so nobody builds an unfixed tree.
check_port_fixes "$SRC_DIR"

git -C "$SRC_DIR" status --short > "$LOG_DIR/source-status-after-prepare.txt"
git -C "$SRC_DIR" rev-parse HEAD > "$LOG_DIR/mobile-commit.txt"

echo "Source tree OK: $SRC_DIR (HEAD $(cat "$LOG_DIR/mobile-commit.txt"))"
