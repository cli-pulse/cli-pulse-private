#!/bin/bash
# Negative controls for check_apple_strings_parity.py.
#
# This repo has shipped five guards that were green while guarding nothing, so
# a new guard is worth exactly the proof that it fires. Every failure mode the
# gate claims to catch is planted here and must be caught FOR THE STATED
# REASON — a guard that fails for the wrong reason is not evidence.
#
# The POSITIVE control is not optional either: without it, a gate that rejects
# every tree looks identical to a gate that works.
#
# Each case runs against a fixture tree via --root. `assert_changed` proves the
# mutation actually landed, so a no-op plant can never be scored as a catch.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/check_apple_strings_parity.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

RES="CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/Resources"

build_fixture() {
    local dest="$1"
    rm -rf "$dest"
    mkdir -p "$dest/$RES/en.lproj" "$dest/$RES/es.lproj" "$dest/$RES/ja.lproj" \
             "$dest/$RES/ko.lproj" "$dest/$RES/zh-Hans.lproj" "$dest/$RES/zh-Hant.lproj" \
             "$dest/scripts"

    cat > "$dest/$RES/en.lproj/Localizable.strings" <<'STRINGS'
/* CLI Pulse — English (Base) */
"tab.overview" = "Overview";
"tab.settings" = "Settings";
"wizard.welcome" = "Welcome";
STRINGS

    # es is deliberately one key short — that gap is the baselined debt.
    cat > "$dest/$RES/es.lproj/Localizable.strings" <<'STRINGS'
/* CLI Pulse — Español */
"tab.overview" = "Resumen";
"tab.settings" = "Ajustes";
STRINGS

    cat > "$dest/$RES/ja.lproj/Localizable.strings" <<'STRINGS'
/* CLI Pulse — 日本語 */
"tab.overview" = "概要";
"tab.settings" = "設定";
"wizard.welcome" = "ようこそ";
STRINGS

    # The three locales the shipped-locale manifest also requires. Full parity
    # so they are inert to every case below except the "locale deleted" one.
    for loc in ko zh-Hans zh-Hant; do
        cat > "$dest/$RES/$loc.lproj/Localizable.strings" <<'STRINGS'
"tab.overview" = "X";
"tab.settings" = "Y";
"wizard.welcome" = "Z";
STRINGS
    done

    mkdir -p "$dest/CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore"
    cat > "$dest/CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/L10n.swift" <<'SWIFT'
public enum L10n {
    public enum tab {
        public static var overview: String { tr("tab.overview") }
        public static var settings: String { tr("tab.settings") }
    }
}
SWIFT

    cat > "$dest/scripts/apple_strings_parity_baseline.json" <<'JSON'
{
  "_comment": ["fixture baseline"],
  "missing": {
    "es": ["wizard.welcome"]
  }
}
JSON
}

assert_changed() {
    local name="$1" file="$2" before="$3"
    local after; after="$(shasum "$file" | cut -d' ' -f1)"
    if [ "$before" = "$after" ]; then
        echo "FAIL: [$name] mutation was a NO-OP — the case proves nothing."
        fail=$((fail + 1)); return 1
    fi
    return 0
}

expect_fail() {
    local name="$1" needle="$2" out rc
    out="$(python3 "$GUARD" --root "$TMP/case" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "FAIL: [$name] guard PASSED a tree it should have rejected."
        fail=$((fail + 1)); return
    fi
    if ! printf '%s' "$out" | grep -qF "$needle"; then
        echo "FAIL: [$name] guard failed (rc=$rc), but not for the expected reason."
        echo "      wanted substring: $needle"
        echo "      got: $out"
        fail=$((fail + 1)); return
    fi
    echo "ok:   [$name] guard rejected it, for the right reason."
    pass=$((pass + 1))
}

expect_ok() {
    local name="$1" out rc
    out="$(python3 "$GUARD" --root "$TMP/case" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "FAIL: [$name] guard REJECTED a tree it should have accepted."
        printf '%s\n' "$out" | sed 's/^/      /'
        fail=$((fail + 1)); return
    fi
    echo "ok:   [$name] guard accepted it."
    pass=$((pass + 1))
}

# ── positive control ────────────────────────────────────────────────────────
build_fixture "$TMP/case"
if python3 "$GUARD" --root "$TMP/case" >/dev/null 2>&1; then
    echo "ok:   [positive control] guard accepts a tree whose only gap is baselined."
    pass=$((pass + 1))
