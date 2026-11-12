#!/usr/bin/env python3
"""Privacy manifests (PrivacyInfo.xcprivacy) checked against Apple's vocabulary,
the project, the code each target compiles, a reviewed per-target record, and
the published App Store label.

WHY THIS EXISTS
---------------
Until 1.63 the iPhone, Watch and widget manifests declared only UserDefaults
CA92.1, and the Mac app and its LoginItem had no manifest at all, while every
one of those binaries links code that reads the system uptime (SystemBootTime)
and file metadata (FileTimestamp), and four of them use the app group's
defaults (UserDefaults 1C8F.1). Nothing connected the manifests to the code, so
a new `lstat` or `systemUptime` could land in any target with every gate green.
Apple validates the required-reason categories at upload (ITMS-91053) and the
Xcode privacy report reads the collected-data part, so both halves matter.

THE REVIEWED RECORD (scripts/privacy_manifests.json)
---------------------------------------------------
Per target: the categories and reason codes its manifest declares, each reason
with the call sites (or the SDK) it rests on; the collected-data rows; and the
categories its archived executable was measured to link. The 1.63 A3 PR has the
review: why each call site meets the whole text of its reason. The manifest
must equal the record exactly, and the record must stay true of the code.

WHAT IT CHECKS (stdlib only, runs on the Linux CI runner: no plutil there)
-------------------------------------------------------------------------
1. Semantics of every manifest: UTF-8 without a BOM, parses as an XML plist
   (plistlib, the plutil -lint equivalent), only the four top-level keys Apple
   defines and each with its type, every element of the right type, known
   category / reason / data-type / purpose strings, a reason that belongs to
   its category, no duplicates, tracking off with no domains.
2. The project: every target that ships a bundle (application or extension) is
   in the record or exempted there with a reason; each manifest is in its own
   target's Resources phase with no platform filter; no
   (EXCLUDED|INCLUDED)_SOURCE_FILE_NAMES setting, conditional or not, and no
   .xcconfig base on the project or a recorded target unless reviewed; no
   synchronized folder, unscanned source type, unreviewed package product or
   other local package.
3. The packages: every target CLIPulseCore's Package.swift declares (kind,
   custom path, dependencies) and every package dependency (url or local
   path) is the reviewed one, and sentry-cocoa is pinned at the version the
   binaries were measured with (a bump means measuring again with --archive).
4. The code each target compiles (its Sources phases plus the package's
   sources for its platform), with comments and string contents blanked,
   `#if` resolved only where the answer is certain (os(), true/false, a few
   canImport()) and both branches read otherwise, searched across line breaks:
   - a required-reason API whose category the manifest lacks fails;
   - app-group `UserDefaults(suiteName:)` without 1C8F.1 in a target entitled
     to the group fails, and 1C8F.1 without the entitlement fails;
   - reading a default the system writes (AppleLanguages and other Apple*
     keys, by literal, @AppStorage or a name bound to one anywhere in the
     target; NSGlobalDomain; dictionaryRepresentation()) fails: no UserDefaults
     reason covers it;
   - each recorded reason's cited call site must still be present in code the
     target can compile (both branches of an uncertain #if count), so a
     reason cannot outlive the code that needed it.
   A function referenced as a value (`= Darwin.statfs`, a default argument)
   counts like a call. This is a drift detector, not a proof: the reviewed
   inventory in the PR that added it is what shows each declaration is right.
5. Collected data: each manifest's rows equal the target's recorded rows
   exactly (type, linked, tracking, purposes); every recorded row is a row of
   the published label, and every label row is recorded for some target.
Reviewed exceptions: scripts/privacy_manifests_allowlist.json (an entry that no
longer matches anything fails).

ARCHIVE MODE (macOS only: needs xcrun)
-------------------------------------
    python3 scripts/check_privacy_manifests.py --archive <x.xcarchive> [...]
lists every .xcprivacy in the archive, requires each target's manifest at its
bundle's path with the repo's content, and reads each target's executable
(nm -u, swift-demangle, the ObjC selector strings) for the required-reason APIs
it links. A category the binary links that the manifest does not declare
fails, and so does a `binary_categories` entry that no longer matches.

Exit 0 clean, 1 problems found, 2 could not check.
"""
from __future__ import annotations

import argparse
import bisect
import json
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIG = "scripts/privacy_manifests.json"
ALLOWLIST = "scripts/privacy_manifests_allowlist.json"


class CheckError(Exception):
    """The check could not run to the end (a tool failed, input unreadable)."""


# ---------------------------------------------------------------------------
# Apple's vocabulary. Copied from Xcode 27.1's own definition of the format
# (PlugIns/DVTCorePlistStructDefs.dvtplugin, "App Privacy Configuration",
# filename pattern *.xcprivacy), which is what the Xcode plist editor offers.
# ---------------------------------------------------------------------------
CAT_FILE = "NSPrivacyAccessedAPICategoryFileTimestamp"
CAT_BOOT = "NSPrivacyAccessedAPICategorySystemBootTime"
CAT_DISK = "NSPrivacyAccessedAPICategoryDiskSpace"
CAT_KEYB = "NSPrivacyAccessedAPICategoryActiveKeyboards"
CAT_DEFAULTS = "NSPrivacyAccessedAPICategoryUserDefaults"
SYSTEM_DEFAULTS = "SystemWrittenDefaults"  # this check's own rule name

CATEGORY_REASONS = {
    CAT_FILE: {"DDA9.1", "C617.1", "3B52.1", "0A2A.1"},
    CAT_BOOT: {"35F9.1", "8FFB.1", "3D61.1"},
    CAT_DISK: {"85F4.1", "E174.1", "7D9E.1", "B728.1"},
    CAT_KEYB: {"3EC4.1", "54BD.1"},
    CAT_DEFAULTS: {"CA92.1", "1C8F.1", "C56D.1", "AC6B.1"},
}
APP_GROUP_REASON = "1C8F.1"

DATA_TYPES = {
    "NSPrivacyCollectedDataType" + t for t in (
        "AdvertisingData", "AudioData", "BrowsingHistory", "CoarseLocation", "Contacts",
        "CrashData", "CreditInfo", "CustomerSupport", "DeviceID", "EmailAddress",
        "EmailsOrTextMessages", "EnvironmentScanning", "Fitness", "GameplayContent", "Hands",
        "Head", "Health", "Name", "OtherDataTypes", "OtherDiagnosticData",
        "OtherFinancialInfo", "OtherUsageData", "OtherUserContactInfo", "OtherUserContent",
        "PaymentInfo", "PerformanceData", "PhoneNumber", "PhotosorVideos", "PhysicalAddress",
        "PreciseLocation", "ProductInteraction", "PurchaseHistory", "SearchHistory",
        "SensitiveInfo", "UserID",
    )
}
PURPOSES = {
    "NSPrivacyCollectedDataTypePurpose" + p for p in (
        "Analytics", "AppFunctionality", "DeveloperAdvertising", "Other",
        "ProductPersonalization", "ThirdPartyAdvertising",
    )
}
TOP_LEVEL_TYPES = {
    "NSPrivacyTracking": bool,
    "NSPrivacyTrackingDomains": list,
    "NSPrivacyCollectedDataTypes": list,
    "NSPrivacyAccessedAPITypes": list,
}
API_ENTRY_KEYS = {"NSPrivacyAccessedAPIType", "NSPrivacyAccessedAPITypeReasons"}
DATA_ENTRY_KEYS = {
    "NSPrivacyCollectedDataType", "NSPrivacyCollectedDataTypeLinked",
    "NSPrivacyCollectedDataTypeTracking", "NSPrivacyCollectedDataTypePurposes",
}

# Every product type that ships a bundle a privacy manifest can sit in.
BUNDLE_PRODUCT_TYPES = (
    "com.apple.product-type.application",          # and .watchapp2, .messages, ...
    "com.apple.product-type.app-extension",        # and .messages, .intents-service, ...
    "com.apple.product-type.watchkit2-extension",
    "com.apple.product-type.extensionkit-extension",
    "com.apple.product-type.tv-app-extension",
    "com.apple.product-type.app-clip",
)

