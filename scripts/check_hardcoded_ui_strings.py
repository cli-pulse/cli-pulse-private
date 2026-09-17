#!/usr/bin/env python3
"""
Hardcoded English in the Apple UI — the half the parity gate cannot see.

`check_apple_strings_parity.py` compares keys BETWEEN .lproj catalogues. A
string that was never externalized has no key, so there is nothing for it to
find missing. On 2026-09-10 the zh-Hans App Store screenshots were shot from the
real app and its Sessions tab still said "Active", "recent activity" and
"Running = process confirmed. Recent = JSONL activity only." in English — with
the parity gate green, because it was correctly reporting that every key had a
translation. The strings simply were not keys.

WHAT IT CHECKS
Every string literal that reaches a user-facing SwiftUI/AppKit/App Intents API,
and every literal handed back from a property or function whose name says it is
display copy (label, title, subtitle, caption, header, hint, message,
placeholder, description …) or that is typed String and returns a phrase, in the
app, watch, widget and CLIPulseCore sources. "Reaches" means:
  * the first argument of a view or modifier — Text, Button, Label, Section,
    ProgressView, LabeledContent, DisclosureGroup, Stepper, Window, .help,
    .alert, .badge, .accessibilityLabel/Value/Hint, .configurationDisplayName,
    .description, Text(verbatim:) …; a header:/title:/message: argument of any
    call; a label:/text:/detail: argument of a call that builds a view;
  * as a whole argument, not only when the literal comes first: a ternary
    branch, a `??` fallback, a concatenation, and on the line after the call;
  * an assignment to messageText, informativeText, .title, .body, toolTip …;
  * an element of an array literal that ForEach iterates;
  * a local `let` whose value is later handed to any of the above;
  * `return "…"`, an implicit return (`var subtitle: String { "…" }`), and a
    `case …: "…"` arm, judged against the enclosing func or property — kept by
    brace depth, so `guard let`, `if let` and local `let`s inside the body do
    not replace it (they used to, and hid everything after them).
Copy is any literal with words outside its interpolations: two ASCII letters in
a row, or any letter in another script — "最近活动" and "한국어" count.
App Intents metadata is localized by the system from the APP bundle's tables,
so a literal there passes when every shipped `<lang>.lproj/Localizable.strings`
of its target has it as a key, and fails when one does not.

A RATCHET, NOT A BAR — same reasoning as the parity gate
Some literals are correct as they are: product and provider names, protocol
tokens, shell commands, DEBUG-only menus, persisted raw values. Those live in
`scripts/hardcoded_ui_strings_baseline.json`, each with the reason it is allowed.
A reason starts with its category (REASON_CATEGORIES below) and gives evidence.
A placeholder such as TODO or NEEDS_JUDGMENT FAILS: deferring the decision is
not a reason to ship English.
  * a literal that is not in the baseline FAILS  — new hardcoded copy is caught
    in the PR that adds it;
  * a baseline entry whose literal is gone FAILS — so the allowlist can only
    shrink, and cannot quietly cover something new under a stale entry.
Entries are keyed by (file, literal, count), not line numbers, so unrelated
edits above a literal do not churn the baseline.

INTERPOLATION
`Text("tokens · \\(x)")` is a hardcoded English word with a variable in it. The
first inventory for this sweep used a regex that rejected backslashes inside the
literal and so structurally could not see it. Literals here come from a small
tokenizer that tracks `\\( … )` depth and nested literals, so neither that nor a
quoted dictionary key inside an interpolation cuts a literal short. Multi-line
triple-quoted string literals are out of scope for a line scanner.

ANDROID (added 2026-09-17)
The Android app had no equivalent, so Kotlin copy was invisible to every gate:
`Text("Resets in ${h}h")`, a share-sheet title, `error = "Session expired…"`
shown in a banner. Kotlin sources under android/app/src/main/java are scanned
with their own tokenizer (`${ … }` templates and `$name`) and their own sinks
(Compose `Text(`, `contentDescription =`, `label =`, `title =`,
`Intent.createChooser`, `NotificationChannel`, UI-state error fields …). A
Compose call usually puts its argument on the NEXT line, so for Kotlin the
text before a literal includes the previous code line when the literal starts
its own line. Same baseline, same ratchet, same reasons.

Pure Python on purpose: repo-hygiene runs on Linux.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

APP = "CLI Pulse Bar"
SCAN_DIRS = [
    f"{APP}/CLI Pulse Bar",
    f"{APP}/CLI Pulse Bar iOS",
    f"{APP}/CLI Pulse Bar Watch",
    f"{APP}/CLI Pulse Widgets",
    f"{APP}/CLIPulseCore/Sources/CLIPulseCore",
]
SKIP_PARTS = {".build", "Tests", "codexbar", "scripts", "DerivedData", "build"}
BASELINE_DEFAULT = "scripts/hardcoded_ui_strings_baseline.json"

# ---- literal tokenizer -------------------------------------------------------
# A regex cannot delimit a Swift literal whose interpolation contains another
# literal: `"\(dict["k"] ?? "")"`. The first version of this gate used one and
# cut such literals off at the inner quote — only ever producing false alarms,
# never misses, but leaving allowlist keys that were fragments of code. This
# walks the line and tracks `\( … )` depth and nested literals instead.

def _scan_string(line: str, i: int) -> int:
    """i is just past an opening quote; return index just past the closing one, or -1."""
    n = len(line)
    while i < n:
        c = line[i]
        if c == '\\':
            if i + 1 < n and line[i + 1] == '(':
                i = _scan_interp(line, i + 2)
                if i < 0:
                    return -1
                continue
            i += 2
            continue
        if c == '"':
            return i + 1
        i += 1
    return -1


def _scan_interp(line: str, i: int) -> int:
    """i is just past `\\(`; return index just past the matching `)`, or -1."""
    depth, n = 1, len(line)
    while i < n:
        c = line[i]
        if c == '"':
            j = _scan_string(line, i + 1)
            if j < 0:
                return -1
            i = j
            continue
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return -1


def literals(line: str) -> list[tuple[int, str]]:
    """(start index, literal incl. quotes) for each single-line literal; stops at a // comment."""
    out, i, n = [], 0, len(line)
    while i < n:
        if line.startswith('//', i):
            break
        if line[i] == '"':
            if line.startswith('"""', i):          # multi-line literal: out of scope for a line scanner
                break
            j = _scan_string(line, i + 1)
            if j < 0:
                break
            out.append((i, line[i:j]))
            i = j
            continue
        i += 1
    return out


