#!/usr/bin/env python3
"""
"Hide personal information" and account labels — the call sites the tests cannot see.

An account's label is whatever its owner typed, often the address it signs in
with. `PersonalInfoMask` (CLIPulseCore) decides what the owner sees in its place
when the switch is on, and `PersonalInfoMaskTests` pins that decision. But the
labels are SHOWN by the Mac, iPhone and Watch apps, and no test target builds
those: CLIPulseCoreTests links CLIPulseCore only. So a view that goes back to
`Label(detail.accountEmail, …)`, a call that passes `hidePersonalInfo: false`,
or a deleted line in the WatchConnectivity hand-off would put addresses back on
screen with every test still green.

This reads the app targets' Swift and checks three things:

  1. EVERY READ OF AN ACCOUNT LABEL IS INSIDE THE MASK.
     Each `.accountLabel` / `.accountEmail` read (a member access or a key
     path) must sit inside the arguments of `PersonalInfoMask.accountName(…)`
     or `PersonalInfoMask.accountLabel(…)`. The gate does not follow values: a
     label read into a local and handed to the mask a line later FAILS, so
     read it inside the call. Writes (`x.accountLabel = …`), the catalogue's
     `L10n.<table>.accountLabel` and comments or string text are not reads.
     A read that is deliberately not masked (the editor, where the label is
     typed) is recorded in scripts/personal_info_mask_allowlist.json with its
     reason; an entry that no longer matches a read fails, so the list can
     only shrink.

  2. THE SWITCH REACHES THE MASK.
     No `hidePersonalInfo: true|false` literal argument anywhere in the app
     targets, and every `var`/`let hidePersonalInfo` is either
     `@AppStorage(PersonalInfoMask.defaultsKey)` (so the view redraws the
     moment the switch changes, under the key the switch writes) or comes from
     `PersonalInfoMask` itself.

  3. THE WATCH FOLLOWS THE IPHONE.
     The Watch has no switch; the iPhone sends its own in the application
     context. `PhoneSessionManager.sendDashboardToWatch` must add the choice
     (`PersonalInfoMask.addPhoneChoice`) before the context is sent or held
     for later, and the iPhone must observe `.hidePersonalInfoDidChange` so a
     change reaches the Watch now rather than at the next refresh.
     `WatchSessionManager` must read the choice
     (`PersonalInfoMask.phoneChoice(inWatchContext:)`) and adopt it
     (`PersonalInfoMask.adoptPhoneChoice`) only after the context's owner and
     epoch are accepted: a `guard …accept(…)` earlier in the same block.

WHAT IT CANNOT SEE
  A label that reaches the screen under another name (a Core type that copies
  it into a field called something else) is invisible here; today Core carries
  labels only as `accountLabel` / `accountEmail`. Nor does it check the
  position a call passes as `index:`. It proves the wiring, not the pixels:
  the pixels are the QA render with address-shaped labels and the switch on.

Pure Python on purpose: repo-hygiene runs on Linux.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

APPLE = "CLI Pulse Bar"
TARGETS = [
    f"{APPLE}/CLI Pulse Bar",
    f"{APPLE}/CLI Pulse Bar iOS",
    f"{APPLE}/CLI Pulse Bar Watch",
    f"{APPLE}/CLI Pulse Widgets",
]
PHONE = f"{APPLE}/CLI Pulse Bar iOS/PhoneSessionManager.swift"
WATCH = f"{APPLE}/CLI Pulse Bar Watch/WatchSessionManager.swift"
ALLOWLIST = "scripts/personal_info_mask_allowlist.json"

# The calls that turn a label into what may be shown. Other PersonalInfoMask
# functions (`looksLikeEmail`) answer a question about a label; a read inside
# them is still a read.
MASKING_CALLS = {"accountName", "accountLabel"}

# Reads the real tree must have, so a moved directory or renamed field cannot
# turn this gate into one that scans nothing and passes: the Mac card, its
# VoiceOver label, the Mac rows (two labels), Settings › Providers and
# Settings › Display, the iPhone row and the Watch.
MIN_MASKED_READS_REAL_TREE = 8

LABEL_READ = re.compile(r"(\\?)\.\s*(accountLabel|accountEmail)\b")
LITERAL_SWITCH = re.compile(r"\bhidePersonalInfo\s*:\s*(true|false)\b")
SWITCH_DECL = re.compile(r"\b(?:var|let)\s+hidePersonalInfo\b")
APP_STORAGE_ON_KEY = re.compile(r"@AppStorage\s*\(\s*PersonalInfoMask\s*\.\s*defaultsKey\s*\)")
APP_STORAGE_ALONE = re.compile(r"\s*" + APP_STORAGE_ON_KEY.pattern + r"\s*")
FROM_MASK = re.compile(r"\bhidePersonalInfo\b[^=\n]*=\s*PersonalInfoMask\s*\.")
RAW_OR_PLAIN_QUOTE = re.compile(r'(#*)("""|")')
ACCEPT_GUARD = re.compile(r"\bguard\s+(?:self\s*\.\s*)?accept\s*\(")


