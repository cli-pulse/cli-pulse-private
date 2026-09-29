#!/usr/bin/env python3
"""Offline tests for scripts/asc_submit.py, against a fake App Store Connect.

A submission cannot be rehearsed against the real store: the only version it
can write to is the one about to ship. So the HTTP layer is replaced by an
in-memory fake that answers the endpoints the script uses, and every case
checks what the script WOULD send:

  * a dry run sends nothing, and shows which file each locale gets;
  * iOS gets <locale>.txt and macOS gets macos-<locale>.txt, never the other
    platform's text; es-ES and es-MX get the same Spanish;
  * a directory with no macOS texts at all gives the Mac <locale>.txt;
  * a split directory missing one macos- file is refused, not filled from the
    iPhone text, and nothing is written;
  * a store localization the directory has no text for is refused before the
    first write; so is a version missing a locale the repo has a listing for,
    unless --allow-missing-locales;
  * a missing or non-editable version, and a build that is not VALID, is for
    another platform or version, or does not exist, are refused with zero writes;
  * texts that fail the checks (length, another platform, a direct-download-only
    feature in macOS text, es-ES != es-MX) are refused before the store is
    contacted at all;
  * What's New is written before the build is attached, only where it differs,
    and read back; a refused or silently dropped write stops the run before the
    build is attached or anything is submitted;
  * --whatsnew is refused; --create-version creates only when asked to, and
    says which releaseType an existing version has, warning when it is not the
    one asked for; --submit's dry run says it too;
  * App Review notes: the dry run prints the notes the version holds (never
    the contact or demo-account fields); notes App Store Connect copied from
    an older version are refused before the first write (the 1.54.0 case);
    --review-notes FILE is checked before the store is contacted, PATCHes
    `notes` and nothing else, before What's New, and is read back (the notes,
    and every other field unchanged); a refused, dropped or field-clobbering
    write stops the run before What's New, the build or the submission;
    --accept-review-notes lets flagged notes through; and the detector itself
    is run on sentences shaped like the real 1.53.0 and 1.54.0 notes.

The real whatsnew_154/ is the fixture: its passing is the positive control.
Runs with a bare python3 (no jwt/requests needed).
"""
from __future__ import annotations

import contextlib
import copy
import io
import shutil
import sys
import tempfile
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import appstore_listing as listing  # noqa: E402
import asc_submit as sub  # noqa: E402

REPO = HERE.parent
NOTES = REPO / "whatsnew_154"
APP = sub.APP_ID
LOCALES = list(listing.LOCALE_SOURCES)


# App Review details. The contact and demo-account values are stand-ins; the
# tests assert none of them is ever printed, and that a notes write leaves
# them as they were.
REVIEW_CONTACT = {"contactFirstName": "Test", "contactLastName": "Reviewer-Contact",
                  "contactPhone": "+00 0000 000 000", "contactEmail": "contact@example.invalid",
                  "demoAccountName": "demo@example.invalid",
                  "demoAccountPassword": "not-a-real-password-7f3a", "demoAccountRequired": False}
# Shaped like the notes 1.54.0 was submitted with: this version named, older
# ones only as the point of comparison.
GOOD_NOTES = ("WHAT 1.54.0 IS\n\n"
              "1.54.0 adds no permission and no entitlement; no Info.plist or entitlements "
              "file changed since 1.53.0.\n"
              "Remote Control was added in 1.53.0 and is unchanged in 1.54.0 apart from "
              "translation.\n"
              "No account is needed: tap Try Demo on the sign-in screen.")
# Shaped like the 1.53.0 notes App Store Connect copied onto 1.54.0.
COPIED_NOTES = ("THE MAIN FEATURE IN 1.53.0 NEEDS A SECOND DEVICE - PLEASE READ\n\n"
                "1.53.0 adds Remote Control: an iPhone drives a CLI session running on a Mac. "
                "Every other tab behaves exactly as in 1.52.1.\n"
                "NEW PERMISSION PROMPTS IN THIS VERSION (both are new since 1.52.1)\n"
                "The iPhone screenshots have been re-taken from this 1.53.0 build. The previous "
                "set still showed a tab that was removed in 1.52.1.\n"
                "ALSO FIXED IN 1.53.0\n"
                "- the usage chart.")


class _Timeout(Exception):
    pass


class _ConnectionError(Exception):
    pass


