#!/usr/bin/env python3
"""Privacy manifests (PrivacyInfo.xcprivacy) checked against Apple's vocabulary,
the project, the code each target compiles, and the published App Store label.

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

WHAT IT CHECKS (stdlib only, runs on the Linux CI runner: no plutil there)
-------------------------------------------------------------------------
1. Semantics of every manifest named in scripts/privacy_manifests.json: UTF-8
   without a BOM, parses as an XML plist (plistlib, the plutil -lint
   equivalent), only the four top-level keys Apple defines and each with its
   type, known category / reason / data-type / purpose strings, a reason that
   belongs to its category, no duplicates, tracking off with no domains.
2. The project: each manifest is in its own target's Resources build phase
   (project.pbxproj, parsed as an OpenStep plist).
3. Drift: the sources each target compiles (its own Sources phase plus
   CLIPulseCore, with `#if os(...)` / `canImport(...)` resolved for the
   target's platform) are searched for the required-reason APIs below. A
   category the code uses and the manifest does not declare fails, as does
   app-group UserDefaults without reason 1C8F.1 in a target entitled to the
   group. `binary_categories` in the config records what the archived binary
   was measured to link (Sentry's merged code included, which no source here
   shows); those must be declared too. A category declared with no use in
   either fails, so the manifests cannot drift the other way either.
   Reviewed exceptions: scripts/privacy_manifests_allowlist.json (an entry
   that no longer matches anything fails).
4. Collected data: every NSPrivacyCollectedDataTypes entry must be one of the
   rows of the published label in the config (type, linked, tracking and
   purposes exactly), and every label row must be declared by some target.

The reason chosen for each call site, and why it meets Apple's whole reason
text, is recorded in the PR that added this check (1.63 A3); this script only
keeps the manifests from drifting away from that review.

ARCHIVE MODE (macOS only: needs xcrun)
-------------------------------------
    python3 scripts/check_privacy_manifests.py --archive <x.xcarchive> [...]
lists every .xcprivacy in the archive, requires each target's manifest at its
bundle's path with the same content as the repo's, and reads each target's
executable (nm -u, swift-demangle, the ObjC selector strings) for the
required-reason APIs it links. A category the binary links that the target's
own manifest does not declare fails, and so does a `binary_categories` entry
that no longer matches the measurement.

Exit 0 clean, 1 problems found, 2 could not check.
"""
from __future__ import annotations

import argparse
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