def code_only(src: str) -> str:
    """`src` with comments and string-literal text blanked to spaces.

    Same length, newlines kept, so offsets and line numbers still map. The
    code inside an interpolation `\\( … )` stays code, with its parentheses,
    so `"\\(config.accountLabel ?? "")"` is a read inside a `(` group.
    """
    out = list(src)
    n = len(src)

    def blank(a: int, b: int) -> None:
        for k in range(a, min(b, n)):
            if out[k] != "\n":
                out[k] = " "

    # A stack of modes: ["code", open-paren depth] or ["str", hashes, multiline].
    stack: list[list] = [["code", 0]]
    i = 0
    while i < n:
        top = stack[-1]
        if top[0] == "code":
            if src.startswith("//", i):
                j = src.find("\n", i)
                j = n if j == -1 else j
                blank(i, j)
                i = j
                continue
            if src.startswith("/*", i):
                depth, k = 1, i + 2
                while k < n and depth:
                    if src.startswith("/*", k):
                        depth, k = depth + 1, k + 2
                    elif src.startswith("*/", k):
                        depth, k = depth - 1, k + 2
                    else:
                        k += 1
                blank(i, k)
                i = k
                continue
            if src[i] in '#"':
                m = RAW_OR_PLAIN_QUOTE.match(src, i)
                if m:
                    blank(i, m.end())
                    stack.append(["str", len(m.group(1)), m.group(2) == '"""'])
                    i = m.end()
                    continue
            c = src[i]
            if c == "(":
                top[1] += 1
            elif c == ")":
                if len(stack) > 1 and top[1] == 0:
                    stack.pop()          # the `)` that closes an interpolation
                    i += 1
                    continue
                top[1] -= 1
            i += 1
            continue

        _, hashes, multi = top
        close = ('"""' if multi else '"') + "#" * hashes
        escape = "\\" + "#" * hashes
        if src.startswith(close, i):
            blank(i, i + len(close))
            stack.pop()
            i += len(close)
            continue
        if src.startswith(escape + "(", i):
            blank(i, i + len(escape))    # keep the `(`: it opens a code group
            stack.append(["code", 0])
            i += len(escape) + 1
            continue
        if src.startswith(escape, i):
            blank(i, i + len(escape) + 1)
            i += len(escape) + 1
            continue
        if src[i] == "\n" and not multi:
            stack.pop()                  # unterminated; resync at the line end
            i += 1
            continue
        blank(i, i + 1)
        i += 1
    return "".join(out)


def enclosing_opens(code: str, positions: list[int]) -> dict[int, list[tuple[int, str]]]:
    """For each position, the brackets open around it as (offset, char)."""
    wanted = sorted(set(positions))
    result: dict[int, list[tuple[int, str]]] = {}
    stack: list[tuple[int, str]] = []
    w = 0
    for i, c in enumerate(code):
        while w < len(wanted) and wanted[w] == i:
            result[i] = list(stack)
            w += 1
        if c in "([{":
            stack.append((i, c))
        elif c in ")]}" and stack:
            stack.pop()
    for p in wanted[w:]:
        result[p] = list(stack)
    return result


def callee(code: str, open_paren: int) -> str | None:
    m = re.search(r"PersonalInfoMask\s*\.\s*(\w+)\s*$", code[:open_paren])
    return m.group(1) if m else None


def matching_close(code: str, open_at: int) -> int:
    depth = 0
    for i in range(open_at, len(code)):
        if code[i] in "([{":
            depth += 1
        elif code[i] in ")]}":
            depth -= 1
            if depth == 0:
                return i
    return len(code)


def line_of(src: str, offset: int) -> int:
    return src.count("\n", 0, offset) + 1


def line_text(src: str, offset: int) -> str:
    start = src.rfind("\n", 0, offset) + 1
    end = src.find("\n", offset)
    return src[start:(len(src) if end == -1 else end)].strip()