class Resp:
    def __init__(self, status: int, body: dict | None = None, text: str = "") -> None:
        self.status_code = status
        self._body = body or {}
        self.text = text or str(body)

    def json(self) -> dict:
        return self._body


class FakeASC:
    """Stands in for the `requests` module."""
    Timeout = _Timeout
    ConnectionError = _ConnectionError

    def __init__(self, platform: str = "IOS", state: str = "PREPARE_FOR_SUBMISSION",
                 locales: list[str] | None = None, version: bool = True,
                 build: dict | None = None, notes: str | None = GOOD_NOTES,
                 release_type: str = "AFTER_APPROVAL") -> None:
        self.calls: list[tuple[str, str]] = []
        self.writes: list[tuple[str, str, dict]] = []
        self.refuse: set[str] = set()   # locales whose whatsNew PATCH gets 409
        self.drop: set[str] = set()     # locales whose whatsNew PATCH is ignored
        # the review-notes PATCH: "refuse" (409), "drop" (200, ignored) or
        # "clobber" (200, and the store also blanks the contact phone)
        self.notes_mode = "ok"
        self.versions: dict[str, dict] = {}
        self.vlocs: dict[str, dict[str, dict]] = {}
        self.reviews: dict[str, dict] = {}       # review detail id -> attributes
        self.review_of: dict[str, str] = {}      # version id -> review detail id
        if version:
            self.versions["v1"] = {"platform": platform, "versionString": "1.54.0",
                                   "appStoreState": state, "releaseType": release_type}
            self.vlocs["v1"] = {f"loc-{loc}": {"locale": loc, "whatsNew": None}
                                for loc in (locales if locales is not None else LOCALES)}
            if notes is not None:
                self.reviews["rd1"] = {"notes": notes, **REVIEW_CONTACT}
                self.review_of["v1"] = "rd1"
        self.builds = {"b1": build if build is not None else
                       {"version": "108", "processingState": "VALID",
                        "pre": {"version": "1.54.0", "platform": platform}}}
        self.attached: dict[str, str] = {}
        self.submissions: dict[str, dict] = {}

    # -- routing ------------------------------------------------------------
    @staticmethod
    def _split(url: str) -> tuple[str, dict]:
        assert url.startswith(sub.BASE), url
        parts = urlsplit(url[len(sub.BASE):])
        return parts.path, {k: v[0] for k, v in parse_qs(parts.query).items()}

    def get(self, url, headers=None, timeout=None):
        path, q = self._split(url)
        self.calls.append(("GET", path))
        if path == f"/apps/{APP}/appStoreVersions":
            rows = [{"id": vid, "attributes": dict(a)} for vid, a in self.versions.items()
                    if a["platform"] == q.get("filter[platform]")
                    and a["versionString"] == q.get("filter[versionString]")]
            return Resp(200, {"data": rows})
        if path.startswith("/appStoreVersions/") and path.endswith("/appStoreVersionLocalizations"):
            vid = path.split("/")[2]
            return Resp(200, {"data": [{"id": lid, "attributes": dict(a)}
                                       for lid, a in self.vlocs[vid].items()]})
        if path.startswith("/appStoreVersions/") and path.endswith("/appStoreReviewDetail"):
            rid = self.review_of.get(path.split("/")[2])
            if rid is None:
                return Resp(200, {"data": None})
            return Resp(200, {"data": {"id": rid, "type": "appStoreReviewDetails",
                                       "attributes": dict(self.reviews[rid])}})
        if path.startswith("/builds/"):
            bid = path.split("/")[2]
            b = self.builds.get(bid)
            if b is None:
                return Resp(404, {"errors": [{"status": "404"}]})
            return Resp(200, {"data": {"id": bid, "attributes": {
                "version": b["version"], "processingState": b["processingState"]}},
                "included": [{"type": "preReleaseVersions", "attributes": dict(b["pre"])}]})
        raise AssertionError(f"unexpected GET {path}")

    def post(self, url, headers=None, json=None, timeout=None):
        path, _ = self._split(url)
        self.calls.append(("POST", path))
        self.writes.append(("POST", path, copy.deepcopy(json)))
        data = json["data"]
        if path == "/appStoreVersions":
            vid = f"v{len(self.versions) + 1}"
            self.versions[vid] = {k: data["attributes"][k]
                                  for k in ("platform", "versionString", "releaseType")}
            self.versions[vid]["appStoreState"] = "PREPARE_FOR_SUBMISSION"
            self.vlocs[vid] = {}
            return Resp(201, {"data": {"id": vid}})
        if path == "/reviewSubmissions":
            sid = f"s{len(self.submissions) + 1}"
            self.submissions[sid] = {"platform": data["attributes"]["platform"], "items": [],
                                     "submitted": False, "canceled": False}
            return Resp(201, {"data": {"id": sid}})
        if path == "/reviewSubmissionItems":
            rel = data["relationships"]
            sid = rel["reviewSubmission"]["data"]["id"]
            self.submissions[sid]["items"].append(rel["appStoreVersion"]["data"]["id"])
            return Resp(201, {"data": {"id": "item1"}})
        raise AssertionError(f"unexpected POST {path}")

    def patch(self, url, headers=None, json=None, timeout=None):
        path, _ = self._split(url)
        self.calls.append(("PATCH", path))
        self.writes.append(("PATCH", path, copy.deepcopy(json)))
        data = json["data"]
        if path.startswith("/appStoreVersionLocalizations/"):
            lid = path.split("/")[2]
            row = next(t[lid] for t in self.vlocs.values() if lid in t)
            if row["locale"] in self.refuse:
                return Resp(409, text='{"errors":[{"detail":"refused"}]}')
            if row["locale"] not in self.drop:
                row["whatsNew"] = data["attributes"]["whatsNew"]
            return Resp(200, {"data": data})
        if path.startswith("/appStoreReviewDetails/"):
            rid = path.split("/")[2]
            if self.notes_mode == "refuse":
                return Resp(409, text='{"errors":[{"detail":"refused"}]}')
            if self.notes_mode != "drop":
                self.reviews[rid].update(data["attributes"])
            if self.notes_mode == "clobber":
                self.reviews[rid]["contactPhone"] = None
            return Resp(200, {"data": data})
        if path.startswith("/appStoreVersions/") and path.endswith("/relationships/build"):
            self.attached[path.split("/")[2]] = data["id"]
            return Resp(204)
        if path.startswith("/reviewSubmissions/"):
            self.submissions[path.split("/")[2]].update(data["attributes"])
            return Resp(200, {"data": data})
        raise AssertionError(f"unexpected PATCH {path}")

    # -- what the tests read --------------------------------------------------
    def whatsnew_writes(self) -> dict[str, str]:
        out = {}
        for m, p, b in self.writes:
            if m == "PATCH" and p.startswith("/appStoreVersionLocalizations/"):
                out[p.split("/")[2][len("loc-"):]] = b["data"]["attributes"]["whatsNew"]
        return out

    def first_index(self, prefix: str) -> int:
        return next((i for i, (m, p, _) in enumerate(self.writes) if p.startswith(prefix)), -1)

    def notes_writes(self) -> list[dict]:
        return [b["data"]["attributes"] for m, p, b in self.writes
                if p.startswith("/appStoreReviewDetails/")]


