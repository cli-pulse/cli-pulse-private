#!/usr/bin/env bash
# Negative controls for check_collector_status_text.py.
#
# The gate's job is to fail, so each case writes one fake collector, runs the real
# gate against it, and asserts the exit code. The passing cases are the false
# alarms the first draft raised on the real tree: an HTTP `status` code, a
# subscript key, a value passed into a builder, an `if let` body.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/scripts/check_collector_status_text.py"
COLLECTORS="CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/Collectors"
pass=0; fail=0

new_tree() {
  T="$(mktemp -d)"
  mkdir -p "$T/$COLLECTORS" "$T/scripts"
  printf '{"entries": []}\n' > "$T/scripts/collector_status_text_allowlist.json"
}
collector() { printf '%s\n' "$1" > "$T/$COLLECTORS/C.swift"; }
allowlist() { printf '%s\n' "$1" > "$T/scripts/collector_status_text_allowlist.json"; }

expect() {  # expect <want-exit> <name>
  local want="$1" name="$2" out got
  out="$(python3 "$GUARD" --root "$T" 2>&1)"; got=$?
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "  ok    $name"
  else fail=$((fail+1)); echo "  FAIL  $name (want exit $want, got $got)"; echo "$out" | sed 's/^/        /'; fi
  rm -rf "$T"
}

echo "check_collector_status_text negative controls"

new_tree; collector 'let u = ProviderUsage(quota: 1,
    status_text: CollectorStatusText.join([CollectorStatusText.percentLeft(p), CollectorStatusText.remaining("\(x) USD")]),
    trend: [])'
expect 0 "a line built from builders passes, values passed into a builder included"

new_tree; collector 'let u = ProviderUsage(status_text: "\(n) widgets left", trend: [])'
expect 1 "a literal status_text argument fails"

new_tree; collector 'var status = CollectorStatusText.percentLeft(p)
if overdue { status += " · overdue invoices" }'
expect 1 "appending English to the status variable fails"

new_tree; collector 'var parts: [String] = []
parts.append("\(n) things")'
expect 1 "appending English to parts fails"

new_tree; collector 'var parts: [String] = ["\(n) requests"]'
expect 1 "English in the initial parts array fails"

new_tree; collector 'let statusText = running.isEmpty
    ? "\(n) models installed"
    : CollectorStatusText.runningInstalled(running: 1, installed: n)'
expect 1 "English in a ternary continued on the next line fails"

new_tree; collector 'let balanceText = "Balance: \(x) credits"
let u = ProviderUsage(status_text: CollectorStatusText.join([balanceText, extra]), trend: [])'
expect 1 "English built in a local and joined into the line fails"

new_tree; collector 'static func formatStatusText(name: String) -> String {
    return "Deployment: \(name)"
}'
expect 1 "English returned from a status-text function fails"

new_tree; collector 'let u = ProviderUsage(status_text: ok ? "Operational" : "\(p)% used", trend: [])
let v = ProviderUsage(status_text: String(format: "%.0f%% used", pct), trend: [])
let w = ProviderUsage(status_text: "Connected", trend: [])'
expect 0 "the sentinels localizedStatusText already translates pass"

new_tree; collector 'let status = (response as? HTTPURLResponse)?.statusCode ?? 0
guard let rawStatus = fields["grpc-status"], let code = Int(rawStatus) else { return }
if status == 401 { throw CollectorError.httpError(status: status, provider: "Acme Cloud") }
let query: [String: Any] = [kSecAttrService as String: "Acme Keychain-credentials"]
let s2 = SecItemCopyMatching(query as CFDictionary, nil)'
expect 0 "an HTTP status code, a subscript key and a keychain query are not status copy"

new_tree; collector 'static func statusText(_ r: R) -> String {
    let diem = r.diem
    return CollectorStatusText.remaining(String(format: "DIEM %.2f", diem))
}
func build() {
    if let diem = r.diem {
        tiers.append(TierDTO(name: "DIEM Balance", quota: 1, remaining: 1, reset_time: nil))
    }
}'
expect 0 "an if-let body elsewhere is not the value of a local the line uses"

new_tree; collector 'let u = ProviderUsage(status_text: "\(used) / \(t) edit predictions", trend: [])'
allowlist '{"entries": [{"path": "CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/Collectors/C.swift", "literal": "{} / {} edit predictions", "reason": "Edit Predictions is the vendor product name, shown as written"}]}'
expect 0 "an allowlisted vendor literal passes"

new_tree; collector 'let u = ProviderUsage(status_text: CollectorStatusText.unlimited, trend: [])'
allowlist '{"entries": [{"path": "CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/Collectors/C.swift", "literal": "{} / {} edit predictions", "reason": "Edit Predictions is the vendor product name, shown as written"}]}'
expect 1 "a stale allowlist entry fails"

new_tree; collector 'let u = ProviderUsage(status_text: "\(used) / \(t) edit predictions", trend: [])'
allowlist '{"entries": [{"path": "CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/Collectors/C.swift", "literal": "{} / {} edit predictions", "reason": "vendor"}]}'
expect 1 "an allowlist entry without a real reason fails"

echo "check_collector_status_text: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
