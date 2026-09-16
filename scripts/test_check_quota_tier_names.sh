#!/usr/bin/env bash
# Negative controls for check_quota_tier_names.py.
#
# The gate's whole job is to fail, so each case builds a tiny fake tree, runs the
# real gate against it, and asserts the exit code. Two cases exist because the
# heuristics got them wrong first: a tier built through a local helper
# (`addPool("Open Source", …)`) rather than a constructor, and a file path passed
# to a function whose name happens to contain "pool".
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/scripts/check_quota_tier_names.py"
APPLE="CLI Pulse Bar"
CORE="$APPLE/CLIPulseCore/Sources/CLIPulseCore"
pass=0; fail=0

new_tree() {
  T="$(mktemp -d)"
  mkdir -p "$T/$CORE/Collectors" "$T/$CORE/Resources" "$T/scripts"
  for loc in en zh-Hans zh-Hant ja ko es; do
    mkdir -p "$T/$CORE/Resources/$loc.lproj"
    printf '"quota_tier.weekly" = "W";\n' > "$T/$CORE/Resources/$loc.lproj/Localizable.strings"
  done
  cat > "$T/$CORE/L10n.swift" <<'L10N'
public enum L10n {
    public enum quotaTier {
        public static var weekly: String { tr("quota_tier.weekly") }
        public static func localized(_ raw: String) -> String {
            switch raw {
            case "Weekly": return weekly
            default: return raw
            }
        }
    }
}
L10N
  producer 'let t = UsageTier(name: "Weekly", usage: 1, quota: 2, remaining: 1, resetTime: nil)'
  manifest '{"entries":[{"name":"Weekly","display":"TRANSLATE","l10n_key":"quota_tier.weekly","reason":"a generic time window this app composed, emitted by nine unrelated collectors"}]}'
}
producer() { printf '%s\n' "$1" > "$T/$CORE/Collectors/C.swift"; }
manifest() { printf '%s\n' "$1" > "$T/scripts/quota_tier_names.json"; }
strings_for() { printf '%s\n' "$2" > "$T/$CORE/Resources/$1.lproj/Localizable.strings"; }
l10n() { printf '%s\n' "$1" > "$T/$CORE/L10n.swift"; }

expect() {  # expect <want-exit> <name>
  local want="$1" name="$2" out got
  out="$(python3 "$GUARD" --root "$T" 2>&1)"; got=$?
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "  ok    $name"
  else fail=$((fail+1)); echo "  FAIL  $name (want exit $want, got $got)"; echo "$out" | sed 's/^/        /'; fi
  rm -rf "$T"
}

# An Android tree, fully wired for "Weekly": the mapper entry and the string in all six files.
android_tree() {
  local m="$T/android/app/src/main/java/com/clipulse/android/ui/common"
  mkdir -p "$m"
  printf '%s\n' 'object QuotaTierDisplay { private val LABELS = mapOf("weekly" to R.string.quota_tier_weekly) }' > "$m/QuotaTierDisplay.kt"
  for d in values values-es values-ja values-ko values-zh-rCN values-zh-rTW; do
    mkdir -p "$T/android/app/src/main/res/$d"
    printf '%s\n' '<resources><string name="quota_tier_weekly">W</string></resources>' > "$T/android/app/src/main/res/$d/strings.xml"
  done
}

echo "check_quota_tier_names negative controls"

new_tree
expect 0 "a fully wired TRANSLATE name passes"

new_tree; producer 'let a = UsageTier(name: "Weekly", usage: 1, quota: 2, remaining: 1, resetTime: nil)
let b = UsageTier(name: "Monthly", usage: 1, quota: 2, remaining: 1, resetTime: nil)'
expect 1 "a newly produced name with no manifest entry fails"

# The scanner cannot see names built through a local helper unless HELPER matches.
new_tree; producer 'func addPool(_ n: String, _ v: Int) {}
let _ = addPool("Open Source", 5)
let t = UsageTier(name: "Weekly", usage: 1, quota: 2, remaining: 1, resetTime: nil)'
expect 1 "a name built through a *Pool( helper is detected (the heuristic blind spot)"

new_tree; producer 'func windowTier(_ n: String) {}
let _ = windowTier("Rolling")
let t = UsageTier(name: "Weekly", usage: 1, quota: 2, remaining: 1, resetTime: nil)'
expect 1 "a name built through a *Tier( helper is detected"

# A path or id that happens to reach a tier-ish helper must NOT be read as a tier.
new_tree; producer 'func poolPath(_ p: String) {}
let _ = poolPath("/Users/jason/Library/Application Support/Claude")
let _ = poolPath("seven_day_omelette")
let t = UsageTier(name: "Weekly", usage: 1, quota: 2, remaining: 1, resetTime: nil)'
expect 0 "a file path and a vendor token passed to a *Pool( helper are not tier names"

new_tree; producer 'let t = UsageTier(name: "\(b.currency) Balance", usage: 1, quota: 2, remaining: 1, resetTime: nil)
let u = UsageTier(name: "Weekly", usage: 1, quota: 2, remaining: 1, resetTime: nil)'
expect 0 "an interpolated name is not treated as a closed literal"

