#!/usr/bin/env bash
set -euo pipefail

# End-to-end simulator demo: build everything that is missing, install the
# app on an iPhone 13 (iOS 26.5) simulator, start the embedded JVM with the
# HTTP server, and verify it with curl. Safe to re-run; each stage is
# incremental or idempotent.

DEMO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TINY_ROOT="${TINY_ROOT:-$DEMO_ROOT/../tiny-zero-ios-build}"

APP_ID="com.wkgcass.TinyHttpServer"
DEVICE="iPhone 13"
RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-26-5"
DEVTYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-13"
PORT="${PORT:-8080}"

cd "$DEMO_ROOT"

# --- 0. prerequisites -------------------------------------------------------
command -v xcodegen >/dev/null || { echo "ERROR: brew install xcodegen" >&2; exit 1; }
[[ -f "$TINY_ROOT/config/build.env" ]] || {
  echo "ERROR: $TINY_ROOT/config/build.env missing; run the Tiny Zero build first" >&2; exit 1; }

# --- 1. simulator device ----------------------------------------------------
if ! xcrun simctl list devices available | grep -q "\"$DEVICE\""; then
  echo "==> creating $DEVICE ($RUNTIME)"
  xcrun simctl create "$DEVICE" "$DEVTYPE" "$RUNTIME" >/dev/null
fi
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null

# --- 2. build pipeline (each script is incremental) -------------------------
echo "==> [1/4] simulator libffi (skipped automatically if installed)"
./support/build-sim-libffi.sh
echo "==> [2/4] simulator Zero JVM + patched runtime image"
./support/build-sim-jvm.sh
echo "==> [3/4] demo jar"
./support/build-java.sh
echo "==> [4/4] Xcode project + app"
xcodegen generate >/dev/null
xcodebuild -project TinyHttpServer.xcodeproj -scheme TinyHttpServer \
  -sdk iphonesimulator -configuration Debug -derivedDataPath build \
  ARCHS=arm64 build \
  2>&1 | grep -E 'error:|BUILD ' | sort -u | tail -1

APP="$DEMO_ROOT/build/Build/Products/Debug-iphonesimulator/TinyHttpServer.app"
# Ad-hoc simulator signing drops the entitlement (JIT entitlement required for
# the MAP_JIT code cache); re-sign explicitly.
codesign -f -s - --entitlements "$DEMO_ROOT/App/Simulator.entitlements" "$APP"

# --- 3. install, launch, verify ----------------------------------------------
xcrun simctl terminate "$DEVICE" "$APP_ID" 2>/dev/null || true
xcrun simctl uninstall "$DEVICE" "$APP_ID" 2>/dev/null || true
xcrun simctl install "$DEVICE" "$APP"

echo "==> launching (JVM bootstrap takes roughly 30-60s on the zero interpreter)"
xcrun simctl launch "$DEVICE" "$APP_ID" -autostart "$PORT" -direct \
  | sed 's/^/    pid /'

ok=""
for i in $(seq 1 24); do
  sleep 10
  if curl -sS -m 5 -o /dev/null http://127.0.0.1:"$PORT"/ 2>/dev/null; then
    ok=1; break
  fi
  echo "    ...waiting ($((i*10))s)"
done

echo
if [[ -n "$ok" ]]; then
  echo "=== HTTP response ==="
  curl -sS -m 5 -i "http://127.0.0.1:$PORT/" | head -12
else
  echo "ERROR: server did not come up within 240s" >&2
  C=$(xcrun simctl get_app_container "$DEVICE" "$APP_ID" data 2>/dev/null || true)
  [[ -n "$C" ]] && tail -20 "$C/Documents/java-console.log" 2>/dev/null || true
  exit 1
fi

echo
echo "=== persisted JVM console (Documents/java-console.log) ==="
C=$(xcrun simctl get_app_container "$DEVICE" "$APP_ID" data)
tail -6 "$C/Documents/java-console.log"

echo
echo "Demo is running. Stop with:"
echo "  xcrun simctl terminate \"$DEVICE\" $APP_ID"