def without_interpolations(body: str) -> str:
    out, i, n = [], 0, len(body)
    while i < n:
        if body[i] == '\\' and i + 1 < n and body[i + 1] == '(':
            j = _scan_interp(body, i + 2)
            if j < 0:
                break
            i = j
            continue
        out.append(body[i])
        i += 1
    return ''.join(out)


DISPLAY_NAME = re.compile(r'label|title|caption|header|footer|hint|message|placeholder|description|'
                          r'displayname|text|subtitle|summary|reason|badge|chip|tooltip|headline|detail|explanation', re.I)
# A name list always has gaps (`var badge: String` returned "recent activity" and was missed by the first
# version of this list). So a second, structural signal: a multi-word phrase returned from a declaration
# typed String is prose whatever the property is called. Words are separated by spaces and prose punctuation,
# or a hyphen before a capital ("Heart-Eyes") — not a bare `.` or a lowercase `-`, which join the parts of an
# SF Symbol name, a bundle id or a host ("exclamationmark.triangle.fill", "com.clipulse.app",
# "status.claude.com"): 59 allowlist entries existed only because the separator class accepted them.
PHRASE = re.compile(r'[A-Za-z]{2,}(?:[\s,;:·—]+|\.\s+|-(?=[A-Z]))[A-Za-z]{2,}')

# Scripts that do not separate words with spaces (kana, CJK ideographs, Hangul): one character is a word.
_CJK = re.compile('[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7af\uf900-\ufaff]')
# Words separated by spaces, or CJK text: what a stored `let` needs to be prose rather than an identifier.
SPACED_PHRASE = re.compile(r'[A-Za-z]{2,}\s+[A-Za-z]{2,}|' + _CJK.pattern)


def has_words(text: str) -> bool:
    """Two ASCII letters in a row, one CJK/kana/Hangul character, or any other non-ASCII letter.

    The first version asked only for `[A-Za-z]{2,}`, so "한국어", "最近活动" and every other
    literal written in a script the app ships were invisible, while "English" beside them was seen.
    """
    if re.search(r'[A-Za-z]{2,}', text) or _CJK.search(text):
        return True
    return any(ch.isalpha() and ord(ch) > 127 for ch in text)


def is_copy(literal: str) -> bool:
    """Literals that could be prose: words outside any interpolation."""
    return has_words(without_interpolations(literal[1:-1]))


# ---- Swift: where a literal ends up ------------------------------------------
#
# The first version looked only at the text directly in front of a literal on
# its own line (`Text("…")`, `title: "…"`, `return "…"`) and remembered the
# enclosing declaration as "the last `let`/`var`/`func` seen". Everything SwiftUI
# writes routinely around a literal fell through, with the gate green:
#   Text(isOn ? "Enabled" : "Disabled")          a ternary branch
#   Text(name ?? "Unknown account")              a nil-coalescing fallback
#   Label(\n    "QA preview uses …",             the literal on the next line
#   alert.messageText = "…"                      an assignment
#   var subtitle: String { "Tap to pair" }       an implicit return
#   let label = "Local session" … Text(label)    a local handed to a sink
#   ForEach(["Critical", "Warning"], …)          an array rendered row by row
#   func tooltip() -> String {                   a `guard let` / `if let` / local
#       guard let day = … else { … }             `let` replaced `tooltip` as the
#       return "\(key): \(n) tokens"             context, so the return was unseen
# So a literal's call is found by walking back through the joined code lines to
# the bracket that encloses it, its argument is judged as a whole, and the
# enclosing declaration is a scope kept by brace depth, which a local binding
# cannot replace.