FAKE: FakeASC = FakeASC()
sub.jwt = object()                     # _deps() sees both modules loaded
sub._token = lambda: "test-token"      # no key file, no signing


def run(fake: FakeASC, *argv: str) -> tuple[int, str]:
    global FAKE
    FAKE = fake
    sub.requests = fake
    out = io.StringIO()
    sys.argv = ["asc_submit.py", *argv]
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        try:
            code = sub.main()
        except SystemExit as exc:
            code = exc.code if isinstance(exc.code, int) else 1
    return code, out.getvalue()


def submit(fake: FakeASC, plat: str, notes: Path, *extra: str) -> tuple[int, str]:
    return run(fake, "--submit", plat, "--build", "b1", "--version", "1.54.0",
               "--whatsnew-dir", str(notes), *extra)


def text(name: str, d: Path = NOTES) -> str:
    return (d / name).read_text(encoding="utf-8").strip()


passed = 0
failed = 0


def check(name: str, cond: bool, detail: str = "") -> None:
    global passed, failed
    if cond:
        print(f"ok:   {name}")
        passed += 1
    else:
        print(f"FAIL: {name}")
        if detail:
            print("      " + detail.replace("\n", "\n      ")[:3000])
        failed += 1


tmp = Path(tempfile.mkdtemp())


def notes_copy(name: str) -> Path:
    d = tmp / name / "whatsnew_154"
    shutil.copytree(NOTES, d)
    return d


