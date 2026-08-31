#!/usr/bin/env python3
"""End-to-end real-device demo without the Xcode GUI.

Signs the app from the command line, installs it on the connected iPhone
via devicectl, launches the embedded JVM running vproxy -Deploy=helloworld,
verifies it with HTTP, and pulls the persisted JVM console out of the app
sandbox. Safe to re-run.

Environment overrides:
  DEVICE       device identifier/name (default: first connected device)
  TEAM_ID      signing team id (default: taken from the newest provisioning
               profile matching the bundle id on this Mac)
  LAUNCH_ARGS  app launch arguments (default: "-autostart", the
               BGContinuedProcessingTask flow; use "-autostart -direct" to
               start in foreground mode and isolate the background machinery)
  DEVICE_IP    phone IP for the HTTP check (default: the device's Bonjour
               <name>.local hostname)
  PORT         helloworld port (default 8080)

Notes:
  - The phone must be UNLOCKED for the launch (iOS refuses to open apps
    while locked, --no-activate does not help); the script reports it.
  - A personal-team provisioning profile is valid for 7 days. The build
    renews it headlessly via -allowProvisioningUpdates as long as the
    Apple ID session from Xcode is valid; only a dead session needs a
    one-time GUI run.
"""

import datetime
import glob
import json
import os
import plistlib
import shutil
import subprocess
import sys
import time
import urllib.request

DEMO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TINY_ROOT = os.environ.get("TINY_ROOT", os.path.abspath(os.path.join(DEMO_ROOT, "..", "tiny-zero-ios-build")))
DIST_DEVICE = os.path.join(TINY_ROOT, "dist", "device")
PROFILES_DIR = os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles")

APP_ID = "com.wkgcass.TinyHttpServer"
PROFILE_APPID_SUFFIX = "." + APP_ID
PORT = int(os.environ.get("PORT", "8080"))
LAUNCH_ARGS = os.environ.get("LAUNCH_ARGS", "-autostart").split()
DEVICE_SEL = os.environ.get("DEVICE", "")
DEVICE_IP = os.environ.get("DEVICE_IP", "")

BUILD_DIR = os.path.join(DEMO_ROOT, "build")
APP_PATH = os.path.join(BUILD_DIR, "Build", "Products", "Debug-iphoneos", "TinyHttpServer.app")


def die(message):
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def run(cmd, cwd=None, check=False, capture_text=True):
    result = subprocess.run(
        cmd, cwd=cwd,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=capture_text)
    if check and result.returncode != 0:
        die(f"command failed ({' '.join(cmd[:3])}...):\n{result.stdout.strip()}")
    return result


def pick_device():
    """Returns (device_identifier, bonjour_hostname) for the device to use."""
    listing = os.path.join(BUILD_DIR, "device-list.json")
    run(["xcrun", "devicectl", "list", "devices", "--json-output", listing], check=True)
    devices = json.load(open(listing))["result"]["devices"]

    def name_of(d):
        props = d.get("deviceProperties", {})
        return props.get("name") or props.get("displayName") or ""

    if DEVICE_SEL:
        for d in devices:
            if DEVICE_SEL == d.get("identifier") or DEVICE_SEL == name_of(d):
                break
        else:
            # devicectl also accepts names/UDIDs it knows; use it verbatim.
            return DEVICE_SEL, ""
        device = d
    else:
        connected = [d for d in devices
                     if d.get("connectionProperties", {}).get("tunnelState") == "connected"]
        if not connected:
            die("no connected device; plug in and trust the iPhone first")
        device = connected[0]

    # The coredevice hostname resolves to the developer tunnel; stripping
    # ".coredevice" leaves the Bonjour <name>.local that resolves to the
    # phone's Wi-Fi IP.
    host = (device.get("connectionProperties", {}).get("localHostnames") or [""])[0]
    return device["identifier"], host.replace(".coredevice", "")


