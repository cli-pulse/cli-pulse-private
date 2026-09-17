#!/usr/bin/env bash
# Negative controls for check_hardcoded_ui_strings.py.
#
# A gate that has only ever been seen green has not been seen to work. Each case
# builds a tiny fake tree, runs the real gate against it, and asserts the exit
# code — including the two blind spots found while building it: an INTERPOLATED
# literal (the first inventory regex rejected backslashes and could not see
# `Text("tokens · \(x)")`) and a phrase returned from a property whose name is
# not on the display-name list (`var badge: String { return "recent activity" }`).
#
# The cases after "Shapes the first version could not see" each plant one shape
# the first scanner passed, and assert the gate names THAT literal as NEW — so a
# case cannot pass because some other literal in the fixture tripped the gate.
# Point HARDCODED_UI_GUARD at an older copy of the script to watch them fail there.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="${HARDCODED_UI_GUARD:-$ROOT/scripts/check_hardcoded_ui_strings.py}"
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

# expect_new <name> <literal>... — exit 1, and every listed literal (without quotes) reported as NEW.
expect_new() {
  local name="$1" out got missing=""; shift
  out="$(python3 "$GUARD" --root "$T" 2>&1)"; got=$?
  for lit in "$@"; do
    printf '%s\n' "$out" | grep -F "NEW" | grep -qF "\"$lit\"" || missing="$missing [$lit]"
  done
  if [ "$got" = 1 ] && [ -z "$missing" ]; then pass=$((pass+1)); echo "  ok    $name"
  else fail=$((fail+1)); echo "  FAIL  $name (exit $got; not reported NEW:${missing:- none})"; echo "$out" | sed 's/^/        /'; fi
  rm -rf "$T"
}

# expect_output <want-exit> <name> <text> — the exit code, and the output names the reason.
expect_output() {
  local want="$1" name="$2" text="$3" out got
  out="$(python3 "$GUARD" --root "$T" 2>&1)"; got=$?
  if [ "$got" = "$want" ] && printf '%s\n' "$out" | grep -qF -- "$text"; then pass=$((pass+1)); echo "  ok    $name"
  else fail=$((fail+1)); echo "  FAIL  $name (want exit $want with \"$text\", got $got)"; echo "$out" | sed 's/^/        /'; fi
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
baseline '{"entries": [{"path": "CLI Pulse Bar/CLI Pulse Bar iOS/V.swift", "literal": "\"CLI Pulse\"", "count": 1, "reason": "KEEP_PROPER_NOUN: the product name, the same in every language"}]}'
expect 0 "a baselined literal with a reason passes"

new_tree; view 'struct V: View { var body: some View { Text("CLI Pulse") } }'
baseline '{"entries": [{"path": "CLI Pulse Bar/CLI Pulse Bar iOS/V.swift", "literal": "\"CLI Pulse\"", "count": 1, "reason": "TODO"}]}'
expect_output 1 "a baseline entry without a real reason fails" "placeholder reason (TODO)"

new_tree; view 'struct V: View { var body: some View { VStack { Text("CLI Pulse"); Text("CLI Pulse") } } }'
baseline '{"entries": [{"path": "CLI Pulse Bar/CLI Pulse Bar iOS/V.swift", "literal": "\"CLI Pulse\"", "count": 1, "reason": "KEEP_PROPER_NOUN: the product name, the same in every language"}]}'
expect_output 1 "a second occurrence beyond the baselined count fails" "(+1 beyond baseline)"

new_tree; view 'struct V: View { var body: some View { Text(L10n.x.y) } }'
baseline '{"entries": [{"path": "CLI Pulse Bar/CLI Pulse Bar iOS/V.swift", "literal": "\"Gone\"", "count": 1, "reason": "KEEP_NOT_USER_VISIBLE: was here once, and is gone now"}]}'
expect_output 1 "a STALE baseline entry fails, so the allowlist can only shrink" "STALE"

# A `case` line's `let` is a PATTERN BINDING, not a declaration. Treating it as
# one reset the tracker, so the enclosing `var errorDescription: String?` was
# forgotten and every error enum's body went unscanned. That is how two of
# GeminiOAuthError's eleven cases stayed English while the other nine were
# localized, with this gate green.
new_tree; core 'enum E: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .bad(let url): return "Invalid URL: \(url)"
        }
    }
}'
expect 1 "copy returned from an errorDescription case with a pattern binding fails"

# The same fix must NOT start flagging protocol tokens returned from a
# non-display-named property — `let reason` used to hijack the tracker (because
# "reason" is on the display-name list) and made three of these false positives.
new_tree; core 'enum E {
    var telemetryToken: String {
        switch self {
        case .notReady(let reason): return "not_ready_\(reason.rawValue)"
        case .producedData: return "ok"
        }
    }
}'
expect 0 "telemetry tokens returned from a non-display property still pass"