else
    echo "FAIL: [positive control] guard rejected a clean tree."
    python3 "$GUARD" --root "$TMP/case" 2>&1 | sed 's/^/      /'
    fail=$((fail + 1))
fi

# ── 1. new key added to en only — the regression that made the 670 ──────────
build_fixture "$TMP/case"
F="$TMP/case/$RES/en.lproj/Localizable.strings"
B="$(shasum "$F" | cut -d' ' -f1)"
printf '"wizard.finish" = "Finish";\n' >> "$F"
assert_changed "new en key" "$F" "$B" && expect_fail "new en key" "wizard.finish"

# ── 2. a translation deleted from a locale ─────────────────────────────────
build_fixture "$TMP/case"
F="$TMP/case/$RES/ja.lproj/Localizable.strings"
B="$(shasum "$F" | cut -d' ' -f1)"
grep -v 'tab.settings' "$F" > "$F.tmp" && mv "$F.tmp" "$F"
assert_changed "deleted translation" "$F" "$B" && expect_fail "deleted translation" "tab.settings"

# ── 3. stale baseline — the key got translated, the entry stayed ────────────
build_fixture "$TMP/case"
F="$TMP/case/$RES/es.lproj/Localizable.strings"
B="$(shasum "$F" | cut -d' ' -f1)"
printf '"wizard.welcome" = "Bienvenido";\n' >> "$F"
assert_changed "stale baseline" "$F" "$B" && expect_fail "stale baseline" "no longer missing"

# ── 4. orphan — a key in a locale that en does not have ────────────────────
build_fixture "$TMP/case"
F="$TMP/case/$RES/ja.lproj/Localizable.strings"
B="$(shasum "$F" | cut -d' ' -f1)"
printf '"wizard.only_in_ja" = "日本語だけ";\n' >> "$F"
assert_changed "orphan key" "$F" "$B" && expect_fail "orphan key" "wizard.only_in_ja"

# ── 5. duplicate key — .strings keeps the last, silently ───────────────────
build_fixture "$TMP/case"
F="$TMP/case/$RES/ja.lproj/Localizable.strings"
B="$(shasum "$F" | cut -d' ' -f1)"
printf '"tab.overview" = "概要(2)";\n' >> "$F"
assert_changed "duplicate key" "$F" "$B" && expect_fail "duplicate key" "declared more than once"

# ── syntax A. unescaped quote — CFBundle drops the WHOLE catalogue ────────
# 2026-09-06: `"Can"t reach this Mac."` shipped into en.lproj and this guard
# printed OK with a full key count, because the key regex read straight past
# the break. The runtime could not load the file at all, so EVERY key in the
# app — long-shipped ones included — rendered as its raw dotted identifier.
build_fixture "$TMP/case"
F="$TMP/case/$RES/en.lproj/Localizable.strings"
B="$(shasum "$F" | cut -d' ' -f1)"
printf '"wizard.broken" = "Can"t do that";\n' >> "$F"
assert_changed "unescaped quote" "$F" "$B" && expect_fail "unescaped quote" "does not parse"

# ── syntax C. a replacement character parses, and still shows as a diamond ──
# ja shipped す���て for すべて: valid UTF-8, a full key count, broken on screen.
build_fixture "$TMP/case"
F="$TMP/case/$RES/ja.lproj/Localizable.strings"
B="$(shasum "$F" | cut -d' ' -f1)"
printf '"wizard.mangled" = "す\xef\xbf\xbdて";\n' >> "$F"
for L in en es ko zh-Hans zh-Hant; do
  printf '"wizard.mangled" = "ok";\n' >> "$TMP/case/$RES/$L.lproj/Localizable.strings"
done
assert_changed "replacement character" "$F" "$B" && expect_fail "replacement character" "U+FFFD replacement character"

# ── syntax B. an escaped quote is LEGAL and must stay accepted ────────────
# The opposite failure: a syntax check strict enough to reject `\"` would
# reject shipped copy (providers.show_all_hint, remote.scan_hint) and the
# multi-line advanced.remote_consent_body. Pairs with 5a so neither
# direction can be "fixed" by breaking the other.
build_fixture "$TMP/case"
F="$TMP/case/$RES/en.lproj/Localizable.strings"
printf '"wizard.quoted" = "Tap \\"Show All\\" to see more";\n' >> "$F"
printf '"wizard.multiline" = "first line\nsecond line";\n' >> "$F"
for L in es ja ko zh-Hans zh-Hant; do
  printf '"wizard.quoted" = "q";\n"wizard.multiline" = "m";\n' >> "$TMP/case/$RES/$L.lproj/Localizable.strings"
