#!/usr/bin/env python3
"""Negative controls for scripts/check_privacy_manifests.py.

A gate only ever seen green has not been seen to work. This copies what the
check reads (the manifests, the project, the package, the entitlements, the
sources and its own records) into a scratch directory, breaks one thing at a
time, and requires the check to fail with the message that names that break,
then puts it back. The unmodified copy must pass, and so must the changes that
should not trip it (an API named only in a comment or a string, or compiled
for another platform).

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
RESOLVED = f"{APP}/CLI Pulse Bar.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
PACKAGE = f"{APP}/CLIPulseCore/Package.swift"
CORE = f"{APP}/CLIPulseCore/Sources/CLIPulseCore"
DUMMY = f"{CORE}/PrivacyManifestNegativeControl.swift"
DUMMY2 = f"{CORE}/PrivacyManifestNegativeControl2.swift"
LOCALE = f"{CORE}/LocaleOverrideStore.swift"
RUNTIME_ENV = f"{CORE}/CLIPulseRuntimeEnvironment.swift"
WIDGET_PROVIDER = f"{APP}/CLI Pulse Widgets/WidgetDataProvider.swift"
CONFIG = "scripts/privacy_manifests.json"
ALLOW = "scripts/privacy_manifests_allowlist.json"
KEEP = {".swift", ".c", ".h", ".m", ".xcprivacy", ".entitlements", ".pbxproj", ".json", ".py", ".resolved"}
STATFS = 'func freeBytes(_ p: String) -> Int64 {\n    var s = statfs()\n    _ = statfs(p, &s)\n    return Int64(s.f_bavail)\n}'


def copy_tree(dst: Path) -> None:
    for rel in ("scripts/check_privacy_manifests.py", CONFIG, ALLOW, PBXPROJ, RESOLVED, PACKAGE):
        (dst / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / rel, dst / rel)
    for sub in ("CLI Pulse Bar", "CLI Pulse Bar iOS", "CLI Pulse Bar Watch", "CLI Pulse Widgets",
                "CLIPulseHelper", "CLIPulseCore/Sources"):
        for f in (ROOT / APP / sub).rglob("*"):
            if f.is_file() and f.suffix in KEEP:
                out = dst / f.relative_to(ROOT)
                out.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(f, out)


# --- mutation helpers -------------------------------------------------------
def edit_plist(rel, fn):
    def mutate(root):
        data = plistlib.loads((root / rel).read_bytes())
        fn(data)
        (root / rel).write_bytes(plistlib.dumps(data, fmt=plistlib.FMT_XML))
    return mutate


def edit_text(rel, old, new, count=1):
    def mutate(root):
        text = (root / rel).read_text(encoding="utf-8")
        assert text.count(old) >= 1, f"{rel}: {old[:60]!r} not found"
        (root / rel).write_text(text.replace(old, new) if count is None else text.replace(old, new, count), encoding="utf-8")
    return mutate


def edit_config(fn):
    def mutate(root):
        cfg = json.loads((root / CONFIG).read_text(encoding="utf-8"))
        fn(cfg)
        (root / CONFIG).write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    return mutate


def both(*mutations):
    def mutate(root):
        for m in mutations:
            m(root)
    return mutate


def dummy(body: str):
    return lambda root: (root / DUMMY).write_text("import Foundation\n\n" + body + "\n", encoding="utf-8")


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


def drop_collected(typ):
    full = "NSPrivacyCollectedDataType" + typ
    return lambda d: d.__setitem__("NSPrivacyCollectedDataTypes", [
        e for e in d["NSPrivacyCollectedDataTypes"] if e["NSPrivacyCollectedDataType"] != full])


def target_cfg(cfg, name):
    return next(t for t in cfg["targets"] if t["name"] == name)


def in_config(config_id: str, line: str, anchor: str = "buildSettings = {\n", indent: str = "\t\t\t\t"):
    """Adds a line to one XCBuildConfiguration (by id): a build setting by
    default, or an attribute of the configuration itself with
    anchor="isa = XCBuildConfiguration;\n"."""
    def mutate(root):
        text = (root / PBXPROJ).read_text(encoding="utf-8")
        at = text.index(f"\t\t{config_id} /* ")
        at = text.index(anchor, at) + len(anchor)
        (root / PBXPROJ).write_text(text[:at] + indent + line + "\n" + text[at:], encoding="utf-8")
    return mutate


def add_objects(objects: str):
    return edit_text(PBXPROJ, "/* End PBXNativeTarget section */", objects + "/* End PBXNativeTarget section */")


NEW_EXTENSION = '''		NC0001 /* NC Share Extension */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = G40003;
			buildPhases = (
				NC0002 /* Sources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = "NC Share Extension";
			productName = "NC Share Extension";
			productType = "com.apple.product-type.app-extension";
		};
		NC0002 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				NC0003 /* Probe.swift in Sources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
		NC0003 /* Probe.swift in Sources */ = {isa = PBXBuildFile; fileRef = NC0004 /* Probe.swift */; };
		NC0004 /* Probe.swift */ = {isa = PBXFileReference; path = "NC Share Extension/Probe.swift"; sourceTree = SOURCE_ROOT; };
'''

# (name, files touched, mutation, expected exit, regex the output must contain [, regex it must not contain])
CASES = [
    ("positive control: the tree as committed passes", [], None, 0, r"check_privacy_manifests: OK"),

    # --- round 1: the four controls the plan asked for --------------------
    ("an invalid reason string", [IOS],
     edit_plist(IOS, lambda d: api(d, "SystemBootTime").__setitem__("NSPrivacyAccessedAPITypeReasons", ["35F9.9"])),
     1, r"reason '35F9\.9' is not a reason Apple defines for NSPrivacyAccessedAPICategorySystemBootTime"),
    ("SystemBootTime removed from the iOS manifest", [IOS],
     edit_plist(IOS, drop_api("SystemBootTime")),
     1, r"CLI Pulse iOS: CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/\S+\.swift:\d+ uses ProcessInfo\.systemUptime "
        r"\(NSPrivacyAccessedAPICategorySystemBootTime\).*which CLI Pulse Bar/CLI Pulse Bar iOS/PrivacyInfo\.xcprivacy does not declare"),
    ("1C8F.1 dropped where the target uses the app group (Widgets)", [WIDGETS],
     edit_plist(WIDGETS, drop_reason("UserDefaults", "1C8F.1")),
     1, r"CLI Pulse Widgets: uses app-group UserDefaults \(CLI Pulse Bar/CLI Pulse Widgets/WidgetDataProvider\.swift:\d+\) "
        r"and is entitled to group\.yyh\.CLI-Pulse, but .* does not declare reason 1C8F\.1"),
    ("a new source file calls an undeclared API (statfs)", [DUMMY], dummy(STATFS),
     1, r"CLI Pulse iOS: CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/PrivacyManifestNegativeControl\.swift:5 uses "
        r"statfs / statvfs / fstatfs / fstatvfs \(NSPrivacyAccessedAPICategoryDiskSpace\)"),

    # --- round 2, MUST 1: defaults the system writes ------------------------
    ("LocaleOverrideStore's old AppleLanguages read comes back", [LOCALE],
     edit_text(LOCALE, "systemPreferredLanguages ?? { Locale.preferredLanguages }",
               "systemPreferredLanguages ?? {\n            defaults.stringArray(forKey: Self.appleLanguagesKey) ?? Locale.preferredLanguages\n        }"),
     1, r"CLI Pulse Bar: CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/LocaleOverrideStore\.swift:\d+ reads a key the "
        r"system writes \(appleLanguagesKey\) through UserDefaults; no UserDefaults reason covers"),
    ("a literal system key read (AppleLanguages)", [DUMMY],
     dummy('let langs = UserDefaults.standard\n    .stringArray(forKey: "AppleLanguages")'),
     1, r"CLI Pulse iOS: .*/PrivacyManifestNegativeControl\.swift:4 reads a key the system writes through UserDefaults"),
    ("dictionaryRepresentation() reads every domain", [DUMMY],
     dummy("let keys = UserDefaults.standard.dictionaryRepresentation().keys"),
     1, r"CLI Pulse Watch: .*/PrivacyManifestNegativeControl\.swift:3 reads dictionaryRepresentation\(\) \(every domain"),

    # --- MUST 2: collected data per target ----------------------------------
    ("Crash Data deleted from the Watch manifest", [WATCH],
     edit_plist(WATCH, drop_collected("CrashData")),
     1, r"CLI Pulse Watch: CLI Pulse Bar/CLI Pulse Bar Watch/PrivacyInfo\.xcprivacy is missing the reviewed row "
        r"CrashData linked=True tracking=False purposes=\['AppFunctionality'\]"),
    ("iOS's Name row copied into the widgets", [WIDGETS],
     lambda r: edit_plist(WIDGETS, lambda d: d["NSPrivacyCollectedDataTypes"].append(
         collected(plistlib.loads((r / IOS).read_bytes()), "Name")))(r),
     1, r"CLI Pulse Widgets: \S.* collects Name linked=True tracking=False purposes=\['AppFunctionality'\], which is not "
        r"in its reviewed record \(the record has no such type for this target\)"),
    ("a Linked flag flipped (Crash Data on the Mac)", [MAC],
     edit_plist(MAC, lambda d: collected(d, "CrashData").__setitem__("NSPrivacyCollectedDataTypeLinked", False)),
     1, r"CLI Pulse Bar: \S.* collects CrashData linked=False .* not in its reviewed record \(the record has CrashData linked=True"),
    ("a purpose added (Email for advertising)", [IOS],
     edit_plist(IOS, lambda d: collected(d, "EmailAddress")["NSPrivacyCollectedDataTypePurposes"].append(
         "NSPrivacyCollectedDataTypePurposeDeveloperAdvertising")),
     1, r"CLI Pulse iOS: \S.* collects EmailAddress linked=True tracking=False purposes=\[.*DeveloperAdvertising.*\], which is not in its reviewed record"),
    ("a recorded row the label does not have", [CONFIG],
     edit_config(lambda c: target_cfg(c, "CLI Pulse iOS")["collected"][0].__setitem__(
         "purposes", ["NSPrivacyCollectedDataTypePurposeAppFunctionality", "NSPrivacyCollectedDataTypePurposeAnalytics"])),
     1, r"privacy_manifests\.json: CLI Pulse iOS records Name linked=True .* which is not a row of the published label"),
    ("a label row no target records (Name, only the iPhone sends it)", [IOS, CONFIG],
     both(edit_plist(IOS, drop_collected("Name")),
          edit_config(lambda c: target_cfg(c, "CLI Pulse iOS").__setitem__("collected", [
              r for r in target_cfg(c, "CLI Pulse iOS")["collected"] if r["type"] != "NSPrivacyCollectedDataTypeName"]))),
     1, r"label row Name linked=True tracking=False purposes=\['AppFunctionality'\] is recorded for no target"),

    # --- MUST 3: reasons per target -----------------------------------------
    ("3B52.1 removed from the Mac manifest", [MAC],
     edit_plist(MAC, drop_reason("FileTimestamp", "3B52.1")),
     1, r"CLI Pulse Bar: \S.* declares FileTimestamp reasons \['C617\.1'\], but the reviewed record .* is \['3B52\.1', 'C617\.1'\]"),
    ("35F9.1 swapped for another valid SystemBootTime reason (iOS)", [IOS],
     edit_plist(IOS, lambda d: api(d, "SystemBootTime").__setitem__("NSPrivacyAccessedAPITypeReasons", ["8FFB.1"])),
     1, r"CLI Pulse iOS: \S.* declares SystemBootTime reasons \['8FFB\.1'\], but the reviewed record .* is \['35F9\.1'\]"),
    ("a reason's cited call site disappears", [RUNTIME_ENV],
     edit_text(RUNTIME_ENV, "Darwin.lstat($0, &metadata)", "Darwin.stat($0, &metadata)", count=None),
     1, r"CLI Pulse Watch: FileTimestamp C617\.1 cites CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/"
        r"CLIPulseRuntimeEnvironment\.swift /Darwin\\\.lstat/, which no longer matches"),
    ("a category recorded with no use anywhere (DiskSpace in the widgets)", [WIDGETS, CONFIG],
     both(edit_plist(WIDGETS, lambda d: d["NSPrivacyAccessedAPITypes"].append(
              {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryDiskSpace", "NSPrivacyAccessedAPITypeReasons": ["E174.1"]})),
          edit_config(lambda c: target_cfg(c, "CLI Pulse Widgets")["reasons"].__setitem__(
              "NSPrivacyAccessedAPICategoryDiskSpace", {"E174.1": {"why": "test", "evidence": []}}))),
     1, r"CLI Pulse Widgets: the record declares NSPrivacyAccessedAPICategoryDiskSpace, but neither the sources"),
    ("1C8F.1 on the Watch app, which has no app group", [WATCH, CONFIG],
     both(edit_plist(WATCH, lambda d: api(d, "UserDefaults")["NSPrivacyAccessedAPITypeReasons"].append("1C8F.1")),
          edit_config(lambda c: target_cfg(c, "CLI Pulse Watch")["reasons"]["NSPrivacyAccessedAPICategoryUserDefaults"]
                      .__setitem__("1C8F.1", {"why": "test", "evidence": []}))),
     1, r"CLI Pulse Watch: .* declares 1C8F\.1 \(app group\) but .*CLI_Pulse_Watch\.entitlements grants no app group"),

    # --- MUST 4: #if handling -----------------------------------------------
    ("`#if false` inside a block comment does not hide the call", [DUMMY],
     dummy("/*\n#if false\n*/\n" + STATFS),
     1, r"CLI Pulse iOS: .*/PrivacyManifestNegativeControl\.swift:8 uses statfs"),
    ("`#if os(tvOS)` inside block comments does not hide the call", [DUMMY],
     dummy("/*\n#if os(tvOS)\n*/\n" + STATFS + "\n/*\n#endif\n*/"),
     1, r"CLI Pulse Bar: .*/PrivacyManifestNegativeControl\.swift:8 uses statfs"),
    ("`#if compiler(<5.0)` ... `#else` statfs: the #else is read", [DUMMY],
     dummy("#if compiler(<5.0)\nlet old = 1\n#else\n" + STATFS + "\n#endif"),
     1, r"CLI Pulse iOS: .*/PrivacyManifestNegativeControl\.swift:8 uses statfs"),
    ("`#if canImport(UIKit)` statfs reaches the Watch app (watchOS has UIKit)", [DUMMY],
     dummy("#if canImport(UIKit)\n" + STATFS + "\n#endif"),
     1, r"CLI Pulse Watch: .*/PrivacyManifestNegativeControl\.swift:6 uses statfs"),
    ("a trailing `// && os(watchOS)` is not part of the condition", [DUMMY],
     dummy("#if os(iOS) // && os(watchOS)\n" + STATFS + "\n#endif"),
     1, r"CLI Pulse iOS: .*/PrivacyManifestNegativeControl\.swift:6 uses statfs"),
    ("statfs only inside #if os(macOS): iOS passes, the Mac app fails", [DUMMY],
     dummy("#if os(macOS)\n" + STATFS + "\n#endif"),
     1, r"CLI Pulse Bar: CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/PrivacyManifestNegativeControl\.swift:6 uses statfs",
     r"CLI Pulse (iOS|Watch|Widgets): .*NegativeControl"),
    ("statfs in an #else of #if os(iOS): the iOS targets pass, the Mac fails", [DUMMY],
     dummy("#if os(iOS)\nlet x = 1\n#else\n" + STATFS + "\n#endif"),
     1, r"CLIPulseHelper: CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/PrivacyManifestNegativeControl\.swift:8 uses statfs",
     r"CLI Pulse (iOS|Widgets): .*NegativeControl"),
    ("statfs named only in a comment and a string passes", [DUMMY],
     dummy('// statfs(path, &buf) would need DiskSpace\n/* volumeAvailableCapacityKey */\n'
           'let note = "statfs(p, &s) and activeInputModes and AppleLanguages"'),
     0, r"check_privacy_manifests: OK"),

    # --- MUST 5: patterns ---------------------------------------------------
    ("a URLResourceValues capacity accessor", [DUMMY],
     dummy("func available(_ values: URLResourceValues) -> Int? {\n    values.volumeAvailableCapacity\n}"),
     1, r"CLI Pulse iOS: .*/PrivacyManifestNegativeControl\.swift:4 uses URLResourceValues volume capacity \(NSPrivacyAccessedAPICategoryDiskSpace\)"),
    ("a statfs call split across lines", [DUMMY],
     dummy("func f(_ p: String) {\n    var s = statfs()\n    _ = statfs\n        (p, &s)\n}"),
     1, r"CLI Pulse iOS: .*/PrivacyManifestNegativeControl\.swift:5 uses statfs"),
    ("a module-qualified call (Foundation.statfs)", [DUMMY],
     dummy("func f(_ p: String) {\n    var s = Foundation.statfs()\n    _ = Foundation.statfs(p, &s)\n}"),
     1, r"CLI Pulse iOS: .*/PrivacyManifestNegativeControl\.swift:5 uses statfs"),
    ("FileManager.attributesOfFileSystem", [DUMMY],
     dummy('let a = try? FileManager.default.attributesOfFileSystem(forPath: "/")'),
     1, r"uses FileManager\.attributesOfFileSystem \(free/total size\) \(NSPrivacyAccessedAPICategoryDiskSpace\)"),
    ("getattrlist counts as DiskSpace too", [DUMMY],
     dummy("func f(_ p: String, _ a: inout attrlist, _ b: UnsafeMutableRawPointer) {\n    _ = getattrlist(p, &a, b, 0, 0)\n}"),
     1, r"CLI Pulse iOS: .*/PrivacyManifestNegativeControl\.swift:4 uses getattrlist family \(NSPrivacyAccessedAPICategoryDiskSpace\)"),
    ("a split `UserDefaults(\\n suiteName:` still counts as the app group", [WIDGETS, WIDGET_PROVIDER],
     both(edit_plist(WIDGETS, drop_reason("UserDefaults", "1C8F.1")),
          edit_text(WIDGET_PROVIDER, "UserDefaults(suiteName: suiteName)", "UserDefaults(\n            suiteName: suiteName)", count=None)),
     1, r"CLI Pulse Widgets: uses app-group UserDefaults \(CLI Pulse Bar/CLI Pulse Widgets/WidgetDataProvider\.swift:106\)"),

    # --- MUST 6 and 7: the project ------------------------------------------
    ("the manifest removed from a target's Resources phase (LoginItem)", [PBXPROJ],
     lambda r: (r / PBXPROJ).write_text(re.sub(r"\n\t+E2A669E4AF3FEA8CD1B23CB2 /\* PrivacyInfo\.xcprivacy in Resources \*/,", "",
                                                (r / PBXPROJ).read_text(encoding="utf-8")), encoding="utf-8"),
     1, r"CLIPulseHelper: CLI Pulse Bar/CLIPulseHelper/PrivacyInfo\.xcprivacy is not in the target's Resources build phase"),
    ("a platform filter on the LoginItem manifest's build file", [PBXPROJ],
     edit_text(PBXPROJ, "fileRef = 595F2271416030DEA737AE50 /* PrivacyInfo.xcprivacy */; };",
               "fileRef = 595F2271416030DEA737AE50 /* PrivacyInfo.xcprivacy */; platformFilter = ios; };"),
     1, r"CLIPulseHelper: the manifest's build file E2A669E4AF3FEA8CD1B23CB2 carries platformFilter = ios"),
    ("EXCLUDED_SOURCE_FILE_NAMES leaves the Mac manifest out", [PBXPROJ],
     edit_text(PBXPROJ, '\t\t\t\tCODE_SIGN_ENTITLEMENTS = "CLI Pulse Bar/CLI_Pulse_Bar.entitlements";\n',
               '\t\t\t\tCODE_SIGN_ENTITLEMENTS = "CLI Pulse Bar/CLI_Pulse_Bar.entitlements";\n'
               '\t\t\t\tEXCLUDED_SOURCE_FILE_NAMES = "*.xcprivacy";\n'),
     1, r"CLI Pulse Bar: build setting \"EXCLUDED_SOURCE_FILE_NAMES\" = '\*\.xcprivacy' in configuration (Debug|Release) "
        r"\(G1000[56]\) can leave files, the privacy manifest among them, out of the bundle"),
    # --- round 3 ---------------------------------------------------------------
    ("R3-1: a conditional EXCLUDED_SOURCE_FILE_NAMES on the LoginItem's Release", [PBXPROJ],
     in_config("G60002", '"EXCLUDED_SOURCE_FILE_NAMES[sdk=macosx*]" = "*.xcprivacy";'),
     1, r"CLIPulseHelper: build setting \"EXCLUDED_SOURCE_FILE_NAMES\[sdk=macosx\*\]\" = '\*\.xcprivacy' in "
        r"configuration Release \(G60002\) can leave files, the privacy manifest among them, out of the bundle"),
    ("R3-1: an INCLUDED_SOURCE_FILE_NAMES at project level", [PBXPROJ],
     in_config("G10004", 'INCLUDED_SOURCE_FILE_NAMES = "*.swift";'),
     1, r"project: build setting \"INCLUDED_SOURCE_FILE_NAMES\" = '\*\.swift' in configuration Release \(G10004\)"),
    ("R3-1: an .xcconfig base on the project", [PBXPROJ],
     both(add_objects('\t\tNC0040 /* Base.xcconfig */ = {isa = PBXFileReference; path = Base.xcconfig; sourceTree = SOURCE_ROOT; };\n'),
          in_config("G10002", "baseConfigurationReference = NC0040 /* Base.xcconfig */;",
                    anchor="isa = XCBuildConfiguration;\n", indent="\t\t\t")),
     1, r"project: configuration Debug \(G10002\) is based on CLI Pulse Bar/Base\.xcconfig \(an \.xcconfig\), whose settings"),
    ("R3-1: a reviewed build setting that matches nothing", [CONFIG],
     edit_config(lambda c: c.__setitem__("reviewed_build_settings", [
         {"owner": "project", "configuration": "Release", "key": "EXCLUDED_SOURCE_FILE_NAMES", "value": "x", "reason": "t"}])),
     1, r"reviewed_build_settings entry .* matches nothing; remove it"),
    ("R3-2: a custom-path package target the record does not list", [PACKAGE, f"{APP}/CLIPulseCore/PrivacyExtra/Probe.swift"],
     both(edit_text(PACKAGE, '                .target(name: "CZstd", condition: .when(platforms: [.macOS]))',
                    '                .target(name: "CZstd", condition: .when(platforms: [.macOS])),\n                "PrivacyExtra"'),
          edit_text(PACKAGE, "        .testTarget(", '        .target(name: "PrivacyExtra", path: "PrivacyExtra"),\n        .testTarget('),
          lambda r: ((r / APP / "CLIPulseCore/PrivacyExtra").mkdir(exist_ok=True),
                     (r / APP / "CLIPulseCore/PrivacyExtra/Probe.swift").write_text(
                         "import Darwin\npublic func probe(_ p: UnsafePointer<CChar>) -> Int32 {\n"
                         "    var value = statfs()\n    return statfs(p, &value)\n}\n"))),
     1, r"Package\.swift: declares target 'PrivacyExtra' \(path PrivacyExtra\), which the reviewed record .* does not "
        r"list, so its sources are not scanned"),
    ("R3-2: a local package dependency", [PACKAGE],
     edit_text(PACKAGE, '.package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.10.0")',
               '.package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.10.0"),\n        .package(path: "../Extra")'),
     1, r"Package\.swift: depends on the local package at \.\./Extra, whose sources this check does not scan"),
    ("R3-2: a dependency added to a reviewed package target", [PACKAGE],
     edit_text(PACKAGE, '                .target(name: "CZstd", condition: .when(platforms: [.macOS]))',
               '                .target(name: "CZstd", condition: .when(platforms: [.macOS])),\n                "CLIPulseCoreTests"'),
     1, r"Package\.swift: 'CLIPulseCore' is declared as .*target:CLIPulseCoreTests.*, but the reviewed record says"),
    ("R3-3: Darwin.statfs assigned as a function value", [DUMMY],
     dummy("var probe: (UnsafePointer<CChar>, UnsafeMutablePointer<statfs>) -> Int32 = Darwin.statfs"),
     1, r"CLI Pulse iOS: .*/PrivacyManifestNegativeControl\.swift:3 uses statfs / statvfs / fstatfs / fstatvfs \(NSPrivacyAccessedAPICategoryDiskSpace\)"),
    ("R3-3: statfs as a default argument value", [DUMMY],
     dummy("func check(_ p: String,\n           using f: (UnsafePointer<CChar>, UnsafeMutablePointer<statfs>) -> Int32 = statfs) {}"),
     1, r"CLI Pulse Watch: .*/PrivacyManifestNegativeControl\.swift:4 uses statfs"),
    ("R3-3: fstatfs referenced without a call", [DUMMY],
     dummy("let reader = fstatfs"),
     1, r"CLI Pulse Widgets: .*/PrivacyManifestNegativeControl\.swift:3 uses statfs / statvfs / fstatfs / fstatvfs"),
    ("R3-4: @AppStorage on a system key", [DUMMY],
     dummy('import SwiftUI\nstruct NCView {\n    @AppStorage("AppleInterfaceStyle") var style = ""\n}'),
     1, r"CLI Pulse iOS: .*/PrivacyManifestNegativeControl\.swift:5 reads a key the system writes, through @AppStorage"),
    ("R3-4: @AppStorage(wrappedValue:, system key)", [DUMMY],
     dummy('import SwiftUI\nstruct NCView {\n    @AppStorage(wrappedValue: "", "AppleLanguages") var langs: String\n}'),
     1, r"CLI Pulse Bar: .*/PrivacyManifestNegativeControl\.swift:5 reads a key the system writes, through @AppStorage"),
    ("R3-4/5: @AppStorage on a name bound to a system key in another file", [DUMMY, DUMMY2],
     both(dummy('enum PrivacyNCKeys { static let style: String = "AppleInterfaceStyle" }'),
          lambda r: (r / DUMMY2).write_text('import SwiftUI\nstruct NCView {\n    @AppStorage(PrivacyNCKeys.style) var style = ""\n}\n')),
     1, r"CLI Pulse iOS: .*/PrivacyManifestNegativeControl2\.swift:3 reads a key the system writes \(style\), through @AppStorage"),
    ("R3-5: forKey: on a name bound to a system key in another file", [DUMMY, DUMMY2],
     both(dummy('enum PrivacyNCKeys { static let lang = "AppleLanguages" }'),
          lambda r: (r / DUMMY2).write_text("import Foundation\nlet ncLangs = UserDefaults.standard.stringArray(forKey: PrivacyNCKeys.lang)\n")),
     1, r"CLI Pulse Watch: .*/PrivacyManifestNegativeControl2\.swift:2 reads a key the system writes \(lang\) through UserDefaults"),
    ("R3 SHOULD: a Linked flag that is an array", [WATCH],
     edit_plist(WATCH, lambda d: collected(d, "CrashData").__setitem__("NSPrivacyCollectedDataTypeLinked", [])),
     1, r"NSPrivacyCollectedDataTypeLinked is an array, not a boolean"),
    ("a manifest file that is missing", [MAC], lambda r: (r / MAC).unlink(),
     1, r"CLI Pulse Bar/CLI Pulse Bar/PrivacyInfo\.xcprivacy: cannot read"),
    ("a new app extension target, not in the record", [PBXPROJ, f"{APP}/NC Share Extension/Probe.swift"],
     both(add_objects(NEW_EXTENSION),
          lambda r: ((r / APP / "NC Share Extension").mkdir(exist_ok=True),
                     (r / APP / "NC Share Extension/Probe.swift").write_text("import Foundation\n" + STATFS + "\n"))),
     1, r"target 'NC Share Extension' \(com\.apple\.product-type\.app-extension\) ships a bundle but is not in"),
    ("an exempt target that does not exist", [CONFIG],
     edit_config(lambda c: c.__setitem__("exempt_targets", {"Ghost": "test"})),
     1, r"exempt_targets names 'Ghost', which is not a target"),

    # --- SHOULD: arrangements the scan cannot see ---------------------------
    ("a synchronized folder", [PBXPROJ],
     add_objects('\t\tNC0010 /* Extra */ = {isa = PBXFileSystemSynchronizedRootGroup; path = Extra; sourceTree = "<group>"; };\n'),
     1, r"PBXFileSystemSynchronizedRootGroup NC0010 \(Extra\): synchronized folders are not mapped"),
    ("an Objective-C++ file in a Sources phase", [PBXPROJ],
     both(add_objects('\t\tNC0020 /* Bridge.mm in Sources */ = {isa = PBXBuildFile; fileRef = NC0021 /* Bridge.mm */; };\n'
                      '\t\tNC0021 /* Bridge.mm */ = {isa = PBXFileReference; path = "CLI Pulse Bar iOS/Bridge.mm"; sourceTree = SOURCE_ROOT; };\n'),
          edit_text(PBXPROJ, "\t\t\t\tA20001 /* CLIPulseApp_iOS.swift in Sources */,\n",
                    "\t\t\t\tA20001 /* CLIPulseApp_iOS.swift in Sources */,\n\t\t\t\tNC0020 /* Bridge.mm in Sources */,\n")),
     1, r"CLI Pulse iOS: compiles CLI Pulse Bar/CLI Pulse Bar iOS/Bridge\.mm, a \.mm file this check does not scan"),
    ("an unreviewed package product", [PBXPROJ],
     both(add_objects("\t\tNC0030 /* Alamofire */ = {isa = XCSwiftPackageProductDependency; productName = Alamofire; };\n"),
          edit_text(PBXPROJ, "\t\t\t\tPKG00003 /* CLIPulseCore */,\n", "\t\t\t\tPKG00003 /* CLIPulseCore */,\n\t\t\t\tNC0030 /* Alamofire */,\n")),
     1, r"CLI Pulse iOS: links package product 'Alamofire', which .* has not reviewed"),
    ("an unreviewed package dependency", [PACKAGE],
     edit_text(PACKAGE, '.package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.10.0")',
               '.package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.10.0"),\n'
               '        .package(url: "https://github.com/example/telemetry", from: "1.0.0")'),
     1, r"Package\.swift: depends on https://github\.com/example/telemetry, which .* has not reviewed"),
    ("a package target the record does not list", [f"{CORE}/../NCExtra/Extra.swift"],
     lambda r: ((r / f"{APP}/CLIPulseCore/Sources/NCExtra").mkdir(),
                (r / f"{APP}/CLIPulseCore/Sources/NCExtra/Extra.swift").write_text(STATFS)),
     1, r"CLIPulseCore/Sources/NCExtra: a package target .* does not list, so its sources are not scanned"),
    ("a Sentry bump without a new measurement", [RESOLVED],
     edit_text(RESOLVED, '"version" : "9.12.1"', '"version" : "9.13.0"'),
     1, r"sentry-cocoa is pinned at 9\.13\.0, but binary_categories were measured with 9\.12\.1"),
    ("a stale allowlist entry fails", [ALLOW],
     lambda r: (r / ALLOW).write_text(json.dumps({"entries": [
         {"target": "CLI Pulse iOS", "category": "NSPrivacyAccessedAPICategoryDiskSpace",
          "file": DUMMY, "pattern": "statfs", "reason": "test"}]}), encoding="utf-8"),
     1, r"privacy_manifests_allowlist\.json: entry 0 \(CLI Pulse iOS, .*\) matches nothing; remove it"),

    # --- manifest semantics, malformed types included ------------------------
    ("a byte order mark", [IOS], lambda r: (r / IOS).write_bytes(b"\xef\xbb\xbf" + (r / IOS).read_bytes()),
     1, r"PrivacyInfo\.xcprivacy: starts with a UTF-8 byte order mark"),
    ("a manifest that does not parse", [LOGIN],
     lambda r: (r / LOGIN).write_bytes((r / LOGIN).read_bytes().replace(b"</dict>\n</plist>", b"</plist>")),
     1, r"CLIPulseHelper/PrivacyInfo\.xcprivacy: does not parse as a property list"),
    ("an unknown top-level key", [MAC], edit_plist(MAC, lambda d: d.__setitem__("NSPrivacyTrackingDomain", [])),
     1, r"unknown top-level key 'NSPrivacyTrackingDomain'"),
    ("NSPrivacyTracking that is not a boolean", [WATCH], edit_plist(WATCH, lambda d: d.__setitem__("NSPrivacyTracking", "NO")),
     1, r"NSPrivacyTracking is a string, not a boolean"),
    ("a tracking domain", [IOS], edit_plist(IOS, lambda d: d.__setitem__("NSPrivacyTrackingDomains", ["example.com"])),
     1, r"NSPrivacyTrackingDomains lists \['example\.com'\]; with tracking off it must be empty"),
    ("an unknown category", [IOS],
     edit_plist(IOS, lambda d: api(d, "FileTimestamp").__setitem__("NSPrivacyAccessedAPIType", "NSPrivacyAccessedAPICategoryFileTimestamps")),
     1, r"unknown category 'NSPrivacyAccessedAPICategoryFileTimestamps'"),
    ("a reason from another category (CA92.1 under SystemBootTime)", [WATCH],
     edit_plist(WATCH, lambda d: api(d, "SystemBootTime")["NSPrivacyAccessedAPITypeReasons"].append("CA92.1")),
     1, r"reason 'CA92\.1' is not a reason Apple defines for NSPrivacyAccessedAPICategorySystemBootTime"),
    ("a category declared twice", [MAC],
     edit_plist(MAC, lambda d: d["NSPrivacyAccessedAPITypes"].append(dict(api(d, "UserDefaults")))),
     1, r"NSPrivacyAccessedAPICategoryUserDefaults is declared twice"),
    ("a reason listed twice", [MAC],
     edit_plist(MAC, lambda d: api(d, "FileTimestamp")["NSPrivacyAccessedAPITypeReasons"].append("C617.1")),
     1, r"reason C617\.1 is listed twice for NSPrivacyAccessedAPICategoryFileTimestamp"),
    ("an unknown collected data type", [MAC],
     edit_plist(MAC, lambda d: collected(d, "OtherDataTypes").__setitem__("NSPrivacyCollectedDataType", "NSPrivacyCollectedDataTypeOtherData")),
     1, r"unknown data type 'NSPrivacyCollectedDataTypeOtherData'"),
    ("malformed: a purpose that is a dictionary", [IOS],
     edit_plist(IOS, lambda d: collected(d, "Name")["NSPrivacyCollectedDataTypePurposes"].append({"x": 1})),
     1, r"a purpose of NSPrivacyCollectedDataTypeName is a dictionary, not a string"),
    ("malformed: reasons that are a string", [IOS],
     edit_plist(IOS, lambda d: api(d, "SystemBootTime").__setitem__("NSPrivacyAccessedAPITypeReasons", "35F9.1")),
     1, r"NSPrivacyAccessedAPITypeReasons of NSPrivacyAccessedAPICategorySystemBootTime is a string, not an array"),
    ("malformed: an API entry that is a string", [WATCH],
     edit_plist(WATCH, lambda d: d["NSPrivacyAccessedAPITypes"].append("NSPrivacyAccessedAPICategoryDiskSpace")),
     1, r"NSPrivacyAccessedAPITypes\[3\]: is a string, not a dictionary"),
    ("malformed: a data type that is an array", [MAC],
     edit_plist(MAC, lambda d: collected(d, "CrashData").__setitem__("NSPrivacyCollectedDataType", ["x"])),
     1, r"NSPrivacyCollectedDataType is an array, not a string"),
    ("malformed: a category that is an array", [LOGIN],
     edit_plist(LOGIN, lambda d: api(d, "FileTimestamp").__setitem__("NSPrivacyAccessedAPIType", ["x"])),
     1, r"NSPrivacyAccessedAPIType is an array, not a string"),
]


# One sample per source pattern: each must be found with its categories (this
# also keeps the hand-kept needles honest), and none of the near misses may be.
PATTERN_SAMPLES = [
    ("let d = attrs[.modificationDate]", {"FileTimestamp"}),
    ("let d = (attrs as NSDictionary).fileCreationDate()", {"FileTimestamp"}),
    ("let k: URLResourceKey = .creationDateKey", {"FileTimestamp"}),
    ("let d = values.contentModificationDate", {"FileTimestamp"}),
    ("let k = NSFileModificationDate", {"FileTimestamp"}),
    ("_ = Darwin.lstat(p, &s)", {"FileTimestamp"}),
    ("_ = getattrlistbulk(fd, &a, b, n, 0)", {"FileTimestamp", "DiskSpace"}),
    ("let t = ProcessInfo.processInfo.systemUptime", {"SystemBootTime"}),
    ("let t = mach_absolute_time()", {"SystemBootTime"}),
    ("let t = mach_continuous_time()", {"SystemBootTime"}),
    ("let clock: () -> UInt64 = mach_absolute_time", {"SystemBootTime"}),
    ("let probe = Darwin.lstat", {"FileTimestamp"}),
    ("var probe: (UnsafePointer<CChar>, UnsafeMutablePointer<stat>) -> Int32 = Darwin.stat", {"FileTimestamp"}),
    ("let probe = Foundation.statvfs", {"DiskSpace"}),
    ("run(with: statfs)", {"DiskSpace"}),
    ("let g = getattrlist", {"FileTimestamp", "DiskSpace"}),
    ("var mib = [CTL_KERN, KERN_BOOTTIME]", {"SystemBootTime"}),
    ('_ = sysctlbyname("kern.boottime", &tv, &size, nil, 0)', {"SystemBootTime"}),
    ("let k: URLResourceKey = .volumeAvailableCapacityForImportantUsageKey", {"DiskSpace"}),
    ("let n = values.volumeTotalCapacity", {"DiskSpace"}),
    ("let f = attrs[.systemFreeSize]", {"DiskSpace"}),
    ("let k = NSFileSystemFreeSize", {"DiskSpace"}),
    ('let a = try FileManager.default.attributesOfFileSystem(forPath: "/")', {"DiskSpace"}),
    ("_ = Glibc.statvfs(p, &s)", {"DiskSpace"}),
    ("let m = UITextInputMode.activeInputModes", {"ActiveKeyboards"}),
    ("let d = UserDefaults.standard", {"UserDefaults"}),
    ('@AppStorage("k") var k = 1', {"UserDefaults"}),
]
NEAR_MISSES = [
    "var s = stat()",                    # the struct's initializer, not a call
    "var v = statfs()",
    "_ = store.statfs(p)",               # a member of something else
    "// lstat(p, &s) systemUptime",      # a comment
    'let s = "statfs(p, &s) volumeTotalCapacity"',  # a string
    "let x = myfstatfs(p)",              # another identifier
    "let n = MemoryLayout<statfs>.size",  # type uses of the struct names
    "var s: statfs = statfs()",
    "let p = UnsafeMutablePointer<statfs>.allocate(capacity: 1)",
    "func g(_ s: statfs) {}",
    "let t = statfs.self",
    "let a: [stat] = []",
    "static let isStatic = true; let state = status",  # words that contain "stat"
]


def check_every_pattern_fires(check) -> tuple[bool, str]:
    wrong = []
    for sample, want in PATTERN_SAMPLES:
        sf = check.SourceFile("import Foundation\n" + sample + "\n", swift=True)
        got = {check.SHORT[c] for c, *_ in sf.hits("ios")}
        if not want <= got:
            wrong.append(f"{sample!r}: found {sorted(got)}, expected {sorted(want)}")
    for sample in NEAR_MISSES:
        sf = check.SourceFile("import Foundation\n" + sample + "\n", swift=True)
        got = {check.SHORT[c] for c, *_ in sf.hits("ios")}
        if got:
            wrong.append(f"{sample!r}: matched {sorted(got)}, expected nothing")
    return not wrong, "; ".join(wrong)


def check_run_reports_tool_failures(check) -> tuple[bool, str]:
    """run() must turn a failing tool into "could not check", never a partial
    measurement (archive mode reads nm, strings and swift-demangle)."""
    try:
        check.run([sys.executable, "-c", "import sys; sys.stderr.write('boom'); sys.exit(3)"])
    except check.CheckError as exc:
        return ("exited 3" in str(exc) and "boom" in str(exc)), str(exc)
    return False, "run() returned normally"


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
            extra_dirs = [root / APP / "NC Share Extension", root / APP / "CLIPulseCore/Sources/NCExtra",
                          root / APP / "CLIPulseCore/PrivacyExtra"]
            try:
                if mutate:
                    mutate(root)
                # In-process: the check keeps what it read of files that did not
                # change, so many runs cost little more than one.
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
                for d in extra_dirs:
                    if d.exists():
                        shutil.rmtree(d)
        for label, fn in (("every source pattern finds its sample, and no near miss", check_every_pattern_fires),
                          ("run() reports a failing tool as could-not-check", check_run_reports_tool_failures)):
            ok, detail = fn(check)
            print(f"{'PASS' if ok else 'FAIL'}: {label}")
            if not ok:
                failures += 1
                print(f"    {detail}")
    total = len(CASES) + 2
    print(f"test_check_privacy_manifests: {total - failures}/{total} cases behaved")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
