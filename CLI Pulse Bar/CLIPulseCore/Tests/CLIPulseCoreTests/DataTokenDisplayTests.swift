import XCTest
@testable import CLIPulseCore

/// Values that are stored identifiers but were rendered as if they were words.
/// Each is mapped at display time; the stored value is untouched, because the
/// views and the persisted config still compare against it.
final class DataTokenDisplayTests: XCTestCase {

    private func withLocale(_ id: String, _ body: () -> Void) {
        let store = LocaleOverrideStore.shared
        let previous = store.override
        store.set(id)
        defer { store.set(previous) }
        body()
    }

    // MARK: - Source type

    /// The source picker used to render `rawValue` — "oauth", "api", "merged" —
    /// which read as lowercase debug tokens even in English.
    func testSourceTypesNoLongerRenderTheirStoredIdentifier() {
        withLocale("en") {
            for source in SourceType.allCases {
                XCTAssertNotEqual(source.localizedName, source.rawValue,
                                  "\(source) still renders its stored identifier")
                XCTAssertFalse(source.localizedName.isEmpty)
            }
            XCTAssertEqual(SourceType.oauth.localizedName, "OAuth")
            XCTAssertEqual(SourceType.api.localizedName, "API")
            XCTAssertEqual(SourceType.cli.localizedName, "CLI")
        }
    }

    func testTranslatableSourceTypesAreLocalized() {
        let translatable: [SourceType] = [.auto, .local, .merged]
        var english: [SourceType: String] = [:]
        withLocale("en") { for s in translatable { english[s] = s.localizedName } }
        withLocale("zh-Hans") {
            for s in translatable {
                XCTAssertNotEqual(s.localizedName, english[s], "\(s) is still English under zh-Hans")
            }
        }
    }

    /// The stored value must not move: persisted configs and the helper decode it.
    func testSourceTypeRawValuesAreUnchanged() {
        XCTAssertEqual(SourceType.allCases.map(\.rawValue),
                       ["auto", "web", "cli", "oauth", "api", "local", "merged"])
    }

    // MARK: - Cookie source

    func testBrowserNamesRenderAsWrittenAndTheRestAreLocalized() {
        withLocale("zh-Hans") {
            XCTAssertEqual(CookieSource.safari.localizedName, "Safari")
            XCTAssertEqual(CookieSource.chrome.localizedName, "Chrome")
            XCTAssertEqual(CookieSource.firefox.localizedName, "Firefox")
            XCTAssertNotEqual(CookieSource.automatic.localizedName, "Automatic")
            XCTAssertNotEqual(CookieSource.manual.localizedName, "Manual")
        }
    }

    // MARK: - Plan

    /// "Multiple accounts" (`APIClient`) and the collectors' fallbacks when a
    /// vendor reports no plan name are words the app writes itself, so they
    /// render in the reader's language. `ProviderAccountAPITests` pins the
    /// "Multiple accounts" producer; this pins the other end.
    func testThePlanWordsTheAppWritesAreLocalizedAndVendorPlansPassThrough() {
        let ours = ["Multiple accounts", "API key", "Paid", "Free", "Legacy", "Unknown", "Local",
                    "Credits", "Pay-as-you-go", "Self-hosted", "Admin API", "Unlimited", "Account"]
        withLocale("en") {
            for raw in ours {
                XCTAssertEqual(L10n.providers.planDisplay(raw), raw, "English catalogue disagrees with \(raw)")
            }
        }
        withLocale("zh-Hans") {
            for raw in ours {
                XCTAssertNotEqual(L10n.providers.planDisplay(raw), raw, "\(raw) still renders in English")
            }
            // CodexCollector writes "unknown".capitalized; JetBrains capitalizes a vendor token.
            XCTAssertEqual(L10n.providers.planDisplay("UNKNOWN"), L10n.providers.planDisplay("Unknown"))
            for vendorPlan in ["Pro", "Max 5x", "Team", "Coding Plan", "Free Trial", ""] {
                XCTAssertEqual(L10n.providers.planDisplay(vendorPlan), vendorPlan,
                               "\(vendorPlan) is a vendor plan name and must render as written")
            }
        }
    }