def label_reads(src: str, code: str) -> list[tuple[int, bool]]:
    """(offset of the field name, masked?) for every read of an account label."""
    found: list[int] = []
    for m in LABEL_READ.finditer(code):
        before = code[:m.start()].rstrip()
        if not m.group(1):
            if re.search(r"\bL10n\s*\.\s*\w+$", before):
                continue                 # the catalogue's "Account label" title
            if re.search(r"\bPersonalInfoMask$", before):
                continue                 # the mask itself
            if re.match(r"\s*=(?!=)", code[m.end():]):
                continue                 # a write, not a read
        found.append(m.start(2))
    opens = enclosing_opens(code, found)
    return [
        (pos, any(ch == "(" and callee(code, at) in MASKING_CALLS for at, ch in opens[pos]))
        for pos in found
    ]


def check_switch(rel: str, src: str, code: str, errors: list[str]) -> None:
    for m in LITERAL_SWITCH.finditer(code):
        errors.append(
            f"{rel}:{line_of(src, m.start())}: passes the literal `hidePersonalInfo: {m.group(1)}`;"
            " pass the switch (`@AppStorage(PersonalInfoMask.defaultsKey)`)"
        )
    lines = code.split("\n")
    for m in SWITCH_DECL.finditer(code):
        ln = line_of(src, m.start())
        here = lines[ln - 1]
        above = lines[ln - 2] if ln >= 2 else ""
        if APP_STORAGE_ON_KEY.search(here) or APP_STORAGE_ALONE.fullmatch(above):
            continue
        if FROM_MASK.search(here):
            continue
        errors.append(
            f"{rel}:{ln}: `hidePersonalInfo` is neither `@AppStorage(PersonalInfoMask.defaultsKey)`"
            " nor read from PersonalInfoMask, so the view can show addresses with the switch on"
        )


def body_of(code: str, func: str) -> tuple[int, int] | None:
    m = re.search(r"\bfunc\s+" + re.escape(func) + r"\s*\(", code)
    if not m:
        return None
    params_end = matching_close(code, m.end() - 1)
    brace = code.find("{", params_end)
    if brace == -1:
        return None
    return brace, matching_close(code, brace)


def top_level(segment: str) -> str:
    """`segment` with everything inside its brackets blanked (the brackets
    themselves kept): what runs at its own level. A guard inside an earlier
    closure does not protect a later line."""
    out, depth = [], 0
    for c in segment:
        if c in "([{":
            out.append(c if depth == 0 else " ")
            depth += 1
        elif c in ")]}":
            depth = max(0, depth - 1)
            out.append(c if depth == 0 else " ")
        else:
            out.append(c if depth == 0 or c == "\n" else " ")
    return "".join(out)


def check_phone(root: Path, errors: list[str]) -> None:
    path = root / PHONE
    if not path.is_file():
        errors.append(f"{PHONE} not found: nothing sends the iPhone's switch to the Watch")
        return
    src = path.read_text(encoding="utf-8", errors="replace")
    code = code_only(src)
    if not re.search(r"\bname\s*:\s*\.hidePersonalInfoDidChange\b", code):
        errors.append(
            f"{PHONE}: does not observe `.hidePersonalInfoDidChange`, so the Watch keeps the old"
            " choice until the next data refresh"
        )
    span = body_of(code, "sendDashboardToWatch")
    if span is None:
        errors.append(f"{PHONE}: `func sendDashboardToWatch` not found; the gate cannot see where the context is built")
        return
    a, b = span
    body = code[a:b]
    add = re.search(r"PersonalInfoMask\s*\.\s*addPhoneChoice\s*\(\s*(\w+)", body)
    if not add:
        errors.append(
            f"{PHONE}: sendDashboardToWatch does not call `PersonalInfoMask.addPhoneChoice`, so the"
            " Watch never learns the iPhone's switch"
        )
        return
    if add.group(1) in ("true", "false"):
        errors.append(f"{PHONE}:{line_of(src, a + add.start())}: sends the literal `{add.group(1)}` instead of the switch")
    for sent in (r"updateApplicationContext\s*\(", r"\bpendingContext\s*=\s*context\b"):
        s = re.search(sent, body)
        if s and s.start() < add.start():
            errors.append(
                f"{PHONE}:{line_of(src, a + s.start())}: the context leaves before"
                " `PersonalInfoMask.addPhoneChoice` adds the switch to it"
            )