try:
    # 0. the fixture itself
    check("whatsnew_154/ passes every What's New check (positive control)",
          listing.whatsnew_problems(NOTES) == [], str(listing.whatsnew_problems(NOTES)))

    # 1. dry run
    f = FakeASC()
    code, out = submit(f, "ios", NOTES)
    check("iOS dry run exits 0 and writes nothing", code == 0 and not f.writes, out)
    check("... and says so", "DRY RUN OK — nothing was written" in out, out)
    check("... and names the file each locale gets",
          all(f"{loc:7} {loc}.txt" in out for loc in LOCALES), out)

    f = FakeASC(platform="MAC_OS")
    code, out = submit(f, "macos", NOTES)
    check("macOS dry run shows macos-<locale>.txt for every locale",
          code == 0 and not f.writes
          and all(f"{loc:7} macos-{loc}.txt" in out for loc in LOCALES), out)

    # 2. iOS apply
    f = FakeASC()
    code, out = submit(f, "ios", NOTES, "--apply")
    wn = f.whatsnew_writes()
    check("iOS apply exits 0 and submits", code == 0
          and any(s["submitted"] for s in f.submissions.values()), out)
    check("every iOS locale gets its <locale>.txt",
          wn == {loc: text(f"{loc}.txt") for loc in LOCALES}, str(sorted(wn)))
    check("es-ES and es-MX get the same Spanish", wn.get("es-ES") == wn.get("es-MX"))
    check("What's New is written before the build is attached",
          -1 < max(i for i, (m, p, _) in enumerate(f.writes)
                   if p.startswith("/appStoreVersionLocalizations/"))
          < f.first_index("/appStoreVersions/v1/relationships/build"), str(f.writes)[:300])
    check("the build is attached to the version", f.attached == {"v1": "b1"})
    check("never DELETEs", all(m in ("POST", "PATCH") for m, _, _ in f.writes))

    # 3. macOS apply: the Mac texts, never the iPhone ones
    f = FakeASC(platform="MAC_OS")
    code, out = submit(f, "macos", NOTES, "--apply")
    wn = f.whatsnew_writes()
    check("every macOS locale gets its macos-<locale>.txt",
          code == 0 and wn == {loc: text(f"macos-{loc}.txt") for loc in LOCALES}, out)
    check("no macOS locale gets the iOS text",
          not any(wn.get(loc) == text(f"{loc}.txt") for loc in LOCALES))

    # 4. idempotent: locales already holding the text are not written again
    f = FakeASC()
    for row in f.vlocs["v1"].values():
        if row["locale"] in ("en-US", "ja"):
            row["whatsNew"] = text(f"{row['locale']}.txt")
    code, out = submit(f, "ios", NOTES, "--apply")
    check("locales already holding their text are not PATCHed",
          code == 0 and sorted(f.whatsnew_writes()) == sorted(set(LOCALES) - {"en-US", "ja"}),
          out)

    # 5. a directory with no macOS texts: the Mac reads <locale>.txt
    shared = notes_copy("shared")
    for p in shared.glob("macos-*.txt"):
        p.unlink()
    f = FakeASC(platform="MAC_OS")
    code, out = submit(f, "macos", shared, "--apply")
    check("without any macos-*.txt the Mac gets <locale>.txt",
          code == 0 and f.whatsnew_writes() == {loc: text(f"{loc}.txt") for loc in LOCALES}, out)

    # 6. a split directory missing one Mac text: refused, not filled from iOS
    partial = notes_copy("partial")
    (partial / "macos-ko.txt").unlink()
    f = FakeASC(platform="MAC_OS")
    code, out = submit(f, "macos", partial, "--apply")
    check("a missing macos-ko.txt is refused, store never contacted",
          code == 1 and not f.calls and "macos-ko.txt: missing" in out
          and "does not fall back to ko.txt" in out, out)
    f = FakeASC()
    code, out = submit(f, "ios", partial)
    check("... while iOS, which has all its files, still passes", code == 0, out)

    # 7. a store localization with no text
    f = FakeASC(locales=LOCALES + ["fr-FR"])
    code, out = submit(f, "ios", NOTES, "--apply")
    check("a store locale with no text is refused with zero writes",
          code == 1 and not f.writes and "fr-FR" in out and "Nothing was written" in out, out)

    # 8. the listing not pushed yet
    f = FakeASC(locales=["en-US", "zh-Hans"])
    code, out = submit(f, "ios", NOTES, "--apply")
    check("a version without the repo's new locales is refused with zero writes",
          code == 1 and not f.writes and "zh-Hant, ja, ko, es-ES, es-MX" in out
          and "asc_push_listing.py" in out, out)
    f = FakeASC(locales=["en-US", "zh-Hans"])
    code, out = submit(f, "ios", NOTES, "--apply", "--allow-missing-locales")
    check("... and allowed with --allow-missing-locales (writes the two it has)",
          code == 0 and sorted(f.whatsnew_writes()) == ["en-US", "zh-Hans"] and "WARN" in out, out)

    # 9. version missing / not editable
    f = FakeASC(version=False)
    code, out = submit(f, "ios", NOTES, "--apply")
    check("a missing version is refused with zero writes, pointing at --create-version",
          code == 1 and not f.writes and "--create-version ios" in out, out)
    f = FakeASC(state="WAITING_FOR_REVIEW")
    code, out = submit(f, "ios", NOTES, "--apply")
    check("a version in review is refused with zero writes",
          code == 1 and not f.writes and "WAITING_FOR_REVIEW" in out, out)
    check("the editable states are asc_push_listing's",
          sub.EDITABLE_STATES == __import__("asc_push_listing").EDITABLE_STATES)

    # 10. the build
    for name, build, needle in [
        ("a build still processing", {"version": "108", "processingState": "PROCESSING",
                                      "pre": {"version": "1.54.0", "platform": "IOS"}},
         "is PROCESSING, not VALID"),
        ("a macOS build for the iOS version", {"version": "108", "processingState": "VALID",
                                               "pre": {"version": "1.54.0", "platform": "MAC_OS"}},
         "belongs to MAC_OS, not IOS"),
        ("a 1.53.0 build for 1.54.0", {"version": "106", "processingState": "VALID",
                                       "pre": {"version": "1.53.0", "platform": "IOS"}},
         "is version 1.53.0, not 1.54.0"),
    ]:
        f = FakeASC(build=build)
        code, out = submit(f, "ios", NOTES, "--apply")
        check(f"{name} is refused with zero writes", code == 1 and not f.writes and needle in out,
              out)
    f = FakeASC(build={"version": "108", "processingState": "VALID", "pre": {}})
    code, out = submit(f, "ios", NOTES, "--apply")
    check("a build the store gives no platform or version for is refused with zero writes",
          code == 1 and not f.writes and "cannot be checked" in out, out)
    f = FakeASC()
    f.builds = {}
    code, out = submit(f, "ios", NOTES, "--apply")
    check("a build id that does not exist is refused with zero writes",
          code == 1 and not f.writes and "does not exist" in out, out)
    f = FakeASC()
    f.versions["v1"]["appVersionState"] = f.versions["v1"].pop("appStoreState")
    code, out = submit(f, "ios", NOTES)
    check("the version state falls back to appVersionState, as in asc_push_listing",
          code == 0 and not f.writes and "state=PREPARE_FOR_SUBMISSION" in out, out)

    # 11. texts that fail the checks never reach the store
    def planted(name: str, file: str, edit) -> Path:
        d = notes_copy(name)
        p = d / file
        p.write_text(edit(p.read_text(encoding="utf-8")), encoding="utf-8")
        return d

    for name, plat, d, needle in [
        ("a macOS text naming Remote Control", "macos",
         planted("devid", "macos-en-US.txt", lambda s: s + "\n• New: Remote Control.\n"),
         "names 'Remote Control'"),
        ("a macOS text naming 遠端控制", "macos",
         planted("devid-hant", "macos-zh-Hant.txt", lambda s: s + "\n• 新增：遠端控制。\n"),
         "names '遠端控制'"),
        ("Android in the Japanese text", "ios",
         planted("android", "ja.txt", lambda s: s + "\n・Android 版も同様です。\n"),
         "names 'Android'"),
        ("a text over 4000 characters", "ios",
         planted("long", "ko.txt", lambda s: s + "\n" + "가" * 4000), "limit of 4000"),
        ("es-MX differing from es-ES", "ios",
         planted("es", "es-MX.txt", lambda s: s.replace("Casi todo", "Casi todo,", 1)),
         "share the listing directory 'es/'"),
        ("a Mainland term in zh-Hant", "ios",
         planted("hant", "zh-Hant.txt", lambda s: s.replace("工作階段", "會話", 1)),
         "uses '會話'"),
    ]:
        f = FakeASC(platform="MAC_OS" if plat == "macos" else "IOS")
        code, out = submit(f, plat, d, "--apply")
        check(f"{name}: refused before the store is contacted",
              code == 1 and not f.calls and needle in out, out)

    d = planted("devid-ios", "en-US.txt", lambda s: s + "\n• Remote Control fix.\n")
    f = FakeASC()
    code, out = submit(f, "ios", d)
    check("the direct-download-only check applies to macOS texts only", code == 0, out)

    # 12. a refused or dropped write stops before the build and the submission
    f = FakeASC()
    f.refuse = {"ko"}
    code, out = submit(f, "ios", NOTES, "--apply")
    check("a refused What's New write stops the run at once: no build, no submission",
          code == 1 and not f.attached and not f.submissions
          and "STOPPED — ko was refused" in out, out)
    f = FakeASC()
    f.drop = {"zh-Hant"}
    code, out = submit(f, "ios", NOTES, "--apply")
    check("a write the store drops is caught by the read-back: no build, no submission",
          code == 1 and not f.attached and not f.submissions and "zh-Hant" in out, out)

    # 13. the retired flag, and --create-version
    f = FakeASC()
    code, out = run(f, "--submit", "ios", "--build", "b1", "--version", "1.54.0",
                    "--whatsnew-dir", str(NOTES), "--whatsnew", str(NOTES / "en-US.txt"))
    check("--whatsnew is refused before anything else", code == 2 and not f.calls
          and "retired" in out, out)
    f = FakeASC()
    code, out = run(f, "--submit", "ios", "--build", "b1", "--version", "1.54.0")
    check("--submit without --whatsnew-dir is refused", code == 2 and not f.calls, out)

    f = FakeASC(version=False)
    code, out = run(f, "--create-version", "ios", "--version", "1.54.0")
    check("--create-version dry run writes nothing", code == 0 and not f.writes
          and "DRY RUN" in out, out)
    code, out = run(f, "--create-version", "ios", "--version", "1.54.0", "--apply")
    created = [b for m, p, b in f.writes if p == "/appStoreVersions"]
    check("--create-version --apply creates the version, MANUAL release, and nothing else",
          code == 0 and len(f.writes) == 1 and len(created) == 1
          and created[0]["data"]["attributes"] == {"platform": "IOS", "versionString": "1.54.0",
                                                   "releaseType": "MANUAL"}, out)
    code, out = run(f, "--create-version", "ios", "--version", "1.54.0", "--apply")
    check("--create-version on an existing version writes nothing",
          code == 0 and len(f.writes) == 1 and "nothing to create" in out, out)

    # 14. releaseType: what the version has is said, never changed
    f = FakeASC(release_type="AFTER_APPROVAL")
    code, out = run(f, "--create-version", "ios", "--version", "1.54.0", "--apply")
    check("--create-version on an AFTER_APPROVAL version, default MANUAL asked: warns, writes "
          "nothing", code == 0 and not f.writes and "releaseType=AFTER_APPROVAL" in out
          and "WARN  it is AFTER_APPROVAL, not the MANUAL asked for" in out, out)
    f = FakeASC(release_type="AFTER_APPROVAL")
    code, out = run(f, "--create-version", "ios", "--version", "1.54.0",
                    "--release-type", "AFTER_APPROVAL", "--apply")
    check("... and says nothing more when it is the one asked for",
          code == 0 and not f.writes and "WARN" not in out, out)
    f = FakeASC(release_type="MANUAL")
    code, out = submit(f, "ios", NOTES)
    check("--submit's dry run says the version's releaseType and what it means",
          code == 0 and "releaseType=MANUAL (after approval it waits until the owner releases "
          "it in App Store Connect)" in out, out)
    f = FakeASC()
    code, out = submit(f, "ios", NOTES)
    check("... AFTER_APPROVAL too", "releaseType=AFTER_APPROVAL (App Store Connect releases it "
          "as soon as Apple approves it)" in out, out)

    # 15. App Review notes: the detector
    def flags(notes: str) -> list[str]:
        return sub.review_notes_problems(notes, "1.54.0")

    for name, notes in [
        ("the notes 1.54.0 was submitted with", GOOD_NOTES),
        ("'since 1.53.0' with no mention of 1.54.0 in the sentence",
         "1.54.0 is a translation release.\nNo entitlement was added or changed since 1.53.0."),
        ("'unchanged from 1.53.0'", "For 1.54.0: the Mac screenshots are unchanged from 1.53.0."),
        ("'exactly as in 1.52.1'", "1.54.0: every other tab behaves exactly as in 1.52.1."),
        ("'was removed in 1.52.1' (history)", "In 1.54.0 the Swarm tab, which was removed in "
         "1.52.1, no longer appears.\nThe tab was removed in 1.52.1."),
        ("guideline and OS numbers", "1.54.0 follows Guidelines 2.1, 1.4.1 and 1.2 and needs "
         "iOS 17.0 or macOS 13.0.\nSee Guideline 1.4.1."),
        ("a later version", "1.54.0 now; 1.55.0 will add more."),
        ("another major version", "1.54.0. The helper protocol 0.9.3 is unchanged."),
        ("no version at all", "No account is needed: tap Try Demo."),
        ("sizes and prices", "1.54.0 is a 1.5 GB smaller download; Pro is $1.49 or 1.49 EUR."),
        ("empty notes", ""),
    ]:
        got = flags(notes)
        check(f"review notes not flagged: {name}", got == [], str(got))

    got = flags(COPIED_NOTES)
    check("the copied 1.53.0 notes are flagged as never naming 1.54.0",
          any("name 1.53.0, 1.52.1 and never 1.54.0" in p for p in got), str(got))
    quoted = [p.split(": ", 1)[1] for p in got if p.startswith("presents 1.53.0")]
    check("... and each claim is quoted: the heading, '1.53.0 adds', 'this 1.53.0 build', "
          "'FIXED IN 1.53.0'",
          [q[:22] for q in quoted] == ["'THE MAIN FEATURE IN 1", "'1.53.0 adds Remote Co",
                                       "'The iPhone screenshot", "'ALSO FIXED IN 1.53.0'"],
          str(got))
    check("... while its comparisons ('as in', 'since', 'was removed in') are not",
          not any("1.52.1 as the version" in p for p in got), str(got))
    half = GOOD_NOTES + "\n\nTHE MAIN FEATURE IN 1.53.0 NEEDS A SECOND DEVICE"
    got = flags(half)
    check("a stale heading left in notes that name 1.54.0 is still flagged",
          len(got) == 1 and "presents 1.53.0" in got[0] and "never" not in got[0], str(got))
    got = flags("1.54.0 ships the fixes.\nScreenshots were re-taken from this 1.53.0 build.")
    check("'this 1.53.0 build' is flagged although 'from' precedes it",
          len(got) == 1 and "this 1.53.0 build" in got[0], str(got))
    got = flags("Fixes in v1.53: the chart.")
    check("v-prefixed and two-part versions count", len(got) == 2, str(got))

    secrets = [v for v in REVIEW_CONTACT.values() if isinstance(v, str)]

    # 16. App Review notes: the 1.54.0 case, notes copied from 1.53.0
    f = FakeASC(notes=COPIED_NOTES)
    code, out = submit(f, "ios", NOTES)
    check("copied 1.53.0 notes: the dry run refuses, writes nothing",
          code == 1 and not f.writes and "REFUSED" in out and "Nothing was written" in out, out)
    check("... after printing the notes the version holds, in full",
          all(f"    | {line}" in out for line in COPIED_NOTES.splitlines() if line), out)
    check("... says why and how to fix it",
          "never 1.54.0" in out and "presents 1.53.0 as the version under review" in out
          and "pass --review-notes <file>" in out, out)
    check("... and never prints a contact or demo-account value",
          not any(v in out for v in secrets), out)
    f = FakeASC(notes=COPIED_NOTES)
    code, out = submit(f, "ios", NOTES, "--apply")
    check("... --apply refuses the same way, before the first write",
          code == 1 and not f.writes and not f.submissions, out)

    f = FakeASC()
    code, out = submit(f, "ios", NOTES)
    check("good notes: the dry run prints them and passes, secrets unprinted",
          code == 0 and all(f"    | {line}" in out for line in GOOD_NOTES.splitlines() if line)
          and "the notes name no older version" in out and not any(v in out for v in secrets),
          out)

    # 17. --review-notes FILE
    good_file = tmp / "notes-1.54.0.txt"
    good_file.write_text(GOOD_NOTES + "\n", encoding="utf-8")
    f = FakeASC(notes=COPIED_NOTES)
    code, out = submit(f, "ios", NOTES, "--review-notes", str(good_file))
    check("--review-notes over copied notes: the dry run passes, writes nothing, shows the old "
          "notes and says they will be replaced",
          code == 0 and not f.writes and "    | THE MAIN FEATURE IN 1.53.0" in out
          and f"replace the App Review notes with {good_file}" in out, out)
    f = FakeASC(notes=COPIED_NOTES)
    code, out = submit(f, "ios", NOTES, "--review-notes", str(good_file), "--apply")
    check("--review-notes --apply: submits, with the notes PATCHed once",
          code == 0 and any(s["submitted"] for s in f.submissions.values())
          and len(f.notes_writes()) == 1, out)
    check("... sending `notes` and nothing else, without the trailing newline",
          f.notes_writes() == [{"notes": GOOD_NOTES}], str(f.notes_writes()))
    check("... before What's New and before the build is attached",
          -1 < f.first_index("/appStoreReviewDetails/")
          < f.first_index("/appStoreVersionLocalizations/")
          < f.first_index("/appStoreVersions/v1/relationships/build"), str(f.writes)[:400])
    check("... the store now holds the file, every other field as it was",
          f.reviews["rd1"] == {"notes": GOOD_NOTES, **REVIEW_CONTACT}, str(f.reviews))
    check("... and the read-back said so", "review notes verified" in out, out)

    f = FakeASC(notes=GOOD_NOTES)
    code, out = submit(f, "ios", NOTES, "--review-notes", str(good_file), "--apply")
    check("--review-notes equal to the store's notes: no notes write",
          code == 0 and not f.notes_writes() and "already holds it" in out, out)

    for name, content, needle in [
        ("notes that are the copied 1.53.0 set", COPIED_NOTES, "never 1.54.0"),
        ("an empty file", "\n", "empty"),
        ("a file over 4000 characters", GOOD_NOTES + "\n" + "x" * 4000, "limit of 4000"),
    ]:
        bad = tmp / f"bad-{len(content)}.txt"
        bad.write_text(content, encoding="utf-8")
        f = FakeASC()
        code, out = submit(f, "ios", NOTES, "--review-notes", str(bad), "--apply")
        check(f"--review-notes with {name}: refused before the store is contacted",
              code == 1 and not f.calls and needle in out and "Nothing was written" in out, out)
    f = FakeASC()
    code, out = submit(f, "ios", NOTES, "--review-notes", str(tmp / "nope.txt"), "--apply")
    check("--review-notes naming no file: refused before the store is contacted",
          code == 1 and not f.calls and "no such file" in out, out)

    # 18. a notes write that does not land stops everything after it
    for mode, needle in [("refuse", "the review notes were refused"),
                         ("drop", "the notes read back are not the file"),
                         ("clobber", "these fields changed although only notes was sent: "
                                     "contactPhone")]:
        f = FakeASC(notes=COPIED_NOTES)
        f.notes_mode = mode
        code, out = submit(f, "ios", NOTES, "--review-notes", str(good_file), "--apply")
        check(f"a notes write the store {mode}s stops the run: no What's New, no build, "
              "no submission",
              code == 1 and not f.whatsnew_writes() and not f.attached and not f.submissions
              and needle in out, out)

    # 19. --accept-review-notes, and a version with no review details
    f = FakeASC(notes=COPIED_NOTES)
    code, out = submit(f, "ios", NOTES, "--accept-review-notes", "--apply")
    check("--accept-review-notes submits flagged notes as they are, with a warning",
          code == 0 and not f.notes_writes() and any(s["submitted"] for s in f.submissions.values())
          and "WARN  the notes on the version:" in out, out)
    f = FakeASC(notes=None)
    code, out = submit(f, "ios", NOTES, "--apply")
    check("a version with no App Review details is refused with zero writes",
          code == 1 and not f.writes and "no App Review details" in out, out)
    f = FakeASC()
    code, out = run(f, "--create-version", "ios", "--version", "1.54.0",
                    "--review-notes", str(good_file))
    check("--review-notes without --submit is a usage error",
          code == 2 and not f.calls and "go with --submit" in out, out)
finally:
    shutil.rmtree(tmp, ignore_errors=True)

print(f"test_asc_submit: {passed} passed, {failed} failed.")
sys.exit(1 if failed else 0)