# Calls whose first positional argument is rendered.
SWIFT_CALL_SINKS = frozenset({
    'Text', 'Button', 'Toggle', 'Label', 'Section', 'TextField', 'SecureField', 'Picker', 'Menu', 'Link',
    'ContentUnavailableView', 'CommandMenu', 'NavigationLink', 'ProgressView', 'LabeledContent', 'GroupBox',
    'DisclosureGroup', 'Stepper', 'DatePicker', 'ColorPicker', 'ShareLink', 'Window', 'WindowGroup',
    'MenuBarExtra', 'Tab', 'LocalizedStringKey',
    '.help', '.navigationTitle', '.navigationSubtitle', '.alert', '.confirmationDialog',
    '.accessibilityLabel', '.accessibilityHint', '.accessibilityValue', '.badge',
    '.configurationDisplayName', '.description',
    # `CredentialIssue.serverMessage` passes server text through untranslated; a literal
    # there is an English message that has escaped the typed credential catalogue.
    '.serverMessage',
    # App Intents: shown by the system in Shortcuts, Spotlight and Siri.
    'IntentDescription', 'IntentDialog', 'Summary', 'LocalizedStringResource',
})
# App Intents metadata is read by the system from the APP bundle's Localizable.strings
# (Shortcuts, Spotlight, Siri — sometimes before the app has run), keyed by the literal.
# It cannot go through L10n; it is localized when every shipped table has the key.
SWIFT_INTENT_CALLS = frozenset({'IntentDescription', 'IntentDialog', 'Summary', 'LocalizedStringResource',
                                'Parameter', 'AppShortcut', 'DisplayRepresentation'})
POSITIONAL_LABELS = (None, 'verbatim', 'stringLiteral')
# Argument labels whose value is rendered, whatever the call.
SWIFT_LABEL_SINK = re.compile(r'(?:header|footer|title|subtitle|message|placeholder|prompt|caption|shortTitle|categoryName)$')
# Argument labels whose value is rendered when the call builds a view or a model of one:
# `diagnosticRow(label:)`, `copyButton(text:)`, `ProviderOption(label:)`, `Row(accessibilityLabel:)`.
# The same words label queues, parsers and log sources (`DispatchQueue(label:)`,
# `parseWindow(label: "Weekly", html:)`, `readSnapshot(sourceLabel: "cache")`), so the call decides.
SWIFT_VIEW_LABEL_SINK = re.compile(r'(?:label|text|detail|\w+(?:Label|Title|Message|Hint|Caption|Subtitle|Placeholder|Tooltip))$')
SWIFT_VIEW_CALL = re.compile(r'^[A-Z]\w*$|(?:Row|Button|Chip|Label|Cell|Badge|Card|Header|Footer|Section|View|Pill|Tile|'
                             r'Banner|Item|Line|Field|Text|Option|Toast)$')
SWIFT_NON_UI_CALLS = frozenset({'DispatchQueue', 'OperationQueue', 'Logger', 'OSLog', 'OSSignposter', 'Thread',
                                'NSLock', 'NSRecursiveLock', 'OSAllocatedUnfairLock', 'NSError', 'URLQueryItem'})
# Calls whose first argument is iterated with each element rendered.
SWIFT_ITERATING_SINKS = frozenset({'ForEach'})
# Assignments that put text on screen: AppKit/UIKit/UserNotifications properties, and
# declarations typed as localized resources.
SWIFT_ASSIGN_SINK = re.compile(
    r'(?:\.(?:messageText|informativeText|title|subtitle|body|toolTip|stringValue|placeholderString|prompt|'
    r'message|nameFieldLabel|accessibilityLabel|accessibilityValue|accessibilityHint)'
    r'|(?P<intent>:\s*(?:LocalizedStringResource|TypeDisplayRepresentation|IntentDescription)\??)'
    r'|:\s*LocalizedStringKey\??)'
    r'\s*=\s*$')
# Where a value is handed back: `return`, a `case …:` / `default:` arm, or a body that opens
# straight onto the value (`var subtitle: String { "…" }`, `else { "…" }`).
SWIFT_RESULT_HEAD = re.compile(r'\breturn\b|\bcase\b[^:;{}]*:|\bdefault\s*:|\{')
SWIFT_BINDING_HEAD = re.compile(r'\b(?:let|var)\s+(\w+)\s*(?::\s*String\??\s*)?=\s*$')
TYPE_KEYWORD = re.compile(r'\b(?:struct|class|enum|extension|protocol|actor)\s+(?!func\b|var\b|let\b|init\b)\w')
FUNC_KEYWORD = re.compile(r'\bfunc\s+([^\s(<]+)|(?<![.\w])(init|subscript|deinit)\b\s*[?!]?\s*[(<{]')
BINDING_KEYWORD = re.compile(r'\b(?:var|let)\s+(\w+)')
PATTERN_BINDING = re.compile(r'\b(?:case|if|guard|while|for)\b|[,(]\s*$')


def value_lead_ok(rest: str) -> bool:
    """True when `rest` (code between the start of a value and a literal) leaves the literal as the value.

    Empty; a ternary branch (`cond ?`, `cond ? "" :`); a nil-coalescing fallback (`x ??`);
    or a concatenation (`name +`).
    """
    rest = rest.strip()
    if not rest:
        return True
    if rest.endswith('??') or rest.endswith('+'):
        return True
    return '?' in rest and (rest.endswith('?') or rest.endswith(':'))


def enclosing_bracket(ctx: str, pos: int) -> tuple[int, str, int, int] | None:
    """Walk back from pos to the unclosed `(` or `[` around it.

    Returns (index, bracket, top-level commas before pos, start of the current argument), or
    None when pos is not inside a bracket of its statement (an enclosing `{` or a `;` comes first).
    """
    nest = brace = commas = 0
    arg_start = -1
    i = pos - 1
    while i >= 0:
        c = ctx[i]
        if c in ')]':
            nest += 1
        elif c == '}':
            brace += 1
        elif c == '{':
            if brace == 0:
                return None
            brace -= 1
        elif c in '([':
            if nest == 0 and brace == 0:
                return i, c, commas, (arg_start if commas else i + 1)
            nest -= 1
        elif nest == 0 and brace == 0:
            if c == ',':
                if commas == 0:
                    arg_start = i + 1
                commas += 1
            elif c == ';':
                return None
        i -= 1
    return None


