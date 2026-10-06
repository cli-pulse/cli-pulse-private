import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// v1.56 — Settings › Advanced and the Developer ID updater without a paired
/// account.
///
/// Until 1.56 both sat behind one gate, `pairedAccountSettings` (signed in
/// and paired). So:
///
/// - a signed-out Developer ID Mac was never offered an update in the app:
///   `AppUpdaterSection` is the only place that build shows an available
///   update and installs it (the popover's daily manifest check ran signed
///   out too, with nowhere to show its result);
/// - "Paused: signed out" could not be seen while it was true: the helper
///   writes it only while the app is signed out, and Advanced was not drawn
///   then. 1.55's notes said Settings › Advanced shows the pause after a
///   sign-out;
/// - after background sync was turned off, the helper's last status stayed in
///   the app group and Advanced drew it: a green "Synced 36000m ago" under a
///   switch that read Off.
///
/// Drawing Advanced in local mode brought it lines written for an account:
/// "Syncs usage data to the cloud" over a green "Running", usage metrics
/// "Synced to your CLI Pulse account", and a login email "Sent to our sign-in
/// service". Local mode uploads nothing and has no sign-in
/// (`AdvancedUploadCopy`).
///
/// Plain values first (`SettingsAccountSections.Advanced`,
/// `HelperStatusLine.forSettings`), then the app's sources, which `swift test`
/// does not build, read to check that Settings and Advanced go through them.
final class SettingsWithoutPairedAccountTests: XCTestCase {

    private func sections(
        signedIn: Bool,
        paired: Bool,
        localMode: Bool = false,
        backgroundSyncOffered: Bool = true
    ) -> SettingsAccountSections {
        SettingsAccountSections(
            isAuthenticated: signedIn,
            isPaired: paired,
            isLocalMode: localMode,
            runtimeOffersCompanionCLI: true,
            runtimeOffersBackgroundSync: backgroundSyncOffered
        )
    }

    // MARK: - Which Advanced

    func testAdvancedIsThePickersOnlyForAPairedAccount() {
        XCTAssertEqual(sections(signedIn: true, paired: true).advanced, .full)
        XCTAssertEqual(sections(signedIn: true, paired: false).advanced, .thisMac)
        XCTAssertEqual(sections(signedIn: false, paired: false, localMode: true).advanced, .thisMac)
        XCTAssertEqual(sections(signedIn: true, paired: false, localMode: true).advanced, .thisMac)
        for paired in [false, true] {
            XCTAssertEqual(
                sections(signedIn: false, paired: paired).advanced, .backgroundSync,
                "signed out, a stale pairing flag (\(paired)) does not bring back the rest"
            )
        }
        // Where the runtime cannot register the helper (QA), a signed-out
        // Advanced would hold nothing, so there is none; elsewhere it still
        // holds this Mac's settings.
        XCTAssertNil(sections(signedIn: false, paired: false, backgroundSyncOffered: false).advanced)
        XCTAssertEqual(sections(signedIn: true, paired: false, backgroundSyncOffered: false).advanced, .thisMac)
        XCTAssertEqual(sections(signedIn: true, paired: true, backgroundSyncOffered: false).advanced, .full)
    }

    func testEachAdvancedHoldsWhatActsOnThisMacAndOnlyThePickersActsThroughTheAccount() {
        let full = SettingsAccountSections.Advanced.full
        let thisMac = SettingsAccountSections.Advanced.thisMac
        let backgroundSync = SettingsAccountSections.Advanced.backgroundSync

        for content in [full, thisMac, backgroundSync] {
            XCTAssertTrue(content.showsBackgroundSync, "\(content)")
        }
        XCTAssertTrue(full.showsCLIToolAccess)
        XCTAssertTrue(thisMac.showsCLIToolAccess)
        XCTAssertFalse(backgroundSync.showsCLIToolAccess, "a signed-out Mac reads no folders")
        XCTAssertTrue(full.showsThisMacSettings)
        XCTAssertTrue(thisMac.showsThisMacSettings)
        XCTAssertFalse(backgroundSync.showsThisMacSettings)
        XCTAssertTrue(full.showsAccountControls)
        XCTAssertFalse(thisMac.showsAccountControls)
        XCTAssertFalse(backgroundSync.showsAccountControls)
    }