done
expect_ok "escaped quote and multi-line value stay legal"

# ── code→catalogue A. a tr() key in NO catalogue is invisible to parity ───
# The comparison is catalogue-to-catalogue, so a key missing from ALL of them
# has no locale to disagree with. NSLocalizedString then echoes the key and the
# user reads the raw dotted identifier. Six such keys existed on the branch that
# added this check.
build_fixture "$TMP/case"
F="$TMP/case/CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/L10n.swift"
BEFORE="$(shasum "$F" | cut -d' ' -f1)"
printf 'extension L10n { static var orphan: String { tr("nowhere.at_all") } }\n' >> "$F"
assert_changed "tr key in no catalogue" "$F" "$BEFORE" &&
expect_fail "tr key in no catalogue" "nowhere.at_all"

# ── code→catalogue B. a key composed at runtime cannot be resolved ────────
# `tr("pet.form_\(form.rawValue)")` is a real pattern in this codebase (71
# cases, 71 keys). Reporting it would make the gate permanently red.
build_fixture "$TMP/case"
F="$TMP/case/CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/L10n.swift"
BEFORE="$(shasum "$F" | cut -d' ' -f1)"
printf 'extension L10n { static func f(_ x: P) -> String { tr("pet.form_\\(x.rawValue)") } }\n' >> "$F"
assert_changed "interpolated tr key" "$F" "$BEFORE" &&
expect_ok "a tr key composed at runtime is skipped, not reported"

# ── code→catalogue C. the check must not fire when the key IS declared ────
build_fixture "$TMP/case"
F="$TMP/case/CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/L10n.swift"
BEFORE="$(shasum "$F" | cut -d' ' -f1)"
printf 'extension L10n { static var w: String { tr("wizard.welcome") } }\n' >> "$F"
assert_changed "declared tr key" "$F" "$BEFORE" &&
expect_ok "a tr key present in en.lproj passes"

# ── format arguments. String(format:) reads arguments by the specifiers it
# finds, so a translation that consumes different ones crashes or misplaces
# values in that language only — English testing cannot see it.
add_format_key() {  # add_format_key <en value> <ja value> [<value for the other four>]
    local other="${3:-$1}"
    printf '"fmt.key" = "%s";\n' "$1" >> "$TMP/case/$RES/en.lproj/Localizable.strings"
    printf '"fmt.key" = "%s";\n' "$2" >> "$TMP/case/$RES/ja.lproj/Localizable.strings"
    for L in es ko zh-Hans zh-Hant; do
        printf '"fmt.key" = "%s";\n' "$other" >> "$TMP/case/$RES/$L.lproj/Localizable.strings"
    done
}

build_fixture "$TMP/case"
add_format_key 'Step %d of %d: %@' '全 %2$d ステップ中 %1$d ステップ目：%3$@'
expect_ok "positional reordering consumes the same arguments"

build_fixture "$TMP/case"
add_format_key '~98%% of tokens, 98% of reads' '約 98%% のトークン、読み取りの 98%'
expect_ok "a literal percent is not an argument"

build_fixture "$TMP/case"
add_format_key '%d alerts' '%@ 件のアラート'
expect_fail "integer became object" "consumes different format arguments"

build_fixture "$TMP/case"
add_format_key '%1$@: %2$@' '%1$@'
expect_fail "dropped argument" "consumes different format arguments"

build_fixture "$TMP/case"
add_format_key 'Synced %dm ago' '%d 分前、%@ に同期'
expect_fail "added argument" "consumes different format arguments"

build_fixture "$TMP/case"
add_format_key 'Critical: %d%%' 'Crítico: %d %'
expect_fail "bare percent in a formatted string" "bare % in a string formatted"

build_fixture "$TMP/case"
printf '"plain.key" = "98%% of reads";\n' >> "$TMP/case/$RES/en.lproj/Localizable.strings"
for L in es ja ko zh-Hans zh-Hant; do
    printf '"plain.key" = "98 %% de lecturas";\n' >> "$TMP/case/$RES/$L.lproj/Localizable.strings"
done
expect_ok "a bare % in a string with no arguments is literal"