new_tree; manifest '{"entries":[{"name":"Weekly","display":"TRANSLATE","l10n_key":"quota_tier.weekly","reason":"a generic time window this app composed, emitted by nine unrelated collectors"},{"name":"Gone","display":"PASSTHROUGH","reason":"used to be Warp product branding, before the collector was rewritten"}]}'
expect 1 "a STALE entry whose literal no producer writes fails"

new_tree; l10n 'public enum L10n { public enum quotaTier { public static func localized(_ raw: String) -> String { return raw } } }'
expect 1 "a TRANSLATE name with no L10n accessor fails"

new_tree; l10n 'public enum L10n { public enum quotaTier {
    public static var weekly: String { tr("quota_tier.weekly") }
    public static func localized(_ raw: String) -> String { return raw } } }'
expect 1 "a TRANSLATE name with an accessor but NO case in localized() fails"

new_tree; strings_for ko '"quota_tier.other" = "X";'
expect 1 "a TRANSLATE name missing from one locale fails"

new_tree; manifest '{"entries":[{"name":"Weekly","display":"TRANSLATE","l10n_key":"quota_tier.weekly","reason":"TODO"}]}'
expect 1 "a boilerplate reason fails"

new_tree; manifest '{"entries":[{"name":"Weekly","display":"TRANSLATE","l10n_key":"quota_tier.weekly","reason":"a generic time window this app composed, emitted by nine unrelated collectors"},{"name":"Weekly","display":"PASSTHROUGH","reason":"changed my mind halfway down the file, which is the bug"}]}'
expect 1 "a name classified twice fails"

new_tree; manifest '{"entries":[{"name":"Weekly","display":"PASSTHROUGH","l10n_key":"quota_tier.weekly","reason":"a passthrough entry must not carry a key, or the wiring check is skipped"}]}'
expect 1 "a PASSTHROUGH entry carrying a key fails"

new_tree; manifest '{"entries":[{"name":"Weekly","display":"MAYBE","l10n_key":"quota_tier.weekly","reason":"an unknown display mode must not be treated as passthrough by default"}]}'
expect 1 "an unrecognized display value fails"

# A comment documenting an XML attribute matched `name="quotaInfo"` and was
# reported as an unclassified tier name (real false positive, found on the tree).
new_tree; producer 'let t = UsageTier(name: "Weekly", usage: 1, quota: 2, remaining: 1, resetTime: nil)
// Pattern: <option name="quotaInfo" value="..."/>
let pattern = "<option name=\"quotaInfo\""'
expect 0 "a name= inside a // comment is not a tier name"

new_tree; producer 'let t = UsageTier(name: "Weekly", usage: 1, quota: 2, remaining: 1, resetTime: nil)
let url = "https://example.com//notacomment"'
expect 0 "a // inside a string literal does not start a comment"

# A name composed at runtime has no literal to find, so the stale-entry check
# must pin the EXPRESSION instead — and must still fail when that goes away.
new_tree; producer 'let t = UsageTier(name: "Weekly", usage: 1, quota: 2, remaining: 1, resetTime: nil)
let u = UsageTier(name: "\(b.currency) Balance", usage: 1, quota: 2, remaining: 1, resetTime: nil)'
manifest '{"entries":[{"name":"Weekly","display":"TRANSLATE","l10n_key":"quota_tier.weekly","reason":"a generic time window this app composed, emitted by nine unrelated collectors"},{"name":"CNY Balance","display":"PASSTHROUGH","reason":"a currency code, and not a closed literal: the collector interpolates the currency","composed_at_runtime":true,"composed_from":"\\(b.currency) Balance"}]}'
expect 0 "a composed_at_runtime entry passes when its expression is present"

new_tree; manifest '{"entries":[{"name":"Weekly","display":"TRANSLATE","l10n_key":"quota_tier.weekly","reason":"a generic time window this app composed, emitted by nine unrelated collectors"},{"name":"CNY Balance","display":"PASSTHROUGH","reason":"a currency code, and not a closed literal: the collector interpolates the currency","composed_at_runtime":true,"composed_from":"\\(b.currency) Balance"}]}'
expect 1 "a composed_at_runtime entry FAILS once its expression is gone"

new_tree; manifest '{"entries":[{"name":"Weekly","display":"TRANSLATE","l10n_key":"quota_tier.weekly","reason":"a generic time window this app composed, emitted by nine unrelated collectors"},{"name":"CNY Balance","display":"PASSTHROUGH","reason":"a currency code, and not a closed literal: the collector interpolates the currency","composed_at_runtime":true}]}'
expect 1 "composed_at_runtime without composed_from fails"

new_tree; android_tree
expect 0 "android: a fully wired TRANSLATE name passes"

new_tree; android_tree; printf '%s\n' '<resources></resources>' > "$T/android/app/src/main/res/values-ja/strings.xml"
expect 1 "android: a TRANSLATE name missing from one strings.xml fails"

new_tree; android_tree; printf '%s\n' 'object QuotaTierDisplay { private val LABELS = mapOf<String, Int>() }' > "$T/android/app/src/main/java/com/clipulse/android/ui/common/QuotaTierDisplay.kt"
expect 1 "android: a TRANSLATE name with no mapper entry fails"

new_tree; android_tree; rm "$T/android/app/src/main/java/com/clipulse/android/ui/common/QuotaTierDisplay.kt"
expect 1 "android: a missing mapper fails"

echo "check_quota_tier_names negative controls: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