# ---------------------------------------------------------------------------
# Source patterns: (categories, regex, what it is). Run over a whole file's
# code with comments and string contents blanked and other platforms' `#if`
# branches removed, so a call split across lines still matches; `strings`
# patterns run on the view that keeps string contents. Apple's lists:
# developer.apple.com, "Describing use of required reason API".
# ---------------------------------------------------------------------------
QUAL = r"(?<![\w.])(?:(?:Darwin|Foundation|Glibc)\s*\.\s*)?"  # module-qualified calls too
CALL = r"\s*\((?!\s*\))"  # a call: `stat()` with nothing inside is the struct's initializer
# A name that is both a struct and a function (stat, statfs, statvfs) used as a
# function value: right after `=` or as an argument (after `(` or `,`, with an
# optional label), and not followed by what a call or a type use would be
# (`(`, `.`, `<`, `>`, `[`, `]`, `?`, `!`). A lone type in a tuple or a
# one-label parameter (`(s: statfs)`) is over-reported, never missed.
FUNC_VALUE = r"(?:=|[(,]\s*(?:\w+\s*:)?)\s*(?:(?:Darwin|Foundation|Glibc)\s*\.\s*)?"
NOT_TYPE_USE = r"\b(?!\s*[(.<>\[\]?!])"
SOURCE_PATTERNS = [
    # FileTimestamp. Apple names creationDate, modificationDate,
    # fileModificationDate, contentModificationDateKey, creationDateKey, and
    # the stat/getattrlist families. Our stat calls read only type, owner and
    # size, but the category is per API, not per field.
    ((CAT_FILE,), r"\.(?:creationDate|modificationDate)\b", "FileAttributeKey / URLResourceValues .creationDate / .modificationDate"),
    ((CAT_FILE,), r"\bfile(?:Modification|Creation)Date\b", "NSDictionary fileModificationDate / fileCreationDate"),
    ((CAT_FILE,), r"\b(?:contentModificationDate|creationDate)Key\b", "URLResourceKey .contentModificationDateKey / .creationDateKey"),
    ((CAT_FILE,), r"\bcontentModificationDate\b", "URLResourceValues.contentModificationDate"),
    ((CAT_FILE,), r"\bNS(?:File(?:Creation|Modification)Date|URL(?:ContentModification|Creation)DateKey)\b", "the ObjC names of the keys above"),
    # `stat` and `stat64` are also struct names: a call, or the function passed
    # or assigned as a value (after `=`, or as an argument).
    ((CAT_FILE,), QUAL + r"(?:stat|stat64)" + CALL, "stat / lstat / fstat / fstatat"),
    ((CAT_FILE,), FUNC_VALUE + r"(?:stat|stat64)" + NOT_TYPE_USE, "stat / lstat / fstat / fstatat"),
    # These names are functions only, so any reference counts, called or not
    # (`let probe = Darwin.lstat`, a default argument value).
    ((CAT_FILE,), QUAL + r"(?:lstat|fstat|fstatat|lstat64|fstat64)\b", "stat / lstat / fstat / fstatat"),
    # getattrlist returns timestamps or volume capacity depending on the
    # attributes asked for, so it needs both until a reviewed allowlist entry
    # says which one a call site is.
    ((CAT_FILE, CAT_DISK), QUAL + r"(?:f?getattrlist|getattrlistbulk|getattrlistat)\b", "getattrlist family"),
    # SystemBootTime. Apple names systemUptime and mach_absolute_time.
    ((CAT_BOOT,), r"\bsystemUptime\b", "ProcessInfo.systemUptime"),
    ((CAT_BOOT,), QUAL + r"mach_absolute_time\b", "mach_absolute_time()"),
    # Not on Apple's list; the same clock counted from boot, so treated alike.
    ((CAT_BOOT,), QUAL + r"mach_continuous_time\b", "mach_continuous_time() (not on Apple's list; same boot clock)"),
    ((CAT_BOOT,), r"\bKERN_BOOTTIME\b", "sysctl KERN_BOOTTIME (how Sentry reads boot time)"),
    # DiskSpace: the keys, the URLResourceValues accessors, the file-system
    # attributes and the statfs family.
    ((CAT_DISK,), r"\bvolume(?:Available|Total)Capacity\w*Key\b", "URLResourceKey volume capacity keys"),
    ((CAT_DISK,), r"\.volume(?:AvailableCapacity(?:ForImportantUsage|ForOpportunisticUsage)?|TotalCapacity)\b", "URLResourceValues volume capacity"),
    ((CAT_DISK,), r"\.system(?:Free)?Size\b", "FileAttributeKey .systemFreeSize / .systemSize"),
    ((CAT_DISK,), r"\bNS(?:FileSystem(?:Free)?Size|URLVolume\w*Capacity\w*Key)\b", "the ObjC names of the keys above"),
    ((CAT_DISK,), r"\battributesOfFileSystem\b", "FileManager.attributesOfFileSystem (free/total size)"),
    # `statfs` and `statvfs` are also struct names (call, or a function value);
    # `fstatfs` and `fstatvfs` are functions only.
    ((CAT_DISK,), QUAL + r"statv?fs(?:64)?" + CALL, "statfs / statvfs / fstatfs / fstatvfs"),
    ((CAT_DISK,), FUNC_VALUE + r"statv?fs(?:64)?" + NOT_TYPE_USE, "statfs / statvfs / fstatfs / fstatvfs"),
    ((CAT_DISK,), QUAL + r"fstatv?fs(?:64)?\b", "statfs / statvfs / fstatfs / fstatvfs"),
    # ActiveKeyboards.
    ((CAT_KEYB,), r"\bactiveInputModes\b", "UITextInputMode.activeInputModes"),
    # UserDefaults: any use needs the category (CA92.1 for the app's own).
    ((CAT_DEFAULTS,), r"\b(?:NS)?UserDefaults\b", "UserDefaults"),
    ((CAT_DEFAULTS,), r"@AppStorage\b", "@AppStorage (UserDefaults underneath)"),
]
SOURCE_PATTERNS_STRINGS = [
    ((CAT_BOOT,), r"kern\.boottime", "sysctlbyname(\"kern.boottime\")"),
]
APP_GROUP_DEFAULTS = re.compile(r"\bUserDefaults\s*\(\s*suiteName\s*:")

# Defaults the system (or another app) writes. CA92.1 covers only what the app
# itself wrote, 1C8F.1 only its app group, so reading these through UserDefaults
# has no reason that fits. Matched on the view that keeps string contents.
DEFAULTS_GETTER = r"\.\s*(?:string|stringArray|array|object|dictionary|value|bool|integer|double|float|url|data)\s*\(\s*forKey\s*:\s*"
SYSTEM_KEY_LITERAL = r'"(?:Apple[A-Z]\w*|NSGlobalDomain|com\.apple\.[\w.-]*)"'
SYSTEM_DEFAULTS_PATTERNS = [
    (DEFAULTS_GETTER + SYSTEM_KEY_LITERAL, "a key the system writes, through UserDefaults"),
    (r"\bdictionaryRepresentation\s*\(\s*\)", "dictionaryRepresentation() (every domain, NSGlobalDomain's included)"),
    (r"\bUserDefaults\s*\.\s*globalDomain\b", "UserDefaults.globalDomain"),
    (r'\bsuiteName\s*:\s*' + SYSTEM_KEY_LITERAL, "another app's or the system's suite"),
    (r'\bpersistentDomain\s*\(\s*forName\s*:\s*' + SYSTEM_KEY_LITERAL, "another app's or the system's domain"),
]
# @AppStorage reads the key it names; its key is the first unlabeled argument.
APPSTORAGE_KEY = r"@AppStorage\s*\(\s*(?:wrappedValue\s*:\s*(?:[^,()]|\([^()]*\))*,\s*)?"
SYSTEM_DEFAULTS_PATTERNS.append((APPSTORAGE_KEY + SYSTEM_KEY_LITERAL, "a key the system writes, through @AppStorage"))
# A name bound to a system key (`static let lang = "AppleLanguages"`, an enum
# case's raw value), collected across every file a target compiles.
SYSTEM_KEY_BINDING = re.compile(
    r"\b(?:(?:let|var)\s+(\w+)\s*(?::\s*String\s*)?|case\s+(\w+)\s*)=\s*" + SYSTEM_KEY_LITERAL)

# ---------------------------------------------------------------------------
# Binary patterns for --archive. Imports from `nm -u` (Darwin's $INODE64
# aliases included), demangled Swift imports, and ObjC selector strings.
# ---------------------------------------------------------------------------
BINARY_IMPORTS = {
    # FileTimestamp: the stat and getattrlist families and their aliases.
    **{s: (CAT_FILE,) for s in (
        "_stat", "_lstat", "_fstat", "_fstatat", "_stat64", "_lstat64", "_fstat64",
        "_stat$INODE64", "_lstat$INODE64", "_fstat$INODE64", "_fstatat$INODE64",
        # FileAttributeKey / URLResourceKey constants (data symbols)
        "_NSFileCreationDate", "_NSFileModificationDate",
        "_NSURLContentModificationDateKey", "_NSURLCreationDateKey",
    )},
    # getattrlist: timestamps or capacity, depending on what is asked for.
    **{s: (CAT_FILE, CAT_DISK) for s in ("_getattrlist", "_getattrlistbulk", "_fgetattrlist", "_getattrlistat")},
    # SystemBootTime: the mach clocks.
    "_mach_absolute_time": (CAT_BOOT,),
    "_mach_continuous_time": (CAT_BOOT,),  # not on Apple's list; same boot clock
    # DiskSpace: the statfs family and the capacity keys.
    **{s: (CAT_DISK,) for s in (
        "_statfs", "_statfs64", "_statfs$INODE64", "_fstatfs", "_fstatfs64",
        "_fstatfs$INODE64", "_statvfs", "_fstatvfs", "_getfsstat", "_getfsstat$INODE64",
        "_NSURLVolumeAvailableCapacityKey", "_NSURLVolumeAvailableCapacityForImportantUsageKey",
        "_NSURLVolumeAvailableCapacityForOpportunisticUsageKey", "_NSURLVolumeTotalCapacityKey",
        "_NSFileSystemFreeSize", "_NSFileSystemSize",
    )},
    # UserDefaults: the class itself.
    "_OBJC_CLASS_$_NSUserDefaults": (CAT_DEFAULTS,),
}
BINARY_DEMANGLED = [
    # Swift overlay accessors that reach the same APIs without a C import.
    (CAT_FILE, re.compile(r"URLResourceValues\.(?:contentModificationDate|creationDate)\b")),
    (CAT_FILE, re.compile(r"FileAttributeKey\.(?:creationDate|modificationDate)\b")),
    (CAT_BOOT, re.compile(r"ProcessInfo\.systemUptime\b")),
    (CAT_DISK, re.compile(r"URLResourceValues\.volume(?:Available|Total)Capacity")),
    (CAT_DISK, re.compile(r"FileAttributeKey\.system(?:Free)?Size\b")),
    (CAT_DEFAULTS, re.compile(r"\bNSUserDefaults\b|\bUserDefaults\b")),
]
BINARY_STRINGS = {
    # ObjC selectors (__objc_methname) and the sysctl name Sentry uses.
    "fileModificationDate": CAT_FILE,
    "fileCreationDate": CAT_FILE,
    "systemUptime": CAT_BOOT,
    "kern.boottime": CAT_BOOT,
    "attributesOfFileSystemForPath:error:": CAT_DISK,
    "activeInputModes": CAT_KEYB,
}

