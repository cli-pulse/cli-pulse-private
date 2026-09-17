import XCTest
@testable import CLIPulseCore

/// Try Demo is what App Review and every localized App Store screenshot see.
/// Its alerts used to be the retired backend's kinds ("Codex quota critically
/// low", "Session failed: …", "Device offline: …") — templates no producer
/// writes and AlertPresentation therefore never recognized — and its risk
/// signals were English literals. So a Japanese or Chinese screen showed whole
/// English alert cards under translated headings.
///
/// Runs in Japanese: under English a broken lookup still passes, because the
/// fallback copy is English.
final class DemoDataLocalizationTests: XCTestCase {

    /// The override persists to UserDefaults.standard; put back whatever the
    /// next suite would otherwise inherit from this one.
    private var savedOverride: String?

    override func setUp() {
        super.setUp()
        savedOverride = LocaleOverrideStore.shared.override
        LocaleOverrideStore.shared.set("ja")
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(savedOverride)
        super.tearDown()
    }

    /// Latin-script words of two or more letters.
    private func latinWords(_ s: String) -> Set<String> {
        let rx = try! NSRegularExpression(pattern: "[A-Za-z]{2,}")
        return Set(rx.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
            Range($0.range, in: s).map { String(s[$0]) }
        })
    }

    /// Every demo alert must be one AlertPresentation recognizes, and its
    /// Japanese rendering must share no English word with the stored template
    /// other than the data inside it (provider, session, project, device) and
    /// "CPU", which the ja catalogue keeps in Latin script. A missing ja key
    /// would still be "recognized" — L10n falls back to English copy — which is
    /// what the word check catches.
    func testEveryDemoAlertIsAProducerTemplateAndRendersInJapanese() {
        let alerts = DemoDataProvider.generate().alerts
        XCTAssertFalse(alerts.isEmpty, "no demo alerts, so this proves nothing")
        XCTAssertTrue(alerts.contains { $0.id.hasPrefix("quota-") },
                      "the quota alert did not fire from the demo providers")

        for alert in alerts {
            let shown = AlertPresentation.text(for: alert)
            XCTAssertTrue(shown.recognized, """
                Demo alert is not a template any producer writes, so it renders English:
                  type: \(alert.type)  id: \(alert.id)
                  title: \(alert.title)
                  message: \(alert.message)
                """)
            XCTAssertNotEqual(shown.title, alert.title, "title still the stored English")
            XCTAssertNotEqual(shown.message, alert.message, "message still the stored English")

            var data: Set<String> = ["CPU"]
            for field in [alert.related_provider, alert.related_session_name,
                          alert.related_project_name, alert.related_device_name] {
                data.formUnion(latinWords(field ?? ""))
            }
            let leaked = latinWords(shown.title + " " + shown.message)
                .intersection(latinWords(alert.title + " " + alert.message))
                .subtracting(data)
            XCTAssertTrue(leaked.isEmpty,
                          "English template words \(leaked.sorted()) in: \(shown.title) / \(shown.message)")
        }
    }

    /// Risk signals are rendered verbatim, so they must already be Japanese
    /// when the demo is built in Japanese.
    func testEveryDemoRiskSignalIsLocalized() {
        let ja = DemoDataProvider.generate()
        LocaleOverrideStore.shared.set("en")
        let en = DemoDataProvider.generate()
        LocaleOverrideStore.shared.set("ja")

        let jaSignals = ja.dashboard.risk_signals
        XCTAssertFalse(jaSignals.isEmpty, "no demo risk signals, so this proves nothing")
        XCTAssertEqual(jaSignals.count, en.dashboard.risk_signals.count)

        var data = Set<String>()
        for name in ja.providers.map(\.provider) + ja.devices.map(\.name) {
            data.formUnion(latinWords(name))
        }
        for (jaSignal, enSignal) in zip(jaSignals, en.dashboard.risk_signals) {
            XCTAssertNotEqual(jaSignal, enSignal, "risk signal not localized: \(jaSignal)")
            XCTAssertNil(jaSignal.range(of: #"%(\d\$)?[@d]"#, options: .regularExpression),
                         "unfilled specifier: \(jaSignal)")
            let leaked = latinWords(jaSignal).intersection(latinWords(enSignal)).subtracting(data)
            XCTAssertTrue(leaked.isEmpty, "English words \(leaked.sorted()) in: \(jaSignal)")
        }
    }

    /// Session names are data, shown as-is in every language, so they read as
    /// identifiers rather than English sentences — and every name an alert or a
    /// provider card refers to is a session that exists.
    func testDemoSessionNamesAreIdentifiersThatAlertsReferToConsistently() {
        let demo = DemoDataProvider.generate()
        let names = Set(demo.sessions.map(\.name))
        let identifier = try! NSRegularExpression(pattern: "^[a-z0-9]+(-[a-z0-9]+)*$")
        for name in names {
            XCTAssertNotNil(identifier.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                            "demo session name reads as prose, not data: \(name)")
        }
        for alert in demo.alerts {
            if let session = alert.related_session_name {
                XCTAssertTrue(names.contains(session), "alert refers to a session that does not exist: \(session)")
            }
        }
        for provider in demo.providers {
            for session in provider.recent_sessions {
                XCTAssertTrue(names.contains(session), "\(provider.provider) lists an unknown session: \(session)")
            }
        }
    }
}