def call_name(ctx: str, bracket_index: int) -> tuple[str, int]:
    """(name, start) of the call whose `(` is at bracket_index: `Text`, `.help`, `Parameter`."""
    m = re.search(r'@?(\.?[A-Za-z_]\w*)\s*(?:<[^<>()]*>)?\s*$', ctx[:bracket_index])
    return (m.group(1), m.start()) if m else ('', bracket_index)


def split_label(segment: str) -> tuple[str | None, str]:
    m = re.match(r'\s*([A-Za-z_]\w*)\s*:(?!:)\s*(.*)$', segment, re.S)
    if m and not re.match(r'\s*\w+\s*\?', segment):
        return m.group(1), m.group(2)
    return None, segment


def call_sink(ctx: str, pos: int) -> tuple[str, int] | None:
    """How the value at ctx[pos] is rendered by the call around it.

    ('ui' | 'intent', pos) when it is; ('through', start) when it is the format of a
    `String(format:)` whose own position decides; None otherwise.
    """
    found = enclosing_bracket(ctx, pos)
    if not found:
        return None
    index, bracket, commas, arg_start = found
    label, rest = split_label(ctx[arg_start:pos])
    if not value_lead_ok(rest):
        return None
    if bracket == '[':
        # An element of an array literal: rendered when the array is what ForEach iterates.
        if label is not None:
            return None
        outer = enclosing_bracket(ctx, index)
        if outer and outer[1] == '(' and outer[2] == 0:
            outer_label, outer_rest = split_label(ctx[outer[3]:index])
            if (outer_label is None and not outer_rest.strip()
                    and call_name(ctx, outer[0])[0] in SWIFT_ITERATING_SINKS):
                return 'ui', pos
        return None
    name, name_start = call_name(ctx, index)
    kind = 'intent' if name in SWIFT_INTENT_CALLS else 'ui'
    if label is not None and SWIFT_LABEL_SINK.match(label):
        return kind, pos
    if (label is not None and SWIFT_VIEW_LABEL_SINK.match(label)
            and SWIFT_VIEW_CALL.search(name.lstrip('.')) and name not in SWIFT_NON_UI_CALLS):
        return kind, pos
    if commas == 0 and label in POSITIONAL_LABELS and name in SWIFT_CALL_SINKS:
        return kind, pos
    if commas == 0 and name == 'String' and label in (None, 'format'):
        return 'through', name_start
    return None


def result_position(ctx: str, pos: int) -> bool:
    """True when the value at ctx[pos] is what the enclosing body or `case` arm hands back."""
    if enclosing_bracket(ctx, pos):
        return False
    heads = list(SWIFT_RESULT_HEAD.finditer(ctx, 0, pos))
    if not heads:
        return False
    rest = ctx[heads[-1].end():pos]
    return ';' not in rest and '=' not in rest.replace('==', '') and value_lead_ok(rest)


def strip_value_lead(before: str) -> str:
    """`x = cond ? "" : ` → `x = `, so an assignment or binding head still matches through a ternary."""
    m = re.search(r'(=\s*)([^=;{}()]*)$', before)
    if m and value_lead_ok(m.group(2)):
        return before[:m.end(1)]
    return before


class _Scope:
    __slots__ = ('depth', 'kind', 'name', 'is_string', 'locals')

    def __init__(self, depth: int, kind: str, name: str, is_string: bool):
        self.depth, self.kind, self.name, self.is_string = depth, kind, name, is_string
        self.locals: dict[str, list[tuple[tuple[int, int, str], str]]] = {}


def code_line(line: str, lits: list[tuple[int, str]]) -> str:
    """The line with each literal's contents blanked (same length) and any // comment removed."""
    chars = list(line)
    for start, lit in lits:
        for k in range(start + 1, start + len(lit) - 1):
            chars[k] = ' '
    code = ''.join(chars)
    cut = code.find('//')
    return code if cut < 0 else code[:cut]


