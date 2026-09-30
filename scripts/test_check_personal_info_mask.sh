#!/usr/bin/env bash
# Negative controls for check_personal_info_mask.py.
#
# The gate's job is to fail, so each case builds a small fake app tree (one Mac
# view plus the iPhone's and the Watch's session managers wired the way the real
# ones are), breaks one thing, runs the real gate against it and asserts the
# exit code. The passing cases are the reads that are not reads: comments,
# string text, the catalogue's own "Account label" title, and writes.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="$ROOT/scripts/check_personal_info_mask.py"
MAC="CLI Pulse Bar/CLI Pulse Bar"
IOS="CLI Pulse Bar/CLI Pulse Bar iOS"
WATCH="CLI Pulse Bar/CLI Pulse Bar Watch"
WIDGETS="CLI Pulse Bar/CLI Pulse Widgets"
pass=0; fail=0

PHONE_OK='final class PhoneSessionManager {
    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(handle(_:)),
                                                name: .hidePersonalInfoDidChange, object: nil)
    }
    func sendDashboardToWatch(userID: String, devices: [DeviceRecord] = [], hidePersonalInfo: Bool) {
        var context: [String: Any] = [:]
        PersonalInfoMask.addPhoneChoice(hidePersonalInfo, to: &context)
        if ready {
            try? WCSession.default.updateApplicationContext(context)
        } else {
            pendingContext = context
        }
    }
}'

WATCH_OK='final class WatchSessionManager {
    func processContext(_ context: [String: Any]) {
        let hidePersonalInfo = PersonalInfoMask.phoneChoice(inWatchContext: context)
        DispatchQueue.main.async {
            guard self.accept(identity) else { return }
            CurrencyConverter.shared.adoptAndRemember(currencyCode: code, rate: rate)
            PersonalInfoMask.adoptPhoneChoice(hidePersonalInfo)
        }
    }
}'

new_tree() {
  T="$(mktemp -d)"
  mkdir -p "$T/$MAC" "$T/$IOS" "$T/$WATCH" "$T/$WIDGETS" "$T/scripts"
  printf '{"entries": []}\n' > "$T/scripts/personal_info_mask_allowlist.json"
  printf '%s\n' "$PHONE_OK" > "$T/$IOS/PhoneSessionManager.swift"
  printf '%s\n' "$WATCH_OK" > "$T/$WATCH/WatchSessionManager.swift"
}
view()      { printf '%s\n' "$1" > "$T/$MAC/V.swift"; }
view_in()   { printf '%s\n' "$2" > "$T/$1/V.swift"; }
phone()     { printf '%s\n' "$1" > "$T/$IOS/PhoneSessionManager.swift"; }
watch_mgr() { printf '%s\n' "$1" > "$T/$WATCH/WatchSessionManager.swift"; }
allowlist() { printf '%s\n' "$1" > "$T/scripts/personal_info_mask_allowlist.json"; }

expect() {  # expect <want-exit> <name>
  local want="$1" name="$2" out got
  out="$(python3 "$GUARD" --root "$T" 2>&1)"; got=$?
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "  ok    $name"
  else fail=$((fail+1)); echo "  FAIL  $name (want exit $want, got $got)"; echo "$out" | sed 's/^/        /'; fi
  rm -rf "$T"
}

echo "check_personal_info_mask negative controls"

MASKED='struct V: View {
    @AppStorage(PersonalInfoMask.defaultsKey) private var hidePersonalInfo = false
    var body: some View {
        Text(
            PersonalInfoMask.accountName(
                label: [
                    usages.first { $0.id == id }?.accountLabel,
                    configs.first { $0.accountID == id }?.accountLabel,
                ].compactMap { $0 }.first,
                index: configs.firstIndex { $0.accountID == id },
                accountCount: configs.count,
                hidePersonalInfo: hidePersonalInfo
            )
        )
        if let line = PersonalInfoMask.accountLabel(detail.accountEmail, index: 0, hidePersonalInfo: hidePersonalInfo) {
            Label(line, systemImage: "envelope")
        }
    }
}'

new_tree; view "$MASKED"
expect 0 "labels read inside accountName/accountLabel, closures and arrays included, pass"

new_tree; view 'struct V: View {
    var body: some View {
        if let email = detail.accountEmail {
            Label(email, systemImage: "envelope")
        }
    }
}'
expect 1 "the Mac card back to Label(detail.accountEmail) fails"

new_tree; view 'let t = Text(account.accountLabel ?? L10n.providers.defaultAccount)'
expect 1 "a label shown with Text fails"

new_tree; view_in "$IOS" 'let t = Text(account.accountLabel ?? "")'
expect 1 "the iPhone target is scanned"

new_tree; view_in "$WATCH" 'let t = Text(account.accountLabel ?? "")'
expect 1 "the Watch target is scanned"

new_tree; view_in "$WIDGETS" 'let t = Text(account.accountLabel ?? "")'
expect 1 "the widgets are scanned"

new_tree; view 'let label = config.accountLabel
let name = PersonalInfoMask.accountName(label: label, index: 0, accountCount: 1, hidePersonalInfo: hide)'
expect 1 "a label read into a local and masked a line later fails (read it inside the call)"

new_tree; view 'let isAddress = PersonalInfoMask.looksLikeEmail(config.accountLabel ?? "")'
expect 1 "a read inside a PersonalInfoMask call that does not mask fails"

new_tree; view 'let a = Text("\(config.provider), \(config.accountLabel ?? "")")'
expect 1 "a label inside a string interpolation fails"

new_tree; view 'let names = configs.map(\.accountLabel)'
expect 1 "a key path to the label fails"

