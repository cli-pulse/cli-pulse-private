#!/usr/bin/env python3
r"""
Writes `CLI Pulse Bar/ThirdPartyNotices.txt`, the license texts of the
third-party software the Apple apps ship (59-08, 1.59).

The file is a resource of the Mac app and of the iPhone/iPad app (their
"Resources" build phases in the pbxproj), so each bundle carries the notices
its licenses ask to be passed on. It is not translated: license texts are
reproduced as their authors wrote them.

WHAT GOES IN, AND FROM WHERE
  1. Every package pinned in `CLI Pulse Bar/CLIPulseCore/Package.resolved`
     (today: sentry-cocoa). Its LICENSE file, and the third-party notices file
     it ships for code it includes itself (Sentry's THIRD_PARTY_NOTICES.md:
     KSCrash, fishhook, Apple's APSL code ...), are read from a resolved
     SwiftPM checkout: `--checkouts DIR`, the `checkouts` folder of a
     `swift package resolve` scratch path or of Xcode's SourcePackages.
     The Xcode workspace's own Package.resolved is not read: it still pins a
     remote `sweetcookiekit` that is not a dependency (its source is vendored,
     item 2), and changing that file is not this script's business.
  2. Every folder under `CLIPulseCore/Sources/CLIPulseCore/Vendor/` (vendored
     source). Each must hold a LICENSE file; a folder without one fails.
  3. Every LICENSE* file under `CLIPulseCore/Sources/CLIPulseCore/Resources/`
     (bundled web assets: xterm.js and its add-ons for the terminal view).
  4. CodexBar's MIT license, `scripts/third_party_licenses/CodexBar-LICENSE.txt`
     (upstream's LICENSE, copied from github.com/steipete/CodexBar). Parts of
     the provider code are adapted from CodexBar, and each such file keeps
     upstream's notice in its header (scripts/check_copyright.sh counts them).

A pin, Vendor folder or resource license this script has no description for
still goes in, under its own name: the file never silently leaves something
out. Versions are not written: the license texts do not change with them, and
the app build and `swift test` resolve different patch versions of Sentry.

WHEN TO RUN IT
  No CI gate (by decision, 59-08). The release checklist says: when a
  dependency, a Vendor folder or a bundled web asset changed, run this and
  commit the result. `--check` compares instead of writing (exit 1 when the
  committed file is out of date).

USAGE
  python3 scripts/generate_third_party_notices.py --checkouts <SourcePackages>/checkouts
  python3 scripts/generate_third_party_notices.py --checkouts <dir> --check
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
APP = REPO / "CLI Pulse Bar"
CORE = APP / "CLIPulseCore"
RESOLVED = CORE / "Package.resolved"
VENDOR = CORE / "Sources" / "CLIPulseCore" / "Vendor"
RESOURCES = CORE / "Sources" / "CLIPulseCore" / "Resources"
CODEXBAR_LICENSE = REPO / "scripts" / "third_party_licenses" / "CodexBar-LICENSE.txt"
OUTPUT = APP / "ThirdPartyNotices.txt"

# Names, homepages and what each component is for. Keyed by package identity,
# Vendor folder name, or resource path relative to RESOURCES.
PACKAGES = {
    "sentry-cocoa": (
        "Sentry Cocoa SDK",
        "crash, hang and error reports (see PRIVACY.md).",
    ),
}
VENDORED = {
    "SweetCookieKit": (
        "SweetCookieKit",
        "https://github.com/steipete/SweetCookieKit",
        "reading browser cookies for providers that sign in through a "
        "browser (Mac only). Its source is included in CLI Pulse.",
    ),
}
BUNDLED = {
    "Terminal/LICENSE.xterm": (
        "xterm.js, with its fit and web-links add-ons",
        "https://github.com/xtermjs/xterm.js",
        "drawing terminal output in the app's terminal views.",
    ),
}
LICENSE_NAMES = ("LICENSE", "LICENSE.md", "LICENSE.txt", "COPYING")
NOTICE_NAMES = ("THIRD_PARTY_NOTICES.md", "THIRD_PARTY_NOTICES.txt", "NOTICE", "NOTICE.md", "NOTICE.txt")

RULE = "=" * 78


class NoticeError(Exception):
    pass


def read_text(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    # One trailing newline, Unix line ends, no trailing spaces on a line.
    lines = [line.rstrip() for line in text.replace("\r\n", "\n").split("\n")]
    return "\n".join(lines).strip("\n") + "\n"


def first_existing(folder: Path, names: tuple[str, ...]) -> Path | None:
    for name in names:
        candidate = folder / name
        if candidate.is_file():
            return candidate
    return None


def pinned_packages() -> list[dict]:
    data = json.loads(RESOLVED.read_text(encoding="utf-8"))
    pins = data.get("pins") or data.get("object", {}).get("pins") or []
    out = []
    for pin in pins:
        identity = pin.get("identity") or pin.get("package", "").lower()
        location = pin.get("location") or pin.get("repositoryURL") or ""
        if not identity:
            raise NoticeError(f"{RESOLVED.relative_to(REPO)}: a pin without an identity")
        out.append({"identity": identity, "location": location})
    return sorted(out, key=lambda p: p["identity"])


def checkout_folder(checkouts: Path, identity: str, location: str) -> Path:
    # SwiftPM names the checkout after the repository; it is the identity for
    # every pin here, but fall back to the URL's last component.
    candidates = [checkouts / identity]
    if location:
        name = location.rstrip("/").split("/")[-1]
        if name.endswith(".git"):
            name = name[:-4]
        candidates.append(checkouts / name)
    for candidate in candidates:
        if candidate.is_dir():
            return candidate
    raise NoticeError(
        f"no checkout of '{identity}' under {checkouts}. Resolve the package first "
        "(swift package resolve, or an Xcode build) and pass its checkouts folder.")


def section(number: int, title: str, lines: list[str], bodies: list[tuple[str, str]]) -> str:
    out = [RULE, f"{number}. {title}", RULE, ""]
    out += lines
    for heading, body in bodies:
        out += ["", f"--- {heading} ---", "", body.rstrip("\n")]
    return "\n".join(out) + "\n"


def build(checkouts: Path) -> str:
    entries: list[tuple[str, list[str], list[tuple[str, str]]]] = []

    for pin in pinned_packages():
        identity, location = pin["identity"], pin["location"]
        folder = checkout_folder(checkouts, identity, location)
        license_file = first_existing(folder, LICENSE_NAMES)
        if license_file is None:
            raise NoticeError(f"the checkout of '{identity}' ({folder}) has no license file")
        name, use = PACKAGES.get(identity, (identity, ""))
        lines = [f"Source: {location}" if location else f"Package: {identity}"]
        if use:
            lines.append(f"Used for: {use}")
        bodies = [(f"License ({license_file.name})", read_text(license_file))]
        notices = first_existing(folder, NOTICE_NAMES)
        if notices is not None:
            bodies.append((f"Notices for the software it includes ({notices.name})", read_text(notices)))
        entries.append((name, lines, bodies))

    if VENDOR.is_dir():
        for folder in sorted(p for p in VENDOR.iterdir() if p.is_dir()):
            license_file = first_existing(folder, LICENSE_NAMES)
            if license_file is None:
                raise NoticeError(f"{folder.relative_to(REPO)} has no LICENSE file")
            name, url, use = VENDORED.get(folder.name, (folder.name, "", ""))
            lines = [f"Source: {url}" if url else f"Vendored source: {folder.relative_to(APP)}"]
            if use:
                lines.append(f"Used for: {use}")
            entries.append((name, lines, [("License", read_text(license_file))]))

    if RESOURCES.is_dir():
        for license_file in sorted(RESOURCES.rglob("LICENSE*")):
            if not license_file.is_file():
                continue
            key = license_file.relative_to(RESOURCES).as_posix()
            name, url, use = BUNDLED.get(key, (key, "", ""))
            lines = [f"Source: {url}" if url else f"Bundled file: {key}"]
            if use:
                lines.append(f"Used for: {use}")
            entries.append((name, lines, [("License", read_text(license_file))]))

    if not CODEXBAR_LICENSE.is_file():
        raise NoticeError(f"{CODEXBAR_LICENSE.relative_to(REPO)} is missing")
    entries.append((
        "CodexBar",
        ["Source: https://github.com/steipete/CodexBar",
         "Used for: parts of the provider code, adapted from CodexBar. Each "
         "adapted file keeps this notice in its header."],
        [("License", read_text(CODEXBAR_LICENSE))],
    ))

    head = [
        "CLI Pulse: third-party notices",
        "",
        "CLI Pulse includes the third-party software listed below. Each is used",
        "under its own license, reproduced here in full.",
        "",
        "This file is generated by scripts/generate_third_party_notices.py.",
        "Do not edit it by hand.",
        "",
        "Contents",
    ]
    head += [f"  {i}. {name}" for i, (name, _, _) in enumerate(entries, start=1)]
    parts = ["\n".join(head) + "\n"]
    parts += [section(i, name, lines, bodies) for i, (name, lines, bodies) in enumerate(entries, start=1)]
    return "\n".join(parts)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0].strip())
    parser.add_argument("--checkouts", type=Path, default=CORE / ".build" / "checkouts",
                        help="a resolved SwiftPM checkouts folder (default: CLIPulseCore/.build/checkouts)")
    parser.add_argument("--check", action="store_true",
                        help="compare with the committed file instead of writing it")
    parser.add_argument("--output", type=Path, default=OUTPUT, help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    try:
        text = build(args.checkouts)
    except NoticeError as error:
        print(f"✗ {error}", file=sys.stderr)
        return 2
    if args.check:
        current = args.output.read_text(encoding="utf-8") if args.output.is_file() else None
        if current != text:
            print(f"✗ {args.output} is out of date: run scripts/generate_third_party_notices.py "
                  "and commit the result", file=sys.stderr)
            return 1
        print(f"✓ {args.output.name} is up to date")
        return 0
    args.output.write_text(text, encoding="utf-8")
    print(f"✓ wrote {args.output} ({len(text.splitlines())} lines)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