def scan_swift_file(path: Path) -> list[tuple[int, str, str]]:
    """(line, literal, 'ui' | 'intent') for every literal that reaches a user-facing sink."""
    found: dict[tuple[int, int, str], str] = {}
    lines = path.read_text(encoding='utf-8', errors='replace').splitlines()
    stack: list[_Scope] = []
    pending: list | None = None          # [kind, name, signature so far, line, column] of a declaration awaiting `{`
    depth = 0
    window: list[str] = []               # previous code lines, for values that wrap onto the next line
    in_block_comment = in_multiline_literal = False

    def context() -> _Scope | None:
        """The func or computed property whose body this is — never a local binding or a closure."""
        for s in reversed(stack):
            if s.kind in ('func', 'var'):
                return s
            if s.kind == 'type':
                return None
        return None

    for n, line in enumerate(lines, 1):
        stripped = line.lstrip()
        if in_multiline_literal:
            if '"""' in line:
                in_multiline_literal = False
                window.clear()
            continue
        if in_block_comment:
            in_block_comment = '*/' not in line
            continue
        if stripped.startswith('/*'):
            in_block_comment = '*/' not in stripped
            continue
        # Swift requires each `#if` branch to be balanced, so its braces can be counted in sequence.
        if not stripped or stripped.startswith(('//', '*', '@available', '#if', '#else', '#elseif', '#endif')):
            continue
        lits = literals(line)
        code = code_line(line, lits)
        base = ' '.join(window) + ' '
        offset = len(base)
        ctx = base + code

        events: list[tuple[int, int, str, object]] = []
        for m in TYPE_KEYWORD.finditer(code):
            events.append((m.start(), 1, 'type', ''))
        for m in FUNC_KEYWORD.finditer(code):
            events.append((m.start(), 1, 'func', m.group(1) or m.group(2)))
        for m in BINDING_KEYWORD.finditer(code):
            events.append((m.start(), 1, 'binding', m.group(1)))
        for i, c in enumerate(code):
            if c in '{}':
                events.append((i, 1, c, ''))
        for start, lit in lits:
            events.append((start, 0, 'literal', lit))
        events.sort(key=lambda e: (e[0], e[1]))

        for pos, _, kind, payload in events:
            if kind in ('type', 'func'):
                pending = [kind, str(payload), code[pos:], n, pos]
            elif kind == 'binding':
                # A binding inside a body — `let x = …`, `guard let x`, `if let x`, `case .a(let x)` —
                # is local. Only a stored or computed property at type level is a context.
                if context() is None and not PATTERN_BINDING.search(code[:pos]):
                    pending = ['var', str(payload), code[pos:], n, pos]
            elif kind == '{':
                if pending:
                    sig = (pending[2] + ' ' + code[:pos]) if pending[3] != n else code[pending[4]:pos]
                    is_string = bool(re.search(r'(?:->|:)\s*String\b', sig))
                    stack.append(_Scope(depth + 1, pending[0], pending[1], is_string))
                    pending = None
                else:
                    stack.append(_Scope(depth + 1, 'block', '', False))
                depth += 1
            elif kind == '}':
                depth = max(0, depth - 1)
                while stack and stack[-1].depth > depth:
                    stack.pop()
                pending = None
            elif kind == 'literal':
                lit = str(payload)
                if not is_copy(lit):
                    continue
                at = offset + pos
                key = (n, pos, lit)
                sink = call_sink(ctx, at)
                if sink and sink[0] in ('ui', 'intent'):
                    found[key] = sink[0]
                    continue
                value_at = sink[1] if sink else at
                before = strip_value_lead(ctx[:value_at])
                assign = SWIFT_ASSIGN_SINK.search(before)
                if assign:
                    found[key] = 'intent' if assign.group('intent') else 'ui'
                    continue
                scope = context()
                phrase = PHRASE.search(without_interpolations(lit[1:-1])) is not None
                if scope and result_position(ctx, value_at) and (
                        DISPLAY_NAME.search(scope.name) or (scope.is_string and phrase)):
                    found[key] = 'ui'
                    continue
                binding = SWIFT_BINDING_HEAD.search(before)
                if binding and not enclosing_bracket(ctx, value_at):
                    if DISPLAY_NAME.search(binding.group(1)) and SPACED_PHRASE.search(without_interpolations(lit[1:-1])):
                        found[key] = 'ui'           # `let emptyMessage = "No sessions yet"`, not `agentLabel = "a.b-C"`
                    elif scope:
                        scope.locals.setdefault(binding.group(1), []).append((key, 'value'))
                    continue
                # An element of a local array: `let severities = ["Critical", "Warning"]` … `ForEach(severities`.
                bracket = enclosing_bracket(ctx, value_at)
                if scope and bracket and bracket[1] == '[' and bracket[2] >= 0:
                    label, rest = split_label(ctx[bracket[3]:value_at])
                    element_binding = SWIFT_BINDING_HEAD.search(strip_value_lead(ctx[:bracket[0]]))
                    if label is None and value_lead_ok(rest) and element_binding:
                        scope.locals.setdefault(element_binding.group(1), []).append((key, 'element'))
        # A local handed to a sink: `let label = "Local \(name) session"` … `Text(label)`,
        # or an array of copy handed to ForEach.
        for s in stack:
            for name, origins in s.locals.items():
                for m in re.finditer(r'(?<![\w.$\\])' + re.escape(name) + r'\b(?!:|\s*[(.=\[])', code):
                    at = offset + m.start()
                    sink = call_sink(ctx, at)
                    rendered = bool(sink and sink[0] in ('ui', 'intent')) or bool(
                        SWIFT_ASSIGN_SINK.search(strip_value_lead(ctx[:at])))
                    iterated = False
                    around = enclosing_bracket(ctx, at)
                    if around and around[1] == '(' and around[2] == 0 and call_name(ctx, around[0])[0] in SWIFT_ITERATING_SINKS:
                        label, rest = split_label(ctx[around[3]:at])
                        iterated = label is None and not rest.strip()
                    for origin, how in origins:
                        if (how == 'value' and rendered) or (how == 'element' and iterated):
                            found.setdefault(origin, 'ui')
        if pending and pending[3] != n:
            pending[2] += ' ' + code
        if code.count('"""') % 2 == 1:
            in_multiline_literal = True     # its lines are text, not code: a JS `return "…"` is not Swift
            window.clear()
        elif code.strip():
            window.append(code.strip())
            del window[:-16]
    return [(n, lit, kind) for (n, _, lit), kind in sorted(found.items())]


