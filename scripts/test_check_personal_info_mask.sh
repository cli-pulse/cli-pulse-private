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
CORE="CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore"
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

NOTIFY_OK='final class DataRefreshManager {
    func sendNotification(for alert: AlertRecord) {
        let content = UNMutableNotificationContent()
        content.title = AlertPresentation.notificationTitle(for: alert)
        content.body = PersonalInfoMask.alertText(
            alert, numbers: .none, hidePersonalInfo: PersonalInfoMask.isOn()
        ).title
    }
}'

new_tree() {
  T="$(mktemp -d)"
  mkdir -p "$T/$MAC" "$T/$IOS" "$T/$WATCH" "$T/$WIDGETS" "$T/$CORE" "$T/scripts"
  printf '{"entries": []}\n' > "$T/scripts/personal_info_mask_allowlist.json"
  printf '%s\n' "$PHONE_OK" > "$T/$IOS/PhoneSessionManager.swift"
  printf '%s\n' "$WATCH_OK" > "$T/$WATCH/WatchSessionManager.swift"
  printf '%s\n' "$NOTIFY_OK" > "$T/$CORE/DataRefreshManager.swift"
}
view()      { printf '%s\n' "$1" > "$T/$MAC/V.swift"; }
view_in()   { printf '%s\n' "$2" > "$T/$1/V.swift"; }
phone()     { printf '%s\n' "$1" > "$T/$IOS/PhoneSessionManager.swift"; }
watch_mgr() { printf '%s\n' "$1" > "$T/$WATCH/WatchSessionManager.swift"; }
notifier()  { printf '%s\n' "$1" > "$T/$CORE/DataRefreshManager.swift"; }
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

# v1.58 (P1-6): projects, session names, alerts, exports and the banner.

SHOWN='struct V: View {
    @AppStorage(PersonalInfoMask.defaultsKey) private var hidePersonalInfo = false
    let numbers: ProjectNameNumbers
    var body: some View {
        Text(PersonalInfoMask.sessionTitle(session, numbers: numbers, hidePersonalInfo: hidePersonalInfo))
        if let project = PersonalInfoMask.sessionProject(session, numbers: numbers, hidePersonalInfo: hidePersonalInfo) {
            Label(project, systemImage: "folder")
        }
        Text(PersonalInfoMask.sessionDetailProject(session, numbers: numbers, hidePersonalInfo: hidePersonalInfo))
        let shown = PersonalInfoMask.alertText(alert, numbers: numbers, hidePersonalInfo: hidePersonalInfo)
        Text(shown.title)
        if let project = PersonalInfoMask.alertProject(alert, numbers: numbers, hidePersonalInfo: hidePersonalInfo) {
            chipView(icon: "folder", text: project)
        }
        if let session = PersonalInfoMask.alertSessionName(alert, hidePersonalInfo: hidePersonalInfo) {
            chipView(icon: "terminal", text: session)
        }
        Text(PersonalInfoMask.projectName(alert.related_project_name, numbers: numbers, hidePersonalInfo: hidePersonalInfo) ?? "")
        Text(PersonalInfoMask.projectName(proj.name, numbers: .none, hidePersonalInfo: hidePersonalInfo) ?? "")
        Text(L10n.detail.project)
        Button(L10n.dashboard.exportSessions) {
            _ = ExportService.exportSessionsCSV(
                sessions: sessions, hidePersonalInfo: hidePersonalInfo, projectNumbers: numbers)
        }
    }
}'

new_tree; view "$SHOWN"
expect 0 "sessions, alerts and projects shown through the mask, an export told the switch, pass"

new_tree; view 'let t = Text(session.displayProject ?? "")'
expect 1 "a session row back on Text(session.displayProject) fails"

new_tree; view 'let t = Label(session.project, systemImage: "folder")'
expect 1 "the stored project of a session shown with Label fails"

new_tree; view 'let t = Text(session.detailProject)'
expect 1 "a detail back on session.detailProject fails"

new_tree; view_in "$WATCH" 'let t = Text(session.displayProject ?? title)'
expect 1 "a Watch card back on session.displayProject fails"

new_tree; view 'if let project = alert.related_project_name { chipView(icon: "folder", text: project) }'
expect 1 "the project chip of an alert back on related_project_name fails"

new_tree; view_in "$IOS" 'if let session = alert.related_session_name { chipView(icon: "terminal", text: session) }'
expect 1 "the session chip of an alert back on related_session_name fails, even on iPhone"

new_tree; view 'let p = PersonalInfoMask.projectName(alert.related_session_name, numbers: n, hidePersonalInfo: hidePersonalInfo)'
expect 1 "a session name is not a project: reading it inside projectName fails"

new_tree; view 'if alert.related_project_name != nil { showRelated() }'
expect 1 "asking whether an alert names a project reads it (use alertProject)"

new_tree; view 'let shown = AlertPresentation.text(for: alert)'
expect 1 "an app calling AlertPresentation.text fails"

new_tree; view_in "$WATCH" 'Text(AlertPresentation.text(for: alert).title)'
expect 1 "the Watch calling AlertPresentation.text fails"

new_tree; view 'let url = ExportService.exportSessionsCSV(sessions: state.sessions, projectNumbers: numbers)'
expect 1 "an export not told the switch fails"

new_tree; view 'let url = ExportService.exportPDFReport(dashboard: d, providers: p, sessions: s, dailyUsage: u, costForecast: f, hidePersonalInfo: false, projectNumbers: .none, destinationURL: url)'
expect 1 "an export told a literal switch fails"

new_tree; view_in "$IOS" 'if let url = ExportService.exportCostReportCSV(dashboard: d, providers: p, sessions: s) { ShareLink(item: url) { Text("x") } }'
expect 1 "the cost report of the iPhone not told the switch fails"