SHORT = {
    CAT_FILE: "FileTimestamp", CAT_BOOT: "SystemBootTime", CAT_DISK: "DiskSpace",
    CAT_KEYB: "ActiveKeyboards", CAT_DEFAULTS: "UserDefaults", SYSTEM_DEFAULTS: SYSTEM_DEFAULTS,
}


# ---------------------------------------------------------------------------
# Manifest semantics
# ---------------------------------------------------------------------------
def load_manifest(path: Path, label: str, problems: list[str]):
    """Parse one manifest. Returns the dict, or None after recording why not."""
    try:
        raw = path.read_bytes()
    except OSError as exc:
        problems.append(f"{label}: cannot read ({exc.strerror})")
        return None
    if raw.startswith(b"\xef\xbb\xbf"):
        problems.append(f"{label}: starts with a UTF-8 byte order mark; write it without one")
        return None
    try:
        raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        problems.append(f"{label}: not UTF-8 ({exc.reason} at byte {exc.start})")
        return None
    if not raw.lstrip().startswith(b"<?xml"):
        problems.append(f"{label}: not an XML property list (Xcode writes .xcprivacy as XML)")
        return None
    try:
        data = plistlib.loads(raw, fmt=plistlib.FMT_XML)
    except Exception as exc:  # plistlib raises several types for bad XML
        problems.append(f"{label}: does not parse as a property list ({exc})")
        return None
    return data


def _kind(value) -> str:
    """The plist type of a value with its article: "an array", "a string"."""
    name = {dict: "dictionary", list: "array", str: "string", bool: "boolean", int: "integer",
            float: "real", bytes: "data"}.get(type(value), type(value).__name__)
    return ("an " if name[0] in "aeiou" else "a ") + name


def validate_manifest(data, label: str, problems: list[str]) -> None:
    """Every element is type-checked before it is compared or hashed, so a
    malformed manifest reads as a message, never as a crash."""
    if not isinstance(data, dict):
        problems.append(f"{label}: the top level is {_kind(data)}, not a dictionary")
        return
    for key in sorted(set(data) - set(TOP_LEVEL_TYPES)):
        problems.append(f"{label}: unknown top-level key {key!r} (Apple defines {', '.join(TOP_LEVEL_TYPES)})")
    for key, typ in TOP_LEVEL_TYPES.items():
        if key not in data:
            problems.append(f"{label}: missing {key} (every manifest here states all four keys)")
        elif not isinstance(data[key], typ):
            problems.append(f"{label}: {key} is {_kind(data[key])}, not {_kind(typ())}")
    if data.get("NSPrivacyTracking") is True:
        problems.append(f"{label}: NSPrivacyTracking is true; CLI Pulse does no tracking and its label says so")
    domains = data.get("NSPrivacyTrackingDomains")
    if isinstance(domains, list):
        if any(not isinstance(d, str) for d in domains):
            problems.append(f"{label}: NSPrivacyTrackingDomains holds something that is not a string")
        if domains:
            problems.append(f"{label}: NSPrivacyTrackingDomains lists {domains}; with tracking off it must be empty")

    apis = data.get("NSPrivacyAccessedAPITypes")
    if isinstance(apis, list):
        seen_cats: set[str] = set()
        for i, entry in enumerate(apis):
            where = f"{label}: NSPrivacyAccessedAPITypes[{i}]"
            if not isinstance(entry, dict):
                problems.append(f"{where}: is {_kind(entry)}, not a dictionary")
                continue
            for key in sorted(set(entry) - API_ENTRY_KEYS):
                problems.append(f"{where}: unknown key {key!r}")
            cat = entry.get("NSPrivacyAccessedAPIType")
            reasons = entry.get("NSPrivacyAccessedAPITypeReasons")
            if not isinstance(cat, str):
                problems.append(f"{where}: NSPrivacyAccessedAPIType is {'missing' if cat is None else _kind(cat)}, not a string")
                continue
            if cat not in CATEGORY_REASONS:
                problems.append(f"{where}: unknown category {cat!r}")
                continue
            if cat in seen_cats:
                problems.append(f"{where}: {cat} is declared twice")
            seen_cats.add(cat)
            if not isinstance(reasons, list):
                problems.append(f"{where}: NSPrivacyAccessedAPITypeReasons of {cat} is "
                                f"{'missing' if reasons is None else _kind(reasons)}, not an array")
                continue
            if not reasons:
                problems.append(f"{where}: {cat} has no NSPrivacyAccessedAPITypeReasons")
                continue
            seen_reasons: set[str] = set()
            for reason in reasons:
                if not isinstance(reason, str):
                    problems.append(f"{where}: a reason of {cat} is {_kind(reason)}, not a string")
                elif reason not in CATEGORY_REASONS[cat]:
                    problems.append(
                        f"{where}: reason {reason!r} is not a reason Apple defines for {cat} "
                        f"({', '.join(sorted(CATEGORY_REASONS[cat]))})"
                    )
                elif reason in seen_reasons:
                    problems.append(f"{where}: reason {reason} is listed twice for {cat}")
                else:
                    seen_reasons.add(reason)

    collected = data.get("NSPrivacyCollectedDataTypes")
    if isinstance(collected, list):
        seen_rows: set[tuple] = set()
        for i, entry in enumerate(collected):
            where = f"{label}: NSPrivacyCollectedDataTypes[{i}]"
            if not isinstance(entry, dict):
                problems.append(f"{where}: is {_kind(entry)}, not a dictionary")
                continue
            for key in sorted(set(entry) - DATA_ENTRY_KEYS):
                problems.append(f"{where}: unknown key {key!r}")
            for key in sorted(DATA_ENTRY_KEYS - set(entry)):
                problems.append(f"{where}: missing {key}")
            typ = entry.get("NSPrivacyCollectedDataType")
            if typ is not None and not isinstance(typ, str):
                problems.append(f"{where}: NSPrivacyCollectedDataType is {_kind(typ)}, not a string")
                typ = None
            elif typ is not None and typ not in DATA_TYPES:
                problems.append(f"{where}: unknown data type {typ!r}")
            for key in ("NSPrivacyCollectedDataTypeLinked", "NSPrivacyCollectedDataTypeTracking"):
                if key in entry and not isinstance(entry[key], bool):
                    problems.append(f"{where}: {key} is {_kind(entry[key])}, not a boolean")
            if entry.get("NSPrivacyCollectedDataTypeTracking") is True:
                problems.append(f"{where}: {typ} is marked as used for tracking")
            if "NSPrivacyCollectedDataTypePurposes" in entry:
                purposes = entry["NSPrivacyCollectedDataTypePurposes"]
                if not isinstance(purposes, list):
                    problems.append(f"{where}: NSPrivacyCollectedDataTypePurposes is {_kind(purposes)}, not an array")
                elif not purposes:
                    problems.append(f"{where}: {typ} has no purposes")
                else:
                    strs = []
                    for p in purposes:
                        if not isinstance(p, str):
                            problems.append(f"{where}: a purpose of {typ} is {_kind(p)}, not a string")
                        elif p not in PURPOSES:
                            problems.append(f"{where}: unknown purpose {p!r}")
                        else:
                            strs.append(p)
                    if len(set(strs)) != len(strs):
                        problems.append(f"{where}: {typ} lists a purpose twice")
            linked = entry.get("NSPrivacyCollectedDataTypeLinked")
            if typ is not None and isinstance(linked, bool):
                if (typ, linked) in seen_rows:
                    problems.append(f"{where}: {typ} (linked={linked}) is declared twice")
                seen_rows.add((typ, linked))


def declared_reasons(data) -> dict[str, set[str]]:
    """{category: {reasons}} from a manifest, ignoring malformed parts (which
    validate_manifest has already reported)."""
    out: dict[str, set[str]] = {}
    apis = (data or {}).get("NSPrivacyAccessedAPITypes") if isinstance(data, dict) else None
    for entry in apis if isinstance(apis, list) else []:
        if isinstance(entry, dict) and isinstance(entry.get("NSPrivacyAccessedAPIType"), str):
            reasons = entry.get("NSPrivacyAccessedAPITypeReasons")
            out[entry["NSPrivacyAccessedAPIType"]] = (
                {r for r in reasons if isinstance(r, str)} if isinstance(reasons, list) else set())
    return out


def collected_rows(data) -> list[tuple]:
    """(type, linked, tracking, purposes) for each well-formed collected row."""
    out = []
    rows = (data or {}).get("NSPrivacyCollectedDataTypes") if isinstance(data, dict) else None
    for entry in rows if isinstance(rows, list) else []:
        if not isinstance(entry, dict):
            continue
        typ = entry.get("NSPrivacyCollectedDataType")
        purposes = entry.get("NSPrivacyCollectedDataTypePurposes")
        linked = entry.get("NSPrivacyCollectedDataTypeLinked")
        tracking = entry.get("NSPrivacyCollectedDataTypeTracking")
        if not isinstance(typ, str) or not isinstance(purposes, list):
            continue
        if not isinstance(linked, bool) or not isinstance(tracking, bool):
            continue  # validate_manifest has reported it
        out.append((typ, entry.get("NSPrivacyCollectedDataTypeLinked"),
                    entry.get("NSPrivacyCollectedDataTypeTracking"),
                    tuple(sorted(p for p in purposes if isinstance(p, str)))))
    return out


