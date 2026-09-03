#!/usr/bin/env python3
"""Package an UNSIGNED ipa of the demo for distribution.

Builds the app for real devices (iphoneos) with code signing disabled
entirely (CODE_SIGNING_ALLOWED=NO) and wraps the .app into the standard
Payload/<bundle>.app ipa layout, ready to be handed to side-loading tools
(iLoader, Sideloadly, AltStore, ...), which apply the recipient's own
signature during installation.

Environment overrides:
  CONFIG   build configuration (default: Debug - the configuration all
           device validation ran on; Release also works)
  OUTPUT   ipa output path (default: build/TinyHttpServer-<CONFIG>-unsigned.ipa)
  TEAM_ID  recipient's signing team id. Sideload tools rewrite the bundle
           identifier to <bundle>.<TEAMID>, but iLoader fails to rewrite
           BGTaskSchedulerPermittedIdentifiers accordingly (its bug), so
           background mode breaks on such installs. When TEAM_ID is given,
           the team-suffixed task identifier
           (<bundle>.<TEAMID>.continuedProcessing.demo, dot separated) is
           baked into the plist next to the plain entry; when omitted,
           nothing is added.

Notes for recipients:
  - The loader re-signs the app with the recipient's own account; a free
    personal team profile then expires after 7 days, same as a local build.
  - Background (BGContinuedProcessingTask) mode needs the task identifier
    to be permitted by the plist; install without a bundle-id rewrite, or
    package with the recipient's TEAM_ID as above.
"""

import os
import plistlib
import subprocess
import sys
import zipfile

DEMO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TINY_ROOT = os.path.abspath(os.path.join(DEMO_ROOT, "..", "tiny-zero-ios-build"))
BUILD_DIR = os.path.join(DEMO_ROOT, "build")
CONFIG = os.environ.get("CONFIG", "Debug")
TEAM_ID = os.environ.get("TEAM_ID", "")
APP_PATH = os.path.join(BUILD_DIR, "Build", "Products",
                        f"{CONFIG}-iphoneos", "TinyHttpServer.app")
# The team id lands in the default file name so a team-suffixed build can
# never be confused with the plain one (handing out the wrong variant is
# exactly how background mode breaks on rewritten installs).
OUTPUT = os.environ.get(
    "OUTPUT",
    os.path.join(BUILD_DIR, f"TinyHttpServer-{CONFIG}"
                 + (f"-team-{TEAM_ID}" if TEAM_ID else "")
                 + "-unsigned.ipa"))


def die(message):
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def rebuild_device_markers():
    """Regenerates the builtin-lib marker dylibs with the iphoneos slice.

    The simulator build stages the simulator slice into the shared
    third_party/lib tree; device packaging needs the device slice so every
    Mach-O in the bundle matches the target (external signing tools parse
    each one; the JVM itself never loads the marker).
    """
    lib = os.path.join(DEMO_ROOT, "third_party", "lib")
    runtime_image = os.path.join(TINY_ROOT, "scripts", "lib", "runtime-image.sh")
    subprocess.run(
        ["bash", "-c",
         f"source '{runtime_image}' && make_marker_dylibs '{lib}' iphoneos"],
        check=True)


def bake_team_identifier_entry():
    """Appends the team-suffixed task identifier to the plist whitelist.

    iLoader rewrites the bundle id to <bundle>.<TEAMID> but leaves
    BGTaskSchedulerPermittedIdentifiers untouched (its bug); the app then
    derives <bundle>.<TEAMID>.continuedProcessing.demo at runtime, which the
    plist must list literally (the gate is exact-match only). Editing the
    plist after the build is safe here: the app is unsigned.
    """
    if not TEAM_ID:
        return
    plist_path = os.path.join(APP_PATH, "Info.plist")
    with open(plist_path, "rb") as f:
        plist = plistlib.load(f)
    entries = plist.setdefault("BGTaskSchedulerPermittedIdentifiers", [])
    team_entry = f"{plist['CFBundleIdentifier']}.{TEAM_ID}.continuedProcessing.demo"
    if team_entry not in entries:
        entries.append(team_entry)
    with open(plist_path, "wb") as f:
        plistlib.dump(plist, f)
    print(f"    BGTask identifier for team {TEAM_ID}: {team_entry}")