build_fixture "$TMP/case"
APPT="$TMP/case/CLI Pulse Bar/Some App"
for L in en es ja ko zh-Hans zh-Hant; do
    mkdir -p "$APPT/$L.lproj"
    printf '"Get ${provider} quota" = "Get ${provider} quota";\n' > "$APPT/$L.lproj/Localizable.strings"
done
printf '"Get ${provider} quota" = "クォータを取得";\n' > "$APPT/ja.lproj/Localizable.strings"
expect_fail "app-table parameter dropped" "consumes different format arguments"

# ── permission prompts. iOS reads NS…UsageDescription from the APP bundle's
# <locale>.lproj/InfoPlist.strings, which no Localizable.strings check can see.
# The repo had zero InfoPlist.strings until this check existed.
write_app_plist() {  # write_app_plist <dir> <has-usage-key: 1|0>
    mkdir -p "$1"
    if [ "$2" = 1 ]; then
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>NSCameraUsageDescription</key><string>Scan the code.</string></dict></plist>\n' > "$1/Info.plist"
    else
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleName</key><string>App</string></dict></plist>\n' > "$1/Info.plist"
    fi
}
write_prompt_strings() {  # write_prompt_strings <app dir> <locale...>
    local dir="$1"; shift
    for loc in "$@"; do
        mkdir -p "$dir/$loc.lproj"
        printf '"NSCameraUsageDescription" = "x";\n' > "$dir/$loc.lproj/InfoPlist.strings"
    done
}

build_fixture "$TMP/case"
write_app_plist "$TMP/case/CLI Pulse Bar/App" 1
expect_fail "usage description with no InfoPlist.strings at all" "InfoPlist.strings is missing"

build_fixture "$TMP/case"
write_app_plist "$TMP/case/CLI Pulse Bar/App" 1
write_prompt_strings "$TMP/case/CLI Pulse Bar/App" en es ja ko zh-Hans    # zh-Hant forgotten
expect_fail "usage description missing from one locale" "zh-Hant.lproj/InfoPlist.strings is missing"

build_fixture "$TMP/case"
write_app_plist "$TMP/case/CLI Pulse Bar/App" 1
write_prompt_strings "$TMP/case/CLI Pulse Bar/App" en es ja ko zh-Hans zh-Hant
printf '"SomethingElse" = "x";\n' > "$TMP/case/CLI Pulse Bar/App/ko.lproj/InfoPlist.strings"
expect_fail "InfoPlist.strings present but the key is not in it" "NSCameraUsageDescription is not in ko.lproj"

build_fixture "$TMP/case"
write_app_plist "$TMP/case/CLI Pulse Bar/App" 1
write_prompt_strings "$TMP/case/CLI Pulse Bar/App" en es ja ko zh-Hans zh-Hant
expect_ok "a usage description localized in every shipped locale passes"

build_fixture "$TMP/case"
write_app_plist "$TMP/case/CLI Pulse Bar/Watch" 0
expect_ok "an app that declares no usage description needs no InfoPlist.strings"

# ── app-bundle tables: App Intent titles and Shortcut phrases live in the APP
# bundle, where the catalogue comparison above cannot see them.
write_shortcuts() {  # write_shortcuts <app dir> <en value> <other-locale value>
    local dir="$1" en="$2" other="$3"
    mkdir -p "$dir"
    printf 'struct S: AppShortcutsProvider { static var appShortcuts: [AppShortcut] { AppShortcut(intent: I(), phrases: [ "Check \\(.applicationName) quota" ], shortTitle: "Q", systemImageName: "cpu") } }\n' > "$dir/S.swift"
    for loc in en es ja ko zh-Hans zh-Hant; do
        mkdir -p "$dir/$loc.lproj"
        local v="$other"; [ "$loc" = en ] && v="$en"
        printf '"Check ${applicationName} quota" = "%s";\n' "$v" > "$dir/$loc.lproj/AppShortcuts.strings"
    done
}

build_fixture "$TMP/case"
write_shortcuts "$TMP/case/CLI Pulse Bar/App" 'Check ${applicationName} quota' 'X ${applicationName} Y'
expect_ok "Shortcut phrases with the token exactly once in every locale pass"

# The silent one: iOS just never responds to this phrase in this language.
build_fixture "$TMP/case"
write_shortcuts "$TMP/case/CLI Pulse Bar/App" 'Check ${applicationName} quota' 'Check the quota'
expect_fail "a translated phrase that DROPPED the token" 'contains ${applicationName} 0 times'