def row_text(row: tuple) -> str:
    typ, linked, tracking, purposes = row
    short = [p.replace("NSPrivacyCollectedDataTypePurpose", "") for p in purposes]
    return f"{typ.replace('NSPrivacyCollectedDataType', '')} linked={linked} tracking={tracking} purposes={short}"


# ---------------------------------------------------------------------------
# project.pbxproj (an OpenStep property list)
# ---------------------------------------------------------------------------
class OpenStepParser:
    _BARE = re.compile(r"[A-Za-z0-9_$+/:.\-]+")

    def __init__(self, text: str):
        self.s = text
        self.i = 0

    def parse(self):
        self._skip()
        return self._value()

    def _skip(self):
        s = self.s
        while self.i < len(s):
            c = s[self.i]
            if c in " \t\r\n":
                self.i += 1
            elif s.startswith("//", self.i):
                nl = s.find("\n", self.i)
                self.i = len(s) if nl < 0 else nl + 1
            elif s.startswith("/*", self.i):
                end = s.find("*/", self.i + 2)
                if end < 0:
                    raise ValueError("unterminated comment")
                self.i = end + 2
            else:
                break

    def _value(self):
        self._skip()
        c = self.s[self.i]
        if c == "{":
            self.i += 1
            out = {}
            while True:
                self._skip()
                if self.s[self.i] == "}":
                    self.i += 1
                    return out
                key = self._value()
                self._skip()
                if self.s[self.i] != "=":
                    raise ValueError(f"expected '=' at {self.i}")
                self.i += 1
                out[key] = self._value()
                self._skip()
                if self.s[self.i] != ";":
                    raise ValueError(f"expected ';' at {self.i}")
                self.i += 1
        if c == "(":
            self.i += 1
            out = []
            while True:
                self._skip()
                if self.s[self.i] == ")":
                    self.i += 1
                    return out
                out.append(self._value())
                self._skip()
                if self.s[self.i] == ",":
                    self.i += 1
        if c == '"':
            self.i += 1
            buf = []
            while self.s[self.i] != '"':
                if self.s[self.i] == "\\":
                    self.i += 1
                    esc = self.s[self.i]
                    buf.append({"n": "\n", "t": "\t"}.get(esc, esc))
                else:
                    buf.append(self.s[self.i])
                self.i += 1
            self.i += 1
            return "".join(buf)
        m = self._BARE.match(self.s, self.i)
        if not m:
            raise ValueError(f"unexpected {c!r} at {self.i}")
        self.i = m.end()
        return m.group(0)


class Project:
    def __init__(self, pbxproj: Path, root: Path):
        text = pbxproj.read_text(encoding="utf-8")
        self.objects = OpenStepParser(text).parse()["objects"]
        # The project's files are relative to the folder holding the .xcodeproj.
        self.srcroot = pbxproj.parent.parent.relative_to(root)
        self.parent: dict[str, str] = {}
        for oid, obj in self.objects.items():
            if obj.get("isa") in ("PBXGroup", "PBXVariantGroup"):
                for child in obj.get("children", []):
                    self.parent[child] = oid

    def native_targets(self):
        return [(oid, obj) for oid, obj in self.objects.items() if obj.get("isa") == "PBXNativeTarget"]

    def target(self, name: str):
        for oid, obj in self.native_targets():
            if obj.get("name") == name:
                return oid, obj
        return None, None

    def path_of(self, ref_id: str) -> Path | None:
        parts = []
        node = ref_id
        tree = None
        while node is not None:
            o = self.objects.get(node, {})
            if o.get("path"):
                parts.append(o["path"])
            tree = o.get("sourceTree")
            if tree != "<group>":
                break
            node = self.parent.get(node)
        if tree in ("SOURCE_ROOT", "<group>", None):
            return Path(self.srcroot, *reversed(parts))
        return None  # BUILT_PRODUCTS_DIR, SDKROOT, ...

    def phases(self, target, isa: str):
        return [(pid, self.objects[pid]) for pid in target.get("buildPhases", [])
                if self.objects.get(pid, {}).get("isa") == isa]

    def phase_files(self, phase) -> list[tuple[str, dict, Path | None, str | None]]:
        out = []
        for bf in phase.get("files", []):
            bfo = self.objects.get(bf, {})
            ref = bfo.get("fileRef")
            product = None
            if bfo.get("productRef"):
                product = self.objects.get(bfo["productRef"], {}).get("productName")
            out.append((bf, bfo, self.path_of(ref) if ref else None, product))
        return out

    def linked_products(self, target) -> set[str]:
        out = {self.objects.get(dep, {}).get("productName") for dep in target.get("packageProductDependencies", [])}
        for _, fw in self.phases(target, "PBXFrameworksBuildPhase"):
            out |= {p for _, _, _, p in self.phase_files(fw) if p}
        out.discard(None)
        return out

    def configurations(self, owner) -> list[tuple[str, dict]]:
        """(id, XCBuildConfiguration) for a target's or the project's list."""
        lst = self.objects.get(owner.get("buildConfigurationList"), {})
        return [(c, self.objects.get(c, {})) for c in lst.get("buildConfigurations", [])]

    def project_object(self):
        return next(((oid, o) for oid, o in self.objects.items() if o.get("isa") == "PBXProject"), (None, {}))


# ---------------------------------------------------------------------------
# Swift source reading: comments and strings blanked, #if resolved
# ---------------------------------------------------------------------------
_TOKEN = re.compile(r'//|/\*|\*/|"""|"|\\\(|\\.|\(|\)|\n')


def blank_swift(text: str) -> tuple[str, str]:
    """Two views with the same length and line structure: code with comments
    and string contents blanked, and code with only comments blanked. Handles
    nested block comments, single- and multi-line strings, escapes and string
    interpolation, which is enough for an API-name search."""
    code: list[str] = []
    keep: list[str] = []
    depth = 0           # block comment nesting
    stack: list[str] = []  # "s" string, "m" multi-line string, "(" interpolation
    parens: list[int] = []  # open parens per interpolation
    i, n = 0, len(text)

    def put(code_text: str, keep_text: str) -> None:
        code.append(code_text)
        keep.append(keep_text)

    def emit(chunk: str, state: str) -> None:
        if state == "comment":
            put(" " * len(chunk), " " * len(chunk))
        elif state in ("s", "m"):
            put(" " * len(chunk), chunk)
        else:
            put(chunk, chunk)

    while i < n:
        m = _TOKEN.search(text, i)
        state = "comment" if depth else (stack[-1] if stack else "code")
        if m is None:
            emit(text[i:], state)
            break
        emit(text[i:m.start()], state)
        tok, i = m.group(0), m.end()
        if tok == "\n":
            put("\n", "\n")
            if state == "s":
                stack.pop()  # an unterminated string ends with its line
            continue
        if state == "comment":
            depth += 1 if tok == "/*" else (-1 if tok == "*/" else 0)
            emit(tok, "comment")
        elif state in ("s", "m"):
            if tok == "\\(":
                stack.append("(")
                parens.append(1)
                put("  ", tok)
            elif (tok == '"' and state == "s") or (tok == '"""' and state == "m"):
                stack.pop()
                put(tok, tok)
            elif tok == '"""':  # closes a one-line string; rescan the rest
                stack.pop()
                put('"', '"')
                i = m.start() + 1
            else:
                emit(tok, state)
        else:  # code, at top level or inside an interpolation
            if tok == "//":
                nl = text.find("\n", i)
                nl = n if nl < 0 else nl
                emit(text[m.start():nl], "comment")
                i = nl
            elif tok == "/*":
                depth = 1
                emit(tok, "comment")
            elif tok in ('"""', '"'):
                stack.append("m" if tok == '"""' else "s")
                put(tok, tok)
            elif tok == "(" and state == "(":
                parens[-1] += 1
                emit(tok, state)
            elif tok == ")" and state == "(":
                parens[-1] -= 1
                if parens[-1] == 0:
                    stack.pop()
                    parens.pop()
                    put(" ", tok)
                else:
                    emit(tok, state)
            else:
                emit(tok, state)
    return "".join(code), "".join(keep)


# canImport answers that do not depend on the SDK release: checked against the
# Xcode 27.1 SDKs (MacOSX, iPhoneOS and WatchOS 27.x). Anything not listed is
# unknown, and an unknown condition has both branches read: watchOS has UIKit,
# macOS 27 has ActivityKit, and older SDKs in CI may differ from this Mac's.
CAN_IMPORT = {
    "macos": {"AppKit": True, "UIKit": False, "Foundation": True, "Darwin": True, "SwiftUI": True, "Combine": True},
    "ios": {"AppKit": False, "UIKit": True, "Foundation": True, "Darwin": True, "SwiftUI": True, "Combine": True},
    "watchos": {"AppKit": False, "UIKit": True, "Foundation": True, "Darwin": True, "SwiftUI": True, "Combine": True},
}
OS_NAME = {"macos": "macOS", "ios": "iOS", "watchos": "watchOS"}
_KNOWN_OS = {"macOS", "iOS", "watchOS", "tvOS", "visionOS", "xrOS", "Linux", "Windows", "Android", "FreeBSD", "OpenBSD", "WASI", "OSX"}