    /// DeepgramCollector names a multi-project key "3 projects".
    func testDeepgramProjectCountIsLocalized() {
        withLocale("en") { XCTAssertEqual(L10n.providers.planDisplay("3 projects"), "3 projects") }
        withLocale("zh-Hans") {
            XCTAssertEqual(L10n.providers.planDisplay("3 projects"), "3 个项目")
            XCTAssertEqual(L10n.providers.planDisplay("many projects"), "many projects")
        }
    }

    /// Account rows on iPhone and the Watch show the plan evidence; the stored
    /// evidence keeps what was detected.
    func testAccountPlanEvidenceRendersThroughThePlanMapper() {
        let evidence = ProviderPlanEvidence(rawValue: "api key", displayValue: "API key",
                                            source: .providerAPI, confidence: .high, observedAt: nil)
        withLocale("ja") {
            XCTAssertEqual(evidence.localizedDisplay, "API キー")
            XCTAssertEqual(evidence.displayValue, "API key")
            let rawOnly = ProviderPlanEvidence(rawValue: "Local", displayValue: nil,
                                               source: .providerAPI, confidence: .high, observedAt: nil)
            XCTAssertEqual(rawOnly.localizedDisplay, "ローカル")
            let none = ProviderPlanEvidence(rawValue: nil, displayValue: nil,
                                            source: .providerAPI, confidence: .high, observedAt: nil)
            XCTAssertNil(none.localizedDisplay)
        }
    }

    // MARK: - Menu bar display mode

    /// The Settings picker listed `rawValue` ("Most Used"), which is the persisted
    /// Codable value; `localizedName` is what it shows now.
    func testMenuBarDisplayModesHaveLocalizedNamesAndKeepTheirRawValues() {
        XCTAssertEqual(MenuBarDisplayMode.allCases.map(\.rawValue), ["Icon", "Percent", "Pace", "Most Used"])
        withLocale("zh-Hans") {
            for mode in MenuBarDisplayMode.allCases {
                XCTAssertNotEqual(mode.localizedName, mode.rawValue, "\(mode) still renders its stored value")
            }
            XCTAssertEqual(MenuBarDisplayMode.mostUsed.localizedName, "最常用")
        }
    }

    // MARK: - Session names

    /// `CostUsageScanner` names a session rebuilt from JSONL logs "Claude session".
    func testJSONLSessionNamesRenderInTheReadersLanguage() {
        func record(id: String, name: String) -> SessionRecord {
            SessionRecord(id: id, name: name, provider: "Codex", project: "p", device_name: "Mac",
                          started_at: "2026-05-05T03:50:00Z", last_active_at: "2026-05-05T03:54:00Z",
                          status: "Running", total_usage: 1, estimated_cost: 0, cost_status: "Estimated",
                          requests: 1, error_count: 0)
        }
        let jsonl = record(id: "jsonl-codex-abc", name: SessionRecord.jsonlSessionName(provider: "Codex"))
        withLocale("en") { XCTAssertEqual(jsonl.displayName, "Codex session") }
        withLocale("zh-Hans") {
            XCTAssertEqual(jsonl.displayName, "Codex 会话")
            XCTAssertEqual(jsonl.name, "Codex session", "the stored name must stay English")
            // A cloud row that happens to carry the same words is someone else's name.
            XCTAssertEqual(record(id: "uuid-1", name: "Codex session").displayName, "Codex session")
        }
    }

    /// The labels the Mac sends as `client_label` stay English on the wire and in
    /// the helper; only the row title is translated.
    func testManagedSessionLabelsTheAppSendsAreTranslatedWhereShown() {
        XCTAssertEqual(ProviderDisplay.localStartClientLabel(for: "codex"), "Local Codex session")
        XCTAssertEqual(ProviderDisplay.inAppTerminalClientLabel, "in-app-terminal")
        withLocale("en") {
            XCTAssertEqual(ProviderDisplay.managedRowLabel(
                clientLabel: "Local Codex session", deviceName: "Mac", provider: "codex"), "Local Codex session")
        }
        withLocale("zh-Hans") {
            XCTAssertEqual(ProviderDisplay.managedRowLabel(
                clientLabel: ProviderDisplay.localStartClientLabel(for: "codex"), deviceName: "Mac", provider: "codex"),
                "本地 Codex 会话")
            XCTAssertEqual(ProviderDisplay.clientLabelDisplay("in-app-terminal", provider: "claude"), "Claude 应用内终端")
            // Another provider's local label is not this row's; a phone's own name is the sender's text.
            XCTAssertEqual(ProviderDisplay.clientLabelDisplay("Local Claude session", provider: "codex"),
                           "Local Claude session")
            XCTAssertEqual(ProviderDisplay.managedRowLabel(
                clientLabel: "Office iPhone", deviceName: "Mac", provider: "claude"), "Office iPhone")
            // The existing fallbacks are unchanged.
            XCTAssertEqual(ProviderDisplay.managedRowLabel(clientLabel: " ", deviceName: "Mac", provider: "gemini"),
                           L10n.sessions.rowFallbackLabel("Gemini"))
            XCTAssertEqual(ProviderDisplay.managedRowLabel(clientLabel: "mac", deviceName: "Mac", provider: "claude"),
                           L10n.sessions.rowLabelOnDevice("Claude", "Mac"))
        }
    }