/// The account name Demo puts in Settings is the heading of that screen in
/// every localized screenshot. It is not the user's data — there is no user —
/// so it is copy, and it goes through the real `enterDemoMode`.
@MainActor
final class DemoAccountNameTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var savedOverride: String?

    override func setUp() {
        super.setUp()
        suiteName = "DemoAccountNameTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        savedOverride = LocaleOverrideStore.shared.override
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(savedOverride)
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// An empty Info.plist resolves to the quarantine capabilities, so entering
    /// Demo here publishes no widget data to the real app group.
    private func demoUserName(in locale: String) -> String {
        LocaleOverrideStore.shared.set(locale)
        let state = AppState(
            runtimeEnvironment: .resolveForTesting(infoDictionary: [:], environment: [:]),
            defaults: defaults,
            performLaunchSetup: false)
        state.enterDemoMode()
        return state.userName
    }

    func testDemoAccountNameIsInTheUsersLanguage() {
        let en = demoUserName(in: "en")
        let ja = demoUserName(in: "ja")

        XCTAssertFalse(en.isEmpty)
        XCTAssertNotEqual(ja, en, "Demo's account name is not localized: \(ja)")
        XCTAssertNil(ja.range(of: "[A-Za-z]", options: .regularExpression),
                     "Latin letters in the Japanese demo account name: \(ja)")
    }
}

/// The demo's quota alert now has a real `quota-` id. Resolving or snoozing a
/// `quota-` alert normally persists a local suppression to UserDefaults — in
/// Demo that would outlive the demo and silence the same alert (same provider,
/// tier and threshold) for the account signed in next.
@MainActor
final class DemoAlertActionTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var savedSuppressions: Any?

    override func setUp() {
        super.setUp()
        suiteName = "DemoAlertActionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        // The suppression store writes to .standard; put back whatever was there.
        savedSuppressions = UserDefaults.standard.object(forKey: AppState.suppressedAlertsV2Key)
    }

    override func tearDown() {
        if let savedSuppressions {
            UserDefaults.standard.set(savedSuppressions, forKey: AppState.suppressedAlertsV2Key)
        } else {
            UserDefaults.standard.removeObject(forKey: AppState.suppressedAlertsV2Key)
        }
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeDemoState() -> AppState {
        let state = AppState(
            runtimeEnvironment: .resolveForTesting(infoDictionary: [:], environment: [:]),
            defaults: defaults,
            performLaunchSetup: false)
        state.isDemoMode = true
        state.applyDemoData(DemoDataProvider.generate())
        return state
    }

    func testResolvingTheDemoQuotaAlertPersistsNoSuppression() async throws {
        let state = makeDemoState()
        let quota = try XCTUnwrap(state.alerts.first { $0.id.hasPrefix("quota-") })

        await state.resolveAlert(quota)

        XCTAssertNil(state.suppressedAlertIDs[quota.id],
                     "a demo resolve persisted a suppression a real account would inherit")
        let row = try XCTUnwrap(state.alerts.first { $0.id == quota.id }, "demo row was removed")
        XCTAssertTrue(row.is_resolved)
    }

    func testSnoozingTheDemoQuotaAlertPersistsNoSuppression() async throws {
        let state = makeDemoState()
        let quota = try XCTUnwrap(state.alerts.first { $0.id.hasPrefix("quota-") })

        await state.snoozeAlert(quota, minutes: 60)

        XCTAssertNil(state.suppressedAlertIDs[quota.id],
                     "a demo snooze persisted a suppression a real account would inherit")
        let row = try XCTUnwrap(state.alerts.first { $0.id == quota.id }, "demo row was removed")
        XCTAssertNotNil(row.snoozed_until)
    }
}
