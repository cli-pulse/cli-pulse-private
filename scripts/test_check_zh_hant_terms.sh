#!/usr/bin/env bash
# Negative controls for check_zh_hant_terms.py.
#
# The gate's job is to fail, so each case copies the REAL zh-Hant / zh-rTW tables
# and the real manifest into a temp tree, plants one defect, runs the real gate
# against it, and asserts the exit code — and, for a failure, that the output
# names the defect, since a gate failing for some other reason proves nothing.
# Every forbidden variant in the manifest is planted on every platform that
# forbids it, so a variant added to the manifest is tested without editing this
# file.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/scripts/check_zh_hant_terms.py"
CORE_TABLE="CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/Resources/zh-Hant.lproj/Localizable.strings"
IOS_DIR="CLI Pulse Bar/CLI Pulse Bar iOS/zh-Hant.lproj"
ANDROID_DIR="android/app/src/main/res/values-zh-rTW"
ANDROID_TABLE="$ANDROID_DIR/strings.xml"
MANIFEST="scripts/zh_hant_terms.json"
pass=0; fail=0

# A copy of exactly what the gate reads in the real tree.
new_tree() {
  T="$(mktemp -d)"
  (cd "$ROOT" && {
      find "CLI Pulse Bar" -path '*/.build' -prune -o -path '*/zh-Hant.lproj/*.strings' -print
      find android -path '*/build' -prune -o -path '*/values-zh-rTW/*.xml' -print
      echo "$MANIFEST"
    } | tar -cf - -T -) | tar -xf - -C "$T"
}
apple_add() {  # apple_add <table relative to the tree> <line>
  printf '%s\n' "$2" >> "$T/$1"
}
android_add() {  # android_add <xml element(s)> [file]
  local f="$T/${2:-$ANDROID_TABLE}"
  python3 - "$f" "$1" <<'PY'
import sys
path, element = sys.argv[1], sys.argv[2]
s = open(path, encoding="utf-8").read()
assert "</resources>" in s, path
open(path, "w", encoding="utf-8").write(s.replace("</resources>", f"    {element}\n</resources>", 1))
PY
}
edit() {  # edit <file relative to the tree> <python expression over s>
  python3 - "$T/$1" "$2" <<'PY'
import sys
path, expr = sys.argv[1], sys.argv[2]
s = open(path, encoding="utf-8").read()
t = eval(expr)
assert t != s, f"edit changed nothing in {path}"
open(path, "w", encoding="utf-8").write(t)
PY
}
manifest_edit() {  # manifest_edit <python statements over m>
  python3 - "$T/$MANIFEST" "$1" <<'PY'
import json, sys
path, code = sys.argv[1], sys.argv[2]
m = json.load(open(path, encoding="utf-8"))
exec(code)
json.dump(m, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
PY
}

expect_pass() {  # expect_pass <name>
  local name="$1" out got
  out="$(python3 "$GUARD" --root "$T" 2>&1)"; got=$?
  if [ "$got" = 0 ]; then pass=$((pass+1)); echo "  ok    $name"
  else fail=$((fail+1)); echo "  FAIL  $name (want exit 0, got $got)"; echo "$out" | sed 's/^/        /'; fi
  rm -rf "$T"
}
expect_fail() {  # expect_fail <name> <needle the output must contain>
  local name="$1" needle="$2" out got
  out="$(python3 "$GUARD" --root "$T" 2>&1)"; got=$?
  if [ "$got" = 1 ] && printf '%s' "$out" | grep -qF -- "$needle"; then pass=$((pass+1)); echo "  ok    $name"
  else fail=$((fail+1)); echo "  FAIL  $name (want exit 1 with: $needle; got exit $got)"; echo "$out" | sed 's/^/        /'; fi
  rm -rf "$T"
}

echo "check_zh_hant_terms negative controls"

new_tree
expect_pass "a copy of the real tables and manifest passes (positive control)"

# ── every forbidden variant, on every platform that forbids it ──────────────────
while IFS=$'\t' read -r platform concept variant; do
  new_tree
  if [ "$platform" = apple ]; then
    apple_add "$CORE_TABLE" "\"zz.planted\" = \"這是${variant}的測試\";"
    expect_fail "apple: $variant ($concept) fails" "Localizable.strings:$(wc -l < "$T/$CORE_TABLE" | tr -d ' '): zz.planted: uses $variant"
  else
    android_add "<string name=\"zz_planted\">這是${variant}的測試</string>"
    expect_fail "android: $variant ($concept) fails" "strings.xml:$(grep -n zz_planted "$T/$ANDROID_TABLE" | cut -d: -f1): zz_planted: uses $variant"
  fi
done < <(python3 - "$ROOT/$MANIFEST" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
for c in m["concepts"]:
    for p in ("apple", "android"):
        for v in c[p]["forbid"]:
            print(f"{p}\t{c['concept']}\t{v}")
PY
)

# ── every kind of table the gate claims to read ─────────────────────────────────
new_tree; apple_add "$IOS_DIR/InfoPlist.strings" '"NSCameraUsageDescription" = "掃描會話";'
expect_fail "the iPhone's permission prompts are scanned" "InfoPlist.strings:"

new_tree; apple_add "$IOS_DIR/AppShortcuts.strings" '"Open ${applicationName} alerts" = "打開 ${applicationName} 告警";'
expect_fail "Siri phrases are scanned" "AppShortcuts.strings:"

new_tree; mkdir -p "$T/CLI Pulse Bar/CLI Pulse Bar Watch/zh-Hant.lproj"
printf '"Title" = "告警";\n' > "$T/CLI Pulse Bar/CLI Pulse Bar Watch/zh-Hant.lproj/Localizable.strings"
expect_fail "a zh-Hant table in a new app target is found without editing the gate" "CLI Pulse Bar Watch/zh-Hant.lproj/Localizable.strings:1: Title: uses 告警"

new_tree; apple_add "$CORE_TABLE" '"zz.quoted" = "他說 \"好\" 然後開了會話";'
expect_fail "a value with escaped quotes is read to its end" "zz.quoted: uses 會話"

new_tree; android_add '<plurals name="zz_count"><item quantity="other">%d 個會話</item></plurals>'
expect_fail "an Android plural item is scanned, labelled by quantity" "zz_count[other]: uses 會話"

new_tree; android_add '<string-array name="zz_list"><item>服務商</item><item>提供者</item></string-array>'
expect_fail "an Android string-array item is scanned, labelled by index" "zz_list[1]: uses 提供者"

# `<string\b` also matches `<string-array`, and would then read on to the NEXT
# </string>, reporting that string's defect under the array's name.
new_tree; android_add '<string-array name="zz_list"><item>服務商</item></string-array>
    <string name="zz_after">告警</string>'
expect_fail "a string after a string-array keeps its own name" "zz_after: uses 告警"

new_tree; apple_add "$CORE_TABLE" '"zz.twice" = "先開會話，再關會話";'
out="$(python3 "$GUARD" --root "$T" 2>&1)"; n="$(printf '%s\n' "$out" | grep -c 'zz.twice: uses 會話')"
if [ "$n" = 2 ]; then pass=$((pass+1)); echo "  ok    every occurrence in a string is reported, not only the first"
else fail=$((fail+1)); echo "  FAIL  every occurrence in a string is reported (want 2 findings, got $n)"; echo "$out" | sed 's/^/        /'; fi
rm -rf "$T"

new_tree; printf '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n    <string name="zz_extra">告警</string>\n</resources>\n' > "$T/$ANDROID_DIR/extra.xml"
expect_fail "a second resource file in values-zh-rTW is scanned" "extra.xml:3: zz_extra: uses 告警"

new_tree; mkdir -p "$T/android/app/src/main/res/values-b+zh+Hant"
printf '<resources>\n    <string name="zz_bcp">會話</string>\n</resources>\n' > "$T/android/app/src/main/res/values-b+zh+Hant/strings.xml"
expect_fail "the BCP-47 values-b+zh+Hant directory is scanned too" "values-b+zh+Hant/strings.xml:2: zz_bcp: uses 會話"

# ── what is NOT a finding ───────────────────────────────────────────────────────
new_tree
apple_add "$CORE_TABLE" '/* 會話 was the old word; 告警 is mainland */'
apple_add "$CORE_TABLE" '/* "zz.retired" = "會話"; */'
apple_add "$CORE_TABLE" '// "zz.retired2" = "帳戶";'
android_add '<!-- <string name="zz_retired">告警 and 提供者</string> -->'
expect_pass "forbidden words in comments, even commented-out entries, are not findings (nobody sees them)"

new_tree; android_add '<string name="zz_process">%1$s 的處理程序</string>'
expect_pass "Android keeps 處理程序, its own platform term"

new_tree; apple_add "$CORE_TABLE" '"zz.process" = "%1$@ 的處理程序";'
expect_fail "...while Apple, which says 程序, rejects it" "zz.process: uses 處理程序"

# ── the allowlist ───────────────────────────────────────────────────────────────
new_tree; edit "$CORE_TABLE" 's.replace("使用你的 Google 帳戶，", "使用你的 Google 帳戶或其他帳戶，", 1)'
expect_fail "an allowlisted phrase excuses itself, not another 帳戶 in the same string" "provider_config.gemini_uses_google: uses 帳戶"

new_tree; edit "$CORE_TABLE" 's.replace("使用你的 Google 帳戶，", "使用你的 Google 帳號，", 1)'
expect_fail "an allowlist entry whose phrase is gone fails as stale" '"Google 帳戶" no longer appears — stale entry'

new_tree; manifest_edit 'm["allowlist"][0]["reason"] = "vendor"'
expect_fail "an allowlist entry without a real reason fails" "needs a real reason"

new_tree; manifest_edit 'm["allowlist"][0]["variant"] = "工作"; m["allowlist"][0]["phrase"] = "Google 帳戶工作"'
expect_fail "an allowlist entry excusing a word nobody forbids fails" "which apple does not forbid"

new_tree; manifest_edit 'm["allowlist"].append(dict(m["allowlist"][0]))'
expect_fail "an allowlist entry listed twice fails" "is listed twice"

# ── the manifest itself ─────────────────────────────────────────────────────────
new_tree; manifest_edit 'next(c for c in m["concepts"] if c["concept"] == "process")["android"]["forbid"].append("程序")'
expect_fail "forbidding a word that is part of a term in use fails" "but it is part of '處理程序'"

new_tree; manifest_edit 'm["concepts"][0]["evidence"] = "trust me"'
expect_fail "a concept without its evidence fails" "needs its evidence"

new_tree; manifest_edit 'del m["concepts"][1]["android"]'
expect_fail "a concept missing a platform fails" "needs android.use"

# ── positive controls: scanning nothing must not pass ───────────────────────────
new_tree; rm -rf "$T/android"
expect_fail "no Android tables at all fails" "no android tables found"

new_tree; find "$T/CLI Pulse Bar" -name '*.strings' -delete
expect_fail "no Apple tables at all fails" "no apple tables found"

new_tree; edit "$ANDROID_TABLE" 's.replace("警示", "ALERT")'
expect_fail "a term in use that appears nowhere fails" "'警示' appears in no android string"

echo "check_zh_hant_terms: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