def scan_file(path: Path) -> list[tuple[int, str]]:
    return [(n, lit) for n, lit, _ in scan_swift_file(path)]


# ---- App-bundle string tables (App Intents) -------------------------------------

APP_BUNDLE_LOCALES = ("en", "es", "ja", "ko", "zh-Hans", "zh-Hant")


def strings_keys(path: Path) -> set[str]:
    if not path.is_file():
        return set()
    text = path.read_text(encoding='utf-8', errors='replace')
    return set(re.findall(r'^\s*"((?:[^"\\]|\\.)*)"\s*=', text, re.M))


def intent_key(literal: str) -> str:
    """The table key App Intents looks up: `\\(\\.$provider)` is written `${provider}`."""
    body = literal[1:-1]
    return re.sub(r'\\\(\\?\.\$?(\w+)\)', r'${\1}', body)


def app_bundle_tables(root: Path, rel: Path) -> list[set[str]] | None:
    """Keys of every shipped Localizable.strings (and AppShortcuts.strings) of the target holding rel."""
    for d in SCAN_DIRS:
        if rel.as_posix().startswith(d + '/'):
            target = root / d
            tables = []
            for loc in APP_BUNDLE_LOCALES:
                keys = strings_keys(target / f"{loc}.lproj" / "Localizable.strings")
                keys |= strings_keys(target / f"{loc}.lproj" / "AppShortcuts.strings")
                tables.append(keys)
            return tables if all(tables) else None
    return None


# ---- Kotlin -------------------------------------------------------------------

KOTLIN_DIR = "android/app/src/main/java"


def _kt_scan_string(line: str, i: int) -> int:
    """i is just past an opening quote; return index just past the closing one, or -1."""
    n = len(line)
    while i < n:
        c = line[i]
        if c == '\\':
            i += 2
            continue
        if c == '$' and i + 1 < n and line[i + 1] == '{':
            i = _kt_scan_template(line, i + 2)
            if i < 0:
                return -1
            continue
        if c == '"':
            return i + 1
        i += 1
    return -1


def _kt_scan_template(line: str, i: int) -> int:
    """i is just past `${`; return index just past the matching `}`, or -1."""
    depth, n = 1, len(line)
    while i < n:
        c = line[i]
        if c == '"':
            j = _kt_scan_string(line, i + 1)
            if j < 0:
                return -1
            i = j
            continue
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return -1


def kotlin_literals(line: str) -> list[tuple[int, str]]:
    out, i, n = [], 0, len(line)
    while i < n:
        if line.startswith('//', i):
            break
        if line[i] == "'":                       # a char literal such as '"' must not open a string
            m = re.match(r"'(?:\\.|[^'\\])'", line[i:])
            if m:
                i += m.end()
                continue
        if line[i] == '"':
            if line.startswith('"""', i):        # raw string: out of scope for a line scanner
                break
            j = _kt_scan_string(line, i + 1)
            if j < 0:
                break
            out.append((i, line[i:j]))
            i = j
            continue
        i += 1
    return out


def kotlin_without_templates(body: str) -> str:
    out, i, n = [], 0, len(body)
    while i < n:
        if body[i] == '$' and i + 1 < n and body[i + 1] == '{':
            j = _kt_scan_template(body, i + 2)
            if j < 0:
                break
            i = j
            continue
        if body[i] == '$' and i + 1 < n and (body[i + 1].isalpha() or body[i + 1] == '_'):
            m = re.match(r'\$\w+', body[i:])
            i += m.end()
            continue
        out.append(body[i])
        i += 1
    return ''.join(out)


# Sinks that render their argument. Compose names are discovered per tree (every
# `@Composable fun Name(`), so the app's own `EditableSettingRow("Usage Spike")`
# counts without a hand-kept list; these are the framework ones.
KT_FRAMEWORK_COMPOSABLES = ("Text", "AlertDialog", "Tab", "NavigationBarItem", "DropdownMenuItem")
KT_NAMED_SINKS = (
    r'text|contentDescription|label|placeholder|title|subtitle|message|trailingText|supportingText|'
    r'headline|description|hint|confirmText|dismissText|chooserTitle|'
    # UI-state fields a screen renders verbatim.
    r'error|errorMessage|mutationError|deleteError|linkIdentityError|statusMessage|notice|userName|displayName'
)
# What may sit between a sink and the literal and still be the rendered value:
# `x ?: "…"`, `if (demo) "…"`, `else "…"`.
KT_VALUE_LEAD = r'(?:[\w.()!]+\s*\?:\s*|if\s*\(.*\)\s*|else\s+)?'
KT_CALL_SINKS = (
    r'\bcreateChooser\s*\([^()]*,\s*'
    r'|\bNotificationChannel\s*\([^()]*,\s*'
    r'|\bmakeText\s*\([^()]*,\s*'
    r'|\b(?:setContentTitle|setContentText|setTicker|showSnackbar)\s*\(\s*'
)
KT_RETURN_PREFIX = re.compile(r'(?:\breturn\s+|->\s*|\bget\(\)\s*=\s*|\)\s*(?::\s*String\??\s*)?=\s*'
                              r'|\bval\s+\w+\s*(?::\s*String\??\s*)?=\s*)' + KT_VALUE_LEAD + r'$')