    // MARK: - Provider service status

    /// The badge used to show Statuspage's own English ("Minor Service Outage").
    func testServiceStatusBadgeUsesTheLocalizedSeverityAndKeepsTheVendorTextAsDetail() {
        let snapshot = ServiceStatusSnapshot(provider: .claude, indicator: .minor,
                                             description: "Partially Degraded Service", updatedAt: nil, pageURL: nil)
        withLocale("ja") {
            XCTAssertEqual(ServiceStatusIndicator.minor.localizedLabel, L10n.status.degraded)
            XCTAssertEqual(ServiceStatusIndicator.major.localizedLabel, L10n.status.partialOutage)
            XCTAssertEqual(ServiceStatusIndicator.critical.localizedLabel, L10n.status.majorOutage)
            XCTAssertEqual(ServiceStatusIndicator.maintenance.localizedLabel, L10n.status.maintenance)
            XCTAssertEqual(snapshot.indicator.localizedLabel, "性能低下")
            XCTAssertEqual(snapshot.badgeHelp, "性能低下\nPartially Degraded Service")
        }
        let bare = ServiceStatusSnapshot(provider: .claude, indicator: .critical,
                                         description: "", updatedAt: nil, pageURL: nil)
        withLocale("zh-Hans") { XCTAssertEqual(bare.badgeHelp, L10n.status.majorOutage) }
    }

    // MARK: - PDF report

    #if canImport(PDFKit) && !os(watchOS)
    /// The Top Sessions table has localized headers; its status cell printed the
    /// stored token ("running") under them.
    func testPDFTopSessionsStatusCellIsLocalized() {
        let s = SessionRecord(id: "s1", name: "claude", provider: "Claude", project: "p", device_name: "Mac",
                              started_at: "2026-05-05T03:50:00Z", last_active_at: "2026-05-05T03:54:00Z",
                              status: "running", total_usage: 1200, estimated_cost: 1.5, cost_status: "Estimated",
                              requests: 3, error_count: 0)
        withLocale("ja") {
            let row = PDFReportGenerator.topSessionRow(s)
            XCTAssertEqual(row.last, L10n.status.running)
            XCTAssertEqual(row.last, "実行中")
            XCTAssertEqual(s.status, "running")
        }
    }
    #endif

    // MARK: - Webhook filter

    /// The chips' raw values are stored, synced and matched by the webhook
    /// sender; only what the chip says is translated.
    func testWebhookFilterChipsShowWordsAndKeepRawValues() {
        XCTAssertEqual(WebhookEventFilter.selectableSeverities, ["Critical", "Warning", "Info"])
        XCTAssertEqual(WebhookEventFilter.selectableTypes,
                       ["cost_spike", "quota_exceeded", "session_long", "device_offline"])
        withLocale("zh-Hans") {
            for raw in WebhookEventFilter.selectableTypes + WebhookEventFilter.selectableSeverities {
                let label = raw.contains("_") ? WebhookEventFilter.typeLabel(raw) : WebhookEventFilter.severityLabel(raw)
                XCTAssertNil(label.range(of: "[A-Za-z]", options: .regularExpression),
                             "\(raw) -> \(label) is still English")
            }
            XCTAssertEqual(WebhookEventFilter.typeLabel("device_offline"), "设备离线")
            XCTAssertEqual(WebhookEventFilter.typeLabel("some_new_type"), "some_new_type")
        }
    }
}