def eval_condition(expr: str, platform: str):
    """Tri-state: True, False, or None. None (both branches read) for anything
    whose answer is not certain here: build flags (DEBUG, DEVID_BUILD, ...),
    compiler() / swift() / hasFeature() versions, arch(), targetEnvironment(),
    and canImport() of anything outside CAN_IMPORT. `expr` comes from the view
    with comments blanked, so a trailing `// && os(watchOS)` is not part of it."""
    tokens = re.findall(r"\|\||&&|!|\(|\)|[A-Za-z_][A-Za-z0-9_]*\s*\([^()]*\)|[A-Za-z_][A-Za-z0-9_]*|\S", expr)
    pos = 0

    def peek():
        return tokens[pos] if pos < len(tokens) else None

    def atom():
        nonlocal pos
        tok = peek()
        pos += 1
        if tok == "!":
            v = atom()
            return None if v is None else not v
        if tok == "(":
            v = disj()
            if peek() == ")":
                pos += 1
            return v
        m = re.match(r"(\w+)\s*\(([^()]*)\)$", tok or "")
        if m:
            fn, arg = m.group(1), m.group(2).strip()
            if fn == "os":
                return arg == OS_NAME[platform] if arg in _KNOWN_OS else None
            if fn == "canImport":
                return CAN_IMPORT[platform].get(arg.split(".")[0])
            return None  # compiler, swift, hasFeature, arch, targetEnvironment, ...
        if tok == "true":
            return True
        if tok == "false":
            return False
        return None  # a -D flag (DEBUG, DEVID_BUILD, ...) or something unparsed

    def conj():
        nonlocal pos
        v = atom()
        while peek() == "&&":
            pos += 1
            w = atom()
            v = False if (v is False or w is False) else (True if (v and w) else None)
        return v

    def disj():
        nonlocal pos
        v = conj()
        while peek() == "||":
            pos += 1
            w = conj()
            v = True if (v is True or w is True) else (False if (v is False and w is False) else None)
        return v

    try:
        value = disj()
    except Exception:
        return None
    return value if pos >= len(tokens) else None  # leftover tokens: not understood


_DIRECTIVE = re.compile(r"^\s*#(if|elseif|else|endif)\b(.*)$")


def active_lines(code_lines: list[str], platform: str) -> list[bool]:
    """For each line, whether it can be compiled for `platform`. Directives are
    read from the view with comments and strings blanked, so a `#if` inside a
    comment or a string is not one."""
    out = []
    stack = []  # frames: [state_of_current_branch, a_branch_was_definitely_taken, all_prior_definitely_false]
    for line in code_lines:
        m = _DIRECTIVE.match(line)
        if m:
            kind, rest = m.group(1), m.group(2).strip()
            if kind == "if":
                v = eval_condition(rest, platform)
                stack.append([v, v is True, v is False])
            elif kind in ("elseif", "else") and stack:
                frame = stack[-1]
                prev_true, all_false = frame[1], frame[2]
                v = True if kind == "else" else eval_condition(rest, platform)
                if prev_true:
                    state = False
                elif all_false:
                    state = v
                else:
                    state = False if v is False else None
                frame[0] = state
                frame[1] = prev_true or state is True
                frame[2] = all_false and state is False
            elif kind == "endif" and stack:
                stack.pop()
            out.append(False)
            continue
        out.append(all(f[0] is not False for f in stack))
    return out


# For each pattern, words one of which any match must contain. A file with none
# of them skips that pattern: a speed-up only, the regex still decides. Kept by
# hand because optional characters (`l?stat`, `f?statv?fs`) defeat extraction;
# `test_check_privacy_manifests.py` has a case per family that would go quiet
# if a needle were wrong.
# The stat family as a whole word ("static", "status" and "state" are not it).
_STAT_WORD = re.compile(r"(?<![A-Za-z])[lf]?stat(?:at|64|v?fs(?:64)?)?(?![A-Za-z])")
_NEEDLES = {
    "FileAttributeKey / URLResourceValues .creationDate / .modificationDate": ("creationDate", "modificationDate"),
    "NSDictionary fileModificationDate / fileCreationDate": ("fileModificationDate", "fileCreationDate"),
    "URLResourceKey .contentModificationDateKey / .creationDateKey": ("contentModificationDateKey", "creationDateKey"),
    "URLResourceValues.contentModificationDate": ("contentModificationDate",),
    "the ObjC names of the keys above": ("NSFile", "NSURL"),
    "stat / lstat / fstat / fstatat": _STAT_WORD,
    "getattrlist family": ("getattrlist",),
    "ProcessInfo.systemUptime": ("systemUptime",),
    "mach_absolute_time()": ("mach_absolute_time",),
    "mach_continuous_time() (not on Apple's list; same boot clock)": ("mach_continuous_time",),
    "sysctl KERN_BOOTTIME (how Sentry reads boot time)": ("KERN_BOOTTIME",),
    "URLResourceKey volume capacity keys": ("Capacity",),
    "URLResourceValues volume capacity": ("Capacity",),
    "FileAttributeKey .systemFreeSize / .systemSize": ("systemFreeSize", "systemSize"),
    "FileManager.attributesOfFileSystem (free/total size)": ("attributesOfFileSystem",),
    "statfs / statvfs / fstatfs / fstatvfs": _STAT_WORD,
    "UITextInputMode.activeInputModes": ("activeInputModes",),
    "UserDefaults": ("UserDefaults",),
    "@AppStorage (UserDefaults underneath)": ("AppStorage",),
    "sysctlbyname(\"kern.boottime\")": ("kern.boottime",),
}


def _compile(patterns):
    return [(cats, re.compile(rx), what, _NEEDLES[what]) for cats, rx, what in patterns]


_CODE_RX = _compile(SOURCE_PATTERNS)
_STRING_RX = _compile(SOURCE_PATTERNS_STRINGS)
_SYSDEF_RX = [(re.compile(rx), what) for rx, what in SYSTEM_DEFAULTS_PATTERNS]
_SCAN_CACHE: dict = {}


class SourceFile:
    """One file, read once per content; views per platform on demand."""

    def __init__(self, raw: str, swift: bool):
        self.raw = raw
        self.swift = swift
        if swift:
            self.code, self.keep = blank_swift(raw)
        else:  # C / ObjC (the vendored decoder): read as is
            self.code = self.keep = raw
        self.line_starts = [0] + [m.end() for m in re.finditer("\n", raw)]
        self.raw_lines = raw.split("\n")
        self._views: dict[str, tuple[str, str]] = {}
        self._hits: dict[str, list] = {}
        self._sysdef: dict[str, list] = {}

    def line_of(self, offset: int) -> int:
        return bisect.bisect_right(self.line_starts, offset)

    def views(self, platform: str) -> tuple[str, str]:
        """(code, keep) with lines this platform does not compile blanked."""
        if platform not in self._views:
            if not self.swift:
                self._views[platform] = (self.code, self.keep)
            else:
                code_lines = self.code.split("\n")
                active = active_lines(code_lines, platform)
                keep_lines = self.keep.split("\n")
                c = "\n".join(line if a else " " * len(line) for line, a in zip(code_lines, active))
                k = "\n".join(line if a else " " * len(line) for line, a in zip(keep_lines, active))
                self._views[platform] = (c, k)
        return self._views[platform]

    def hits(self, platform: str):
        """[(category, line, what, text, is_app_group)] on lines `platform` compiles."""
        if platform in self._hits:
            return self._hits[platform]
        out = []
        def present(needles) -> bool:
            if isinstance(needles, re.Pattern):
                return needles.search(self.keep) is not None
            return any(n in self.keep for n in needles)

        candidates = [(view_index, cats, rx, what) for view_index, table in ((0, _CODE_RX), (1, _STRING_RX))
                      for cats, rx, what, needles in table if present(needles)]
        if candidates:
            views = self.views(platform)
            group_lines = {self.line_of(m.start()) for m in APP_GROUP_DEFAULTS.finditer(views[0])}
            for view_index, cats, rx, what in candidates:
                for m in rx.finditer(views[view_index]):
                    line = self.line_of(m.start())
                    for cat in cats:
                        out.append((cat, line, what, self.raw_lines[line - 1].strip(), line in group_lines))
        self._hits[platform] = out
        return out

    def system_key_bindings(self) -> set[str]:
        """Names this file binds to a system key, whatever the platform."""
        if "_bindings" not in self.__dict__:
            self._bindings = {a or b for a, b in SYSTEM_KEY_BINDING.findall(self.keep)}
        return self._bindings

    def system_defaults_reads(self, platform: str, bound: frozenset = frozenset()):
        """[(line, what, text)]: reads of defaults the system writes. `bound`:
        the names bound to system keys anywhere in the target."""
        key = (platform, bound)
        if key in self._sysdef:
            return self._sysdef[key]
        out = []
        if any(n in self.keep for n in ("forKey", "dictionaryRepresentation", "globalDomain", "suiteName",
                                        "persistentDomain", "AppStorage")):
            code, keep = self.views(platform)
            for rx, what in _SYSDEF_RX:
                view = code if "dictionaryRepresentation" in rx.pattern or "globalDomain" in rx.pattern else keep
                for m in rx.finditer(view):
                    line = self.line_of(m.start())
                    out.append((line, what, self.raw_lines[line - 1].strip()))
            names = sorted(n for n in bound if n in code)
            if names:
                ident = r"(?:(?:Self|[A-Z]\w*)\s*\.\s*)?(" + "|".join(map(re.escape, names)) + r")\b(?:\s*\.\s*rawValue\b)?"
                for prefix, how in ((DEFAULTS_GETTER, ", through UserDefaults"), (APPSTORAGE_KEY, ", through @AppStorage")):
                    for m in re.finditer(prefix + ident, code):
                        line = self.line_of(m.start())
                        out.append((line, f"a key the system writes ({m.group(1)}){how}", self.raw_lines[line - 1].strip()))
        self._sysdef[key] = out
        return out

    def matches(self, platform: str, pattern: str) -> bool:
        code, _ = self.views(platform)
        return re.search(pattern, code) is not None