KT_FUN = re.compile(r'\bfun\s+(?:<[^>]*>\s*)?(?:[\w<>?,. ]+\.)?(\w+)\s*\(')
KT_PROP = re.compile(r'\b(?:const\s+)?va[lr]\s+(\w+)\s*(?::\s*String\??\s*)?(?:=|$|\bget\(\))')
KT_DISPLAY_NAME = re.compile(DISPLAY_NAME.pattern + r'|^format|channel_?name', re.I)
# Words separated by whitespace. Swift's PHRASE also accepts `.` and `-`, which in
# Kotlin constants reads product ids and hosts (`com.clipulse.pro`, `api.anthropic`) as prose.
KT_PHRASE = re.compile(r'[A-Za-z]{2,}\s+[A-Za-z]{2,}')


def kotlin_composables(root: Path) -> set[str]:
    names = set(KT_FRAMEWORK_COMPOSABLES)
    base = root / KOTLIN_DIR
    if base.is_dir():
        for f in base.rglob('*.kt'):
            src = f.read_text(encoding='utf-8', errors='replace')
            names.update(re.findall(r'@Composable\s+(?:(?:private|internal|public)\s+)?fun\s+([A-Z]\w*)\s*\(', src))
    return names


def kotlin_ui_prefix(composables: set[str]) -> re.Pattern[str]:
    calls = '|'.join(sorted(map(re.escape, composables)))
    return re.compile(
        r'(?:(?<![\w.])(?:' + calls + r')\s*\((?:[^()]*,)?\s*'
        r'|\b(?:' + KT_NAMED_SINKS + r')\s*=\s*'
        r'|' + KT_CALL_SINKS + r')' + KT_VALUE_LEAD + r'$'
    )


def kotlin_is_copy(literal: str) -> bool:
    return has_words(kotlin_without_templates(literal[1:-1]))


def scan_kotlin_file(path: Path, ui_prefix: re.Pattern[str]) -> list[tuple[int, str]]:
    found: list[tuple[int, str]] = []
    lines = path.read_text(encoding='utf-8', errors='replace').splitlines()
    fun_name, fun_is_string = '', False
    prop_name, prop_is_string = '', False
    previous_code = ''
    depth = 0
    ui_when_depths: list[int] = []          # brace depths of `when`/`if` blocks whose value feeds a sink
    in_block_comment = False
    for n, line in enumerate(lines, 1):
        stripped = line.lstrip()
        if in_block_comment:
            if '*/' in stripped:
                in_block_comment = False
            continue
        if stripped.startswith('/*'):
            in_block_comment = '*/' not in stripped
            continue
        if not stripped or stripped.startswith(('//', '*', '@file', 'import ', 'package ')):
            continue
        lits = kotlin_literals(line)
        code_only = line
        for start, lit in reversed(lits):
            code_only = code_only[:start] + '""' + code_only[start + len(lit):]
        code = code_only.split('//')[0].rstrip()
        # A local `val hours = …` must not replace the enclosing function as the
        # context, or `fun formatResetTime(): String { … -> "Resets in …" }` is lost.
        m = KT_FUN.search(code)
        if m:
            fun_name, fun_is_string = m.group(1), bool(re.search(r'\)\s*:\s*String\??', code))
            prop_name, prop_is_string = '', False
        else:
            m = KT_PROP.search(code)
            if m and (': String' in code or 'get()' in code or 'const ' in code):
                prop_name, prop_is_string = m.group(1), True
        context_name = prop_name or fun_name
        named_copy = bool(KT_DISPLAY_NAME.search(context_name))
        string_typed = prop_is_string or fun_is_string
        joined = (previous_code + ' ') if previous_code else ''
        for start, lit in lits:
            if not kotlin_is_copy(lit):
                continue
            before = line[:start]
            lead_only = re.fullmatch(r'\s*' + KT_VALUE_LEAD + r'\s*', before) is not None
            context = joined + before if lead_only else before
            in_ui_when = bool(ui_when_depths) and re.search(r'->\s*' + KT_VALUE_LEAD + r'$', before)
            if ui_prefix.search(context) or in_ui_when:
                found.append((n, lit))
            elif KT_RETURN_PREFIX.search(context) and (
                    named_copy or (string_typed and KT_PHRASE.search(kotlin_without_templates(lit[1:-1])))):
                found.append((n, lit))
        opens, closes = code.count('{'), code.count('}')
        if opens > closes and re.search(r'(?:when|if\s*\(.*\))\s*(?:\([^)]*\))?\s*\{\s*$', code):
            head = code[:code.rfind('when')] if 'when' in code else code[:code.rfind('if')]
            head_context = head if head.strip() else joined + head
            if ui_prefix.search(head_context.rstrip() + ' '):
                ui_when_depths.append(depth + opens - closes)
        depth += opens - closes
        while ui_when_depths and depth < ui_when_depths[-1]:
            ui_when_depths.pop()
        if code.strip():
            previous_code = code
    return found


def scan(root: Path) -> dict[tuple[str, str], list[int]]:
    hits: dict[tuple[str, str], list[int]] = {}
    for d in SCAN_DIRS:
        base = root / d
        if not base.is_dir():
            continue
        for f in sorted(base.rglob('*.swift')):
            rel = f.relative_to(root)
            if SKIP_PARTS & set(rel.parts[1:]):
                continue
            tables = None
            for n, lit, kind in scan_swift_file(f):
                if kind == 'intent':
                    tables = tables if tables is not None else (app_bundle_tables(root, rel) or [])
                    if tables and all(intent_key(lit) in t for t in tables):
                        continue        # localized by the system from the app bundle's tables
                hits.setdefault((rel.as_posix(), lit), []).append(n)
    kotlin = root / KOTLIN_DIR
    if kotlin.is_dir():
        ui_prefix = kotlin_ui_prefix(kotlin_composables(root))
        for f in sorted(kotlin.rglob('*.kt')):
            rel = f.relative_to(root)
            for n, lit in scan_kotlin_file(f, ui_prefix):
                hits.setdefault((rel.as_posix(), lit), []).append(n)
    return hits


