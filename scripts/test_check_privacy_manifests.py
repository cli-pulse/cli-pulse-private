#!/usr/bin/env python3
"""Negative controls for scripts/check_privacy_manifests.py.

A gate only ever seen green has not been seen to work. This copies what the
check reads (the manifests, the project, the entitlements and the sources)
into a scratch directory, breaks one thing at a time, and requires the check
to fail with the message that names that break, then puts it back. The
unmodified copy must pass, and so must the changes that should not trip it
(an API named only in a comment or a string, or compiled for another platform).

Stdlib only; runs on the Linux CI runner, like the check itself.
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import plistlib
import re
import shutil
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = "CLI Pulse Bar"
IOS = f"{APP}/CLI Pulse Bar iOS/PrivacyInfo.xcprivacy"
WATCH = f"{APP}/CLI Pulse Bar Watch/PrivacyInfo.xcprivacy"
WIDGETS = f"{APP}/CLI Pulse Widgets/PrivacyInfo.xcprivacy"
MAC = f"{APP}/CLI Pulse Bar/PrivacyInfo.xcprivacy"
LOGIN = f"{APP}/CLIPulseHelper/PrivacyInfo.xcprivacy"
PBXPROJ = f"{APP}/CLI Pulse Bar.xcodeproj/project.pbxproj"
CORE = f"{APP}/CLIPulseCore/Sources/CLIPulseCore"
DUMMY = f"{CORE}/PrivacyManifestNegativeControl.swift"
ALLOW = "scripts/privacy_manifests_allowlist.json"
KEEP = {".swift", ".c", ".h", ".m", ".xcprivacy", ".entitlements", ".pbxproj", ".json", ".py"}


def copy_tree(dst: Path) -> None:
    for rel in ("scripts/check_privacy_manifests.py", "scripts/privacy_manifests.json", ALLOW, PBXPROJ):
        (dst / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / rel, dst / rel)
    for sub in ("CLI Pulse Bar", "CLI Pulse Bar iOS", "CLI Pulse Bar Watch", "CLI Pulse Widgets",
                "CLIPulseHelper", "CLIPulseCore/Sources"):
        src = ROOT / APP / sub
        for f in src.rglob("*"):
            if f.is_file() and f.suffix in KEEP:
                out = dst / f.relative_to(ROOT)
                out.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(f, out)


def edit_plist(path: Path, fn) -> None:
    data = plistlib.loads(path.read_bytes())
    fn(data)
    path.write_bytes(plistlib.dumps(data, fmt=plistlib.FMT_XML))


def api(data, cat):
    full = "NSPrivacyAccessedAPICategory" + cat
    return next(e for e in data["NSPrivacyAccessedAPITypes"] if e["NSPrivacyAccessedAPIType"] == full)


def drop_api(cat):
    full = "NSPrivacyAccessedAPICategory" + cat
    return lambda d: d.__setitem__(
        "NSPrivacyAccessedAPITypes", [e for e in d["NSPrivacyAccessedAPITypes"] if e["NSPrivacyAccessedAPIType"] != full])


def drop_reason(cat, reason):
    return lambda d: api(d, cat)["NSPrivacyAccessedAPITypeReasons"].remove(reason)


def collected(data, typ, linked=True):
    full = "NSPrivacyCollectedDataType" + typ
    return next(e for e in data["NSPrivacyCollectedDataTypes"]
                if e["NSPrivacyCollectedDataType"] == full and e["NSPrivacyCollectedDataTypeLinked"] == linked)


def dummy(body: str):
    return lambda root: (root / DUMMY).write_text("import Foundation\n\n" + body + "\n", encoding="utf-8")


# (name, files touched, mutation, expected exit, regex the output must contain
#  [, regex it must not contain])
CASES = [
    ("positive control: the tree as committed passes", [], None, 0, r"check_privacy_manifests: OK"),

    # --- the four controls the 1.63 A3 review asked for -------------------
    ("an invalid reason string", [IOS],
     lambda r: edit_plist(r / IOS, lambda d: api(d, "SystemBootTime").__setitem__("NSPrivacyAccessedAPITypeReasons", ["35F9.9"])),
     1, r"reason '35F9\.9' is not a reason Apple defines for NSPrivacyAccessedAPICategorySystemBootTime"),
    ("SystemBootTime removed from the iOS manifest", [IOS],
     lambda r: edit_plist(r / IOS, drop_api("SystemBootTime")),
     1, r"CLI Pulse iOS: CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/\S+\.swift:\d+ uses ProcessInfo\.systemUptime "
        r"\(NSPrivacyAccessedAPICategorySystemBootTime\).*which CLI Pulse Bar/CLI Pulse Bar iOS/PrivacyInfo\.xcprivacy does not declare"),
    ("1C8F.1 dropped where the target uses the app group (Widgets)", [WIDGETS],
     lambda r: edit_plist(r / WIDGETS, drop_reason("UserDefaults", "1C8F.1")),
     1, r"CLI Pulse Widgets: uses app-group UserDefaults \(CLI Pulse Bar/CLI Pulse Widgets/WidgetDataProvider\.swift:\d+\) "
        r"and is entitled to group\.yyh\.CLI-Pulse, but .* does not declare reason 1C8F\.1"),
    ("a new source file calls an undeclared API (statfs)", [DUMMY],
     dummy('func freeBytes(_ p: String) -> Int64 {\n    var s = statfs()\n    _ = statfs(p, &s)\n'
           '    return Int64(s.f_bavail) * Int64(s.f_bsize)\n}'),
     1, r"CLI Pulse iOS: CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/PrivacyManifestNegativeControl\.swift:5 uses "
        r"statfs / statvfs / fstatfs / fstatvfs \(NSPrivacyAccessedAPICategoryDiskSpace\)"),

    # --- the project ------------------------------------------------------
    ("the manifest removed from a target's Resources phase (LoginItem)", [PBXPROJ],
     lambda r: (r / PBXPROJ).write_text(
         re.sub(r"\n\t+E2A669E4AF3FEA8CD1B23CB2 /\* PrivacyInfo\.xcprivacy in Resources \*/,", "",
                (r / PBXPROJ).read_text(encoding="utf-8")), encoding="utf-8"),
     1, r"CLIPulseHelper: CLI Pulse Bar/CLIPulseHelper/PrivacyInfo\.xcprivacy is not in the target's Resources build phase"),
    ("a manifest file that is missing", [MAC],
     lambda r: (r / MAC).unlink(),
     1, r"CLI Pulse Bar/CLI Pulse Bar/PrivacyInfo\.xcprivacy: cannot read"),

    # --- the drift scanner's reading of the code ---------------------------
    ("statfs only inside #if os(macOS): iOS passes, the Mac app fails", [DUMMY],
     dummy('#if os(macOS)\nfunc freeBytes(_ p: String) {\n    var s = statfs()\n    _ = statfs(p, &s)\n}\n#endif'),
     1, r"CLI Pulse Bar: CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/PrivacyManifestNegativeControl\.swift:6 uses statfs",
     r"CLI Pulse (iOS|Watch|Widgets): .*NegativeControl"),
    ("statfs in an #else of #if os(iOS): the iOS targets pass, the Mac fails", [DUMMY],
     dummy('#if os(iOS)\nlet x = 1\n#else\nfunc f(_ p: String) { var s = statfs(); _ = statfs(p, &s) }\n#endif'),
     1, r"CLIPulseHelper: CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/PrivacyManifestNegativeControl\.swift:6 uses statfs",
     r"CLI Pulse (iOS|Widgets): .*NegativeControl"),
    ("statfs named only in a comment and a string passes", [DUMMY],
     dummy('// statfs(path, &buf) would need DiskSpace\n/* volumeAvailableCapacityKey */\n'
           'let note = "statfs(p, &s) and activeInputModes"'),
     0, r"check_privacy_manifests: OK"),
    ("an API declared with no use anywhere fails (DiskSpace in Widgets)", [WIDGETS],
     lambda r: edit_plist(r / WIDGETS, lambda d: d["NSPrivacyAccessedAPITypes"].append(
         {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryDiskSpace", "NSPrivacyAccessedAPITypeReasons": ["E174.1"]})),
     1, r"CLI Pulse Widgets: .* declares NSPrivacyAccessedAPICategoryDiskSpace, but neither the sources"),
    ("1C8F.1 declared by the Watch app, which has no app group", [WATCH],
     lambda r: edit_plist(r / WATCH, lambda d: api(d, "UserDefaults")["NSPrivacyAccessedAPITypeReasons"].append("1C8F.1")),
     1, r"CLI Pulse Watch: .* declares 1C8F\.1 \(app group\) but .*CLI_Pulse_Watch\.entitlements grants no app group"),
    ("a stale allowlist entry fails", [ALLOW],
     lambda r: (r / ALLOW).write_text(json.dumps({"entries": [
         {"target": "CLI Pulse iOS", "category": "NSPrivacyAccessedAPICategoryDiskSpace",
          "file": DUMMY, "pattern": "statfs", "reason": "test"}]}), encoding="utf-8"),
     1, r"privacy_manifests_allowlist\.json: entry 0 \(CLI Pulse iOS, .*\) matches nothing; remove it"),

    # --- manifest semantics -----------------------------------------------
    ("a byte order mark", [IOS],
     lambda r: (r / IOS).write_bytes(b"\xef\xbb\xbf" + (r / IOS).read_bytes()),
     1, r"PrivacyInfo\.xcprivacy: starts with a UTF-8 byte order mark"),
    ("a manifest that does not parse", [LOGIN],
     lambda r: (r / LOGIN).write_bytes((r / LOGIN).read_bytes().replace(b"</dict>\n</plist>", b"</plist>")),
     1, r"CLIPulseHelper/PrivacyInfo\.xcprivacy: does not parse as a property list"),
    ("an unknown top-level key", [MAC],
     lambda r: edit_plist(r / MAC, lambda d: d.__setitem__("NSPrivacyTrackingDomain", [])),
     1, r"unknown top-level key 'NSPrivacyTrackingDomain'"),
    ("NSPrivacyTracking that is not a boolean", [WATCH],
     lambda r: edit_plist(r / WATCH, lambda d: d.__setitem__("NSPrivacyTracking", "NO")),
     1, r"NSPrivacyTracking is a str, not a bool"),
    ("a tracking domain", [IOS],
     lambda r: edit_plist(r / IOS, lambda d: d.__setitem__("NSPrivacyTrackingDomains", ["example.com"])),
     1, r"NSPrivacyTrackingDomains lists \['example\.com'\]; with tracking off it must be empty"),
    ("an unknown category", [IOS],
     lambda r: edit_plist(r / IOS, lambda d: api(d, "FileTimestamp").__setitem__(
         "NSPrivacyAccessedAPIType", "NSPrivacyAccessedAPICategoryFileTimestamps")),
     1, r"unknown category 'NSPrivacyAccessedAPICategoryFileTimestamps'"),
    ("a reason from another category (CA92.1 under SystemBootTime)", [WATCH],
     lambda r: edit_plist(r / WATCH, lambda d: api(d, "SystemBootTime")["NSPrivacyAccessedAPITypeReasons"].append("CA92.1")),
     1, r"reason 'CA92\.1' is not a reason Apple defines for NSPrivacyAccessedAPICategorySystemBootTime"),
    ("a category declared twice", [MAC],
     lambda r: edit_plist(r / MAC, lambda d: d["NSPrivacyAccessedAPITypes"].append(dict(api(d, "UserDefaults")))),
     1, r"NSPrivacyAccessedAPICategoryUserDefaults is declared twice"),
    ("a reason listed twice", [MAC],
     lambda r: edit_plist(r / MAC, lambda d: api(d, "FileTimestamp")["NSPrivacyAccessedAPITypeReasons"].append("C617.1")),
     1, r"reason C617\.1 is listed twice for NSPrivacyAccessedAPICategoryFileTimestamp"),
    ("an unknown collected data type", [MAC],
     lambda r: edit_plist(r / MAC, lambda d: collected(d, "OtherDataTypes").__setitem__(
         "NSPrivacyCollectedDataType", "NSPrivacyCollectedDataTypeOtherData")),
     1, r"unknown data type 'NSPrivacyCollectedDataTypeOtherData'"),

    # --- the published label ----------------------------------------------
    ("a Linked flag flipped (Crash Data on the Mac)", [MAC],
     lambda r: edit_plist(r / MAC, lambda d: collected(d, "CrashData").__setitem__("NSPrivacyCollectedDataTypeLinked", False)),
     1, r"NSPrivacyCollectedDataTypeCrashData linked=False tracking=False .* is not a row of the published label"),
    ("a purpose the label does not have (Email for advertising)", [IOS],
     lambda r: edit_plist(r / IOS, lambda d: collected(d, "EmailAddress")["NSPrivacyCollectedDataTypePurposes"].append(
         "NSPrivacyCollectedDataTypePurposeDeveloperAdvertising")),
     1, r"NSPrivacyCollectedDataTypeEmailAddress .* is not a row of the published label"),
    ("a label row no target declares (Name, only the iPhone sends it)", [IOS],
     lambda r: edit_plist(r / IOS, lambda d: d.__setitem__("NSPrivacyCollectedDataTypes", [
         e for e in d["NSPrivacyCollectedDataTypes"] if e["NSPrivacyCollectedDataType"] != "NSPrivacyCollectedDataTypeName"])),
     1, r"label row NSPrivacyCollectedDataTypeName linked=True .* is declared by no target's manifest"),
]


def main() -> int:
    failures = 0
    with tempfile.TemporaryDirectory(prefix="privacy-manifests-") as tmp:
        root = Path(tmp)
        copy_tree(root)
        spec = importlib.util.spec_from_file_location("check_privacy_manifests", root / "scripts/check_privacy_manifests.py")
        check = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(check)
        for name, touched, mutate, want_rc, want, *absent in CASES:
            saved = {t: (root / t).read_bytes() if (root / t).exists() else None for t in touched}
            try:
                if mutate:
                    mutate(root)
                # In-process: the check keeps what it read of files that did not
                # change, so 26 runs cost little more than one.
                buf = io.StringIO()
                with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
                    rc = check.main(["--root", str(root)])
                out = buf.getvalue()
                ok = rc == want_rc and re.search(want, out) is not None
                if ok and absent:
                    ok = re.search(absent[0], out) is None
                print(f"{'PASS' if ok else 'FAIL'}: {name}")
                if not ok:
                    failures += 1
                    extra = f" and not /{absent[0]}/" if absent else ""
                    print(f"    expected exit {want_rc} and /{want}/{extra}; got exit {rc}:")
                    print("    " + "\n    ".join(out.splitlines()[-25:]))
            finally:
                for t, data in saved.items():
                    if data is None:
                        (root / t).unlink(missing_ok=True)
                    else:
                        (root / t).write_bytes(data)
    print(f"test_check_privacy_manifests: {len(CASES) - failures}/{len(CASES)} cases behaved")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
