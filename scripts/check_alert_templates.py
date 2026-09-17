#!/usr/bin/env python3
"""
Alert templates the Python helper uploads, pinned to what the apps can translate.

`AlertPresentation.text(for:)` translates an alert row by recognising the
PRODUCER'S English: `public.alerts` has no kind or parameter columns, so the
title and message are matched against each producer's template and the
parameters are read back out of them. Any template a matcher does not accept
renders the stored English, in every language, on the Mac Alerts tab, the
iPhone Alerts tab, the Watch and the macOS notification body.

The in-app Swift generator is covered by `AlertPresentationTests`, which runs
its real output through the matchers. The legacy Python helper is not something
`swift test` can execute, so its three templates (device CPU, session CPU,
session too long) were pinned only by strings copied by hand into
`testPythonHelperTemplatesAreRecognized`, and `helper/test_system_collector.py`
asserts only that alerts is a list. Rewording `system_collector.py`'s
"Process CPU is {…}% for {…}." left every suite green and every Usage Spike row
from such a Mac English under ja/zh/ko/es.

WHAT IT CHECKS, for every `CollectedAlert(...)` in `helper/system_collector.py`:

  1. the template, rendered with sample values, is accepted by ONE matcher in
     AlertPresentation.swift — its `a.type ==`, `a.id.hasPrefix(`, exact
     `a.title ==` / `a.message ==`, `stripSuffix(a.title, …)` and
     `capture(a.message, #"…"#)` constraints, read from the Swift source rather
     than copied here, so a change on either side is seen;
  2. a hand-written fixture in `testPythonHelperTemplatesAreRecognized` matches
     the template (placeholders as wildcards), and every fixture there still
     matches some template. That XCTest runs the REAL matcher over the fixture,
     so the chain producer → fixture → matcher holds even where this script's
     reading of Swift regex semantics could be wrong.

HelperSwift's own AlertGenerator is deliberately NOT a producer here: nothing
outside its tests constructs it, and the app's HelperDaemon uploads alerts from
CLIPulseCore's generator. The Tauri desktop's templates live in another
repository.

Pure Python on purpose: repo-hygiene runs on Linux.

Usage:
  python3 scripts/check_alert_templates.py [--root <tree>]
Exit codes: 0 OK, 1 a template is not recognised or not pinned, 2 inputs unreadable.
"""
from __future__ import annotations

import argparse
import ast
import io
import re
import sys
import tokenize
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_apple_strings_parity import match_close, swift_masks  # noqa: E402

PRODUCER = Path("helper/system_collector.py")
PRESENTATION = Path("CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AlertPresentation.swift")
FIXTURES = Path("CLI Pulse Bar/CLIPulseCore/Tests/CLIPulseCoreTests/AlertPresentationTests.swift")
FIXTURE_TEST = "testPythonHelperTemplatesAreRecognized"
FIELDS = ("alert_id", "type", "title", "message")

# Sample values for the placeholders. A value with a format spec is a number and
# is formatted with that spec, as the f-string would; so is anything whose name
# says it is a percentage. Everything else is a name, with a space in it so a
# matcher that assumes names have none is caught.
NUMERIC_NAME = re.compile(r"(?:cpu|usage|percent|pct|count|seconds)$", re.I)
SAMPLE_NUMBER = 91.25
SAMPLE_NAME = "api gateway"


class Template:
    def __init__(self, line: int, parts: dict[str, list[tuple[str, str | None]]]) -> None:
        self.line = line
        self.parts = parts   # field -> [(literal text, None) | (expression, format spec)]

    def sample(self, field: str) -> str:
        out = []
        for text, spec in self.parts[field]:
            if spec is None:
                out.append(text)
            elif spec or NUMERIC_NAME.search(text):
                out.append(format(SAMPLE_NUMBER, spec) if spec else str(SAMPLE_NUMBER))
            else:
                out.append(SAMPLE_NAME)
        return "".join(out)

    def pattern(self, field: str) -> re.Pattern:
        """The template as a regex: literal text exact, each placeholder a wildcard."""
        return re.compile("".join(re.escape(text) if spec is None else ".+?"
                                  for text, spec in self.parts[field]) + r"\Z", re.S)

    def static_prefix(self, field: str) -> str:
        prefix = []
        for text, spec in self.parts[field]:
            if spec is not None:
                break
            prefix.append(text)
        return "".join(prefix)

    def describe(self) -> str:
        return " / ".join(repr(self.sample(f)) for f in ("type", "title", "message"))


