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

write_host_plist() {  # write_host_plist <app dir> <locale...>
    local dir="$1"; shift
    mkdir -p "$dir"
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>\n'
        printf '<key>CFBundleDevelopmentRegion</key><string>$(DEVELOPMENT_LANGUAGE)</string>\n'
        printf '<key>CFBundleLocalizations</key><array>\n<!-- a comment, as the real ones carry -->\n'
        for loc in "$@"; do printf '<string>%s</string>\n' "$loc"; done
        printf '</array></dict></plist>\n'
    } > "$dir/Info.plist"
}

# An Xcode project that copies every app-bundle table on disk, written the way
# Xcode writes one: every table a PBXVariantGroup with one child per locale, in
# the Resources phase of the target whose INFOPLIST_FILE lives in that folder.
# Written just before the guard runs, so a case that only plants a .strings
# defect is not ALSO failing for a missing project. A case that plants a
# project defect writes it first and edits it.
write_pbxproj() {  # write_pbxproj <tree>
    python3 - "$1" <<'PY'
import sys
from pathlib import Path
root = Path(sys.argv[1])
app_root = root / "CLI Pulse Bar"
apps = {}
for t in sorted(app_root.glob("*/*.lproj/*.strings")):
    apps.setdefault(t.parent.parent.name, {}).setdefault(t.name, []).append(t.parent.name[:-6])
out = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tobjects = {"]
for a, (app, tables) in enumerate(sorted(apps.items()), 1):
    out += [f"\t\tG{a} /* {app} */ = {{", "\t\t\tisa = PBXGroup;", "\t\t\tchildren = ("]
    out += [f"\t\t\t\tV{a}_{b} /* {table} */," for b, table in enumerate(sorted(tables), 1)]
    out += ["\t\t\t);", f'\t\t\tpath = "{app}";', '\t\t\tsourceTree = "<group>";', "\t\t};"]
    for b, (table, locs) in enumerate(sorted(tables.items()), 1):
        out += [f"\t\tV{a}_{b} /* {table} */ = {{", "\t\t\tisa = PBXVariantGroup;", "\t\t\tchildren = ("]
        out += [f"\t\t\t\tR{a}_{b}_{c} /* {loc}.lproj/{table} */," for c, loc in enumerate(sorted(locs), 1)]
        out += ["\t\t\t);", f"\t\t\tname = {table};", "\t\t};"]
        for c, loc in enumerate(sorted(locs), 1):
            out.append(f'\t\tR{a}_{b}_{c} /* {loc}.lproj/{table} def */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.strings; '
                       f'name = "{loc}"; path = "{loc}.lproj/{table}"; sourceTree = "<group>"; }};')
        out.append(f"\t\tB{a}_{b} /* {table} in Resources def */ = {{isa = PBXBuildFile; fileRef = V{a}_{b} /* {table} */; }};")
    out += [f"\t\tP{a} /* Resources */ = {{", "\t\t\tisa = PBXResourcesBuildPhase;", "\t\t\tfiles = ("]
    out += [f"\t\t\t\tB{a}_{b} /* {table} in Resources */," for b, table in enumerate(sorted(tables), 1)]
    out += ["\t\t\t);", "\t\t};"]
    out += [f"\t\tT{a} /* {app} */ = {{", "\t\t\tisa = PBXNativeTarget;", f"\t\t\tbuildConfigurationList = L{a};",
            "\t\t\tbuildPhases = (", f"\t\t\t\tS{a} /* Sources */,", f"\t\t\t\tP{a} /* Resources */,", "\t\t\t);",
            f'\t\t\tname = "{app}";', "\t\t};",
            f"\t\tS{a} /* Sources */ = {{isa = PBXSourcesBuildPhase; files = (); }};",
            f"\t\tL{a} = {{isa = XCConfigurationList; buildConfigurations = ( C{a} /* Release */, ); }};",
            f'\t\tC{a} /* Release */ = {{isa = XCBuildConfiguration; buildSettings = {{ INFOPLIST_FILE = "{app}/Info.plist"; '
            f'SHELL = /bin/bash; }}; name = Release; }};']
out += ["\t};", "\trootObject = G1;", "}"]
proj = app_root / "CLI Pulse Bar.xcodeproj" / "project.pbxproj"
proj.parent.mkdir(parents=True, exist_ok=True)
proj.write_text("\n".join(out) + "\n", encoding="utf-8")
PY
}

PBXPROJ="CLI Pulse Bar/CLI Pulse Bar.xcodeproj/project.pbxproj"

prepare_case() {
    if [ ! -f "$TMP/case/$PBXPROJ" ] && [ ! -f "$TMP/case/.no-pbxproj" ]; then
        write_pbxproj "$TMP/case"
    fi
}

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

    # The four targets that render L10n declare the shipped locales, as the real
    # ones do; the CFBundleLocalizations cases below take one away.
    for host in "CLI Pulse Bar" "CLI Pulse Bar iOS" "CLI Pulse Bar Watch" "CLI Pulse Widgets"; do
        write_host_plist "$dest/CLI Pulse Bar/$host" en zh-Hans zh-Hant ja ko es
    done

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
    prepare_case
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
    prepare_case
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

# ── code→catalogue B. a key composed at runtime is expanded per enum case ──
# `tr("pet.form_\(form.rawValue)")` names 71 keys and no literal says which.
# It used to be skipped, so a PetForm case added without its key showed
# "pet.form_<raw>" in the Cattery in every language with every gate green.
write_composed() {  # write_composed <enum body>  — P plus a composed accessor
    local core="$TMP/case/CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore"
    printf 'public enum P: String, Codable, CaseIterable {\n%s\n    var label: String { switch self { case .a: return "x"; default: return "y" } }\n}\n' "$1" > "$core/P.swift"
    printf 'extension L10n { static func f(_ x: P) -> String { tr("pet.form_\\(x.rawValue)") } }\n' >> "$core/L10n.swift"
}
add_key_everywhere() {  # add_key_everywhere <key>
    for L in en es ja ko zh-Hans zh-Hant; do
        printf '"%s" = "v";\n' "$1" >> "$TMP/case/$RES/$L.lproj/Localizable.strings"
    done
}

build_fixture "$TMP/case"
write_composed '    case a   // a trailing comment
    case b = "bee"'
add_key_everywhere pet.form_a; add_key_everywhere pet.form_bee
expect_ok "a composed key whose every expansion is declared passes"

build_fixture "$TMP/case"
write_composed '    case a
    case b = "bee"
    case c'
add_key_everywhere pet.form_a; add_key_everywhere pet.form_bee
expect_fail "an enum case added without its composed key" "pet.form_c"

build_fixture "$TMP/case"
F="$TMP/case/CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/L10n.swift"
BEFORE="$(shasum "$F" | cut -d' ' -f1)"
printf 'extension L10n { static func f(_ x: Q) -> String { tr("pet.form_\\(x.rawValue)") } }\n' >> "$F"
assert_changed "unexpandable tr key" "$F" "$BEFORE" &&
expect_fail "a composed key over a type the gate cannot find FAILS, not skips" "cannot expand"

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

# ═══ App bundles: what the iPhone app ships from its own folder ═════════════
# An iOS-shaped app: three intents (one hidden), a Shortcuts provider, and the
# three tables the system reads from the app bundle, each with the header
# comment the real ones carry. Every case below starts from this and plants one
# defect the real tree could acquire.
APP="$TMP/case/CLI Pulse Bar/Phone"
write_phone_app() {
    mkdir -p "$APP/Intents"
    write_host_plist "$APP" en zh-Hans zh-Hant ja ko es
    python3 - "$APP/Info.plist" <<'PY'
import sys; p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s.replace("<dict>\n", "<dict>\n<key>NSCameraUsageDescription</key><string>Scan the code.</string>\n", 1))
PY
    cat > "$APP/Intents/StatusIntent.swift" <<'SWIFT'
import AppIntents

// static var title: LocalizedStringResource = "A title only a comment mentions"
struct StatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Pulse Status"
    static var description = IntentDescription(
        "Get today's usage.",
        categoryName: "Status"
    )
    func perform() async throws -> some IntentResult { .result() }
}