# ---------------------------------------------------------------------------
# Source patterns: (category, regex, what it is). Matched on the code with
# comments and string contents blanked, except where `strings` is True.
# Apple's lists: developer.apple.com, "Describing use of required reason API".
# ---------------------------------------------------------------------------
SOURCE_PATTERNS = [
    # FileTimestamp. Apple names creationDate, modificationDate,
    # fileModificationDate, contentModificationDateKey, creationDateKey, and
    # the stat/getattrlist families. Our stat calls read only type, owner and
    # size, but the category is per API, not per field.
    (CAT_FILE, r"\.(?:creationDate|modificationDate)\b", "FileAttributeKey / URLResourceValues .creationDate / .modificationDate"),
    (CAT_FILE, r"\bfile(?:Modification|Creation)Date\b", "NSDictionary fileModificationDate / fileCreationDate"),
    (CAT_FILE, r"\b(?:contentModificationDate|creationDate)Key\b", "URLResourceKey .contentModificationDateKey / .creationDateKey"),
    (CAT_FILE, r"\bcontentModificationDate\b", "URLResourceValues.contentModificationDate"),
    (CAT_FILE, r"\bNS(?:File(?:Creation|Modification)Date|URL(?:ContentModification|Creation)DateKey)\b", "the ObjC names of the keys above"),
    # `stat()` with nothing inside is the struct's initializer, not a call.
    (CAT_FILE, r"(?<![\w.])(?:Darwin\.)?(?:l?stat|fstat|fstatat|stat64|lstat64|fstat64)\s*\((?!\s*\))", "stat / lstat / fstat / fstatat"),
    (CAT_FILE, r"\b(?:f?getattrlist|getattrlistbulk|getattrlistat)\s*\(", "getattrlist family"),
    # SystemBootTime. Apple names systemUptime and mach_absolute_time.
    (CAT_BOOT, r"\bsystemUptime\b", "ProcessInfo.systemUptime"),
    (CAT_BOOT, r"\bmach_absolute_time\s*\(", "mach_absolute_time()"),
    # Not on Apple's list; the same clock counted from boot, so treated alike.
    (CAT_BOOT, r"\bmach_continuous_time\s*\(", "mach_continuous_time() (not on Apple's list; same boot clock)"),
    (CAT_BOOT, r"\bKERN_BOOTTIME\b", "sysctl KERN_BOOTTIME (how Sentry reads boot time)"),
    # DiskSpace.
    (CAT_DISK, r"\bvolume(?:Available|Total)Capacity\w*Key\b", "URLResourceKey volume capacity keys"),
    (CAT_DISK, r"\.system(?:Free)?Size\b", "FileAttributeKey .systemFreeSize / .systemSize"),
    (CAT_DISK, r"\bNS(?:FileSystem(?:Free)?Size|URLVolume\w*Capacity\w*Key)\b", "the ObjC names of the keys above"),
    (CAT_DISK, r"\battributesOfFileSystem\b", "FileManager.attributesOfFileSystem (free/total size)"),
    (CAT_DISK, r"(?<![\w.])(?:Darwin\.)?f?statv?fs(?:64)?\s*\((?!\s*\))", "statfs / statvfs / fstatfs / fstatvfs"),
    # ActiveKeyboards.
    (CAT_KEYB, r"\bactiveInputModes\b", "UITextInputMode.activeInputModes"),
    # UserDefaults: any use needs the category (CA92.1 for the app's own).
    (CAT_DEFAULTS, r"\b(?:NS)?UserDefaults\b", "UserDefaults"),
    (CAT_DEFAULTS, r"@AppStorage\b", "@AppStorage (UserDefaults underneath)"),
]
SOURCE_PATTERNS_STRINGS = [
    (CAT_BOOT, r"kern\.boottime", "sysctlbyname(\"kern.boottime\")"),
]
APP_GROUP_DEFAULTS = re.compile(r"\bUserDefaults\s*\(\s*suiteName\s*:")

