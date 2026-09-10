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

Notes for recipients:
  - The loader re-signs the app with the recipient's own account; a free
    personal team profile then expires after 7 days, same as a local build.
  - Background (BGContinuedProcessingTask) mode needs the task identifier
    to be permitted by the plist; for installs whose bundle id gets
    rewritten by the signing tool (iLoader), patch the ipa afterwards with
    support/patch-ipa-team.py (see README).
"""

import os
import shutil
import subprocess
import sys
import zipfile

DEMO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TINY_ROOT = os.path.abspath(os.path.join(DEMO_ROOT, "..", "tiny-zero-ios-build"))
BUILD_DIR = os.path.join(DEMO_ROOT, "build")
CONFIG = os.environ.get("CONFIG", "Debug")
APP_PATH = os.path.join(BUILD_DIR, "Build", "Products",
                        f"{CONFIG}-iphoneos", "TinyHttpServer.app")
OUTPUT = os.environ.get(
    "OUTPUT", os.path.join(BUILD_DIR, f"TinyHttpServer-{CONFIG}-unsigned.ipa"))


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


def stage_device_frameworks():
    """Stages the iphoneos variant of the vproxy frameworks.

    build-java.sh stages the simulator variant by default (the documented
    sim-first flow); the unsigned device build needs the device slice in
    third_party/Frameworks.
    """
    subprocess.run(["./support/stage-frameworks.sh", "iphoneos"],
                   cwd=DEMO_ROOT, check=True)


def sync_device_static_lib():
    """Refreshes third_party/libtinyjvm.a from the device pipeline dist.

    The dist archive is the authoritative device JVM (symbol keeper,
    fallbackLinker/syslookup, port fixes); a stale third_party copy from an
    older device build would link an app whose -Dvfd=posix path is broken.
    """
    dist_lib = os.path.join(TINY_ROOT, "dist", "device", "lib", "libtinyjvm.a")
    local_lib = os.path.join(DEMO_ROOT, "third_party", "libtinyjvm.a")
    if os.path.exists(dist_lib):
        if os.path.getmtime(dist_lib) > os.path.getmtime(local_lib):
            print("==> copying libtinyjvm.a from dist/device")
            shutil.copy(dist_lib, local_lib)


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
    if not os.path.isdir(os.path.join(DEMO_ROOT, "third_party", "vproxy-frameworks")):
        die("third_party/vproxy-frameworks missing; run ./support/build-java.sh "
            "once (builds the libpni/libvfdposix frameworks)")

    # The bundle's lib/ folder is copied from third_party/lib at BUILD time,
    # so the iphoneos markers must be in place before xcodebuild runs.
    sync_device_static_lib()
    rebuild_device_markers()
    stage_device_frameworks()

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

    # Sanity: the bundle must be truly unsigned and self-contained.
    codesign = subprocess.run(["codesign", "-dv", APP_PATH],
                              capture_output=True, text=True)
    if codesign.returncode == 0 and "Signature=" in codesign.stdout:
        die("unexpected: the built app carries a signature")
    for must_exist in ("lib/lib/modules", "lib/lib/tzdb.dat",
                       "lib/libjimage.dylib", "lib/libj2pkcs11.dylib",
                       "Frameworks/libpni.framework/libpni.dylib",
                       "Frameworks/libvfdposix.framework/libvfdposix.dylib",
                       "vproxy.jar", "vproxy-ios-bootstrap.jar"):
        if not os.path.exists(os.path.join(APP_PATH, must_exist)):
            die(f"bundle incomplete: {must_exist} missing")
    # The marker dylibs (and the embedded vproxy frameworks) must be valid
    # Mach-O: external signing tools reject anything else ("file is too
    # small" from iLoader on 0-byte markers).
    for marker in ("lib/libjimage.dylib", "lib/libj2pkcs11.dylib",
                   "Frameworks/libpni.framework/libpni.dylib",
                   "Frameworks/libvfdposix.framework/libvfdposix.dylib"):
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