def check_watch(root: Path, errors: list[str]) -> None:
    path = root / WATCH
    if not path.is_file():
        errors.append(f"{WATCH} not found: nothing adopts the iPhone's switch on the Watch")
        return
    src = path.read_text(encoding="utf-8", errors="replace")
    code = code_only(src)
    if not re.search(r"PersonalInfoMask\s*\.\s*phoneChoice\s*\(\s*inWatchContext\s*:", code):
        errors.append(f"{WATCH}: never reads the iPhone's choice (`PersonalInfoMask.phoneChoice(inWatchContext:)`)")
    adopts = list(re.finditer(r"PersonalInfoMask\s*\.\s*adoptPhoneChoice\s*\(\s*(\w+)", code))
    if not adopts:
        errors.append(
            f"{WATCH}: never calls `PersonalInfoMask.adoptPhoneChoice`, so the Watch shows every"
            " address whatever the iPhone's switch says"
        )
        return
    opens = enclosing_opens(code, [m.start() for m in adopts])
    for m in adopts:
        ln = line_of(src, m.start())
        if m.group(1) in ("true", "false"):
            errors.append(f"{WATCH}:{ln}: adopts the literal `{m.group(1)}` instead of the iPhone's choice")
        blocks = [at for at, ch in opens[m.start()] if ch == "{"]
        if not any(ACCEPT_GUARD.search(top_level(code[at + 1:m.start()])) for at in blocks):
            errors.append(
                f"{WATCH}:{ln}: adopts the choice without a `guard …accept(…)` before it in the same"
                " block, so a context from another account or an older epoch could change it"
            )


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    real_tree = "--root" not in sys.argv
    if not real_tree:
        root = Path(sys.argv[sys.argv.index("--root") + 1]).resolve()

    errors: list[str] = []
    allow_path = root / ALLOWLIST
    entries = json.loads(allow_path.read_text(encoding="utf-8"))["entries"] if allow_path.exists() else []
    allowed: dict[tuple[str, str], dict] = {}
    for e in entries:
        key = (e["path"], e["line"].strip())
        if key in allowed:
            errors.append(f'{e["path"]}: "{e["line"]}" is allowlisted twice')
        allowed[key] = e
        if len((e.get("reason") or "").strip()) < 30:
            errors.append(f'{e["path"]}: "{e["line"]}" needs a real reason why this label is shown unmasked')

    used: set[tuple[str, str]] = set()
    masked = 0
    scanned = 0
    for rel_dir in TARGETS:
        base = root / rel_dir
        if not base.is_dir():
            if real_tree:
                errors.append(f"{rel_dir} not found: the gate is not looking where the app targets are")
            continue
        for path in sorted(base.rglob("*.swift")):
            if "/.build/" in str(path):
                continue
            scanned += 1
            rel = str(path.relative_to(root))
            src = path.read_text(encoding="utf-8", errors="replace")
            code = code_only(src)
            for pos, is_masked in label_reads(src, code):
                if is_masked:
                    masked += 1
                    continue
                key = (rel, line_text(src, pos))
                if key in allowed:
                    used.add(key)
                    continue
                errors.append(
                    f"{rel}:{line_of(src, pos)}: `{code[pos:pos + 12].strip()}` is read outside"
                    f" PersonalInfoMask.accountName/accountLabel: {key[1]}"
                )
            check_switch(rel, src, code, errors)

    for key in allowed:
        if key not in used:
            errors.append(f'{key[0]}: allowlisted "{key[1]}" no longer reads a label unmasked — stale entry, delete it')

    check_phone(root, errors)
    check_watch(root, errors)

    if real_tree and masked < MIN_MASKED_READS_REAL_TREE:
        errors.append(
            f"only {masked} masked label reads found (expected at least {MIN_MASKED_READS_REAL_TREE}):"
            " the gate is not seeing the places that name accounts"
        )

    if errors:
        print("personal info mask: FAILED\n")
        for e in errors:
            print(f"  - {e}")
        print(
            "\nWith \"Hide personal information\" on, an account label that is an email address must not"
            " reach the screen.\nRead the label inside PersonalInfoMask.accountName(...) or"
            " PersonalInfoMask.accountLabel(...) with the switch from\n"
            "@AppStorage(PersonalInfoMask.defaultsKey), or, if it must show as typed, record the line in"
            f"\n{ALLOWLIST} with the reason."
        )
        return 1
    print(
        f"personal info mask: OK — {scanned} Swift files, {masked} label reads masked,"
        f" {len(used)} shown as typed with a recorded reason; the Watch follows the iPhone."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