enum IntentProvider: String, AppEnum {
    case claude
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Provider"
    static var caseDisplayRepresentations: [IntentProvider: DisplayRepresentation] = [
        .claude: DisplayRepresentation(title: "Claude"),
    ]
}

struct QuotaIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Provider Quota"
    @Parameter(title: "Provider")
    var provider: IntentProvider
    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$provider) quota")
    }
    func perform() async throws -> some IntentResult { .result() }
}

struct HiddenIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh the widget"
    static var description = IntentDescription("Not listed anywhere.", categoryName: "Widgets")
    static var isDiscoverable: Bool = false
    func perform() async throws -> some IntentResult { .result() }
}
SWIFT
    cat > "$APP/Intents/Shortcuts.swift" <<'SWIFT'
import AppIntents

struct Shortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StatusIntent(), phrases: [ "Get \(.applicationName) status" ],
                    shortTitle: "Get Status", systemImageName: "gauge")
    }
}
SWIFT
    for loc in en es ja ko zh-Hans zh-Hant; do
        mkdir -p "$APP/$loc.lproj"
        cat > "$APP/$loc.lproj/Localizable.strings" <<'STRINGS'
/* App Intents: names, descriptions and parameter titles.
   Keys are the English literals in the intent source. */

"Get Pulse Status" = "T";
"Get today's usage." = "D";
"Status" = "S";
"Provider" = "P";
"Get Provider Quota" = "Q";
"Get ${provider} quota" = "${provider} Q";
"Get Status" = "G";
STRINGS
        cat > "$APP/$loc.lproj/AppShortcuts.strings" <<'STRINGS'