# Why a literal may stay English. The category is the decision; the words after it are the evidence.
REASON_CATEGORIES = (
    "KEEP_PROPER_NOUN",        # a brand, product, plan or unit name that reads the same in every language
    "KEEP_NOT_USER_VISIBLE",   # identifiers, logs, wire text, dead or unreachable paths
    "KEEP_STORED_DATA",        # English data that is stored, synced or compared; its rendering is translated
    "KEEP_DEMO_CONTENT",       # sample data shown only in Demo mode
    "KEEP_DEBUG_OR_QA_ONLY",   # compiled out of release builds, or reachable only in the QA runtime
    "KEEP_BY_DECISION",        # an owner decision to keep English, cited
)
# A reason that defers the decision is not a reason. The first baseline carried 17 entries marked
# NEEDS_JUDGMENT ("real user-visible English deferred"), and the gate accepted them as permission
# indefinitely — while their text described a banner path the code no longer had.
PLACEHOLDER_REASON = re.compile(r'^\s*(?:(?:TODO|TBD|FIXME|XXX|NEEDS[_ ]?\w*|DEFER\w*|PENDING\w*|UNKNOWN)\b|\?)', re.I)
MIN_REASON_WORDS = 4


def reason_problem(reason: object) -> str | None:
    """Why a baseline reason is not acceptable, or None when it is."""
    if not isinstance(reason, str) or not reason.strip():
        return "without a reason"
    if PLACEHOLDER_REASON.match(reason):
        return f"with a placeholder reason ({reason.split(':')[0].strip()}) — decide: localize it, or say why it stays"
    m = re.match(r'^(KEEP_[A-Z_]+):\s*(.*)$', reason, re.S)
    if not m or m.group(1) not in REASON_CATEGORIES:
        return "whose reason does not start with a category (" + ", ".join(REASON_CATEGORIES) + ")"
    if len(m.group(2).split()) < MIN_REASON_WORDS:
        return f"whose reason is too short to be evidence (at least {MIN_REASON_WORDS} words after the category)"
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    ap.add_argument('--baseline', type=Path, default=None)
    ap.add_argument('--write-baseline', action='store_true',
                    help='print a baseline for the current tree (reasons left for a human)')
    args = ap.parse_args()
    root = args.root
    baseline_path = args.baseline or (root / BASELINE_DEFAULT)
    hits = scan(root)

    if args.write_baseline:
        entries = [{"path": p, "literal": lit, "count": len(ns), "reason": "TODO"}
                   for (p, lit), ns in sorted(hits.items())]
        print(json.dumps({"entries": entries}, ensure_ascii=False, indent=1))
        return 0

    try:
        baseline = json.loads(baseline_path.read_text(encoding='utf-8'))["entries"]
    except FileNotFoundError:
        print(f"check_hardcoded_ui_strings: baseline not found: {baseline_path}", file=sys.stderr)
        return 2

    allowed = Counter()
    bad_reasons = []
    for e in baseline:
        problem = reason_problem(e.get("reason"))
        if problem:
            bad_reasons.append(f"  REASON {e['path']}  {e['literal']}  — entry {problem}")
        allowed[(e["path"], e["literal"])] += int(e.get("count", 1))
    if bad_reasons:
        print("check_hardcoded_ui_strings: FAILED — the allowlist must say why each literal stays English")
        print("\n".join(bad_reasons))
        return 1

    errors = []
    for (p, lit), ns in sorted(hits.items()):
        extra = len(ns) - allowed.get((p, lit), 0)
        if extra > 0:
            errors.append(f"  NEW   {p}:{ns[-1]}  {lit}"
                          + (f"  (+{extra} beyond baseline)" if allowed.get((p, lit)) else ""))
    for (p, lit), count in sorted(allowed.items()):
        present = len(hits.get((p, lit), []))
        if present < count:
            errors.append(f"  STALE {p}  {lit}  (baseline {count}, found {present}) — shrink the baseline")

    if errors:
        print("check_hardcoded_ui_strings: FAILED")
        print("\n".join(errors))
        print("\nUser-visible copy must go through L10n (CLIPulseCore/L10n.swift + all six .lproj),\n"
              "or on Android through string resources (res/values*/strings.xml, all six).\n"
              "App Intents metadata (LocalizedStringResource, IntentDescription, @Parameter titles) is read\n"
              "from the app bundle instead: add the literal as a key to that target's six Localizable.strings.\n"
              "If a literal is genuinely not translatable (a product name, a shell command, a DEBUG-only\n"
              f"menu), add it to {BASELINE_DEFAULT} with the reason.")
        return 1

    total = sum(len(v) for v in hits.values())
    print(f"check_hardcoded_ui_strings: OK — {total} literal(s) in scope, all allowlisted with a reason.")
    return 0


if __name__ == '__main__':
    sys.exit(main())
