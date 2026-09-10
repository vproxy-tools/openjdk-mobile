#!/usr/bin/env python3
"""Sign the unsigned demo ipa with the LOCAL development identity.

Works fully offline: code signing only needs a keychain certificate plus a
provisioning profile that already lists the target device (created when the
phone was last connected through Xcode). The phone itself is only needed to
INSTALL the signed app, never to sign it.

How the defaults are resolved:
  profile   newest *.mobileprovision under Xcode's UserData profile dir whose
            application-identifier matches the app's bundle id (same rule as
            run-device-demo.py); --profile overrides
  identity  a valid codesigning identity whose certificate OU equals the
            profile's team id (newest certificate wins); --identity overrides

Free personal-team profiles (and therefore the signed app) expire 7 days
after issuance; --renewal hints are printed when time is short.

Usage:
  ./support/sign-ipa.py                                   # sign the default ipa
  ./support/sign-ipa.py build/TinyHttpServer-Release-unsigned.ipa
  ./support/sign-ipa.py -o /tmp/out.ipa
  ./support/sign-ipa.py --profile <x.mobileprovision> --identity "<cert name>"

Output default: <input>-unsigned.ipa -> <input>-signed.ipa
"""

import argparse
import datetime
import glob
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

DEMO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD_DIR = os.path.join(DEMO_ROOT, "build")
DEFAULT_IPA = os.path.join(BUILD_DIR, "TinyHttpServer-Debug-unsigned.ipa")
PROFILES_DIR = os.path.expanduser(
    "~/Library/Developer/Xcode/UserData/Provisioning Profiles")