/* App Shortcut phrases — what a person SAYS to Siri. Every phrase must contain
   ${applicationName} exactly once. */

"Get ${applicationName} status" = "${applicationName} status";
STRINGS
        cat > "$APP/$loc.lproj/InfoPlist.strings" <<'STRINGS'
/* Permission prompts. */

"NSCameraUsageDescription" = "Camera, to scan the pairing code.";
STRINGS
    done
}
phone_case() { build_fixture "$TMP/case"; write_phone_app; }
edit() {  # edit <file> <python expression over s>  — fails the case if nothing changed
    python3 - "$1" "$2" <<'PY'
import sys
p, expr = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
t = eval(expr)
if t == s:
    sys.exit("edit was a no-op: " + expr)
open(p, "w", encoding="utf-8").write(t)
PY
}

phone_case
expect_ok "positive control: an iOS-shaped app with intents, phrases, prompts and a project"

# ── app-bundle syntax. These tables were read only by line regexes. ────────
# Deleting a header's closing */ empties the table — `plutil -p` prints {} and
# `plutil -lint` still says OK, so Xcode ships it — and this gate said OK.
phone_case
edit "$APP/ja.lproj/AppShortcuts.strings" 's.replace("exactly once. */", "exactly once.", 1)' &&
expect_fail "an app-bundle table whose header comment never closes" "unterminated /* comment"

# A stray quote: iOS drops the whole InfoPlist table, both prompts go English.
phone_case
edit "$APP/ja.lproj/InfoPlist.strings" 's.replace("Camera, to", "Camera\", to", 1)' &&
expect_fail "an unescaped quote in an app-bundle InfoPlist.strings" "Phone/ja.lproj/InfoPlist.strings — line"

# A comment that swallows entries but finds a later */ — the two readers disagree.
phone_case
edit "$APP/ko.lproj/Localizable.strings" 's.replace("intent source. */", "intent source.", 1).replace("\"Get Status\" = \"G\";", "/* x */ \"Get Status\" = \"G\";", 1)' &&
expect_fail "a header comment that swallows entries up to a later */" "the two readers disagree"

phone_case
printf '"Status" = "S2";\n' >> "$APP/zh-Hant.lproj/Localizable.strings"
expect_fail "a key declared twice in an app-bundle table" "Phone/zh-Hant.lproj/Localizable.strings: Status is declared more than once"

phone_case
printf '/* only a comment */\n' > "$APP/es.lproj/InfoPlist.strings"
expect_fail "an app-bundle table emptied to a comment" "Phone/es.lproj/InfoPlist.strings — parsed, but declares no entries"

# ── App Intents literals. The system looks each one up by its English text. ─
phone_case
edit "$APP/Intents/StatusIntent.swift" 's.replace("\"Get Pulse Status\"", "\"Get Pulse Summary\"", 1)' &&
expect_fail "an intent title renamed in Swift" "title 'Get Pulse Summary' has no entry in Phone/en.lproj/Localizable.strings"

phone_case
edit "$APP/Intents/StatusIntent.swift" 's.replace("\"Get Pulse Status\"", "\"Get Pulse Summary\"", 1)' &&
expect_fail "…and the translations it orphaned are reported too" "'Get Pulse Status' is not written by any App Intents literal"

phone_case
edit "$APP/Intents/StatusIntent.swift" 's.replace("Summary(\"Get ", "Summary(\"Show ", 1)' &&
expect_fail "a parameter summary reworded" 'parameterSummary '"'"'Show ${provider} quota'"'"' has no entry'