    /// Over every state: background sync and its line are reachable wherever
    /// the runtime registers the helper, the folders the scan reads are
    /// offered wherever this Mac scans, and the account's controls only with
    /// a paired account.
    func testEveryState() {
        var reachedSignedOut = 0
        var reachedUnpaired = 0
        for signedIn in [false, true] {
            for paired in [false, true] {
                for localMode in [false, true] {
                    for demo in [false, true] {
                        let s = sections(signedIn: signedIn, paired: paired, localMode: localMode)
                        let state = "signed in \(signedIn), paired \(paired), local mode \(localMode), demo \(demo)"
                        let advanced = s.advanced
                        XCTAssertNotNil(advanced, state)
                        XCTAssertEqual(advanced?.showsBackgroundSync, true, state)
                        let route = RefreshRouter.decide(
                            isAuthenticated: signedIn,
                            isDemoMode: demo,
                            isPaired: paired,
                            isLocalMode: localMode,
                            isMacOS: true
                        )
                        if route != .noOp {
                            XCTAssertEqual(advanced?.showsCLIToolAccess, true, "scans, with no CLI Tool Access: \(state)")
                        }
                        XCTAssertEqual(
                            advanced?.showsAccountControls, s.pairedAccountSettings,
                            "the account's controls follow the paired account: \(state)"
                        )
                        if !signedIn && !localMode { reachedSignedOut += 1 }
                        if signedIn && !paired { reachedUnpaired += 1 }
                    }
                }
            }
        }
        // Controls: the loop reached both states the change is for.
        XCTAssertGreaterThan(reachedSignedOut, 0)
        XCTAssertGreaterThan(reachedUnpaired, 0)
    }

    // MARK: - The status line

