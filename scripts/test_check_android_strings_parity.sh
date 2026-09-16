#!/bin/bash
# Negative controls for ci_check_android_strings_parity.py.
#
# Every defect the gate claims to catch is planted in a fixture tree and must be
# caught FOR THE STATED REASON; every legal shape it must not flag is planted
# too, because a gate that rejects everything looks identical to one that works.
# `assert_changed` proves each mutation landed, so a no-op plant is never scored
# as a catch.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/scripts/ci_check_android_strings_parity.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
RES="android/app/src/main/res"

pass=0
fail=0

write_locale() {  # write_locale <dir> <label-value> <count-value> <plural-block>
    mkdir -p "$TMP/case/$RES/$1"
    cat > "$TMP/case/$RES/$1/strings.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<resources xmlns:xliff="urn:oasis:names:tc:xliff:document:1.2">
    <string name="app_name">CLI Pulse</string>
    <string name="label">$2</string>
    <string name="count">$3</string>
$4
</resources>
XML
}

build_fixture() {
    rm -rf "$TMP/case"
    write_locale values "Today\\'s Usage" "Plan: %1\$s, %2\$d left" \
        '    <plurals name="devices"><item quantity="one">%d device</item><item quantity="other">%d devices</item></plurals>'
    write_locale values-es "Uso de hoy" "Plan: %1\$s, quedan %2\$d" \
        '    <plurals name="devices"><item quantity="one">%d dispositivo</item><item quantity="other">%d dispositivos</item></plurals>'
    for d in values-ja values-ko values-zh-rCN values-zh-rTW; do
        write_locale "$d" "X" "%1\$s %2\$d" \
            '    <plurals name="devices"><item quantity="other">%d</item></plurals>'
    done
}

assert_changed() {
    local name="$1" file="$2" before="$3"
    if [ "$before" = "$(shasum "$file" | cut -d' ' -f1)" ]; then
        echo "FAIL: [$name] mutation was a NO-OP — the case proves nothing."
        fail=$((fail + 1)); return 1
    fi
}

expect_fail() {
    local name="$1" needle="$2" out rc
    out="$(python3 "$GUARD" --root "$TMP/case" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ]; then
        echo "FAIL: [$name] guard PASSED a tree it should have rejected."
        fail=$((fail + 1)); return
    fi
    if ! printf '%s' "$out" | grep -qF -- "$needle"; then
        echo "FAIL: [$name] guard failed (rc=$rc), but not for the expected reason."
        echo "      wanted substring: $needle"
        printf '%s\n' "$out" | sed 's/^/      /'
        fail=$((fail + 1)); return
    fi
    echo "ok:   [$name] rejected, for the right reason."
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
    echo "ok:   [$name] accepted."
    pass=$((pass + 1))
}

mutate() {  # mutate <name> <locale-dir> <python-expression over s>
    local f="$TMP/case/$RES/$2/strings.xml" before
    before="$(shasum "$f" | cut -d' ' -f1)"
    python3 -c "import sys; p=sys.argv[1]; s=open(p).read(); s=$3; open(p,'w').write(s)" "$f"
    assert_changed "$1" "$f" "$before"
}

# ── positive control ────────────────────────────────────────────────────────
build_fixture; expect_ok "positive control"

# ── parity ─────────────────────────────────────────────────────────────────
build_fixture; mutate "missing key" values-ja "s.replace('<string name=\"label\">X</string>', '')" &&
    expect_fail "missing key" "'label' is missing"
build_fixture; mutate "orphan key" values-ko "s.replace('</resources>', '<string name=\"only_ko\">Y</string></resources>')" &&
    expect_fail "orphan key" "'only_ko' is not in values/"
build_fixture; mutate "duplicate key" values-es "s.replace('</resources>', '<string name=\"label\">Otra</string></resources>')" &&
    expect_fail "duplicate key" "declared more than once"
build_fixture; mutate "type changed" values-zh-rCN "s.replace('<string name=\"label\">X</string>', '<plurals name=\"label\"><item quantity=\"other\">X</item></plurals>')" &&
    expect_fail "type changed" "is a <plurals> here but a <string> in values/"