def die(message):
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def run(cmd, input_bytes=None):
    result = subprocess.run(cmd, input=input_bytes,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode != 0:
        die(f"command failed: {' '.join(cmd)}\n"
            f"{result.stderr.decode(errors='replace').strip()}")
    return result.stdout.decode(errors="replace")


def find_profile(bundle_id):
    """Newest local profile whose application-identifier matches the bundle
    id (exact app id or wildcard). Returns the parsed profile plist."""
    best = None  # (mtime, path, plist)
    for path in glob.glob(os.path.join(PROFILES_DIR, "*.mobileprovision")):
        decoded = subprocess.run(["security", "cms", "-D", "-i", path],
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        try:
            plist = plistlib.loads(decoded.stdout)
        except Exception:
            continue
        appid = plist.get("Entitlements", {}).get("application-identifier", "")
        prefix, _, app_id = appid.partition(".")
        if app_id != bundle_id and app_id != "*":
            continue
        mtime = os.path.getmtime(path)
        if best is None or mtime > best[0]:
            best = (mtime, path, plist)
    if best is None:
        die(f"no provisioning profile for {bundle_id} in {PROFILES_DIR}; "
            "connect the phone once via Xcode (or run ./support/"
            "run-device-demo.py) to create one, or pass --profile")
    return best[1], best[2]


def find_identity(team_id):
    """A valid codesigning identity belonging to team_id (certificate OU);
    among equals the newest certificate wins. Returns (hash, name)."""
    listing = run(["security", "find-identity", "-v", "-p", "codesigning"])
    valid = re.findall(r'\)\s*([0-9A-F]{40})\s+"([^"]+)"', listing)
    if not valid:
        die("no valid codesigning identity in the keychain "
            '(security find-identity -v -p codesigning)')

    certs = run(["security", "find-certificate", "-a", "-Z", "-p"])
    matches = []  # (notAfter, hash, name)
    for block in re.split(r"(?=SHA-1 hash:)", certs):
        m = re.match(r"SHA-1 hash:\s*([0-9A-F]{40})", block)
        if not m:
            continue
        pem = block[block.find("-----BEGIN"):]
        if not pem.startswith("-----BEGIN"):
            continue
        info = run(["openssl", "x509", "-noout", "-subject", "-enddate"],
                   input_bytes=pem.encode())
        if f"/OU={team_id}" not in info:
            continue
        end = re.search(r"notAfter=(.+)", info)
        expiry = end.group(1).strip() if end else ""
        for h, name in valid:
            if h == m.group(1):
                matches.append((expiry, h, name))
    if not matches:
        die(f"no signing certificate for team {team_id} among: " +
            ", ".join(name for _, name in valid) +
            "; pass --identity explicitly")
    matches.sort()  # newest notAfter last
    return matches[-1][1], matches[-1][2]


def check_expiry(plist):
    expires = plist.get("ExpirationDate")
    if expires is None:
        return
    if expires.tzinfo is None:
        expires = expires.replace(tzinfo=datetime.timezone.utc)
    now = datetime.datetime.now(datetime.timezone.utc)
    if expires < now:
        die("the provisioning profile already EXPIRED "
            f"({expires:%Y-%m-%d %H:%M} UTC); renew it without the phone via "
            "xcodebuild -allowProvisioningUpdates (or ./support/run-device-demo.py), "
            "then re-run this script")
    left = expires - now
    if left < datetime.timedelta(days=2):
        print(f"==> WARNING: profile expires in {left}, the signed app stops "
              "launching after that (free personal team = 7 days per profile)")


def codesign(path, identity, entitlements=None):
    cmd = ["codesign", "--force", "--timestamp=none", "--sign", identity]
    if entitlements:
        cmd += ["--entitlements", entitlements]
    cmd.append(path)
    print(f"    codesign {os.path.basename(path)}")
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode != 0:
        die(f"codesign failed for {path}:\n"
            f"{result.stdout.decode(errors='replace').strip()}")


def main():
    sys.stdout.reconfigure(line_buffering=True)
    parser = argparse.ArgumentParser(
        description="Sign the unsigned demo ipa with the local development identity.")
    parser.add_argument("ipa", nargs="?", default=DEFAULT_IPA,
                        help=f"input ipa (default: {DEFAULT_IPA})")
    parser.add_argument("-o", "--output", default=None,
                        help="output ipa (default: input name with -signed.ipa)")
    parser.add_argument("--profile", default=None,
                        help="path to a .mobileprovision (default: newest local match)")
    parser.add_argument("--identity", default=None,
                        help='signing identity name or hash (default: resolved by team)')
    args = parser.parse_args()

    if not os.path.exists(args.ipa):
        die(f"ipa not found: {args.ipa}; run ./support/package-ipa.py first")
    output = args.output or re.sub(r"(-unsigned)?\.ipa$", "", args.ipa) + "-signed.ipa"

    work = tempfile.mkdtemp(prefix="sign-ipa-")
    try:
        with zipfile.ZipFile(args.ipa) as ipa:
            ipa.extractall(work)
        apps = glob.glob(os.path.join(work, "Payload", "*.app"))
        if len(apps) != 1:
            die(f"expected exactly one .app inside the ipa, found {len(apps)}")
        app = apps[0]

        with open(os.path.join(app, "Info.plist"), "rb") as f:
            bundle_id = plistlib.load(f)["CFBundleIdentifier"]

        if args.profile:
            profile_path = args.profile
            decoded = subprocess.run(["security", "cms", "-D", "-i", profile_path],
                                     stdout=subprocess.PIPE)
            try:
                profile = plistlib.loads(decoded.stdout)
            except Exception:
                die(f"cannot parse profile: {profile_path}")
        else:
            profile_path, profile = find_profile(bundle_id)

        team = (profile.get("TeamIdentifier") or [""])[0]
        appid = profile.get("Entitlements", {}).get("application-identifier", "")
        devices = profile.get("ProvisionedDevices", [])
        if not appid.endswith("." + bundle_id) and not appid.endswith(".*"):
            die(f"profile {profile_path} is for {appid}, not {bundle_id}")
        print(f"==> profile: {os.path.basename(profile_path)}")
        print(f"    team {team}, {len(devices)} registered device(s), "
              f"expires {profile.get('ExpirationDate')}")
        check_expiry(profile)

        identity = args.identity
        if not identity:
            # Sign by certificate HASH: multiple certificates in the keychain
            # may share the same friendly name, which makes "-s <name>"
            # ambiguous.
            hash_, name = find_identity(team)
            identity = hash_
            print(f"==> identity: {name} ({hash_[:8]}…)")

        # Entitlements: the profile's own Entitlements dict is exactly the
        # authorized set for this app id (application-identifier, team id,
        # get-task-allow, ...).
        ents_path = os.path.join(work, "entitlements.plist")
        with open(ents_path, "wb") as f:
            plistlib.dump(profile.get("Entitlements", {}), f)

        # The profile rides inside the app; the device checks it at install.
        shutil.copy(profile_path, os.path.join(app, "embedded.mobileprovision"))

        # Sign nested code first, the outer bundle last.
        for fw in sorted(glob.glob(os.path.join(app, "Frameworks",
                                                "*.framework"))):
            codesign(fw, identity)
        for root, dirs, files in os.walk(app):
            if os.path.join(app, "Frameworks") in root:
                continue  # signed above (framework inner dylib included)
            for name in sorted(files):
                if name.endswith(".dylib"):
                    codesign(os.path.join(root, name), identity)
        # The profile itself is picked up from the copied
        # embedded.mobileprovision (this codesign version has no
        # --provisioning-profile flag).
        codesign(app, identity, entitlements=ents_path)

        verify = subprocess.run(["codesign", "--verify", "--verbose=1", app],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if verify.returncode != 0:
            die("codesign --verify failed:\n"
                + verify.stdout.decode(errors="replace").strip())
        print("    signature verified")

        if os.path.exists(output):
            os.remove(output)
        app_name = os.path.basename(app)
        with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as out:
            for root, dirs, files in os.walk(work):
                dirs[:] = [d for d in dirs if d != ".DS_Store"]
                for name in sorted(files):
                    if name == ".DS_Store" or name == "entitlements.plist":
                        continue
                    full = os.path.join(root, name)
                    arc = os.path.relpath(full, work)
                    out.write(full, arc)
    finally:
        shutil.rmtree(work, ignore_errors=True)

    size = os.path.getsize(output) / 1024 / 1024
    print(f"\nOK: {output} ({size:.1f} MB)")
    print("Install with the phone connected, e.g.:")
    print("  xcrun devicectl device install app --device <device> " + output)


if __name__ == "__main__":
    main()