# `.serverMessage` passes server text through untranslated. A LITERAL there is an
# English message that has escaped the typed credential catalogue.
new_tree; core 'func f() throws { throw CollectorError.missingCredentials(CredentialProblem("X", .serverMessage("Please sign in again"))) }'
expect 1 "an English literal passed to .serverMessage fails"

new_tree; core 'func f(message: String) throws { throw CollectorError.missingCredentials(CredentialProblem("X", .serverMessage(message))) }'
expect 0 "server-supplied text passed to .serverMessage passes"

# ── Shapes the first version could not see ──────────────────────────────────
# Each passed the first scanner with the gate green (2026-09-17 audit). Single
# words are used where a phrase would have been caught by the phrase signal
# alone, so the case proves the new mechanism rather than the old one.

new_tree; view 'struct V: View { var body: some View { Text(isOn ? "Enabled" : "Disabled") } }'
expect_new "a ternary inside Text( fails, both branches" "Enabled" "Disabled"

new_tree; view 'struct V: View { var body: some View { Text(name ?? "Unknown") } }'
expect_new "a ?? fallback inside Text( fails" "Unknown"

new_tree; view 'struct V: View {
    var body: some View {
        Label(
            "Synthetic",
            systemImage: "gear"
        )
    }
}'
expect_new "a literal on the line after Label( fails" "Synthetic"

# SessionsTab.swift:566-569 had exactly this shape.
new_tree; view 'struct V: View {
    var body: some View {
        Text(isShared
             ? "Syncing"
             : "Off")
    }
}'
expect_new "a ternary spread over three lines fails" "Syncing" "Off"

new_tree; core 'func f() { let alert = NSAlert(); alert.messageText = "Failed"; content.body = "Quota"; panel.prompt = "Choose" }'
expect_new "assignments to messageText, .body and .prompt fail" "Failed" "Quota" "Choose"

new_tree; core 'enum T { var subtitle: String { "Pairing" } }'
expect_new "an implicit return from a display-named property fails" "Pairing"

new_tree; core 'enum E: LocalizedError {
    case a, b
    var errorDescription: String? {
        switch self {
        case .a: "Waiting"
        case .b:
            "Declined"
        }
    }
}'
expect_new "implicit-return case arms in errorDescription fail, same line and next line" "Waiting" "Declined"

# UsageHeatmap.swift:75-79: `guard !isFuture, let day = …` replaced `tooltip` as the
# context, and its "tokens" tooltip shipped in English.
new_tree; core 'enum H {
    static func tooltip(key: String) -> String {
        guard let day = archive[key] else { return "" }
        return "\(key): \(day.n) tokens"
    }
}'
expect_new "a return after guard let in a display function fails" '\(key): \(day.n) tokens'

new_tree; core 'enum H {
    static func statusText(p: Int?) -> String {
        if let p { return "\(p) left" }
        while let next = queue.pop() { _ = next }
        return "unavailable"
    }
}'
expect_new "returns after if let and while let in a display function fail" '\(p) left' "unavailable"

# GeminiStatusProbe.formatResetTime-style: plain local lets before the return.
new_tree; core 'enum H {
    static func resetHint(date: Date) -> String {
        let now = Date()
        let hours = Int(date.timeIntervalSince(now) / 3600)
        return "in \(hours)h"
    }
}'
expect_new "a return after plain local lets in a display function fails" 'in \(hours)h'

new_tree; view 'struct V: View {
    var body: some View {
        let label = "Local session"
        Text(label)
    }
}'
expect_new "a local let handed to Text( fails" "Local session"

new_tree; view 'struct V: View { var body: some View { ForEach(["Critical", "Warning"], id: \.self) { Text($0) } } }'
expect_new "an array literal iterated by ForEach fails" "Critical" "Warning"

new_tree; view 'struct V: View {
    var body: some View {
        let severities = ["Critical", "Info"]
        ForEach(severities, id: \.self) { chip($0) }
    }
}'
expect_new "a local array iterated by ForEach fails" "Critical" "Info"

new_tree; view 'struct V: View { var body: some View { Text("最近活动") ; Text("한국어") } }'
expect_new "non-Latin copy fails (Chinese, Korean)" "最近活动" "한국어"