def assemble_device_artifacts():
    """Copies the device static lib + runtime image into third_party/."""
    local_lib = os.path.join(DEMO_ROOT, "third_party", "libtinyjvm.a")
    if os.path.exists(local_lib):
        return
    dist_lib = os.path.join(DIST_DEVICE, "lib", "libtinyjvm.a")
    if not os.path.exists(dist_lib):
        die("no device JVM: third_party/libtinyjvm.a missing and "
            f"{dist_lib} not found; run the Tiny Zero build first "
            "(tiny-zero-ios-build/build.sh, README section 8)")
    print("==> assembling device artifacts from dist/device")
    shutil.copy(dist_lib, local_lib)
    shutil.copy(os.path.join(DIST_DEVICE, "runtime", "lib", "modules"),
                os.path.join(DEMO_ROOT, "third_party", "lib", "lib", "modules"))
    shutil.copy(os.path.join(DIST_DEVICE, "runtime", "release"),
                os.path.join(DEMO_ROOT, "third_party", "lib", "release"))


def ensure_jars():
    jars = [os.path.join(DEMO_ROOT, "third_party", n)
            for n in ("vproxy.jar", "vproxy-ios-bootstrap.jar")]
    if not all(os.path.exists(p) for p in jars):
        run(["./support/build-java.sh"], cwd=DEMO_ROOT, check=True)