    private var previousOverride: String?
    private let device = "8f0c3a52-1111-4c1e-9d7e-3b1f5d0a2c44"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        // Asserted in zh-Hans: a broken lookup would still produce English and
        // pass under en.
        previousOverride = LocaleOverrideStore.shared.override
        LocaleOverrideStore.shared.set("zh-Hans")
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(previousOverride)
        super.tearDown()
    }

    private func line(
        _ status: HelperIPC.Status?,
        on: Bool = true,
        paired: Bool = true,
        pairing: ThisMacPairing.State = .notNeeded,
        pairedDeviceId: String? = nil,
        account: HelperAccountRecord,
        shouldBePaused: Bool,
        appBuild: String? = "109"
    ) -> HelperStatusLine? {
        HelperStatusLine.forSettings(
            status: status,
            backgroundSyncOn: on,
            isPaired: paired,
            thisMacPairing: pairing,
            pairedDeviceId: pairedDeviceId,
            appAccount: account,
            helperShouldBePaused: shouldBePaused,
            appBuild: appBuild,
            now: now
        )
    }

    /// The finding: a helper from before 1.55, turned off weeks ago, left a
    /// "running" status with an old sync behind it.
    func testNothingWhileBackgroundSyncIsOff() {
        let left = HelperIPC.Status(
            state: .running,
            lastSync: now.addingTimeInterval(-36_000 * 60),
            helperVersion: "1.0.0",
            deviceId: device
        )
        let accounts: [HelperAccountRecord] = [.signedIn(userId: "u1"), .localMode, .signedOut]
        for account in accounts {
            for paired in [false, true] {
                XCTAssertNil(
                    line(left, on: false, paired: paired, pairedDeviceId: device,
                         account: account, shouldBePaused: account == .signedOut),
                    "\(account), paired \(paired)"
                )
            }
        }
        let paused = HelperIPC.Status(
            state: .running, helperVersion: "1.0.0",
            pauseCode: HelperIPC.PauseCode.signedOut, helperBuild: "109"
        )
        XCTAssertNil(line(paused, on: false, account: .signedOut, shouldBePaused: true))

        // Control: with the switch on, the same status is drawn, so the nil
        // above is the switch and not the status.
        XCTAssertEqual(
            line(left, pairedDeviceId: device, account: .signedIn(userId: "u1"), shouldBePaused: false)?.text,
            "36000 分钟前同步"
        )
        XCTAssertNil(line(nil, account: .signedIn(userId: "u1"), shouldBePaused: false), "no status, no line")
    }

    /// Reachable: a signed-out Mac whose helper is registered says so.
    func testPausedSignedOutIsShownWhileSignedOut() {
        let paused = HelperIPC.Status(
            state: .running, helperVersion: "1.0.0",
            pauseCode: HelperIPC.PauseCode.signedOut, helperBuild: "109"
        )
        for paired in [false, true] {
            XCTAssertEqual(
                line(paused, paired: paired, account: .signedOut, shouldBePaused: true),
                HelperStatusLine(tone: .inactive, text: "已暂停：未登录", isError: false),
                "a stale pairing flag (\(paired)) changes nothing while signed out"
            )
        }
        XCTAssertEqual(L10n.advanced.helperPausedSignedOut, "已暂停：未登录")
        // A helper from before 1.55 ignores the sign-out: the line says so
        // rather than claiming a pause.
        let old = HelperIPC.Status(state: .running, lastSync: now, helperVersion: "1.0.0")
        XCTAssertEqual(
            line(old, account: .signedOut, shouldBePaused: true)?.text,
            L10n.advanced.helperRestartNeeded
        )
    }

    /// Not claimed once the app has left the signed-out state: the code stays
    /// until the helper's next cycle.
    func testAStaleSignedOutPauseIsNotClaimed() {
        let stale = HelperIPC.Status(
            state: .running, helperVersion: "1.0.0",
            pauseCode: HelperIPC.PauseCode.signedOut, helperBuild: "109"
        )
        let running = HelperStatusLine(tone: .good, text: "运行中", isError: false)
        XCTAssertEqual(
            line(stale, pairedDeviceId: device, account: .signedIn(userId: "u1"), shouldBePaused: false),
            running, "signed back in"
        )
        XCTAssertEqual(line(stale, paired: false, account: .localMode, shouldBePaused: false), running, "local mode")
        XCTAssertNotEqual(
            line(stale, pairedDeviceId: device, account: .signedIn(userId: "u1"), shouldBePaused: true)?.text,
            L10n.advanced.helperPausedSignedOut,
            "signed in with \"Not now\": paused, but not for a sign-out"
        )
        // `make` without an account keeps trusting the code, as before.
        XCTAssertEqual(
            HelperStatusLine.make(status: stale, thisMacPairing: .notNeeded, pairedDeviceId: nil).text,
            L10n.advanced.helperPausedSignedOut
        )
    }

    /// A Mac signed in to an account that is not paired: whatever its helper
    /// last wrote (here a sync for another account), nothing syncs for this
    /// one.
    func testAnAccountThatIsNotPairedReadsNotPaired() {
        let syncedElsewhere = HelperIPC.Status(
            state: .running, lastSync: now, helperVersion: "1.0.0",
            deviceId: device, helperBuild: "109"
        )
        let notPaired = HelperStatusLine(tone: .attention, text: L10n.settings.notPaired, isError: false)
        XCTAssertEqual(L10n.settings.notPaired, "未同步")
        XCTAssertEqual(
            line(syncedElsewhere, paired: false, account: .signedIn(userId: "u1"), shouldBePaused: false),
            notPaired
        )
        // Controls: the same status on a paired account, and in local mode
        // (no account to be paired with), is not "not paired".
        XCTAssertEqual(
            line(syncedElsewhere, paired: true, pairedDeviceId: device,
                 account: .signedIn(userId: "u1"), shouldBePaused: false)?.text,
            L10n.advanced.syncJustNow
        )
        XCTAssertNotEqual(
            line(syncedElsewhere, paired: false, account: .localMode, shouldBePaused: false),
            notPaired
        )
    }

    // MARK: - What leaves this Mac, in local mode

    /// Local mode reaches Advanced for the first time in 1.56, and uploads
    /// nothing. The hint under the switch, Usage metrics and the login email
    /// were written for an account; there they said the opposite of the
    /// welcome screen's "no account, nothing uploaded". Asserted in zh-Hans.
    func testLocalModeIsNotToldItsUsageLeavesThisMac() {
        let local = AdvancedUploadCopy(appAccount: .localMode)
        XCTAssertEqual(local.backgroundSyncHint, "在后台读取这台 Mac 的用量。本地模式下不上传任何数据。")
        XCTAssertEqual(local.backgroundSyncHint, L10n.advanced.backgroundSyncHintLocalMode)
        XCTAssertFalse(local.usageMetricsLeaveThisMac)
        XCTAssertEqual(local.usageMetricsDetail, "在你选择登录之前，用量数据只会保留在这台 Mac 上。")
        XCTAssertFalse(local.showsLoginEmail, "no sign-in, no login email")

        // Controls: every other account keeps the account's wording, so the
        // local-mode lines above are the account's doing and not the lookup.
        // "Apple Watch" is one no-break space in the catalogue, and "CLI Pulse"
        // one at lookup (`L10n.keepingBrandUnbroken`).
        // Signed in but not paired, the app syncs daily usage itself; signed
        // out, the hint sits above "Paused: signed out"; Demo is `.signedOut`.
        for account: HelperAccountRecord in [.signedIn(userId: "u1"), .signedOut] {
            let copy = AdvancedUploadCopy(appAccount: account)
            XCTAssertEqual(copy.backgroundSyncHint, "将用量数据同步到云端，供 iPhone、Apple\u{00A0}Watch 和 Android 使用", "\(account)")
            XCTAssertTrue(copy.usageMetricsLeaveThisMac, "\(account)")
            XCTAssertEqual(copy.usageMetricsDetail, "同步到你的 CLI\u{00A0}Pulse 账户，供 iPhone 和 Apple\u{00A0}Watch 使用", "\(account)")
            XCTAssertTrue(copy.showsLoginEmail, "\(account)")
            XCTAssertNotEqual(copy, local, "\(account)")
        }
    }

    /// The new hint in every language, word for word: each uses its own name
    /// for local mode and its own "nothing uploaded". A missing key would
    /// read as the raw key, and a fallback as English.
    func testTheLocalModeHintInEveryLanguage() {
        let expected = [
            "en": "Reads this Mac's usage in the background. In local mode, nothing is uploaded.",
            "zh-Hans": "在后台读取这台 Mac 的用量。本地模式下不上传任何数据。",
            "zh-Hant": "在背景讀取這台 Mac 的用量。本機模式下不上傳任何資料。",
            "ja": "この Mac の使用状況をバックグラウンドで読み取ります。ローカルモードでは何もアップロードしません。",
            "ko": "이 Mac의 사용량을 백그라운드에서 읽습니다. 로컬 모드에서는 아무것도 업로드되지 않습니다.",
            "es": "Lee el uso de este Mac en segundo plano. En modo local no se sube nada.",
        ]
        for (language, text) in expected {
            LocaleOverrideStore.shared.set(language)
            XCTAssertEqual(AdvancedUploadCopy(appAccount: .localMode).backgroundSyncHint, text, language)
            XCTAssertNotEqual(L10n.advanced.backgroundSyncHint, text, "\(language): the cloud hint is a different string")
        }
    }

    // MARK: - The app's sources

    private var appDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // …/Tests/CLIPulseCoreTests
            .deletingLastPathComponent()    // …/Tests
            .deletingLastPathComponent()    // …/CLIPulseCore
            .deletingLastPathComponent()    // …/CLI Pulse Bar
            .appending(path: "CLI Pulse Bar")
    }

    /// The file without its `//` and `///` comment lines, which name the
    /// things the gates hide.
    private func code(_ name: String) throws -> String {
        let text = try String(contentsOf: appDir.appending(path: name), encoding: .utf8)
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertGreaterThan(kept.count, text.count / 2, "the comment filter removed too much: \(name)")
        return kept
    }

    private func squeezed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The body of `private var <name>: ` up to the first line that closes at
    /// four spaces.
    private func body(of name: String, in text: String) throws -> String {
        let start = try XCTUnwrap(text.range(of: "private var \(name): "), name)
        let rest = text[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: "\n    }\n"), name)
        return String(rest[..<end.lowerBound])
    }

    /// The inside of every block opened by the first `{` at or after each
    /// `header` in `text`: `if a {`, and `if a, b {` read from `if a`.
    private func blocks(_ header: String, in text: String) -> [String] {
        var found: [String] = []
        var searchFrom = text.startIndex
        while let open = text.range(of: header, range: searchFrom..<text.endIndex),
              let brace = text.range(of: "{", range: open.lowerBound..<text.endIndex) {
            var depth = 1
            var index = brace.upperBound
            while index < text.endIndex, depth > 0 {
                if text[index] == "{" { depth += 1 }
                if text[index] == "}" { depth -= 1 }
                index = text.index(after: index)
            }
            found.append(String(text[brace.upperBound..<index]))
            searchFrom = open.upperBound
        }
        return found
    }

    /// How many braces are open at each occurrence of `needle` in `text`.
    private func depths(of needle: String, in text: String) -> [Int] {
        var result: [Int] = []
        var depth = 0
        var index = text.startIndex
        while index < text.endIndex {
            if text[index...].hasPrefix(needle) {
                result.append(depth)
                index = text.index(index, offsetBy: needle.count)
                continue
            }
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" { depth -= 1 }
            index = text.index(after: index)
        }
        return result
    }

    /// Both branches draw the updater (one view, `appUpdaterSection`) at the
    /// top level of their stack: inside `#if DEVID_BUILD` and no `if`.
    func test_theUpdaterIsInBothBranchesBehindNoAccountGate() throws {
        let settings = try code("SettingsTab.swift")
        XCTAssertEqual(settings.components(separatedBy: "AppUpdaterSection(").count - 1, 1)
        XCTAssertTrue(
            squeezed(try body(of: "appUpdaterSection", in: settings))
                .contains("AppUpdaterSection( updater: state.appUpdater, permMigration: state.permissionMigrationChecker )")
        )
        XCTAssertTrue(
            squeezed(settings).contains("} else { loginSection signedOutSections }"),
            "the sign-in form's branch draws signedOutSections, local mode or not"
        )
        for name in ["signedOutSections", "authenticatedSection"] {
            let section = try body(of: name, in: settings)
            XCTAssertTrue(squeezed(section).contains("#if DEVID_BUILD Divider() appUpdaterSection #endif"), name)
            // `some View {` and the stack's `{`: two braces, so no `if` is open.
            XCTAssertEqual(depths(of: "appUpdaterSection", in: section), [2], name)
            for gate in ["if accountSections.pairedAccountSettings {", "if accountSections.companionCLI {", "if accountSections.privacy {"] {
                for block in blocks(gate, in: section) {
                    XCTAssertFalse(block.contains("appUpdaterSection"), "\(name): inside \(gate)")
                }
            }
            // Control: the depth reader sees a gated section as gated.
            XCTAssertEqual(depths(of: "CompanionCLISection(", in: section), [3], name)
        }
    }

    /// Advanced without the picker is drawn in both branches outside the
    /// paired block, for every `advanced` but the picker's; the picker draws
    /// `.full`.
    func test_advancedIsDrawnWithoutThePickerWhereThereIsNoPairedAccount() throws {
        let settings = try code("SettingsTab.swift")
        let decision = squeezed(try body(of: "accountSections", in: settings))
        XCTAssertTrue(
            decision.contains("runtimeOffersBackgroundSync: state.runtimeEnvironment.capabilities.allowsHelperRegistration )"),
            decision
        )
        let without = squeezed(try body(of: "advancedWithoutPicker", in: settings))
        XCTAssertTrue(without.contains("if let content = accountSections.advanced, content != .full {"), without)
        XCTAssertTrue(
            without.contains("AdvancedSection( launchAtLogin: $launchAtLogin, helperEnabled: $helperEnabled, content: content )"),
            without
        )
        XCTAssertTrue(without.contains("Text(L10n.settings.advanced)"), "named like the picker's segment")

        for name in ["signedOutSections", "authenticatedSection"] {
            let section = try body(of: name, in: settings)
            XCTAssertEqual(depths(of: "advancedWithoutPicker", in: section), [2], name)
        }
        let signedIn = try body(of: "authenticatedSection", in: settings)
        let paired = blocks("if accountSections.pairedAccountSettings {", in: signedIn)
        XCTAssertTrue(paired.contains { squeezed($0).contains("case .advanced: AdvancedSection( launchAtLogin: $launchAtLogin, helperEnabled: $helperEnabled, content: .full )") })
        XCTAssertEqual(settings.components(separatedBy: "AdvancedSection(").count - 1, 2, "the picker's and the one without it")
    }

    /// Inside Advanced, each part is drawn under its `content` flag, and the
    /// controls that act through the account under `showsAccountControls`
    /// only.
    func test_advancedDrawsEachPartUnderItsFlag() throws {
        let advanced = try code("AdvancedSection.swift")
        XCTAssertTrue(advanced.contains("struct AdvancedSection"), "this is not AdvancedSection")
        XCTAssertTrue(advanced.contains("let content: SettingsAccountSections.Advanced"))

        // The status line: `forSettings`, fed the switch and the account.
        XCTAssertFalse(advanced.contains("HelperStatusLine.make("), "Advanced words the status through forSettings")
        let callStart = try XCTUnwrap(advanced.range(of: "if let line = HelperStatusLine.forSettings("))
        let callEnd = try XCTUnwrap(advanced.range(of: ") {", range: callStart.upperBound..<advanced.endIndex))
        let statusCall = squeezed(String(advanced[callStart.upperBound..<callEnd.lowerBound]))
        for argument in ["status: HelperIPC.readStatus(),", "backgroundSyncOn: helperEnabled,",
                         "isPaired: authState.isPaired,", "appAccount: state.accountRecordForHelper,",
                         "helperShouldBePaused: state.helperShouldBePaused,"] {
            XCTAssertTrue(statusCall.contains(argument), argument)
        }

        let backgroundSync = blocks("if content.showsBackgroundSync,", in: advanced)
        XCTAssertEqual(backgroundSync.count, 1)
        XCTAssertTrue(backgroundSync.first?.contains("Toggle(isOn: $helperEnabled)") == true)
        XCTAssertTrue(backgroundSync.first?.contains("HelperStatusLine.forSettings(") == true)

        let cliToolAccess = blocks("if content.showsCLIToolAccess,", in: advanced)
        XCTAssertEqual(cliToolAccess.count, 1)
        XCTAssertTrue(cliToolAccess.first?.contains("FolderAccessView()") == true)
        XCTAssertEqual(advanced.components(separatedBy: "FolderAccessView()").count - 1, 1)

        XCTAssertTrue(blocks("if content.showsThisMacSettings {", in: advanced).contains { $0.contains("thisMacSettings") })

        // The account's controls: only inside its gate. A marker found outside
        // every gated block is drawn without a paired account.
        let gated = blocks("if content.showsAccountControls", in: advanced).joined(separator: "\n")
        var outside = advanced
        for block in blocks("if content.showsAccountControls", in: advanced) {
            outside = outside.replacingOccurrences(of: block, with: "")
        }
        for marker in ["get: { state.gitTrackingEnabled }",
                       "if MacControlRequests.areHonoredByThisBuild {",
                       "get: { state.remoteMachineControlEnabled }",
                       "if RemoteSessionPlane.isEnabled {"] {
            XCTAssertTrue(gated.contains(marker), "the gate no longer contains \(marker)")
            XCTAssertFalse(outside.contains(marker), "\(marker) is drawn without a paired account")
        }
        // Control: what acts on this Mac alone is outside that gate.
        for marker in ["Toggle(isOn: $state.hidePersonalInfo)", "get: { state.machineControlsEnabled }"] {
            XCTAssertTrue(outside.contains(marker), marker)
        }
    }

    /// The hint, Usage metrics and the login email come from
    /// `AdvancedUploadCopy`, built from the account the helper is told, so
    /// local mode reads what it does.
    func test_advancedWordsWhatLeavesThisMacForTheAccount() throws {
        let advanced = try code("AdvancedSection.swift")
        XCTAssertTrue(
            squeezed(advanced).contains("AdvancedUploadCopy(appAccount: state.accountRecordForHelper)"),
            "built from the account the status line is worded for"
        )

        // The hint, in the background sync block, only through the copy.
        let backgroundSync = try XCTUnwrap(blocks("if content.showsBackgroundSync,", in: advanced).first)
        XCTAssertTrue(backgroundSync.contains("Text(uploadCopy.backgroundSyncHint)"))
        XCTAssertFalse(advanced.contains("L10n.advanced.backgroundSyncHint"), "the hint is chosen by the copy, not named here")

        // Usage metrics: its detail and icon follow the copy.
        let metrics = squeezed(advanced)
        XCTAssertTrue(metrics.contains(
            "privacyRow( icon: uploadCopy.usageMetricsLeaveThisMac ? \"icloud.and.arrow.up.fill\" : \"internaldrive.fill\", "
            + "color: uploadCopy.usageMetricsLeaveThisMac ? .blue : .green, "
            + "title: L10n.advanced.privacyMetricsTitle, detail: uploadCopy.usageMetricsDetail )"
        ))
        XCTAssertFalse(advanced.contains("L10n.advanced.privacyMetricsDetail"))

        // The login email: only inside its flag.
        let email = blocks("if uploadCopy.showsLoginEmail {", in: advanced)
        XCTAssertEqual(email.count, 1)
        XCTAssertTrue(email.first?.contains("title: L10n.advanced.privacyEmailTitle") == true)
        XCTAssertEqual(advanced.components(separatedBy: "L10n.advanced.privacyEmailTitle").count - 1, 1)

        // Control: the rows that are true in local mode are drawn whatever
        // the copy says.
        var outside = advanced
        for block in email { outside = outside.replacingOccurrences(of: block, with: "") }
        for marker in ["title: L10n.advanced.privacyKeysTitle", "title: L10n.advanced.privacyLogsTitle",
                       "title: L10n.advanced.privacySessionsTitle"] {
            XCTAssertTrue(outside.contains(marker), marker)
        }
    }
}

#endif