new_tree; view '// config.accountLabel used to be shown here
/* Text(detail.accountEmail) */
let hint = "set .accountLabel in the editor"
let doc = """
    detail.accountEmail is masked
    """
let title = Text(L10n.providerConfig.accountLabel)
state.providerConfigs[idx].accountLabel = accountLabel.isEmpty ? nil : accountLabel'
expect 0 "comments, string text, the catalogue title and a write are not reads"

new_tree; view 'let t = Text(config.accountLabel == nil ? "a" : "b")'
expect 1 "a comparison is a read (== is not a write)"

new_tree; view 'accountLabel = config.accountLabel ?? ""'
allowlist '{"entries": [{"path": "CLI Pulse Bar/CLI Pulse Bar/V.swift", "line": "accountLabel = config.accountLabel ?? \"\"", "reason": "The editor, where the owner types the label, shows it as written."}]}'
expect 0 "an allowlisted read with a reason passes"

new_tree; view 'let x = 1'
allowlist '{"entries": [{"path": "CLI Pulse Bar/CLI Pulse Bar/V.swift", "line": "accountLabel = config.accountLabel ?? \"\"", "reason": "The editor, where the owner types the label, shows it as written."}]}'
expect 1 "a stale allowlist entry fails"

new_tree; view 'accountLabel = config.accountLabel ?? ""'
allowlist '{"entries": [{"path": "CLI Pulse Bar/CLI Pulse Bar/V.swift", "line": "accountLabel = config.accountLabel ?? \"\"", "reason": "editor"}]}'
expect 1 "an allowlist entry without a real reason fails"

new_tree; view "${MASKED/hidePersonalInfo: hidePersonalInfo$'\n'/hidePersonalInfo: false$'\n'}"
expect 1 "passing hidePersonalInfo: false to the mask fails"

new_tree; view 'func f() { sendDashboardToWatch(userID: id, hidePersonalInfo: true) }'
expect 1 "passing a literal switch anywhere fails"

new_tree; view "${MASKED/@AppStorage(PersonalInfoMask.defaultsKey) private var/@State private var}"
expect 1 "a switch kept in @State instead of the defaults fails"

new_tree; view "${MASKED/@AppStorage(PersonalInfoMask.defaultsKey)/@AppStorage(\"cli_pulse_hide_personal_info\")}"
expect 1 "a switch read under a spelled-out key fails (use PersonalInfoMask.defaultsKey)"

new_tree; view "${MASKED/@AppStorage(PersonalInfoMask.defaultsKey) private var/@AppStorage(PersonalInfoMask.defaultsKey)
    private var}"
expect 0 "the @AppStorage attribute on the line above passes"

new_tree; phone "${PHONE_OK/PersonalInfoMask.addPhoneChoice(hidePersonalInfo, to: &context)/}"
expect 1 "the iPhone not adding its choice to the context fails"

new_tree; phone "${PHONE_OK/addPhoneChoice(hidePersonalInfo/addPhoneChoice(false}"
expect 1 "the iPhone sending a literal choice fails"

new_tree; phone 'final class PhoneSessionManager {
    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(handle(_:)),
                                                name: .hidePersonalInfoDidChange, object: nil)
    }
    func sendDashboardToWatch(userID: String, hidePersonalInfo: Bool) {
        var context: [String: Any] = [:]
        try? WCSession.default.updateApplicationContext(context)
        PersonalInfoMask.addPhoneChoice(hidePersonalInfo, to: &context)
    }
}'
expect 1 "the iPhone adding its choice after the context is sent fails"

new_tree; phone "${PHONE_OK/name: .hidePersonalInfoDidChange/name: .displayCurrencyDidChange}"
expect 1 "the iPhone not observing the switch fails"

new_tree; rm "$T/$IOS/PhoneSessionManager.swift"
expect 1 "a missing PhoneSessionManager fails"

new_tree; watch_mgr "${WATCH_OK/PersonalInfoMask.adoptPhoneChoice(hidePersonalInfo)/}"
expect 1 "the Watch not adopting the iPhone's choice fails"

new_tree; watch_mgr "${WATCH_OK/PersonalInfoMask.phoneChoice(inWatchContext: context)/context[\"hide\"] as? Bool}"
expect 1 "the Watch not reading the choice through PersonalInfoMask fails"

new_tree; watch_mgr 'final class WatchSessionManager {
    func processContext(_ context: [String: Any]) {
        let hidePersonalInfo = PersonalInfoMask.phoneChoice(inWatchContext: context)
        PersonalInfoMask.adoptPhoneChoice(hidePersonalInfo)
        DispatchQueue.main.async {
            guard self.accept(identity) else { return }
        }
    }
}'
expect 1 "the Watch adopting before the owner and epoch are accepted fails"

new_tree; watch_mgr 'final class WatchSessionManager {
    func processContext(_ context: [String: Any]) {
        let hidePersonalInfo = PersonalInfoMask.phoneChoice(inWatchContext: context)
        DispatchQueue.main.async {
            guard self.accept(identity) else { return }
        }
        PersonalInfoMask.adoptPhoneChoice(hidePersonalInfo)
    }
}'
expect 1 "a guard inside an earlier closure does not cover a later adopt"

new_tree; watch_mgr 'final class WatchSessionManager {
    func processContext(_ context: [String: Any]) {
        let hidePersonalInfo = PersonalInfoMask.phoneChoice(inWatchContext: context)
        DispatchQueue.main.async {
            guard self.accept(identity) else { return }
            if let changed {
                PersonalInfoMask.adoptPhoneChoice(hidePersonalInfo)
            }
        }
    }
}'
expect 0 "an adopt nested inside the accepted block passes"

echo "check_personal_info_mask: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
