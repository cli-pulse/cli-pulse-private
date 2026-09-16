#!/usr/bin/env python3
"""Negative controls for play_publish.collect_release_notes (no Google libraries needed)."""
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from play_publish import PLAY_NOTES_LIMIT, collect_release_notes  # noqa: E402

passed = failed = 0


def check(name, fn):
    global passed, failed
    try:
        fn()
        print(f"  ok    {name}")
        passed += 1
    except AssertionError as e:
        print(f"  FAIL  {name}: {e}")
        failed += 1


def raises(fn, needle):
    try:
        fn()
    except ValueError as e:
        assert needle in str(e), f"wrong reason: {e}"
        return
    raise AssertionError("did not raise")


with tempfile.TemporaryDirectory() as d:
    def write(name, text):
        path = os.path.join(d, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        return path

    notes_dir = os.path.join(d, "whatsnew")
    os.mkdir(notes_dir)
    for loc, text in [("en-US", "Fixes."), ("zh-Hans", "修复。"), ("zh-Hant", "修正。"), ("ja", "修正。"), ("ko", "수정."), ("es", "Correcciones.")]:
        with open(os.path.join(notes_dir, f"{loc}.txt"), "w", encoding="utf-8") as f:
            f.write(text + "\n")

    def dir_maps_apple_locales():
        got = collect_release_notes(notes_dir=notes_dir)
        assert sorted(n["language"] for n in got) == ["en-US", "es-ES", "ja-JP", "ko-KR", "zh-CN", "zh-TW"], got
        assert {n["language"]: n["text"] for n in got}["zh-CN"] == "修复。"

    def legacy_single_file_still_works():
        got = collect_release_notes(notes_file=write("n.txt", "Fixes.\n"))
        assert got == [{"language": "en-US", "text": "Fixes."}], got

    check("a notes dir maps Apple locale names to Play codes", dir_maps_apple_locales)
    check("the old --notes-file/--notes-lang form is unchanged", legacy_single_file_still_works)
    check("an unknown language fails", lambda: raises(lambda: collect_release_notes(notes=[f"fr={write('fr.txt', 'x')}"]), "no Play language"))
    check("the same language twice fails", lambda: raises(
        lambda: collect_release_notes(notes_file=write("a.txt", "a"), notes=[f"en={write('b.txt', 'b')}"]), "already comes from"))
    check("an over-limit text fails before any upload", lambda: raises(
        lambda: collect_release_notes(notes=[f"ja={write('long.txt', 'あ' * (PLAY_NOTES_LIMIT + 1))}"]), "over Play's"))
    check("an empty text fails", lambda: raises(lambda: collect_release_notes(notes=[f"ko={write('e.txt', '  ')}"]), "empty"))
    check("a malformed --notes fails", lambda: raises(lambda: collect_release_notes(notes=["ja-notes.txt"]), "LANG=FILE"))

print(f"play_publish release-notes controls: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