build_fixture "$TMP/case"
write_shortcuts "$TMP/case/CLI Pulse Bar/App" 'Check ${applicationName} quota' '${applicationName} ${applicationName}'
expect_fail "a translated phrase with the token twice" 'contains ${applicationName} 2 times'

build_fixture "$TMP/case"
write_shortcuts "$TMP/case/CLI Pulse Bar/App" 'Check ${applicationName} quota' 'X ${applicationName} Y'
printf 'struct T: AppShortcutsProvider { static var appShortcuts: [AppShortcut] { AppShortcut(intent: J(), phrases: [ "Open \\(.applicationName)" ], shortTitle: "O", systemImageName: "x") } }\n' > "$TMP/case/CLI Pulse Bar/App/T.swift"
expect_fail "a new phrase in Swift with no translation" "has no entry in AppShortcuts.strings"

build_fixture "$TMP/case"
write_shortcuts "$TMP/case/CLI Pulse Bar/App" 'Check ${applicationName} quota' 'X ${applicationName} Y'
printf '"Something" = "else";\n' > "$TMP/case/CLI Pulse Bar/App/ja.lproj/AppShortcuts.strings"
expect_fail "one locale's table lacks a key" "ja.lproj/AppShortcuts.strings lacks"

# ── syntax C. an empty catalogue is the same outage as an unparseable one ─
build_fixture "$TMP/case"
printf '// only a comment\n' > "$TMP/case/$RES/en.lproj/Localizable.strings"
expect_fail "empty catalogue" "declares no entries"

# ── syntax D. the two readers must agree — two entries on one line ────────
# The key regex is anchored to line start, so it sees one; the syntax scanner
# sees both. A disagreement means one of them is misreading the file, which is
# exactly the state 5a shipped in.
build_fixture "$TMP/case"
F="$TMP/case/$RES/ja.lproj/Localizable.strings"
B="$(shasum "$F" | cut -d' ' -f1)"
printf '"wizard.a" = "x"; "wizard.b" = "y";\n' >> "$F"
assert_changed "two readers" "$F" "$B" && expect_fail "two readers" "disagree"

# ── 5b. an entire SHIPPED locale disappearing ──────────────────────────────
#    Discovery by glob simply stopped iterating the deleted locale, so a whole
#    translation could vanish with the gate green. (Codex review, 2026-08-30.)
build_fixture "$TMP/case"
rm -rf "$TMP/case/$RES/zh-Hans.lproj"
expect_fail "shipped locale deleted" "zh-Hans.lproj"

# ── 5c. --update-baseline must not launder new debt ────────────────────────
#    The baseline is a ratchet; regenerating it was a way to grow it silently.
build_fixture "$TMP/case"
printf '"wizard.finish" = "Finish";\n' >> "$TMP/case/$RES/en.lproj/Localizable.strings"
out="$(python3 "$GUARD" --root "$TMP/case" --update-baseline 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
    echo "FAIL: [baseline growth] --update-baseline silently grew the debt."
    fail=$((fail + 1))
elif ! printf '%s' "$out" | grep -qF "may only shrink"; then
    echo "FAIL: [baseline growth] refused, but not for the expected reason: $out"
    fail=$((fail + 1))
else
    echo "ok:   [baseline growth] --update-baseline refused to grow the debt."
    pass=$((pass + 1))
fi
#    …and --allow-growth is the explicit, reviewable escape hatch.
if python3 "$GUARD" --root "$TMP/case" --update-baseline --allow-growth >/dev/null 2>&1; then
    echo "ok:   [baseline growth] --allow-growth permits it explicitly."
    pass=$((pass + 1))
else
    echo "FAIL: [baseline growth] --allow-growth did not work."
    fail=$((fail + 1))
fi

# ── 6. the baseline itself going missing must not be a silent pass ─────────
build_fixture "$TMP/case"
rm "$TMP/case/scripts/apple_strings_parity_baseline.json"
expect_fail "absent baseline" "baseline missing"

# ── 7. an empty resources tree must not be a silent pass ──────────────────
build_fixture "$TMP/case"
rm -rf "$TMP/case/$RES/es.lproj" "$TMP/case/$RES/ja.lproj" \
       "$TMP/case/$RES/ko.lproj" "$TMP/case/$RES/zh-Hans.lproj" "$TMP/case/$RES/zh-Hant.lproj"
expect_fail "single locale" "nothing to compare"

echo
echo "check_apple_strings_parity negative controls: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