def find_signing_profile():
    """Newest local profile matching the bundle id -> (team_id, expires)."""
    best = None  # (mtime, team, expires)
    for path in glob.glob(os.path.join(PROFILES_DIR, "*.mobileprovision")):
        decoded = subprocess.run(["security", "cms", "-D", "-i", path],
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        try:
            plist = plistlib.loads(decoded.stdout)
        except Exception:
            continue
        appid = plist.get("Entitlements", {}).get("application-identifier", "")
        if not appid.endswith(PROFILE_APPID_SUFFIX):
            continue
        mtime = os.path.getmtime(path)
        if best is None or mtime > best[0]:
            team = (plist.get("TeamIdentifier") or [None])[0]
            best = (mtime, team, plist.get("ExpirationDate"))
    if best is None:
        return None, None
    return best[1], best[2]


def build_signed_app(team_id):
    print("==> [1/2] signed app build (xcodebuild, no Xcode GUI)")
    run(["xcodegen", "generate"], cwd=DEMO_ROOT, check=True)
    build_log = os.path.join(BUILD_DIR, "device-build.log")
    result = subprocess.run(
        ["xcodebuild", "-project", "TinyHttpServer.xcodeproj",
         "-scheme", "TinyHttpServer", "-sdk", "iphoneos",
         "-configuration", "Debug", "-derivedDataPath", "build",
         "ARCHS=arm64", "-allowProvisioningUpdates",
         f"DEVELOPMENT_TEAM={team_id}", "build"],
        cwd=DEMO_ROOT,
        stdout=open(build_log, "w"), stderr=subprocess.STDOUT)
    if result.returncode != 0 or not os.path.isdir(APP_PATH):
        errors = sorted({line.strip() for line in open(build_log)
                         if "error: " in line})
        print(f"ERROR: signed build failed (full log: {build_log})",
              file=sys.stderr)
        for line in errors:
            print(f"    {line}", file=sys.stderr)
        if "No Account for Team" in open(build_log).read():
            print("    → Xcode 的 Apple ID 会话不可用:打开 Xcode → Settings →",
                  file=sys.stderr)
            print("      Accounts 确认账号已登录,GUI Run 一次刷新描述文件后重跑本脚本",
                  file=sys.stderr)
        sys.exit(1)
    print("    BUILD SUCCEEDED")


def install_and_launch(device):
    print(f"==> [2/2] install + launch ({' '.join(LAUNCH_ARGS)})")
    run(["xcrun", "devicectl", "device", "install", "app",
         "--device", device, APP_PATH], check=True)
    # "--" shields the app arguments: without it devicectl parses "-autostart"
    # as its own bundled short options (-a -u -t ... → "Missing value for -t").
    result = run(["xcrun", "devicectl", "device", "process", "launch",
                  "--terminate-existing", "--device", device,
                  APP_ID, "--", *LAUNCH_ARGS])
    if result.returncode != 0:
        print("ERROR: launch failed:", file=sys.stderr)
        for line in result.stdout.splitlines():
            if "ERROR" in line or "NSLocalizedFailureReason" in line:
                print(f"    {line.strip()}", file=sys.stderr)
        if "could not be, unlocked" in result.stdout:
            print("    → 手机处于锁屏状态:解锁手机后重新运行本脚本",
                  file=sys.stderr)
        sys.exit(1)


def wait_for_http(host):
    url = f"http://{host}:{PORT}/"
    print(f"==> waiting for HTTP on {host}:{PORT} "
          "(zero-interpreter bootstrap can take minutes)")
    for attempt in range(1, 41):
        time.sleep(10)
        try:
            with urllib.request.urlopen(url, timeout=5) as response:
                return response.status, response.read().decode(errors="replace")
        except Exception:
            print(f"    ...waiting ({attempt * 10}s)")
    return None, None


def pull_console_log(device):
    print("\n=== persisted JVM console (Documents/java-console.log, "
          "pulled from the device) ===")
    dest = os.path.join(BUILD_DIR, "device-java-console.log")
    result = run(["xcrun", "devicectl", "device", "copy", "from",
                  "--device", device, "--domain-type", "appDataContainer",
                  "--domain-identifier", APP_ID,
                  "--source", "Documents/java-console.log",
                  "--destination", dest])
    if result.returncode == 0 and os.path.exists(dest):
        lines = open(dest).read().splitlines()
        for line in lines[-8:]:
            print(line)
    else:
        print("(log not retrievable yet)")


def device_pid(device):
    result = run(["xcrun", "devicectl", "device", "info", "processes",
                  "--device", device])
    for line in result.stdout.splitlines():
        if "TinyHttpServer.app" in line:
            parts = line.split()
            if parts and parts[0].isdigit():
                return parts[0]
    return None


def main():
    # Progress interleaves sensibly with errors when piped (2>&1).
    sys.stdout.reconfigure(line_buffering=True)
    os.makedirs(BUILD_DIR, exist_ok=True)
    if shutil.which("xcodegen") is None:
        die("xcodegen not found: brew install xcodegen")

    device, host = pick_device()
    print(f"==> device: {device} (LAN: {host or '?'})")

    assemble_device_artifacts()
    ensure_jars()

    expires = None
    team_id = os.environ.get("TEAM_ID", "")
    if not team_id:
        team_id, expires = find_signing_profile()
    if not team_id:
        die("no provisioning profile for "
            f"{APP_ID} on this Mac; open the project in Xcode once, pick "
            "your team and Run (README section 8), or pass TEAM_ID=<id>")
    print(f"==> signing team: {team_id} "
          f"(profile expires: {expires or 'unknown'})")
    if expires and expires < datetime.datetime.now():
        print("==> WARNING: local profile already expired; the build will try")
        print("    to renew it headlessly via -allowProvisioningUpdates "
              "(needs a valid")
        print("    Apple ID session from Xcode). If that fails, open the "
              "project in Xcode")
        print("    once and press Run to refresh it.")

    build_signed_app(team_id)
    install_and_launch(device)

    target = DEVICE_IP or host
    if not target:
        print("WARNING: no hostname for the device; set DEVICE_IP=<phone ip>",
              file=sys.stderr)
    status, body = wait_for_http(target) if target else (None, None)
    if status is not None:
        print(f"\n=== HTTP response (http://{target}:{PORT}/) ===")
        print(f"HTTP {status}")
        print(body.strip())
    else:
        print("WARNING: no HTTP answer within 400s. Either the JVM is still",
              file=sys.stderr)
        print("booting, or the phone is unreachable at "
              f"{target} - set DEVICE_IP=<phone ip>", file=sys.stderr)
        print("(Settings > Wi-Fi > your network) and re-run. "
              "The console log below tells.", file=sys.stderr)

    pull_console_log(device)

    print()
    pid = device_pid(device)
    if pid:
        print("Stop the app with:")
        print(f"  xcrun devicectl device process terminate "
              f"--device \"{device}\" --pid {pid}")
    else:
        print("Stop the app via the app switcher, or find the pid with:")
        print(f"  xcrun devicectl device info processes --device \"{device}\"")


if __name__ == "__main__":
    main()