new_tree; view 'struct V: View {
    var body: some View {
        VStack {
            ProgressView("Loading")
            LabeledContent("Account", value: name)
            Text(verbatim: "Verbatim")
            Stepper("Threshold", value: $n)
            DisclosureGroup("Advanced") { EmptyView() }
            Text(n).badge("New").accessibilityValue("Half")
        }
    }
}'
expect_new "ProgressView, LabeledContent, Text(verbatim:), Stepper, DisclosureGroup, .badge, .accessibilityValue fail" \
  "Loading" "Account" "Verbatim" "Threshold" "Advanced" "New" "Half"

new_tree; view 'struct W: Widget { var body: some WidgetConfiguration { StaticConfiguration(kind: k) { _ in V() }.configurationDisplayName("Usage").description("Shows usage") } }'
expect_new "a widget configurationDisplayName and description fail" "Usage" "Shows usage"

new_tree; view 'struct V: View { var body: some View { diagnosticRow(label: "Socket", value: x) ; copyButton(text: "Copied") } }'
expect_new "label: and text: arguments of a view-building call fail" "Socket" "Copied"

new_tree; core 'final class Q { let queue = DispatchQueue(label: "com.example.queue"); func f() { parse(label: "Weekly", html: h) } }'
expect 0 "label: of a queue or a parser passes"

new_tree; core 'enum T { static func summary(_ n: Int) -> String { return String(format: "%d running", n) } }'
expect_new "a String(format:) returned from a display function fails" "%d running"

# 59 allowlist entries were SF Symbol names, bundle ids and hosts that the phrase signal
# read as prose because it accepted a bare "." as a word separator.
new_tree; core 'enum T { var symbol: String { "exclamationmark.triangle.fill" } ; var host: String { return "status.claude.com" } }'
expect 0 "SF Symbol names and hosts returned from String properties pass"

new_tree; core 'enum T { var freshness: String { "recent activity" } }'
expect_new "a phrase implicitly returned from an unlisted String property fails" "recent activity"

# App Intents metadata is localized from the app bundle's own tables, keyed by the literal.
intent='struct I: AppIntent { static var title: LocalizedStringResource = "Refresh Widget"; @Parameter(title: "Provider") var p: String }'
tables() {  # tables <locales...> — give those iOS app-bundle tables both keys
  for loc in "$@"; do
    mkdir -p "$T/CLI Pulse Bar/CLI Pulse Bar iOS/$loc.lproj"
    printf '"Refresh Widget" = "x";\n"Provider" = "y";\n' > "$T/CLI Pulse Bar/CLI Pulse Bar iOS/$loc.lproj/Localizable.strings"
  done
}
new_tree; view "$intent"
expect_new "App Intents metadata with no app-bundle table fails" "Refresh Widget" "Provider"

new_tree; view "$intent"; tables en es ja ko zh-Hans zh-Hant
expect 0 "App Intents metadata keyed in all six app-bundle tables passes"

new_tree; view "$intent"; tables en es ja ko zh-Hans
expect_new "App Intents metadata missing from one locale's table fails" "Refresh Widget" "Provider"

# A literal the owner decided stays English still passes in the new shapes.
new_tree; view 'struct V: View { var body: some View { Label(codexOffPlan ? L10n.sessions.offPlan : "Codex", systemImage: "gear") } }'
baseline '{"entries": [{"path": "CLI Pulse Bar/CLI Pulse Bar iOS/V.swift", "literal": "\"Codex\"", "count": 1, "reason": "KEEP_PROPER_NOUN: provider product name in the New Local menu"}]}'
expect 0 "a known-English literal allowlisted with a reason still passes in a ternary"

# ── The allowlist's reasons ─────────────────────────────────────────────────
# 17 entries said NEEDS_JUDGMENT ("real user-visible English deferred") and the
# gate accepted them indefinitely.
new_tree; view 'struct V: View { var body: some View { Text("CLI Pulse") } }'
baseline '{"entries": [{"path": "CLI Pulse Bar/CLI Pulse Bar iOS/V.swift", "literal": "\"CLI Pulse\"", "count": 1, "reason": "NEEDS_JUDGMENT: dual-use description, decide later"}]}'
expect_output 1 "a NEEDS_JUDGMENT reason fails" "placeholder reason (NEEDS_JUDGMENT)"

new_tree; view 'struct V: View { var body: some View { Text("CLI Pulse") } }'
baseline '{"entries": [{"path": "CLI Pulse Bar/CLI Pulse Bar iOS/V.swift", "literal": "\"CLI Pulse\"", "count": 1, "reason": "debug description mirroring the enum case name"}]}'
expect_output 1 "a reason without a category fails" "does not start with a category"