phone_case
edit "$APP/Intents/StatusIntent.swift" 's.replace("@Parameter(title: \"Provider\")", "@Parameter(title: \"Provider\", description: \"Which coding agent to check\")", 1)' &&
expect_fail "a parameter description added without a translation" "@Parameter description 'Which coding agent to check' has no entry"

phone_case
edit "$APP/Intents/Shortcuts.swift" 's.replace("shortTitle: \"Get Status\"", "shortTitle: \"Status Now\"", 1)' &&
expect_fail "a shortTitle changed" "shortTitle 'Status Now' has no entry"

phone_case
edit "$APP/Intents/StatusIntent.swift" 's.replace("categoryName: \"Status\"", "categoryName: \"Usage\"", 1)' &&
expect_fail "a categoryName changed" "categoryName 'Usage' has no entry"

phone_case
edit "$APP/Intents/StatusIntent.swift" 's.replace("TypeDisplayRepresentation = \"Provider\"", "TypeDisplayRepresentation = \"Agent\"", 1)' &&
expect_fail "a typeDisplayRepresentation changed" "typeDisplayRepresentation 'Agent' has no entry"

phone_case
for loc in en es ja ko zh-Hans zh-Hant; do printf '"Old intent name" = "x";\n' >> "$APP/$loc.lproj/Localizable.strings"; done
expect_fail "a table entry no intent asks for any more" "'Old intent name' is not written by any App Intents literal"

# The exemption is the declaration, not the file: make the hidden intent
# discoverable and its three strings are suddenly required.
phone_case
edit "$APP/Intents/StatusIntent.swift" 's.replace("isDiscoverable: Bool = false", "isDiscoverable: Bool = true", 1)' &&
expect_fail "an intent made discoverable without translations" "title 'Refresh the widget' has no entry"

# ── CFBundleLocalizations. The macOS app, Watch and widgets have no .lproj. ─
build_fixture "$TMP/case"
edit "$TMP/case/CLI Pulse Bar/CLI Pulse Bar/Info.plist" 's.replace("<string>ko</string>\n", "", 1)' &&
expect_fail "ko removed from the macOS app's CFBundleLocalizations" "CLI Pulse Bar/Info.plist: CFBundleLocalizations lacks ko"

build_fixture "$TMP/case"
edit "$TMP/case/CLI Pulse Bar/CLI Pulse Widgets/Info.plist" 's.replace("<string>es</string>\n", "<string>es</string>\n<string>fr</string>\n", 1)' &&
expect_fail "a locale declared that does not ship" "declares fr, which is not a shipped locale"

build_fixture "$TMP/case"
edit "$TMP/case/CLI Pulse Bar/CLI Pulse Bar Watch/Info.plist" 's.replace("<string>ja</string>\n", "<string>ja</string>\n<string>ja</string>\n", 1)' &&
expect_fail "a locale listed twice" "lists ja twice"

build_fixture "$TMP/case"
rm "$TMP/case/CLI Pulse Bar/CLI Pulse Bar iOS/Info.plist"
expect_fail "a host Info.plist that vanished" "CLI Pulse Bar iOS/Info.plist is missing"

build_fixture "$TMP/case"
edit "$TMP/case/CLI Pulse Bar/CLI Pulse Bar Watch/Info.plist" 's.replace("</dict>", "<key>Broken</key></dict>", 1)' &&
expect_fail "a host Info.plist that does not parse" "CLI Pulse Bar Watch/Info.plist does not parse"

phone_case
edit "$APP/Info.plist" 's.replace("<string>zh-Hant</string>\n", "", 1)' &&
expect_fail "any other app that declares the key must declare all six" "Phone/Info.plist: CFBundleLocalizations lacks zh-Hant"

# ── Xcode copies the tables, or they do not ship. ──────────────────────────
phone_case
write_pbxproj "$TMP/case"
python3 - "$TMP/case/$PBXPROJ" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p).read()
t = re.sub(r"^\s*R\w+ /\* ko\.lproj/AppShortcuts\.strings \*/,\n", "", s, count=1, flags=re.M)
assert t != s, "plant did not land"
open(p, "w").write(t)
PY
expect_fail "a locale removed from a variant group" "Phone: ko.lproj/AppShortcuts.strings is not a child of the AppShortcuts.strings variant group"