build_fixture; rm -rf "$TMP/case/$RES/values-ko"
    expect_fail "shipped locale deleted" "values-ko"
build_fixture; mkdir -p "$TMP/case/$RES/values-fr" && cp "$TMP/case/$RES/values-es/strings.xml" "$TMP/case/$RES/values-fr/"
    expect_fail "undeclared locale" "does not declare"
build_fixture; mkdir -p "$TMP/case/$RES/values-night" "$TMP/case/$RES/values-v23"
    expect_ok "configuration qualifiers are not locales"
build_fixture; mutate "malformed xml" values-ja "s.replace('</resources>', '')" &&
    expect_fail "malformed xml" "does not parse"
build_fixture; mutate "translatable=false stays out" values "s.replace('</resources>', '<string name=\"brand\" translatable=\"false\">CLI Pulse</string></resources>')" &&
    expect_ok "a translatable=false key is not required in locales"

# ── format arguments ───────────────────────────────────────────────────────
build_fixture; mutate "dropped argument" values-ja "s.replace('%1\$s %2\$d', '%1\$s')" &&
    expect_fail "dropped argument" "'count' consumes"
build_fixture; mutate "integer became string" values-zh-rCN "s.replace('%1\$s %2\$d', '%1\$s %2\$s')" &&
    expect_fail "integer became string" "'count' consumes"
build_fixture; mutate "positional reorder" values-ko "s.replace('%1\$s %2\$d', '%2\$d개 남음, %1\$s')" &&
    expect_ok "positional reordering consumes the same arguments"
build_fixture; mutate "literal percent" values-es "s.replace('Uso de hoy', '98 %% del uso')" &&
    expect_ok "a literal percent is not an argument"
build_fixture; mutate "xliff wrapper" values-ja "s.replace('%1\$s %2\$d', '<xliff:g id=\"p\">%1\$s</xliff:g> %2\$d')" &&
    expect_ok "a specifier inside xliff:g is still counted"
build_fixture; mutate "plural other argument dropped" values-ja "s.replace('<item quantity=\"other\">%d</item>', '<item quantity=\"other\">many</item>')" &&
    expect_fail "plural other argument dropped" "[other] consumes"

build_fixture; mutate "bare percent in formatted string" values-es "s.replace('quedan %2\$d', 'quedan %2\$d (98 % del total)')" &&
    expect_fail "bare percent in formatted string" "bare % in a string formatted"
build_fixture; mutate "bare percent in plain string" values-es "s.replace('Uso de hoy', 'Uso de hoy: 98 %')" &&
    expect_ok "a bare % in a string with no arguments is literal"

# ── plurals ────────────────────────────────────────────────────────────────
build_fixture; mutate "plural without other" values-ko "s.replace('<item quantity=\"other\">%d</item>', '')" &&
    expect_fail "plural without other" "no quantity=\"other\""
build_fixture; mutate "dead quantity" values-ja "s.replace('<item quantity=\"other\">', '<item quantity=\"one\">%d</item><item quantity=\"other\">')" &&
    expect_fail "dead quantity" "never selects"
build_fixture; mutate "es many" values-es "s.replace('<item quantity=\"other\">', '<item quantity=\"many\">%d de dispositivos</item><item quantity=\"other\">')" &&
    expect_ok "es may carry quantity=many"
build_fixture; mutate "en one missing" values "s.replace('<item quantity=\"one\">%d device</item>', '')" &&
    expect_fail "en one missing" "no quantity=\"one\""

# ── apostrophes ────────────────────────────────────────────────────────────
build_fixture; mutate "unescaped apostrophe" values-es "s.replace('Uso de hoy', \"Today's\")" &&
    expect_fail "unescaped apostrophe" "unescaped apostrophe"
build_fixture; mutate "quoted apostrophe" values-es "s.replace('Uso de hoy', '\"Today\\'s\"'.replace(chr(92), ''))" &&
    expect_ok "an apostrophe inside a double-quoted value is legal"

echo
echo "ci_check_android_strings_parity negative controls: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