def main():
    sys.stdout.reconfigure(line_buffering=True)
    if subprocess.run(["which", "xcodegen"], capture_output=True).returncode != 0:
        die("xcodegen not found: brew install xcodegen")
    if not os.path.exists(os.path.join(DEMO_ROOT, "third_party", "libtinyjvm.a")):
        die("third_party/libtinyjvm.a missing; run ./support/run-device-demo.py "
            "once (or the Tiny Zero build pipeline) to assemble device artifacts")
    if not os.path.isdir(os.path.join(DEMO_ROOT, "third_party", "lib")):
        die("third_party/lib missing; run ./support/build-sim-jvm.sh once to "
            "stage the runtime tree")

    # The bundle's lib/ folder is copied from third_party/lib at BUILD time,
    # so the iphoneos markers must be in place before xcodebuild runs.
    rebuild_device_markers()

    print(f"==> [1/2] unsigned device build ({CONFIG}, CODE_SIGNING_ALLOWED=NO)")
    subprocess.run(["xcodegen", "generate"], cwd=DEMO_ROOT,
                   stdout=subprocess.DEVNULL, check=True)
    build_log = os.path.join(BUILD_DIR, "ipa-build.log")
    result = subprocess.run(
        ["xcodebuild", "-project", "TinyHttpServer.xcodeproj",
         "-scheme", "TinyHttpServer", "-sdk", "iphoneos",
         "-configuration", CONFIG, "-derivedDataPath", "build",
         "ARCHS=arm64", "CODE_SIGNING_ALLOWED=NO", "build"],
        cwd=DEMO_ROOT, stdout=open(build_log, "w"), stderr=subprocess.STDOUT)
    if result.returncode != 0 or not os.path.isdir(APP_PATH):
        for line in sorted({l.strip() for l in open(build_log) if "error: " in l}):
            print(f"    {line}", file=sys.stderr)
        die(f"unsigned build failed (full log: {build_log})")
    print("    BUILD SUCCEEDED")

    bake_team_identifier_entry()

    # Sanity: the bundle must be truly unsigned and self-contained.
    codesign = subprocess.run(["codesign", "-dv", APP_PATH],
                              capture_output=True, text=True)
    if codesign.returncode == 0 and "Signature=" in codesign.stdout:
        die("unexpected: the built app carries a signature")
    for must_exist in ("lib/lib/modules", "lib/lib/tzdb.dat",
                       "lib/libjimage.dylib", "lib/libj2pkcs11.dylib",
                       "vproxy.jar", "vproxy-ios-bootstrap.jar"):
        if not os.path.exists(os.path.join(APP_PATH, must_exist)):
            die(f"bundle incomplete: {must_exist} missing")
    # The marker dylibs must be valid Mach-O: external signing tools reject
    # anything else ("file is too small" from iLoader on 0-byte markers).
    for marker in ("lib/libjimage.dylib", "lib/libj2pkcs11.dylib"):
        with open(os.path.join(APP_PATH, marker), "rb") as f:
            magic = f.read(4)
        if magic not in (b"\xcf\xfa\xed\xfe",   # MH_MAGIC_64
                         b"\xca\xfe\xba\xbe"):  # FAT magic
            die(f"{marker} is not a Mach-O file: {magic!r}")

    print("==> [2/2] packaging ipa")
    if os.path.exists(OUTPUT):
        os.remove(OUTPUT)
    with zipfile.ZipFile(OUTPUT, "w", zipfile.ZIP_DEFLATED) as ipa:
        app_name = os.path.basename(APP_PATH)
        for root, dirs, files in os.walk(APP_PATH):
            dirs[:] = [d for d in dirs if d != ".DS_Store"]
            for name in sorted(files):
                if name == ".DS_Store":
                    continue
                full = os.path.join(root, name)
                arc = os.path.join("Payload", app_name,
                                   os.path.relpath(full, APP_PATH))
                ipa.write(full, arc)

    size = os.path.getsize(OUTPUT) / 1024 / 1024
    print(f"\nOK: {OUTPUT} ({size:.1f} MB)")
    print("The app inside is unsigned; the receiving side signs it during")
    print("installation (iLoader/Sideloadly/AltStore or similar).")


if __name__ == "__main__":
    main()
