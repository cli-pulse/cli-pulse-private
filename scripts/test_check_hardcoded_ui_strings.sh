#!/usr/bin/env bash
# Negative controls for check_hardcoded_ui_strings.py.
#
# A gate that has only ever been seen green has not been seen to work. Each case
# builds a tiny fake tree, runs the real gate against it, and asserts the exit
# code — including the two blind spots found while building it: an INTERPOLATED
# literal (the first inventory regex rejected backslashes and could not see
# `Text("tokens · \(x)")`) and a phrase returned from a property whose name is
# not on the display-name list (`var badge: String { return "recent activity" }`).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/scripts/check_hardcoded_ui_strings.py"
pass=0; fail=0

new_tree() {
  T="$(mktemp -d)"
  mkdir -p "$T/CLI Pulse Bar/CLI Pulse Bar iOS" "$T/CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore" "$T/scripts"
  echo '{"entries": []}' > "$T/scripts/hardcoded_ui_strings_baseline.json"
}
view() { printf '%s\n' "$1" > "$T/CLI Pulse Bar/CLI Pulse Bar iOS/V.swift"; }
core() { printf '%s\n' "$1" > "$T/CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/C.swift"; }
baseline() { printf '%s\n' "$1" > "$T/scripts/hardcoded_ui_strings_baseline.json"; }

expect() {  # expect <want-exit> <name>
  local want="$1" name="$2" out got
  out="$(python3 "$GUARD" --root "$T" 2>&1)"; got=$?
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "  ok    $name"
  else fail=$((fail+1)); echo "  FAIL  $name (want exit $want, got $got)"; echo "$out" | sed 's/^/        /'; fi
  rm -rf "$T"
}

echo "check_hardcoded_ui_strings negative controls"

new_tree; view 'struct V: View { var body: some View { Text(L10n.sessions.title) } }'
expect 0 "copy routed through L10n passes"

new_tree; view 'struct V: View { var body: some View { Text("Active") } }'
expect 1 "a new hardcoded Text literal fails"

new_tree; view 'struct V: View { var body: some View { Text("tokens · \(scope)") } }'
expect 1 "an INTERPOLATED hardcoded literal fails (the regex blind spot)"

new_tree; view 'struct V: View { var body: some View { VStack { Section(header: Text("x")) {}; Text("").help("Open Settings to fix") } } }'
expect 1 ".help tooltip copy fails"

new_tree; view 'struct V: View { var body: some View { Group { Header(title: "Recent · last 30 min") } } }'
expect 1 "a title: argument literal fails"

# `freshness` is deliberately NOT on the display-name list. An earlier version of this case used
# `var badge`, which is on the list — so it passed with the phrase signal deleted and tested nothing.
new_tree; core 'enum T { var freshness: String { switch self { case .a: return "recent activity" } } }'
expect 1 "a phrase returned from an unlisted String property fails (the name-list blind spot)"

new_tree; core 'enum T { var badge: String { switch self { case .a: return "running" } } }'
expect 1 "the property that started it (var badge) is on the name list"

new_tree; core 'enum T { var label: String { switch self { case .a: return "running" } } }'
expect 1 "a single word returned from a display-named property fails"

new_tree; core 'enum T { var iconName: String { return "cpu" } ; var key: String { "claude" } }'
expect 0 "identifier-like returns from non-display properties pass"

new_tree; view 'struct V: View { var body: some View { Text("42") ; Text("·") ; Text("\(count)") } }'
expect 0 "literals with no English words pass"

# A literal inside an interpolation must not end the outer literal. The regex version cut
# `"\(L10n.settings.version) \(info["CFBundleShortVersionString"] ?? "")"` at the inner quote.
new_tree; view 'struct V: View { var body: some View { Text("\(L10n.settings.version) \(info["CFBundleShortVersionString"] as? String ?? "")") } }'
expect 0 "a nested-quote interpolation with no English passes"

new_tree; view 'struct V: View { var body: some View { Text("Build \(info["CFBundleVersion"] ?? "")") } }'
expect 1 "English outside a nested-quote interpolation still fails"

new_tree; view 'struct V: View { var body: some View { Text("x") } } // Text("Commented out copy")'
expect 0 "copy inside a // comment passes"

new_tree; view 'struct V: View { var body: some View { Text("CLI Pulse") } }'
baseline '{"entries": [{"path": "CLI Pulse Bar/CLI Pulse Bar iOS/V.swift", "literal": "\"CLI Pulse\"", "count": 1, "reason": "product name"}]}'
expect 0 "a baselined literal with a reason passes"

new_tree; view 'struct V: View { var body: some View { Text("CLI Pulse") } }'
baseline '{"entries": [{"path": "CLI Pulse Bar/CLI Pulse Bar iOS/V.swift", "literal": "\"CLI Pulse\"", "count": 1, "reason": "TODO"}]}'
expect 1 "a baseline entry without a real reason fails"

new_tree; view 'struct V: View { var body: some View { VStack { Text("CLI Pulse"); Text("CLI Pulse") } } }'
baseline '{"entries": [{"path": "CLI Pulse Bar/CLI Pulse Bar iOS/V.swift", "literal": "\"CLI Pulse\"", "count": 1, "reason": "product name"}]}'
expect 1 "a second occurrence beyond the baselined count fails"

new_tree; view 'struct V: View { var body: some View { Text(L10n.x.y) } }'
baseline '{"entries": [{"path": "CLI Pulse Bar/CLI Pulse Bar iOS/V.swift", "literal": "\"Gone\"", "count": 1, "reason": "was here once"}]}'
expect 1 "a STALE baseline entry fails, so the allowlist can only shrink"

echo "check_hardcoded_ui_strings negative controls: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