new_tree; view 'struct V: View { var body: some View { Text("CLI Pulse") } }'
baseline '{"entries": [{"path": "CLI Pulse Bar/CLI Pulse Bar iOS/V.swift", "literal": "\"CLI Pulse\"", "count": 1, "reason": "KEEP_PROPER_NOUN: brand"}]}'
expect_output 1 "a category with no evidence fails" "too short"

# ── Android / Kotlin ────────────────────────────────────────────────────────
# The Kotlin scanner has its own tokenizer and sinks. Compose puts arguments on
# the NEXT line, the app defines its own composables, and a `when` often computes
# the value a sink renders — each of those was a miss in the first version.
kt() { mkdir -p "$T/android/app/src/main/java/app"; printf '%s\n' "$1" > "$T/android/app/src/main/java/app/V.kt"; }

new_tree; kt '@Composable fun S() { Text(stringResource(R.string.overview)) }'
expect 0 "kotlin: copy from a string resource passes"

new_tree; kt '@Composable fun S() { Text("Active") }'
expect 1 "kotlin: a hardcoded Text literal fails"

new_tree; kt '@Composable fun S(h: Int) { Text("Resets in ${h}h") }'
expect 1 "kotlin: a literal with a \${} template fails"

new_tree; kt '@Composable fun S() {
    Text(
        "Resets soon",
        style = MaterialTheme.typography.bodySmall,
    )
}'
expect 1 "kotlin: a literal on the line after Text( fails"

new_tree; kt '@Composable fun SettingRow(label: String) {}
@Composable fun S() { SettingRow("Usage Spike (tokens)") }'
expect 1 "kotlin: a literal passed to one of the app composables fails"

new_tree; kt '@Composable fun S(n: Int) {
    MetricCard(
        subtitle = when {
            n > 0 -> "${n} critical"
            else -> null
        },
    )
}'
expect 1 "kotlin: a when branch whose value feeds a sink fails"

# A single word, so only the enclosing function name can flag it: a multi-word
# phrase would be caught by the phrase signal whatever the tracker remembered.
new_tree; kt 'fun formatResetTime(iso: String?): String? {
    val hours = 3
    return when {
        hours < 0 -> "Resetting"
        else -> null
    }
}'
expect 1 "kotlin: a local val does not hide the enclosing format* function"

new_tree; kt '@Composable fun S(t: String?, p: Int) {
    Text(
        t ?: "${p}% left",
    )
}'
expect 1 "kotlin: an elvis fallback on its own line inherits the sink"

new_tree; kt 'class VM { fun f() { state = state.copy(error = "Failed to load") } }'
expect 1 "kotlin: an English UI-state error fails"

new_tree; kt '@Composable fun S() { Text("最近活动") }'
expect_new "kotlin: non-Latin copy fails" "最近活动"

new_tree; kt '@Composable fun S() { Icon(Icons.Filled.Close, contentDescription = "Close") }'
expect 1 "kotlin: a contentDescription literal fails"

new_tree; kt 'object P { private const val CHANNEL_NAME = "Alerts" }'
expect 1 "kotlin: a one-word notification channel name constant fails"

new_tree; kt 'object C {
    private const val TAG = "SyncWorker"
    const val MONTHLY = "com.clipulse.pro.monthly"
    val baseUrl: String = "https://api.example.com"
    fun f(t: String) { Log.w(TAG, "Failed to load"); header("Authorization", "Bearer $t") }
}'
expect 0 "kotlin: log text, headers, ids and hosts pass"

# A char literal holding a double quote must not open a string.
new_tree; kt "@Composable fun S() {
    // Text(\"Commented out\")
    /* Text(\"Block comment\") */
    val quote = '\"'
    Text(quote)
}"
expect 0 "kotlin: comments and a quote char literal pass"

new_tree; kt "@Composable fun S() { val q = '\"'; Text(\"Active\") }"
expect 1 "kotlin: copy after a quote char literal on the same line is still seen"

new_tree; kt '@Composable fun S() { Text("CLI Pulse") }'
baseline '{"entries": [{"path": "android/app/src/main/java/app/V.kt", "literal": "\"CLI Pulse\"", "count": 1, "reason": "KEEP_PROPER_NOUN: the product name, the same in every language"}]}'
expect 0 "kotlin: a baselined literal with a reason passes"

new_tree; kt '@Composable fun S() { Text(stringResource(R.string.brand)) }'
baseline '{"entries": [{"path": "android/app/src/main/java/app/V.kt", "literal": "\"CLI Pulse\"", "count": 1, "reason": "KEEP_PROPER_NOUN: the product name, the same in every language"}]}'
expect_output 1 "kotlin: a stale baseline entry fails" "STALE"

echo "check_hardcoded_ui_strings negative controls: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
