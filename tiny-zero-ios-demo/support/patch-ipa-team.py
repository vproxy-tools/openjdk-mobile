#!/usr/bin/env python3
"""Patch BGTaskSchedulerPermittedIdentifiers in an ipa for iLoader installs.

iLoader-style sideload tools rewrite the bundle identifier to
<bundle>.<TEAMID> when signing but leave BGTaskSchedulerPermittedIdentifiers
untouched (their bug), and the whitelist matches entries EXACTLY, so such
installs cannot submit the runtime-derived task identifier. This script
adds the team-suffixed identifier(s) next to the originals (append-only:
the patched ipa keeps working for installs that preserve the bundle id).

Standalone (stdlib only): ship it together with the unsigned ipa; the
recipient runs it with their own team id, then signs with iLoader as usual.

Usage:
  python3 patch-ipa-team.py <input.ipa> <TEAMID> [-o output.ipa]
"""

import argparse
import plistlib
import shutil
import sys
import zipfile
from pathlib import Path

KEY = "BGTaskSchedulerPermittedIdentifiers"


def find_main_info_plist(zf: zipfile.ZipFile) -> str:
    candidates = []
    for name in zf.namelist():
        parts = name.split("/")
        # Payload/Foo.app/Info.plist
        if (len(parts) == 3 and parts[0] == "Payload"
                and parts[1].endswith(".app") and parts[2] == "Info.plist"):
            candidates.append(name)
    if not candidates:
        raise RuntimeError("Cannot find main app Info.plist in IPA")
    if len(candidates) > 1:
        raise RuntimeError("Multiple main app candidates found: " + ", ".join(candidates))
    return candidates[0]


def patch_plist(data: bytes, team_id: str):
    plist = plistlib.loads(data)
    bundle_id = plist.get("CFBundleIdentifier")
    if not isinstance(bundle_id, str) or not bundle_id:
        raise RuntimeError("CFBundleIdentifier not found in Info.plist")
    identifiers = plist.get(KEY)
    if not isinstance(identifiers, list):
        raise RuntimeError(f"{KEY} not found or is not an array")

    # Append the team-suffixed twin of every bundle-id-derived identifier,
    # keeping the originals so the patched ipa still works for installs
    # that preserve the bundle id. Entries already carrying this team
    # suffix are skipped, making repeated runs idempotent.
    team_prefix = f"{bundle_id}.{team_id}"
    added = []
    for identifier in list(identifiers):
        if not isinstance(identifier, str):
            continue
        if identifier == bundle_id:
            candidate = team_prefix
        elif identifier.startswith(team_prefix):
            continue  # already team-suffixed for this team
        elif identifier.startswith(bundle_id + "."):
            candidate = f"{team_prefix}{identifier[len(bundle_id):]}"
        else:
            continue  # unrelated identifier, leave alone
        if candidate not in identifiers:
            identifiers.append(candidate)
            added.append((identifier, candidate))

    plist[KEY] = identifiers
    # Preserve binary/XML plist format.
    fmt = plistlib.FMT_BINARY if data.startswith(b"bplist00") else plistlib.FMT_XML
    return plistlib.dumps(plist, fmt=fmt, sort_keys=False), bundle_id, added


def patch_ipa(input_ipa: Path, output_ipa: Path, team_id: str):
    temp_output = output_ipa.with_suffix(output_ipa.suffix + ".tmp")
    if temp_output.exists():
        temp_output.unlink()
    with zipfile.ZipFile(input_ipa, "r") as zin:
        info_plist_path = find_main_info_plist(zin)
        patched, bundle_id, added = patch_plist(zin.read(info_plist_path), team_id)
        with zipfile.ZipFile(temp_output, "w") as zout:
            for item in zin.infolist():
                data = patched if item.filename == info_plist_path else zin.read(item.filename)
                # Reuse the original ZipInfo so permissions/timestamps/compression
                # are retained.
                zout.writestr(item, data)
    shutil.move(temp_output, output_ipa)

    print(f"Input IPA:      {input_ipa}")
    print(f"Output IPA:     {output_ipa}")
    print(f"bundle id:      {bundle_id}")
    print(f"iLoader rewrite: {bundle_id}.{team_id}")
    print(f"{KEY}:")
    if not added:
        print("  (nothing to add - entries already present)")
    for old, new in added:
        print(f"  {old}")
        print(f"    + {new}")


def main():
    parser = argparse.ArgumentParser(
        description="Add team-suffixed BGTaskSchedulerPermittedIdentifiers to an "
                    "ipa for the bundle id iLoader/isideload will generate.")
    parser.add_argument("ipa", type=Path, help="Input IPA file")
    parser.add_argument("team_id", help="Apple Team ID, e.g. ABCDE12345")
    parser.add_argument("-o", "--output", type=Path, help="Output IPA path")
    args = parser.parse_args()

    team_id = args.team_id.strip()
    if not team_id:
        print("Team ID cannot be empty", file=sys.stderr)
        sys.exit(1)
    if not args.ipa.is_file():
        print(f"IPA not found: {args.ipa}", file=sys.stderr)
        sys.exit(1)
    output_ipa = args.output or args.ipa.with_name(f"{args.ipa.stem}-{team_id}{args.ipa.suffix}")

    try:
        patch_ipa(args.ipa, output_ipa, team_id)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