# ---------------------------------------------------------------------------
# Binary patterns for --archive. Imports from `nm -u` (Darwin's $INODE64
# aliases included), demangled Swift imports, and ObjC selector strings.
# ---------------------------------------------------------------------------
BINARY_IMPORTS = {
    # FileTimestamp: the stat and getattrlist families and their aliases.
    **{s: CAT_FILE for s in (
        "_stat", "_lstat", "_fstat", "_fstatat", "_stat64", "_lstat64", "_fstat64",
        "_stat$INODE64", "_lstat$INODE64", "_fstat$INODE64", "_fstatat$INODE64",
        "_getattrlist", "_getattrlistbulk", "_fgetattrlist", "_getattrlistat",
        # FileAttributeKey / URLResourceKey constants (data symbols)
        "_NSFileCreationDate", "_NSFileModificationDate",
        "_NSURLContentModificationDateKey", "_NSURLCreationDateKey",
    )},
    # SystemBootTime: the mach clocks.
    "_mach_absolute_time": CAT_BOOT,
    "_mach_continuous_time": CAT_BOOT,  # not on Apple's list; same boot clock
    # DiskSpace: the statfs family and the capacity keys.
    **{s: CAT_DISK for s in (
        "_statfs", "_statfs64", "_statfs$INODE64", "_fstatfs", "_fstatfs64",
        "_fstatfs$INODE64", "_statvfs", "_fstatvfs", "_getfsstat", "_getfsstat$INODE64",
        "_NSURLVolumeAvailableCapacityKey", "_NSURLVolumeAvailableCapacityForImportantUsageKey",
        "_NSURLVolumeAvailableCapacityForOpportunisticUsageKey", "_NSURLVolumeTotalCapacityKey",
        "_NSFileSystemFreeSize", "_NSFileSystemSize",
    )},
    # UserDefaults: the class itself.
    "_OBJC_CLASS_$_NSUserDefaults": CAT_DEFAULTS,
}
BINARY_DEMANGLED = [
    # Swift overlay accessors that reach the same APIs without a C import.
    (CAT_FILE, re.compile(r"URLResourceValues\.(?:contentModificationDate|creationDate)\b")),
    (CAT_FILE, re.compile(r"FileAttributeKey\.(?:creationDate|modificationDate)\b")),
    (CAT_BOOT, re.compile(r"ProcessInfo\.systemUptime\b")),
    (CAT_DISK, re.compile(r"URLResourceValues\.volume(?:Available|Total)Capacity")),
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
    CAT_KEYB: "ActiveKeyboards", CAT_DEFAULTS: "UserDefaults",
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


def validate_manifest(data, label: str, problems: list[str]) -> None:
    if not isinstance(data, dict):
        problems.append(f"{label}: the top level is a {type(data).__name__}, not a dictionary")
        return
    for key in sorted(set(data) - set(TOP_LEVEL_TYPES)):
        problems.append(f"{label}: unknown top-level key {key!r} (Apple defines {', '.join(TOP_LEVEL_TYPES)})")
    for key, typ in TOP_LEVEL_TYPES.items():
        if key not in data:
            problems.append(f"{label}: missing {key} (every manifest here states all four keys)")
        elif not isinstance(data[key], typ):
            problems.append(f"{label}: {key} is a {type(data[key]).__name__}, not a {typ.__name__}")
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
                problems.append(f"{where}: not a dictionary")
                continue
            for key in sorted(set(entry) - API_ENTRY_KEYS):
                problems.append(f"{where}: unknown key {key!r}")
            cat = entry.get("NSPrivacyAccessedAPIType")
            reasons = entry.get("NSPrivacyAccessedAPITypeReasons")
            if not isinstance(cat, str):
                problems.append(f"{where}: NSPrivacyAccessedAPIType is missing or not a string")
                continue
            if cat not in CATEGORY_REASONS:
                problems.append(f"{where}: unknown category {cat!r}")
                continue
            if cat in seen_cats:
                problems.append(f"{where}: {cat} is declared twice")
            seen_cats.add(cat)
            if not isinstance(reasons, list) or not reasons:
                problems.append(f"{where}: {cat} has no NSPrivacyAccessedAPITypeReasons")
                continue
            seen_reasons: set[str] = set()
            for reason in reasons:
                if not isinstance(reason, str):
                    problems.append(f"{where}: a reason is not a string")
                elif reason not in CATEGORY_REASONS[cat]:
                    problems.append(
                        f"{where}: reason {reason!r} is not a reason Apple defines for {cat} "
                        f"({', '.join(sorted(CATEGORY_REASONS[cat]))})"
                    )
                elif reason in seen_reasons:
                    problems.append(f"{where}: reason {reason} is listed twice for {cat}")
                seen_reasons.add(reason)

    collected = data.get("NSPrivacyCollectedDataTypes")
    if isinstance(collected, list):
        seen_rows: set[tuple] = set()
        for i, entry in enumerate(collected):
            where = f"{label}: NSPrivacyCollectedDataTypes[{i}]"
            if not isinstance(entry, dict):
                problems.append(f"{where}: not a dictionary")
                continue
            for key in sorted(set(entry) - DATA_ENTRY_KEYS):
                problems.append(f"{where}: unknown key {key!r}")
            for key in sorted(DATA_ENTRY_KEYS - set(entry)):
                problems.append(f"{where}: missing {key}")
            typ = entry.get("NSPrivacyCollectedDataType")
            if typ is not None and typ not in DATA_TYPES:
                problems.append(f"{where}: unknown data type {typ!r}")
            for key in ("NSPrivacyCollectedDataTypeLinked", "NSPrivacyCollectedDataTypeTracking"):
                if key in entry and not isinstance(entry[key], bool):
                    problems.append(f"{where}: {key} is not a boolean")
            if entry.get("NSPrivacyCollectedDataTypeTracking") is True:
                problems.append(f"{where}: {typ} is marked as used for tracking")
            purposes = entry.get("NSPrivacyCollectedDataTypePurposes")
            if "NSPrivacyCollectedDataTypePurposes" in entry:
                if not isinstance(purposes, list) or not purposes:
                    problems.append(f"{where}: {typ} has no purposes")
                else:
                    for p in purposes:
                        if p not in PURPOSES:
                            problems.append(f"{where}: unknown purpose {p!r}")
                    if len(set(purposes)) != len(purposes):
                        problems.append(f"{where}: {typ} lists a purpose twice")
            row = (typ, entry.get("NSPrivacyCollectedDataTypeLinked"))
            if row in seen_rows:
                problems.append(f"{where}: {typ} (linked={row[1]}) is declared twice")
            seen_rows.add(row)


def declared_reasons(data) -> dict[str, set[str]]:
    out: dict[str, set[str]] = {}
    for entry in (data or {}).get("NSPrivacyAccessedAPITypes") or []:
        if isinstance(entry, dict) and isinstance(entry.get("NSPrivacyAccessedAPIType"), str):
            reasons = entry.get("NSPrivacyAccessedAPITypeReasons")
            out[entry["NSPrivacyAccessedAPIType"]] = set(r for r in reasons if isinstance(r, str)) if isinstance(reasons, list) else set()
    return out


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
        value = self._value()
        return value

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

    def target(self, name: str):
        for oid, obj in self.objects.items():
            if obj.get("isa") == "PBXNativeTarget" and obj.get("name") == name:
                return oid, obj
        return None, None

    def path_of(self, ref_id: str) -> Path | None:
        obj = self.objects.get(ref_id, {})
        parts = []
        node = ref_id
        tree = obj.get("sourceTree")
        while True:
            o = self.objects.get(node, {})
            if o.get("path"):
                parts.append(o["path"])
            tree = o.get("sourceTree")
            if tree != "<group>":
                break
            node = self.parent.get(node)
            if node is None:
                break
        if tree in ("SOURCE_ROOT", "<group>", None):
            return Path(self.srcroot, *reversed(parts))
        return None  # BUILT_PRODUCTS_DIR, SDKROOT, ...

    def phase(self, target, isa: str):
        for pid in target.get("buildPhases", []):
            if self.objects.get(pid, {}).get("isa") == isa:
                return pid, self.objects[pid]
        return None, None

    def phase_files(self, phase) -> list[tuple[str, Path | None, str | None]]:
        out = []
        for bf in phase.get("files", []):
            bfo = self.objects.get(bf, {})
            ref = bfo.get("fileRef")
            product = None
            if bfo.get("productRef"):
                product = self.objects.get(bfo["productRef"], {}).get("productName")
            out.append((bf, self.path_of(ref) if ref else None, product))
        return out

    def links_product(self, target, product: str) -> bool:
        for dep in target.get("packageProductDependencies", []):
            if self.objects.get(dep, {}).get("productName") == product:
                return True
        _, fw = self.phase(target, "PBXFrameworksBuildPhase")
        return bool(fw) and any(p == product for _, _, p in self.phase_files(fw))


# ---------------------------------------------------------------------------
# Swift source reading: comments and strings blanked, #if resolved
# ---------------------------------------------------------------------------
_TOKEN = re.compile(r'//|/\*|\*/|"""|"|\\\(|\\.|\(|\)|\n')


def blank_swift(text: str) -> tuple[str, str]:
    """Two views with the same line structure: code with comments and string
    contents blanked, and code with only comments blanked. Handles nested
    block comments, single- and multi-line strings, escapes and string
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


# canImport answers per platform for the modules the sources test.
CAN_IMPORT = {
    "macos": {"AppKit": True, "UIKit": False, "WidgetKit": True, "WatchKit": False,
              "WatchConnectivity": False, "ActivityKit": False, "IOKit": True,
              "ServiceManagement": True, "Darwin": True, "Foundation": True},
    "ios": {"AppKit": False, "UIKit": True, "WidgetKit": True, "WatchKit": False,
            "WatchConnectivity": True, "ActivityKit": True, "IOKit": False,
            "ServiceManagement": False, "Darwin": True, "Foundation": True},
    "watchos": {"AppKit": False, "UIKit": False, "WidgetKit": True, "WatchKit": True,
                "WatchConnectivity": True, "ActivityKit": False, "IOKit": False,
                "ServiceManagement": False, "Darwin": True, "Foundation": True},
}
OS_NAME = {"macos": "macOS", "ios": "iOS", "watchos": "watchOS"}


def eval_condition(expr: str, platform: str):
    """Tri-state: True, False, or None (depends on a build flag we cannot see,
    such as DEBUG or DEVID_BUILD: then both branches count)."""
    tokens = re.findall(r"\|\||&&|!|\(|\)|[A-Za-z_][A-Za-z0-9_]*\s*\([^()]*\)|[A-Za-z_][A-Za-z0-9_]*", expr)
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
            pos += 1  # ')'
            return v
        m = re.match(r"(\w+)\s*\(([^()]*)\)", tok or "")
        if m:
            fn, arg = m.group(1), m.group(2).strip()
            if fn == "os":
                return arg == OS_NAME[platform]
            if fn == "canImport":
                return CAN_IMPORT[platform].get(arg.split(".")[0])
            if fn == "targetEnvironment":
                return False if arg == "macCatalyst" else None
            if fn in ("swift", "compiler", "hasFeature", "hasAttribute"):
                return True
            return None  # arch(...) and anything else
        if tok in ("true",):
            return True
        if tok in ("false",):
            return False
        return None  # a -D flag (DEBUG, DEVID_BUILD, ...)

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
        return disj()
    except Exception:
        return None


def active_lines(raw: str, platform: str) -> list[bool]:
    """For each line, whether it can be compiled for `platform`."""
    out = []
    stack = []  # frames: [state_of_current_branch, taken_definitely, all_prior_false]
    directive = re.compile(r"^\s*#(if|elseif|else|endif)\b(.*)$")
    for line in raw.split("\n"):
        m = directive.match(line)
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


_CODE_RX = [(cat, re.compile(rx), what) for cat, rx, what in SOURCE_PATTERNS]
_STRING_RX = [(cat, re.compile(rx), what) for cat, rx, what in SOURCE_PATTERNS_STRINGS]
# A cheap first pass: a line none of these words appears in cannot match.
_PREFILTER = re.compile(
    r"Date|stat|getattrlist|[Uu]ptime|mach_|BOOTTIME|boottime|Capacity|Size|attributesOfFileSystem|"
    r"InputModes|UserDefaults|AppStorage"
)


_SCAN_CACHE: dict = {}


def scan_source(path: Path, platform: str, cache: dict):
    """[(category, line_no, what, text, is_app_group)] for one file, on the
    lines `platform` compiles. A file is searched once per content (the cache
    outlives one check, for the tests); only the #if resolution is per
    platform."""
    raw = path.read_text(encoding="utf-8", errors="replace")
    entry = cache.get(path)
    if entry is None or entry["raw"] != raw:
        if path.suffix == ".swift":
            code, keep = blank_swift(raw)
        else:  # C / ObjC (the vendored decoder): read as is
            code = keep = raw
        raw_lines = raw.split("\n")
        hits = []
        for no, (cl, kl) in enumerate(zip(code.split("\n"), keep.split("\n")), start=1):
            if not _PREFILTER.search(kl):
                continue
            for cat, rx, what in _CODE_RX:
                if rx.search(cl):
                    hits.append((cat, no, what, raw_lines[no - 1].strip(), bool(APP_GROUP_DEFAULTS.search(cl))))
            for cat, rx, what in _STRING_RX:
                if rx.search(kl):
                    hits.append((cat, no, what, raw_lines[no - 1].strip(), False))
        entry = cache[path] = {"raw": raw, "hits": hits, "active": {}}
    if not entry["hits"]:
        return []
    active = entry["active"].get(platform)
    if active is None:
        active = (active_lines(entry["raw"], platform) if path.suffix == ".swift"
                  else [True] * (entry["raw"].count("\n") + 1))
        entry["active"][platform] = active
    return [h for h in entry["hits"] if active[h[1] - 1]]


# ---------------------------------------------------------------------------
# The repo check
# ---------------------------------------------------------------------------
def entitlement_groups(path: Path) -> list[str]:
    try:
        data = plistlib.loads(path.read_bytes())
    except Exception:
        return []
    return list(data.get("com.apple.security.application-groups") or [])


def check_repo(root: Path, verbose: bool) -> list[str]:
    problems: list[str] = []
    cfg = json.loads((root / CONFIG).read_text(encoding="utf-8"))
    allow = json.loads((root / ALLOWLIST).read_text(encoding="utf-8"))
    allow_entries = allow.get("entries", [])
    allow_used = [False] * len(allow_entries)
    project = Project(root / cfg["project"], root)
    label_rows = cfg["label"]["rows"]
    covered = [False] * len(label_rows)
    cache = _SCAN_CACHE

    shared_files: list[Path] = []
    for rel in cfg["shared_sources"]:
        base = root / rel
        shared_files += sorted(p for p in base.rglob("*") if p.suffix in (".swift", ".m", ".c", ".h") and p.is_file())

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
        # 1. the manifest ships: it is in this target's Resources phase.
        rid, res = project.phase(target, "PBXResourcesBuildPhase")
        in_resources = bool(res) and any(p == mpath for _, p, _ in project.phase_files(res))
        if not in_resources:
            where = f"Resources build phase ({rid})" if rid else "Resources build phase (the target has none)"
            problems.append(f"{name}: {mpath} is not in the target's {where}, so it is not copied into the bundle")
        for other in cfg["targets"]:
            if other is t:
                continue
            _, ot = project.target(other["name"])
            if ot is None:
                continue
            _, ores = project.phase(ot, "PBXResourcesBuildPhase")
            if ores and any(p == mpath for _, p, _ in project.phase_files(ores)):
                problems.append(f"{name}: {mpath} is also in {other['name']}'s Resources phase; each bundle carries its own")

        # 2. what the sources it compiles use.
        _, src = project.phase(target, "PBXSourcesBuildPhase")
        files = [root / p for _, p, _ in project.phase_files(src) if p is not None] if src else []
        if project.links_product(target, "CLIPulseCore"):
            files += shared_files
            for rel in cfg.get("platform_sources", {}).get(platform, []):
                files += sorted(p for p in (root / rel).rglob("*") if p.suffix in (".c", ".h", ".m", ".swift"))
        groups = entitlement_groups(root / t["entitlements"]) if t.get("entitlements") else []
        used: dict[str, list] = {}
        group_uses = []
        for f in files:
            if not f.is_file():
                problems.append(f"{name}: compiles {f.relative_to(root)}, which does not exist")
                continue
            rel = f.relative_to(root).as_posix()
            for cat, no, what, text, is_group in scan_source(f, platform, cache):
                hit = (rel, no, what, text)
                skipped = False
                for k, e in enumerate(allow_entries):
                    if e["target"] == name and e["category"] == cat and e["file"] == rel and re.search(e["pattern"], text):
                        allow_used[k] = True
                        skipped = True
                if skipped:
                    continue
                used.setdefault(cat, []).append(hit)
                if is_group:
                    group_uses.append(hit)
        measured = set(t.get("binary_categories", []))
        for cat, hits in sorted(used.items()):
            if cat not in declared:
                rel, no, what, text = hits[0]
                more = f" (and {len(hits) - 1} more)" if len(hits) > 1 else ""
                problems.append(
                    f"{name}: {rel}:{no} uses {what} ({cat}){more}, which {label} does not declare"
                )
        for cat in sorted(measured - set(declared)):
            problems.append(
                f"{name}: the archived binary links {SHORT.get(cat, cat)} ({cat}, recorded in {CONFIG} "
                f"binary_categories), which {label} does not declare"
            )
        for cat in sorted(set(declared) - set(used) - measured):
            problems.append(
                f"{name}: {label} declares {cat}, but neither the sources {name} compiles nor its "
                f"measured binary use it; remove it or record the use"
            )
        defaults_reasons = declared.get(CAT_DEFAULTS, set())
        if group_uses and groups and APP_GROUP_REASON not in defaults_reasons and CAT_DEFAULTS in declared:
            rel, no, _, _ = group_uses[0]
            problems.append(
                f"{name}: uses app-group UserDefaults ({rel}:{no}) and is entitled to {groups[0]}, "
                f"but {label} does not declare reason {APP_GROUP_REASON} for {CAT_DEFAULTS}"
            )
        if APP_GROUP_REASON in defaults_reasons and not groups:
            problems.append(
                f"{name}: {label} declares {APP_GROUP_REASON} (app group) but {t.get('entitlements')} grants no app group"
            )
        if verbose:
            print(f"--- {name} ({platform}): {len(files)} source files")
            for cat, hits in sorted(used.items()):
                print(f"    {SHORT[cat]:15} {len(hits):3} use(s), first {hits[0][0]}:{hits[0][1]}  "
                      f"declared {sorted(declared.get(cat, set())) or 'NO'}")
            print(f"    binary_categories: {sorted(SHORT[c] for c in measured)}")

        # 3. collected data: rows of the published label, nothing else.
        for i, entry in enumerate((data or {}).get("NSPrivacyCollectedDataTypes") or []):
            if not isinstance(entry, dict):
                continue
            row = {
                "type": entry.get("NSPrivacyCollectedDataType"),
                "linked": entry.get("NSPrivacyCollectedDataTypeLinked"),
                "tracking": entry.get("NSPrivacyCollectedDataTypeTracking"),
                "purposes": sorted(entry.get("NSPrivacyCollectedDataTypePurposes") or []),
            }
            match = [k for k, r in enumerate(label_rows)
                     if r["type"] == row["type"] and r["linked"] == row["linked"]
                     and r["tracking"] == row["tracking"] and sorted(r["purposes"]) == row["purposes"]]
            if not match:
                same_type = [r for r in label_rows if r["type"] == row["type"]]
                want = "; ".join(
                    f"linked={r['linked']} tracking={r['tracking']} purposes={sorted(r['purposes'])}" for r in same_type
                ) or "the label does not list this type"
                problems.append(
                    f"{label}: NSPrivacyCollectedDataTypes[{i}] {row['type']} linked={row['linked']} "
                    f"tracking={row['tracking']} purposes={row['purposes']} is not a row of the published "
                    f"label ({want})"
                )
            for k in match:
                covered[k] = True

    for k, r in enumerate(label_rows):
        if not covered[k]:
            problems.append(
                f"label row {r['type']} linked={r['linked']} purposes={sorted(r['purposes'])} is declared "
                f"by no target's manifest"
            )
    for k, e in enumerate(allow_entries):
        if not allow_used[k]:
            problems.append(f"{ALLOWLIST}: entry {k} ({e['target']}, {e['file']}) matches nothing; remove it")
    return problems


# ---------------------------------------------------------------------------
# Archive mode
# ---------------------------------------------------------------------------
def run(cmd: list[str], stdin: str | None = None) -> str:
    return subprocess.run(cmd, input=stdin, capture_output=True, text=True, check=False).stdout


def binary_categories(exe: Path) -> dict[str, list[str]]:
    found: dict[str, list[str]] = {}
    imports = run(["xcrun", "nm", "-u", str(exe)]).split()
    for sym in sorted(set(imports)):
        if sym in BINARY_IMPORTS:
            found.setdefault(BINARY_IMPORTS[sym], []).append(sym)
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
        print("archive mode needs xcrun (macOS with Xcode)", file=sys.stderr)
        sys.exit(2)
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
    except (OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
        print(f"check_privacy_manifests: could not check: {exc!r}", file=sys.stderr)
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