def _string_parts(node: ast.expr) -> list[tuple[str, str | None]] | None:
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return [(node.value, None)]
    if isinstance(node, ast.JoinedStr):
        parts: list[tuple[str, str | None]] = []
        for v in node.values:
            if isinstance(v, ast.Constant):
                parts.append((str(v.value), None))
            elif isinstance(v, ast.FormattedValue):
                spec = ""
                if isinstance(v.format_spec, ast.JoinedStr):
                    spec = "".join(str(c.value) for c in v.format_spec.values if isinstance(c, ast.Constant))
                parts.append((ast.unparse(v.value), spec))
            else:
                return None
        return parts
    return None


def _call_tokens(src: str, name: str) -> int:
    """How many times `name(` appears as code — not in a comment or a string."""
    tokens = [t for t in tokenize.generate_tokens(io.StringIO(src).readline)
              if t.type not in (tokenize.NL, tokenize.NEWLINE, tokenize.COMMENT, tokenize.INDENT, tokenize.DEDENT)]
    return sum(1 for a, b in zip(tokens, tokens[1:])
               if a.type == tokenize.NAME and a.string == name and b.type == tokenize.OP and b.string == "(")


def producer_templates(src: str) -> tuple[list[Template], list[str]]:
    problems: list[str] = []
    templates: list[Template] = []
    tree = ast.parse(src)
    calls = [n for n in ast.walk(tree) if isinstance(n, ast.Call)
             and isinstance(n.func, ast.Name) and n.func.id == "CollectedAlert"]
    textual = _call_tokens(src, "CollectedAlert")
    if len(calls) != textual:
        problems.append(f"{PRODUCER}: {textual} `CollectedAlert(` in the text but {len(calls)} calls parsed — "
                        "the reader is missing some")
    for call in calls:
        kwargs = {k.arg: k.value for k in call.keywords}
        parts: dict[str, list[tuple[str, str | None]]] = {}
        for field in FIELDS:
            node = kwargs.get(field)
            got = _string_parts(node) if node is not None else None
            if got is None:
                problems.append(f"{PRODUCER}:{call.lineno}: CollectedAlert {field}= is not a string literal "
                                "or f-string, so its template cannot be checked")
                break
            parts[field] = got
        else:
            templates.append(Template(call.lineno, parts))
    return templates, problems


class Matcher:
    def __init__(self, name: str) -> None:
        self.name = name
        self.types: list[str] = []
        self.id_prefixes: list[str] = []
        self.titles: list[str] = []
        self.messages: list[str] = []
        self.title_suffixes: list[str] = []
        self.title_patterns: list[str] = []
        self.message_patterns: list[str] = []

    def rejects(self, t: Template) -> str | None:
        """Why this matcher would not recognise the rendered template, or None."""
        kind, ident = t.sample("type"), t.sample("alert_id")
        title, message = t.sample("title"), t.sample("message")
        if kind not in self.types:
            return f"type {kind!r} is not one of {self.types}"
        if self.id_prefixes and not any(ident.startswith(p) for p in self.id_prefixes):
            return f"id {ident!r} starts with none of {self.id_prefixes}"
        if self.titles and title not in self.titles:
            return f"title {title!r} is not {self.titles}"
        if self.title_patterns and not any(re.search(p, title) for p in self.title_patterns):
            return f"title {title!r} matches none of {self.title_patterns}"
        if self.title_suffixes and not any(title.endswith(s) and len(title) > len(s) for s in self.title_suffixes):
            return f"title {title!r} ends with none of {self.title_suffixes}"
        if self.messages and message not in self.messages:
            return f"message {message!r} is not {self.messages}"
        if self.message_patterns and not any(re.search(p, message) for p in self.message_patterns):
            return f"message {message!r} matches none of {self.message_patterns}"
        return None


SWIFT_RAW_OR_PLAIN = r'(?:#"((?:[^"]|"(?!#))*)"#|"((?:[^"\\]|\\.)*)")'


def presentation_matchers(src: str) -> list[Matcher]:
    no_comments, code = swift_masks(src)
    matchers: list[Matcher] = []
    for m in re.finditer(r"\bstatic\s+func\s+(\w+)\s*\(\s*_\s+a\s*:\s*AlertRecord\s*\)\s*->\s*Text\?\s*\{", code):
        close = match_close(code, m.end() - 1)
        if close < 0:
            continue
        body = no_comments[m.end():close - 1]
        matcher = Matcher(m.group(1))

        def lits(pattern: str) -> list[str]:
            found = []
            for x in re.finditer(pattern + SWIFT_RAW_OR_PLAIN, body):
                raw, plain = x.group(1), x.group(2)
                if plain is not None and "\\(" in plain:
                    continue   # interpolated at runtime (the quota title suffix): not a fixed constraint
                found.append(raw if raw is not None else re.sub(r"\\(.)", r"\1", plain))
            return found

        matcher.types = lits(r"\ba\.type\s*==\s*")
        matcher.id_prefixes = lits(r"\ba\.id\.hasPrefix\(\s*")
        matcher.titles = lits(r"\ba\.title\s*==\s*")
        matcher.messages = lits(r"\ba\.message\s*==\s*")
        matcher.title_suffixes = lits(r"\bstripSuffix\(\s*a\.title\s*,\s*")
        matcher.title_patterns = lits(r"\bcapture\(\s*a\.title\s*,\s*")
        matcher.message_patterns = lits(r"\bcapture\(\s*a\.message\s*,\s*")
        if matcher.types:
            matchers.append(matcher)
    return matchers