new_tree; view 'Text(PersonalInfoMask.sessionTitle(session, numbers: numbers, hidePersonalInfo: true))'
expect 1 "a session title masked with a literal switch fails"

new_tree; notifier "${NOTIFY_OK/PersonalInfoMask.alertText(/AlertPresentation.text(for: }"
expect 1 "the banner back on AlertPresentation.text fails"

new_tree; notifier "${NOTIFY_OK/hidePersonalInfo: PersonalInfoMask.isOn()/hidePersonalInfo: false}"
expect 1 "a banner told a literal switch fails"

new_tree; notifier "${NOTIFY_OK/hidePersonalInfo: PersonalInfoMask.isOn()/hidePersonalInfo: hide}"
expect 1 "a banner not told the switch from the defaults fails"

new_tree; rm "$T/$CORE/DataRefreshManager.swift"
expect 1 "a missing DataRefreshManager fails"

# The stored fields under common words, found by the receiver's name.

new_tree; view 'Text(alert.title)'
expect 1 "the Mac alert row back on alert.title (a command line) fails"

new_tree; view_in "$IOS" 'Text(session.name)'
expect 1 "the iPhone session detail back on session.name fails"

new_tree; view_in "$WATCH" 'Text(alert.message).font(.caption2)'
expect 1 "the Watch alert back on alert.message fails"

new_tree; view 'let t = alerts.filter { a in a.title.contains(query) }'
expect 1 "a closure reading a.title fails (a search over the stored title is a read too)"

new_tree; view_in "$IOS" 'Text(selectedSession?.name ?? "")'
expect 1 "an optional-chained selectedSession?.name fails"

new_tree; view_in "$WATCH" 'Text(proj.name)'
expect 1 "the Watch Top Projects back on proj.name fails"

new_tree; view 'let s = PersonalInfoMask.projectName(session.name, numbers: n, hidePersonalInfo: hidePersonalInfo)'
expect 1 "a session name is not a project: session.name inside projectName fails"

new_tree; view 'let t = Text(L10n.alert.title)
alert.title = "x"
// Text(alert.title) used to be here
let doc = "session.name is masked"'
expect 0 "a catalogue entry, a write, a comment and string text are not reads of the stored fields"

new_tree; view 'Text(session.name)'
allowlist '{"entries": [{"path": "CLI Pulse Bar/CLI Pulse Bar/V.swift", "line": "Text(session.name)", "reason": "A made-up editor where the owner types the session name, so it shows as typed."}]}'
expect 0 "an allowlisted session.name read with a reason passes"

new_tree; view 'Text(chip.project)'
allowlist '{"entries": [{"path": "CLI Pulse Bar/CLI Pulse Bar/V.swift", "line": "Text(chip.project)", "reason": "A made-up chip whose project is a placeholder the app wrote, not a folder."}]}'
expect 0 "an allowlisted project read with a reason passes"

# v1.60 (C9): device names.
new_tree; view 'Label(session.device_name, systemImage: "desktopcomputer")'
expect 1 "a session's device shown as stored fails"

new_tree; view_in "$IOS" 'if let device = alert.related_device_name { chipView(icon: "desktopcomputer", text: device) }'
expect 1 "an alert's device read into a local and shown fails"

new_tree; view_in "$WATCH" 'Text(device.name)'
expect 1 "the Watch machine card back on device.name fails"

new_tree; view 'Text(row.clientLabel ?? ProviderDisplay.defaultLabel(for: row.provider))'
expect 1 "a managed session's label (an iPhone's name) shown as stored fails"

new_tree; mkdir -p "$T/$CORE"; printf '%s\n' 'Text(peer.displayName)' > "$T/$CORE/LANRemoteControlSection.swift"
expect 1 "Remote Control's paired list in CLIPulseCore is scanned, and peer.displayName fails"

new_tree; mkdir -p "$T/$CORE"; printf '%s\n' 'ForEach(browser.macs) { m in Text(m.name) }' > "$T/$CORE/LANRemoteScreens.swift"
expect 1 "in Remote Control's Core screens any receiver's .name fails (m.name)"

new_tree; view_in "$IOS" 'Text(UIDevice.current.name)'
expect 1 "this iPhone's own name shown fails"

new_tree; view 'Text(Host.current().localizedName ?? "Mac")'
expect 1 "this Mac's own name shown fails"

new_tree; view 'Text(mode.localizedName)
Text(ProviderDisplay.displayName(for: p))'
expect 0 "an enum's localizedName and a provider's display name are not device names"

new_tree; view 'struct V: View {
    @AppStorage(PersonalInfoMask.defaultsKey) private var hidePersonalInfo = false
    var body: some View {
        if let device = PersonalInfoMask.deviceName(session.device_name, numbers: n, hidePersonalInfo: hidePersonalInfo) {
            Label(device, systemImage: "desktopcomputer")
        }
        Text(PersonalInfoMask.deviceName(device.name, numbers: n, hidePersonalInfo: hidePersonalInfo) ?? "")
        Text(PersonalInfoMask.listedDeviceName(peer.displayName, position: 0, hidePersonalInfo: hidePersonalInfo))
        Text(PersonalInfoMask.pairedDeviceName(mac.name, peerID: nil, hidePersonalInfo: hidePersonalInfo, peers: p))
        Text(PersonalInfoMask.managedSessionTitle(clientLabel: s.client_label, deviceName: s.device_name,
             provider: s.provider, numbers: n, hidePersonalInfo: hidePersonalInfo))
    }
}'
expect 0 "device names and managed labels read inside the mask pass"

echo "check_personal_info_mask: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