phone_case
write_pbxproj "$TMP/case"
python3 - "$TMP/case/$PBXPROJ" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p).read()
t = re.sub(r"^\s*B\w+ /\* InfoPlist\.strings in Resources \*/,\n", "", s, count=1, flags=re.M)
assert t != s, "plant did not land"
open(p, "w").write(t)
PY
expect_fail "a variant group dropped from the Resources phase" "does not copy InfoPlist.strings"

phone_case
write_pbxproj "$TMP/case"
python3 - "$TMP/case/$PBXPROJ" <<'PY'
import sys, re
p = sys.argv[1]; s = open(p).read()
t = re.sub(r"^\s*V\w+ /\* Localizable\.strings \*/,\n", "", s, count=1, flags=re.M)
assert t != s, "plant did not land"
open(p, "w").write(t)
PY
expect_fail "a table on disk that the project never mentions" "Localizable.strings is on disk (en, es, ja, ko, zh-Hans, zh-Hant) but is not a variant group"

phone_case
touch "$TMP/case/.no-pbxproj"
expect_fail "app-bundle tables with no project to prove they are copied" "project.pbxproj is missing"

phone_case
write_pbxproj "$TMP/case"
printf 'garbage {\n' >> "$TMP/case/$PBXPROJ"
expect_fail "a project file that does not parse" "project.pbxproj does not parse"

# ── Arguments L10n.swift passes vs what ENGLISH consumes. ──────────────────
# The translation check compares locales with en, so a specifier changed in all
# six at once still "matches". providers.tracked_count going %d → %@ everywhere
# passed and would crash String(format:) on the Providers tab in every language.
CORE="$TMP/case/CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore"
code_case() {  # code_case <en/other value for fmt.count> [<value for fmt.named>]
    build_fixture "$TMP/case"
    cat >> "$CORE/L10n.swift" <<'SWIFT'
enum Issue { case pair(String, Int) }
extension L10n {
    static func trackedCount(_ a0: Int) -> String {
        a0 == 1 ? tr("fmt.count_one", a0) : tr("fmt.count", a0)
    }
    static func named(_ name: String, english: Bool = false) -> String {
        let shown = String(name.prefix(20))
        return tr("fmt.named", english: english, shown, name)
    }
    static func issue(_ i: Issue) -> String {
        switch i {
        case .pair(let a0, let a1): return tr("fmt.pair", a0, a1)
        }
    }
}
SWIFT
    add_key_everywhere_value fmt.count "$1"
    add_key_everywhere_value fmt.count_one '%d provider'
    add_key_everywhere_value fmt.named "${2:-%1\$@ (%2\$@), again %1\$@}"
    add_key_everywhere_value fmt.pair '%@: %d'
}
add_key_everywhere_value() {  # add_key_everywhere_value <key> <value>
    for L in en es ja ko zh-Hans zh-Hant; do
        printf '"%s" = "%s";\n' "$1" "$2" >> "$TMP/case/$RES/$L.lproj/Localizable.strings"
    done
}

code_case '%d providers'
expect_ok "Int→%d, String→%@ (positional, reused), a local let, a switch-bound payload, english: skipped"

code_case '%@ providers'
expect_fail "an Int passed to %@ — changed in all six catalogues at once" "fmt.count — L10n.swift passes [('1', 'integer')], en consumes [('1', 'object')]"

code_case '%d of %d providers'
expect_fail "English consumes an argument the code never passes" "fmt.count — L10n.swift passes"

code_case '%d providers' '%1$d (%2$@)'
expect_fail "a String passed to %d" "fmt.named — L10n.swift passes"

code_case '%d providers'
printf 'extension L10n { static var bare: String { tr("fmt.count") } }\n' >> "$CORE/L10n.swift"
expect_fail "a formatted key called with no arguments shows its specifiers" "fmt.count is called with no arguments"

code_case '%d providers'
printf 'let someGlobal = 3\nextension L10n { static func g() -> String { tr("fmt.count", someGlobal) } }\n' >> "$CORE/L10n.swift"
expect_fail "an argument whose type cannot be read FAILS rather than being skipped" "cannot find where 'someGlobal' is declared"

code_case '%d providers'
edit "$CORE/L10n.swift" 's.replace("case pair(String, Int)", "case pair(Int, Int)", 1)' &&
expect_fail "an enum payload type changed under a switch-bound argument" "fmt.pair — L10n.swift passes"

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