def fixture_records(src: str) -> list[dict[str, str]] | None:
    no_comments, code = swift_masks(src)
    m = re.search(r"\bfunc\s+" + FIXTURE_TEST + r"\s*\(\s*\)[^{]*\{", code)
    if not m:
        return None
    close = match_close(code, m.end() - 1)
    body = no_comments[m.end():close - 1]
    records = []
    for r in re.finditer(r"\brecord\(", body):
        end = match_close(code[m.end():close - 1], r.end() - 1)
        call = body[r.end():end - 1] if end > 0 else ""
        fields = {k: re.sub(r"\\(.)", r"\1", v) for k, v in
                  re.findall(r'\b(id|type|title|message)\s*:\s*"((?:[^"\\]|\\.)*)"', call)}
        if set(fields) == {"id", "type", "title", "message"}:
            records.append(fields)
    return records


def fixture_matches(t: Template, rec: dict[str, str]) -> bool:
    return (rec["type"] == t.sample("type")
            and rec["id"].startswith(t.static_prefix("alert_id"))
            and t.pattern("title").match(rec["title"]) is not None
            and t.pattern("message").match(rec["message"]) is not None)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=None, help="repo root to check (used by the negative controls)")
    args = ap.parse_args()
    root = Path(args.root).resolve() if args.root else Path(__file__).resolve().parent.parent

    try:
        producer_src = (root / PRODUCER).read_text(encoding="utf-8")
        presentation_src = (root / PRESENTATION).read_text(encoding="utf-8")
        fixture_src = (root / FIXTURES).read_text(encoding="utf-8")
    except OSError as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return 2
    try:
        templates, problems = producer_templates(producer_src)
    except SyntaxError as exc:
        print(f"FATAL: {PRODUCER} does not parse: {exc}", file=sys.stderr)
        return 2
    matchers = presentation_matchers(presentation_src)
    records = fixture_records(fixture_src)

    if not templates:
        problems.append(f"{PRODUCER}: no CollectedAlert templates found — nothing was checked")
    if not matchers:
        problems.append(f"{PRESENTATION}: no `static func …(_ a: AlertRecord) -> Text?` matchers found")
    if records is None:
        problems.append(f"{FIXTURES}: {FIXTURE_TEST}() is gone, so no XCTest runs these templates "
                        "through the real matcher")
        records = []

    for t in templates:
        verdicts = [(mt.name, mt.rejects(t)) for mt in matchers]
        if matchers and all(why is not None for _, why in verdicts):
            closest = [f"{name}: {why}" for name, why in verdicts if not why.startswith("type ")]
            problems.append(
                f"{PRODUCER}:{t.line}: {t.describe()} is recognised by no AlertPresentation matcher, so it "
                "renders in English in every language"
                + ("".join(f"\n        {c}" for c in closest) if closest else ""))
        if not any(fixture_matches(t, rec) for rec in records):
            problems.append(
                f"{PRODUCER}:{t.line}: {t.describe()} has no fixture in {FIXTURE_TEST}() — the XCTest that "
                "runs the real matcher does not cover this template")
    for rec in records:
        if not any(fixture_matches(t, rec) for t in templates):
            problems.append(
                f"{FIXTURES}: the {FIXTURE_TEST}() fixture {rec['message']!r} matches no template "
                f"{PRODUCER} still writes — the test pins a string nothing produces")

    if problems:
        print("FAIL — a Python helper alert template is not pinned to what the apps translate.\n",
              file=sys.stderr)
        for line in problems:
            print(f"    {line}", file=sys.stderr)
        print("\n    Change the template, the matcher in AlertPresentation.swift and the fixture in\n"
              f"    {FIXTURE_TEST}() together. Stored alerts stay English; only the\n"
              "    rendering is translated, and only for text a matcher recognises.\n", file=sys.stderr)
        return 1

    print(f"OK — {len(templates)} Python helper alert template(s), each recognised by an "
          f"AlertPresentation matcher ({len(matchers)} read) and pinned by a fixture "
          f"({len(records)} in {FIXTURE_TEST}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