def source_file(path: Path) -> SourceFile:
    raw = path.read_text(encoding="utf-8", errors="replace")
    entry = _SCAN_CACHE.get(path)
    if entry is None or entry.raw != raw:
        entry = _SCAN_CACHE[path] = SourceFile(raw, path.suffix == ".swift")
    return entry


# ---------------------------------------------------------------------------
# The repo check
# ---------------------------------------------------------------------------
SCANNED_SUFFIXES = {".swift", ".c", ".h", ".m"}
NEVER_COMPILED = {".xcprivacy", ".plist", ".strings", ".xcassets", ".json", ".txt", ".entitlements"}


def entitlement_groups(path: Path) -> list[str]:
    try:
        data = plistlib.loads(path.read_bytes())
    except Exception:
        return []
    groups = data.get("com.apple.security.application-groups") if isinstance(data, dict) else None
    return [g for g in groups if isinstance(g, str)] if isinstance(groups, list) else []


def _split_top(text: str, code: str, start: int, end: int) -> list[tuple[int, int]]:
    """Spans of the comma-separated items between start and end at bracket
    depth 0, read on `code` (strings blanked, so a comma in a string is not one)."""
    items, depth, item_start = [], 0, start
    for i in range(start, end):
        c = code[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "," and depth == 0:
            items.append((item_start, i))
            item_start = i + 1
    if text[item_start:end].strip():
        items.append((item_start, end))
    return items


def _closing(code: str, open_index: int) -> int:
    """Index of the bracket closing the one at open_index."""
    depth = 0
    for i in range(open_index, len(code)):
        if code[i] in "([{":
            depth += 1
        elif code[i] in ")]}":
            depth -= 1
            if depth == 0:
                return i
    raise ValueError("unbalanced brackets in Package.swift")


def _labelled_args(keep: str, code: str, open_paren: int) -> dict[str, tuple[int, int]]:
    """{label: (start, end)} of a call's arguments (unlabelled ones as "_0", "_1")."""
    close = _closing(code, open_paren)
    out, n = {}, 0
    for a, b in _split_top(keep, code, open_paren + 1, close):
        m = re.match(r"\s*(\w+)\s*:", code[a:b])
        if m and not code[a:b].lstrip().startswith("."):
            out[m.group(1)] = (a + m.end(), b)
        else:
            out[f"_{n}"] = (a, b)
            n += 1
    return out


def _string(keep: str, span) -> str | None:
    m = re.fullmatch(r'\s*"([^"]*)"\s*', keep[span[0]:span[1]]) if span else None
    return m.group(1) if m else None


def _literal(keep: str, span, out: dict, what: str) -> str | None:
    """`_string`, but an argument that is present and not a plain string literal
    (a constant, an expression, an interpolation) is recorded as unparsed: read
    as "absent" it would let `path: somePath` build from a folder the check
    never scans while comparing equal to a record that has no path."""
    if span is None:
        return None
    value = _string(keep, span)
    if value is None:
        out["unparsed"].append(f"{what} is not a string literal: {keep[span[0]:span[1]].strip()[:60]}")
    return value


def parse_package(text: str) -> dict:
    """The declarations of a Package.swift that decide what is compiled:
    {"targets": {name: {"kind", "path", "dependencies"}}, "urls": [...],
     "paths": [...] (local packages), "unparsed": [...]} . Only an array
    literal `targets: [...]` of `.target(...)`-style calls is understood;
    anything else lands in "unparsed", which the caller fails on."""
    code, keep = blank_swift(text)
    out = {"targets": {}, "urls": [], "paths": [], "unparsed": []}
    for m in re.finditer(r"\.package\s*\(", code):
        args = _labelled_args(keep, code, m.end() - 1)
        if "url" in args:
            out["urls"].append(_literal(keep, args["url"], out, ".package url:"))
        elif "path" in args:
            out["paths"].append(_literal(keep, args["path"], out, ".package path:"))
        else:
            out["unparsed"].append(keep[m.start():_closing(code, m.end() - 1) + 1].strip()[:80])
    pm = re.search(r"\bPackage\s*\(", code)
    pargs = _labelled_args(keep, code, pm.end() - 1) if pm else {}
    span = pargs.get("targets")
    lb = code.find("[", span[0], span[1]) if span else -1
    if lb < 0 or code[span[0]:lb].strip():
        out["unparsed"].append("no `targets: [...]` array literal in Package(...)")
        return out
    close = _closing(code, lb)
    for a, b in _split_top(keep, code, lb + 1, close):
        item = code[a:b]
        km = re.match(r"\s*\.(\w+)\s*\(", item)
        if not km:
            out["unparsed"].append(keep[a:b].strip()[:80])
            continue
        args = _labelled_args(keep, code, a + km.end() - 1)
        name = _literal(keep, args.get("name"), out, f".{km.group(1)} name:")
        deps = []
        if "dependencies" in args:
            da, db = args["dependencies"]
            lb = code.index("[", da)
            for x, y in _split_top(keep, code, lb + 1, _closing(code, lb)):
                dep = keep[x:y].strip()
                dm = re.match(r'"([^"]+)"$', dep)
                if dm:
                    deps.append(f"target:{dm.group(1)}")
                    continue
                cm = re.match(r"\.(\w+)\s*\(", code[x:y].strip())
                if cm:
                    dargs = _labelled_args(keep, code, code.index("(", x))
                    dname = _string(keep, dargs.get("name"))
                    pkg_name = _string(keep, dargs.get("package"))
                    deps.append(f"{cm.group(1)}:{dname}" + (f"@{pkg_name}" if pkg_name else ""))
                else:
                    deps.append(f"unparsed:{dep[:40]}")
        out["targets"][name or f"?{len(out['targets'])}"] = {
            "kind": km.group(1), "path": _literal(keep, args.get("path"), out, f".{km.group(1)} path:"),
            "dependencies": sorted(deps)}
    return out


def package_checks(root: Path, cfg: dict, project, problems: list[str]) -> None:
    pkg = cfg["package"]
    base = root / pkg["path"]
    where = f"{pkg['path']}/Package.swift"
    parsed = parse_package((base / "Package.swift").read_text(encoding="utf-8"))
    for item in parsed["unparsed"]:
        problems.append(f"{where}: cannot read {item!r}; this check understands a `targets: [...]` literal of "
                        f"`.target(...)` calls and `.package(url:/path:)` only")
    for url in parsed["urls"]:
        if url not in pkg["dependencies"]:
            problems.append(f"{where}: depends on {url}, which {CONFIG} has not reviewed; "
                            f"measure what it links (--archive) and record it")
    for path in parsed["paths"]:
        problems.append(f"{where}: depends on the local package at {path}, whose sources this check does not scan; "
                        f"review it and record it in {CONFIG}")
    reviewed = pkg["targets"]
    for name, decl in parsed["targets"].items():
        want = reviewed.get(name)
        got = {"kind": decl["kind"], "path": decl["path"], "dependencies": decl["dependencies"]}
        if want is None:
            problems.append(f"{where}: declares {decl['kind']} {name!r} (path {decl['path'] or 'default'}), which the "
                            f"reviewed record in {CONFIG} does not list, so its sources are not scanned")
            continue
        have = {"kind": want.get("kind"), "path": want.get("path"), "dependencies": sorted(want.get("dependencies", []))}
        if got != have:
            problems.append(f"{where}: {name!r} is declared as {got}, but the reviewed record says {have}")
        default = ("Tests/" if decl["kind"] == "testTarget" else "Sources/") + name
        if want.get("sources") != (decl["path"] or default):
            problems.append(f"{CONFIG}: package target {name!r} is scanned at {want.get('sources')}, but "
                            f"{where} builds it from {decl['path'] or default}")
    for name in reviewed:
        if name not in parsed["targets"]:
            problems.append(f"{CONFIG}: package target {name!r} is not declared in {where}; remove it from the record")
    present = sorted(p.name for p in (base / "Sources").iterdir() if p.is_dir())
    for name in present:
        if name not in pkg["targets"]:
            problems.append(f"{pkg['path']}/Sources/{name}: a package target {CONFIG} does not list, so its "
                            f"sources are not scanned")
    for oid, obj in project.objects.items():
        if obj.get("isa") == "XCLocalSwiftPackageReference":
            rel = (project.srcroot / obj.get("relativePath", "")).as_posix()
            if rel != pkg["path"]:
                problems.append(f"{cfg['project']}: links the local package {rel}, which {CONFIG} does not review; "
                                f"its sources are not scanned")
    resolved = json.loads((root / cfg["package_resolved"]).read_text(encoding="utf-8"))
    pins = {p.get("identity"): (p.get("state") or {}).get("version") for p in resolved.get("pins", [])}
    for sdk, info in cfg["sdks"].items():
        if pins.get(sdk) != info["version"]:
            problems.append(f"{cfg['package_resolved']}: {sdk} is pinned at {pins.get(sdk)}, but binary_categories "
                            f"were measured with {info['version']}; archive, run --archive, and update {CONFIG}")


SOURCE_FILTER_KEY = re.compile(r"^(?:EXCLUDED|INCLUDED)_SOURCE_FILE_NAMES(?:\[.*\])?$")


def source_filter_settings(project, owner, owner_name, cfg, problems, used) -> None:
    """Build settings that can keep a file out of a target, in any
    configuration, conditional (`[sdk=...]`, `[arch=...]`) or not, and
    .xcconfig files, whose settings this check does not read: each fails
    unless the reviewed record lists it (`reviewed_build_settings`). Resolving
    which configuration ships and what a pattern matches is left to review."""
    reviewed = cfg.get("reviewed_build_settings", [])
    for cid, conf in project.configurations(owner):
        cname = conf.get("name", "?")
        if conf.get("baseConfigurationReference"):
            ref = conf["baseConfigurationReference"]
            path = project.path_of(ref)
            entry = {"owner": owner_name, "configuration": cname, "key": "baseConfigurationReference", "value": str(path)}
            if entry in [{k: r.get(k) for k in entry} for r in reviewed]:
                used.add(json.dumps(entry, sort_keys=True))
            else:
                problems.append(f"{owner_name}: configuration {cname} ({cid}) is based on {path} (an .xcconfig), whose "
                                f"settings this check does not read; record it in reviewed_build_settings after review")
        for key, value in (conf.get("buildSettings") or {}).items():
            if not SOURCE_FILTER_KEY.match(str(key)):
                continue
            entry = {"owner": owner_name, "configuration": cname, "key": key, "value": value}
            if entry in [{k: r.get(k) for k in entry} for r in reviewed]:
                used.add(json.dumps(entry, sort_keys=True))
                continue
            problems.append(f"{owner_name}: build setting \"{key}\" = {value!r} in configuration {cname} ({cid}) can "
                            f"leave files, the privacy manifest among them, out of the bundle; not in the reviewed record")


def check_repo(root: Path, verbose: bool) -> list[str]:
    problems: list[str] = []
    cfg = json.loads((root / CONFIG).read_text(encoding="utf-8"))
    allow = json.loads((root / ALLOWLIST).read_text(encoding="utf-8"))
    allow_entries = allow.get("entries", [])
    allow_used = [False] * len(allow_entries)
    project = Project(root / cfg["project"], root)
    label_rows = [(r["type"], r["linked"], r["tracking"], tuple(sorted(r["purposes"]))) for r in cfg["label"]["rows"]]
    covered = set()

    # Arrangements the source scan cannot see.
    for oid, obj in project.objects.items():
        if str(obj.get("isa", "")).startswith("PBXFileSystemSynchronized"):
            problems.append(f"{cfg['project']}: {obj['isa']} {oid} ({obj.get('path', '?')}): synchronized folders "
                            f"are not mapped to targets by this check; list the files in the target instead")
    for remote in (o for o in project.objects.values() if o.get("isa") == "XCRemoteSwiftPackageReference"):
        problems.append(f"{cfg['project']}: remote package {remote.get('repositoryURL')} is linked straight into the "
                        f"project; review what it links and record it in {CONFIG}")
    package_checks(root, cfg, project, problems)
    reviewed_settings_used: set[str] = set()
    _, project_obj = project.project_object()
    source_filter_settings(project, project_obj, "project", cfg, problems, reviewed_settings_used)

    # Every bundle-shipping target is listed or exempted.
    listed = {t["name"] for t in cfg["targets"]}
    exempt = cfg.get("exempt_targets", {})
    existing = set()
    for _, obj in project.native_targets():
        name, ptype = obj.get("name"), str(obj.get("productType", ""))
        existing.add(name)
        if ptype.startswith(BUNDLE_PRODUCT_TYPES) and name not in listed and name not in exempt:
            problems.append(f"target {name!r} ({ptype}) ships a bundle but is not in {CONFIG}; add it with its "
                            f"manifest and reviewed record, or exempt it there with a reason")
    for name in exempt:
        if name not in existing:
            problems.append(f"{CONFIG}: exempt_targets names {name!r}, which is not a target; remove it")

    pkg = cfg["package"]
    package_files: dict[str, list[Path]] = {}
    for tname, tinfo in pkg["targets"].items():
        base = root / pkg["path"] / tinfo["sources"]
        files = sorted(p for p in base.rglob("*") if p.is_file())
        for f in files:
            if f.suffix in (".mm", ".cpp", ".cc", ".cxx", ".s", ".S"):
                problems.append(f"{f.relative_to(root)}: {f.suffix} sources are not scanned by this check")
        package_files[tname] = [f for f in files if f.suffix in SCANNED_SUFFIXES]

    for t in cfg["targets"]:
        name, platform = t["name"], t["platform"]
        mpath = Path(t["manifest"])
        label = str(mpath)
        data = load_manifest(root / mpath, label, problems)
        if data is not None:
            validate_manifest(data, label, problems)
        declared = declared_reasons(data)

        tid, target = project.target(name)
        if target is None:
            problems.append(f"{name}: no such target in {cfg['project']}")
            continue

        # 1. The manifest ships: in this target's Resources phase, unfiltered.
        res_phases = project.phases(target, "PBXResourcesBuildPhase")
        found = [(pid, ph, bf, bfo) for pid, ph in res_phases
                 for bf, bfo, p, _ in project.phase_files(ph) if p == mpath]
        if not found:
            where = (f"Resources build phase ({', '.join(pid for pid, _ in res_phases)})" if res_phases
                     else "Resources build phase (the target has none)")
            problems.append(f"{name}: {mpath} is not in the target's {where}, so it is not copied into the bundle")
        for pid, ph, bf, bfo in found:
            for key in ("platformFilter", "platformFilters"):
                if key in bfo:
                    problems.append(f"{name}: the manifest's build file {bf} carries {key} = {bfo[key]}, which "
                                    f"can leave it out of the {name} bundle; remove the filter")
            settings = bfo.get("settings") or {}
            if settings:
                problems.append(f"{name}: the manifest's build file {bf} carries settings {settings}; a resource "
                                f"copied as-is needs none")
            if str(ph.get("runOnlyForDeploymentPostprocessing", "0")) != "0":
                problems.append(f"{name}: Resources phase {pid} runs only for deployment postprocessing, so the "
                                f"manifest is missing from ordinary builds")
        source_filter_settings(project, target, name, cfg, problems, reviewed_settings_used)
        for other in cfg["targets"]:
            if other is t:
                continue
            _, ot = project.target(other["name"])
            if ot is not None and any(p == mpath for _, ph in project.phases(ot, "PBXResourcesBuildPhase")
                                      for _, _, p, _ in project.phase_files(ph)):
                problems.append(f"{name}: {mpath} is also in {other['name']}'s Resources phase; each bundle carries its own")

        # 2. What it compiles.
        files: list[Path] = []
        for _, src in project.phases(target, "PBXSourcesBuildPhase"):
            for bf, _, p, product in project.phase_files(src):
                if p is None:
                    continue
                if p.suffix in SCANNED_SUFFIXES:
                    files.append(root / p)
                elif p.suffix not in NEVER_COMPILED:
                    problems.append(f"{name}: compiles {p}, a {p.suffix or 'suffix-less'} file this check does not scan")
        products = project.linked_products(target)
        for product in sorted(products - set(cfg.get("reviewed_products", []))):
            problems.append(f"{name}: links package product {product!r}, which {CONFIG} has not reviewed")
        if pkg["product"] in products:
            for tname, tinfo in pkg["targets"].items():
                if platform in tinfo["platforms"]:
                    files += package_files[tname]
        groups = entitlement_groups(root / t["entitlements"]) if t.get("entitlements") else []

        used: dict[str, list] = {}
        group_uses = []
        sysdef = []
        compiled: dict[str, SourceFile] = {}
        for f in files:
            if not f.is_file():
                problems.append(f"{name}: compiles {f.relative_to(root)}, which does not exist")
                continue
            compiled[f.relative_to(root).as_posix()] = source_file(f)
        # Names bound to system keys anywhere in what this target compiles, so
        # `forKey: Keys.lang` in one file finds `static let lang = "AppleLanguages"` in another.
        bound = frozenset().union(*(sf.system_key_bindings() for sf in compiled.values()))

        for rel, sf in compiled.items():
            def allowed(cat, text, rel=rel):
                hit = False
                for k, e in enumerate(allow_entries):
                    if e["target"] == name and e["category"] == cat and e["file"] == rel and re.search(e["pattern"], text):
                        allow_used[k] = True
                        hit = True
                return hit

            for cat, no, what, text, is_group in sf.hits(platform):
                if allowed(cat, text):
                    continue
                used.setdefault(cat, []).append((rel, no, what, text))
                if is_group:
                    group_uses.append((rel, no))
            for no, what, text in sf.system_defaults_reads(platform, bound):
                if not allowed(SYSTEM_DEFAULTS, text):
                    sysdef.append((rel, no, what, text))

        for rel, no, what, text in sysdef:
            problems.append(f"{name}: {rel}:{no} reads {what}; no UserDefaults reason covers "
                            f"what the system or another app wrote (CA92.1 is the app's own values, 1C8F.1 its app group)")
        for cat, hits in sorted(used.items()):
            if cat not in declared:
                rel, no, what, text = hits[0]
                more = f" (and {len(hits) - 1} more)" if len(hits) > 1 else ""
                problems.append(f"{name}: {rel}:{no} uses {what} ({cat}){more}, which {label} does not declare")
        measured = set(t.get("binary_categories", []))
        for cat in sorted(measured - set(declared)):
            problems.append(f"{name}: the archived binary links {SHORT.get(cat, cat)} ({cat}, recorded in {CONFIG} "
                            f"binary_categories), which {label} does not declare")
        defaults_reasons = declared.get(CAT_DEFAULTS, set())
        if group_uses and groups and CAT_DEFAULTS in declared and APP_GROUP_REASON not in defaults_reasons:
            rel, no = group_uses[0]
            problems.append(f"{name}: uses app-group UserDefaults ({rel}:{no}) and is entitled to {groups[0]}, "
                            f"but {label} does not declare reason {APP_GROUP_REASON} for {CAT_DEFAULTS}")
        if APP_GROUP_REASON in defaults_reasons and not groups:
            problems.append(f"{name}: {label} declares {APP_GROUP_REASON} (app group) but "
                            f"{t.get('entitlements')} grants no app group")

        # 3. The reviewed record: categories and reasons exactly, each reason
        #    still resting on code this target compiles.
        record = {cat: set(rs) for cat, rs in t["reasons"].items()}
        if data is not None and declared != record:
            for cat in sorted(set(declared) | set(record)):
                have, want = sorted(declared.get(cat, set())), sorted(record.get(cat, set()))
                if have != want:
                    problems.append(f"{name}: {label} declares {SHORT.get(cat, cat)} reasons {have or 'none'}, "
                                    f"but the reviewed record in {CONFIG} is {want or 'none'}")
        for cat, reasons in t["reasons"].items():
            for reason, info in reasons.items():
                for ev in info.get("evidence", []):
                    if "sdk" in ev:
                        sdk = cfg["sdks"].get(ev["sdk"])
                        if sdk is None or cat not in sdk["categories"] or pkg["product"] not in products:
                            problems.append(f"{name}: {SHORT.get(cat, cat)} {reason} cites SDK {ev['sdk']}, which "
                                            f"{name} does not link or which does not use that category per {CONFIG}")
                        continue
                    sf = compiled.get(ev["file"])
                    if sf is None or not sf.matches(platform, ev["match"]):
                        problems.append(f"{name}: {SHORT.get(cat, cat)} {reason} cites {ev['file']} /{ev['match']}/, "
                                        f"which no longer matches a line {name} compiles; re-review the reason and "
                                        f"update {CONFIG}")
        for cat in sorted(set(record) - set(used) - measured):
            problems.append(f"{name}: the record declares {cat}, but neither the sources {name} compiles nor its "
                            f"measured binary use it; remove it")

        # 4. Collected data: the reviewed rows exactly, each a label row.
        want_rows = [(r["type"], r["linked"], r["tracking"], tuple(sorted(r["purposes"]))) for r in t["collected"]]
        for row in want_rows:
            if row not in label_rows:
                problems.append(f"{CONFIG}: {name} records {row_text(row)}, which is not a row of the published label")
            covered.add(row)
        if data is not None:
            have_rows = collected_rows(data)
            for row in sorted(set(have_rows) - set(want_rows)):
                same = [row_text(r) for r in want_rows if r[0] == row[0]]
                hint = f" (the record has {'; '.join(same)})" if same else " (the record has no such type for this target)"
                problems.append(f"{name}: {label} collects {row_text(row)}, which is not in its reviewed record{hint}")
            for row in sorted(set(want_rows) - set(have_rows)):
                problems.append(f"{name}: {label} is missing the reviewed row {row_text(row)}")

        if verbose:
            print(f"--- {name} ({platform}): {len(files)} source files")
            for cat, hits in sorted(used.items()):
                print(f"    {SHORT[cat]:15} {len(hits):3} use(s), first {hits[0][0]}:{hits[0][1]}  "
                      f"declared {sorted(declared.get(cat, set())) or 'NO'}")
            print(f"    binary_categories: {sorted(SHORT[c] for c in measured)}")

    for row in label_rows:
        if row not in covered:
            problems.append(f"label row {row_text(row)} is recorded for no target")
    for r in cfg.get("reviewed_build_settings", []):
        entry = {k: r.get(k) for k in ("owner", "configuration", "key", "value")}
        if json.dumps(entry, sort_keys=True) not in reviewed_settings_used:
            problems.append(f"{CONFIG}: reviewed_build_settings entry {entry} matches nothing; remove it")
    for k, e in enumerate(allow_entries):
        if not allow_used[k]:
            problems.append(f"{ALLOWLIST}: entry {k} ({e['target']}, {e['file']}) matches nothing; remove it")
    return problems


# ---------------------------------------------------------------------------
# Archive mode
# ---------------------------------------------------------------------------
def run(cmd: list[str], stdin: str | None = None) -> str:
    """A tool's stdout; any failure stops the check ("could not check")
    rather than yielding a partial measurement."""
    try:
        proc = subprocess.run(cmd, input=stdin, capture_output=True, text=True, check=False)
    except OSError as exc:
        raise CheckError(f"{cmd[0]} {' '.join(cmd[1:2])}: {exc}") from exc
    if proc.returncode != 0:
        raise CheckError(f"{' '.join(cmd[:3])} exited {proc.returncode}: {proc.stderr.strip()[:500]}")
    return proc.stdout


def binary_categories(exe: Path) -> dict[str, list[str]]:
    if not exe.is_file():
        raise CheckError(f"{exe}: no such executable")
    found: dict[str, list[str]] = {}
    imports = run(["xcrun", "nm", "-u", str(exe)]).split()
    for sym in sorted(set(imports)):
        for cat in BINARY_IMPORTS.get(sym, ()):
            found.setdefault(cat, []).append(sym)
    demangled = run(["xcrun", "swift-demangle", "--simplified"], "\n".join(sorted(set(imports))))
    for line in demangled.splitlines():
        for cat, rx in BINARY_DEMANGLED:
            if rx.search(line) and not line.startswith("_OBJC_CLASS_$_NSUserDefaults"):
                found.setdefault(cat, []).append(line.strip()[:120])
    strings = set(run(["strings", "-a", str(exe)]).splitlines())
    for s, cat in BINARY_STRINGS.items():
        if s in strings:
            found.setdefault(cat, []).append(f'"{s}"')
    return {k: sorted(set(v)) for k, v in found.items()}


def check_archives(root: Path, archives: list[Path]) -> list[str]:
    if not shutil.which("xcrun"):
        raise CheckError("archive mode needs xcrun (macOS with Xcode)")
    problems: list[str] = []
    cfg = json.loads((root / CONFIG).read_text(encoding="utf-8"))
    for archive in archives:
        kind = None
        apps = list((archive / "Products" / "Applications").glob("*.app"))
        for t in cfg["targets"]:
            if apps and Path(t["bundle"]["path"]).parts[2] == apps[0].name:
                kind = t["bundle"]["archive"]
        if kind is None:
            problems.append(f"{archive}: no application this config knows ({[a.name for a in apps]})")
            continue
        print(f"=== {archive.name} ({kind})")
        print("    every .xcprivacy in the archive:")
        for p in sorted(archive.rglob("*.xcprivacy")):
            print(f"      {p.relative_to(archive)}")
        for t in cfg["targets"]:
            b = t["bundle"]
            if b["archive"] != kind:
                continue
            bundle = archive / b["path"]
            mpath = bundle / b["manifest"]
            label = f"{t['name']}: {mpath.relative_to(archive)}"
            plist = None
            if not mpath.is_file():
                problems.append(f"{label} is missing from the archive")
            else:
                plist = load_manifest(mpath, label, problems)
            if plist is not None:
                validate_manifest(plist, label, problems)
                repo = plistlib.loads((root / t["manifest"]).read_bytes())
                if plist != repo:
                    problems.append(f"{label} differs from {t['manifest']} (archive built from another tree?)")
            exe = bundle / b["executable"]
            found = binary_categories(exe)
            declared = declared_reasons(plist)
            print(f"    {t['name']}: {exe.relative_to(archive)}")
            print(f"      manifest: {mpath.relative_to(archive)}")
            for cat in sorted(found):
                print(f"      {SHORT[cat]:15} declared={sorted(declared.get(cat, set())) or 'NO'}  via {', '.join(found[cat][:6])}")
            for cat in sorted(set(found) - set(declared)):
                problems.append(f"{t['name']}: the archived binary links {cat} ({', '.join(found[cat][:3])}), "
                                f"which its manifest does not declare")
            if set(found) != set(t.get("binary_categories", [])):
                problems.append(
                    f"{t['name']}: {CONFIG} binary_categories {sorted(SHORT[c] for c in t.get('binary_categories', []))} "
                    f"does not match the measurement {sorted(SHORT[c] for c in found)}"
                )
    return problems


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--root", type=Path, default=ROOT, help="repository root (tests point this at a copy)")
    ap.add_argument("--archive", type=Path, action="append", default=[], help="an .xcarchive to verify (macOS)")
    ap.add_argument("-v", "--verbose", action="store_true", help="print what each target uses")
    args = ap.parse_args(argv)
    root = args.root.resolve()
    try:
        problems = check_archives(root, args.archive) if args.archive else check_repo(root, args.verbose)
    except (CheckError, OSError, ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
        print(f"check_privacy_manifests: could not check: {exc}", file=sys.stderr)
        return 2
    for p in problems:
        print(f"FAIL: {p}")
    what = "archive" if args.archive else "privacy manifests"
    if problems:
        print(f"check_privacy_manifests: {len(problems)} problem(s) in the {what}")
        return 1
    print(f"check_privacy_manifests: OK ({what})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
